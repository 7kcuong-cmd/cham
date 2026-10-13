import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/call_service.dart';
import '../services/screen_recorder.dart';
import 'call_context.dart';
import 'swipe_controller.dart' show TimerFactory;

/// Mục đích ghi hình – người nhận thấy rõ khi được xin phép.
enum RecPurpose { private, public }

enum RecState { idle, requesting, asking, recording }

/// Ghi hình cuộc gọi CHỈ KHI CẢ HAI ĐỒNG Ý (xem DIEU-KHOAN-GHI-HINH.md §1–3).
/// Giao thức đi thẳng qua DataChannel: `rec.request` / `rec.accept` / `rec.deny` / `rec.stop`.
/// Không có đường ghi nào bỏ qua `rec.accept`; mất kênh, đổi phòng hoặc bên nào dừng thì dừng ngay.
class RecordingController extends ChangeNotifier {
  RecordingController({
    required CallService call,
    required RoomSource room,
    required ScreenRecorder recorder,
    TimerFactory? timerFactory,
    String Function()? newId,
    DateTime Function()? now,
    this.onConsentLog,
  })  : _call = call,
        _room = room,
        _recorder = recorder,
        _timerFactory = timerFactory ?? Timer.new,
        _newId = newId ?? _randomId,
        _now = now ?? DateTime.now {
    _sub = _call.dataMessages.listen(_onData);
    final r = _recorder;
    if (r is ExternalStopSource) _extSub = (r as ExternalStopSource).externalStops.listen(_onExternalStop);
    _room.addListener(_onRoomChanged);
    _lastRoom = _room.roomName;
  }

  static const askTimeout = Duration(seconds: 15);
  static const maxRequestsPerCall = 2;
  static const maxDuration = Duration(seconds: 60);

  final CallService _call;
  final RoomSource _room;
  final ScreenRecorder _recorder;
  final TimerFactory _timerFactory;
  final String Function() _newId;
  final DateTime Function() _now;

  /// Nhật ký đồng ý lưu trên máy (dùng khi báo cáo vi phạm). Mỗi dòng là một sự kiện.
  final void Function(Map<String, Object?> entry)? onConsentLog;

  late final StreamSubscription<Map<String, dynamic>> _sub;
  StreamSubscription<String?>? _extSub;
  RecState _state = RecState.idle;
  RecPurpose? _purpose;
  String? _recId;
  bool _iRecord = false;
  Timer? _askTimer;
  Timer? _maxTimer;
  int _requests = 0;
  String? _lastRoom;
  String? _notice;
  String? _lastClipPath;
  bool _lastClipShareable = false;
  bool _disposed = false;

  /// Đang gọi `recorder.start()` (hộp thoại quyền chụp màn hình có thể mở rất lâu): đã làm mờ đối phương từ trước khi
  /// khung hình đầu tiên được ghi, không để lộ mặt họ trong vài giây đầu của clip.
  bool _starting = false;

  static String _randomId() {
    final r = Random.secure();
    return List<String>.generate(12, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  RecState get state => _state;
  RecPurpose? get purpose => _purpose;
  bool get isRecording => _state == RecState.recording;

  /// Máy này đang là máy ghi (khác máy chỉ "bị ghi").
  bool get iAmRecording => _iRecord && (isRecording || _starting);

  /// Có thể xin ghi: máy hỗ trợ, đang trong phòng, rảnh, chưa quá số lần.
  bool get canRequest =>
      _recorder.supported && _room.roomName != null && _state == RecState.idle && _requests < maxRequestsPerCall;

  /// Mã thông báo cho UI (`rec_denied`, `rec_timeout`, `rec_failed`, `rec_unsupported`, `rec_ended`); đọc xong gọi [clearNotice].
  String? get notice => _notice;

  /// Clip vừa ghi xong và có được chia sẻ công khai không (chỉ khi mục đích public đã được đồng ý).
  String? get lastClipPath => _lastClipPath;
  bool get lastClipShareable => _lastClipShareable;

  void clearLastClip() {
    _lastClipPath = null;
    _lastClipShareable = false;
    notifyListeners();
  }

  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  /// Mình xin ghi.
  bool request(RecPurpose purpose) {
    if (!canRequest) {
      if (!_recorder.supported) _setNotice('rec_unsupported');
      return false;
    }
    final id = _newId();
    if (!_call.sendData(<String, dynamic>{'t': 'rec.request', 'recId': id, 'purpose': purpose.name})) {
      _setNotice('rec_failed');
      return false;
    }
    _requests++;
    _recId = id;
    _purpose = purpose;
    _iRecord = true;
    _state = RecState.requesting;
    _log('request_sent');
    _askTimer = _timerFactory(askTimeout, () {
      if (_state == RecState.requesting) {
        _reset();
        _setNotice('rec_timeout');
      }
    });
    notifyListeners();
    return true;
  }

  /// Mình trả lời yêu cầu của bên kia.
  void respond({required bool accept}) {
    if (_state != RecState.asking || _recId == null) return;
    _call.sendData(<String, dynamic>{'t': accept ? 'rec.accept' : 'rec.deny', 'recId': _recId});
    _log(accept ? 'accepted' : 'denied');
    _askTimer?.cancel();
    if (accept) {
      _iRecord = false;
      _state = RecState.recording;
    } else {
      _reset();
    }
    notifyListeners();
  }

  /// Dừng (bất kỳ bên nào). Máy ghi trả về đường dẫn clip qua [lastClipPath].
  Future<void> stop() async {
    if (_state == RecState.idle) return;
    final id = _recId;
    if (id != null) _call.sendData(<String, dynamic>{'t': 'rec.stop', 'recId': id});
    await _finish('stopped_local');
  }

  void _onData(Map<String, dynamic> m) {
    final t = m['t'];
    if (t is! String || !t.startsWith('rec.')) return;
    final id = m['recId'];
    if (id is! String) return;
    switch (t) {
      case 'rec.request':
        if (_state != RecState.idle) {
          // đang bận: từ chối thẳng
          _call.sendData(<String, dynamic>{'t': 'rec.deny', 'recId': id});
          return;
        }
        if (_room.roomName == null) return;
        _recId = id;
        _purpose = m['purpose'] == 'public' ? RecPurpose.public : RecPurpose.private;
        _iRecord = false;
        _state = RecState.asking;
        _log('request_received');
        _askTimer = _timerFactory(askTimeout, () {
          if (_state == RecState.asking) {
            _call.sendData(<String, dynamic>{'t': 'rec.deny', 'recId': _recId});
            _reset();
            notifyListeners();
          }
        });
        notifyListeners();
      case 'rec.accept':
        if (_state != RecState.requesting || id != _recId) return;
        _askTimer?.cancel();
        unawaited(_beginRecording());
      case 'rec.deny':
        if (_state != RecState.requesting || id != _recId) return;
        _log('denied_by_peer');
        _reset();
        _setNotice('rec_denied');
      case 'rec.stop':
        if (_state == RecState.idle || id != _recId) return;
        unawaited(_finish('stopped_by_peer'));
    }
  }

  Future<void> _beginRecording() async {
    _starting = true;
    notifyListeners(); // UI làm mờ đối phương NGAY, trước khi bộ ghi bắt đầu chụp
    final bool ok;
    try {
      ok = await _recorder.start();
    } on Object {
      _starting = false;
      if (!_disposed && _state == RecState.requesting) {
        _call.sendData(<String, dynamic>{'t': 'rec.stop', 'recId': _recId});
        _reset();
        _setNotice('rec_failed');
      }
      return;
    }
    _starting = false;
    if (_disposed || _state != RecState.requesting) {
      if (ok) await _recorder.stop();
      return;
    }
    if (!ok) {
      _call.sendData(<String, dynamic>{'t': 'rec.stop', 'recId': _recId});
      _reset();
      _setNotice('rec_failed');
      return;
    }
    _state = RecState.recording;
    _log('recording_started');
    _maxTimer = _timerFactory(maxDuration, () => unawaited(stop()));
    notifyListeners();
  }

  /// Người ghi bấm "Dừng" ở thông báo (giao diện đã ẩn nên không có nút trong app) hoặc hệ thống dừng ghi.
  void _onExternalStop(String? path) {
    if (!(_iRecord && (_state == RecState.recording || _starting))) return;
    final id = _recId;
    if (id != null) _call.sendData(<String, dynamic>{'t': 'rec.stop', 'recId': id});
    unawaited(_finish('stopped_external', knownPath: path));
  }

  Future<void> _finish(String why, {String? knownPath}) async {
    final wasMine = _iRecord && _state == RecState.recording;
    final purpose = _purpose;
    _log(why);
    _maxTimer?.cancel();
    _askTimer?.cancel();
    String? path;
    if (wasMine) path = knownPath ?? await _recorder.stop();
    _reset();
    if (wasMine && path != null) {
      _lastClipPath = path;
      _lastClipShareable = purpose == RecPurpose.public;
    }
    if (!_disposed) {
      _setNotice(wasMine ? null : 'rec_ended');
      notifyListeners();
    }
  }

  void _onRoomChanged() {
    final room = _room.roomName;
    if (room == _lastRoom) return;
    _lastRoom = room;
    _requests = 0;
    if (_state != RecState.idle) unawaited(_finish('room_changed'));
  }

  void _reset() {
    _askTimer?.cancel();
    _maxTimer?.cancel();
    _state = RecState.idle;
    _purpose = null;
    _recId = null;
    _iRecord = false;
    if (!_disposed) notifyListeners();
  }

  void _setNotice(String? n) {
    _notice = n;
    if (!_disposed) notifyListeners();
  }

  void _log(String event) {
    onConsentLog?.call(<String, Object?>{
      'event': event,
      'recId': _recId,
      'purpose': _purpose?.name,
      'room': _room.roomName,
      'at': _now().toUtc().toIso8601String(),
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _askTimer?.cancel();
    _maxTimer?.cancel();
    _room.removeListener(_onRoomChanged);
    unawaited(_sub.cancel());
    unawaited(_extSub?.cancel() ?? Future<void>.value());
    if (iAmRecording) unawaited(_recorder.stop());
    super.dispose();
  }
}
