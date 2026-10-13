import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/call_service.dart';
import '../watch/watch_player.dart';
import '../watch/watch_protocol.dart';
import '../watch/watch_runtime.dart';
import 'call_context.dart';
import 'swipe_controller.dart' show TimerFactory;

enum WatchPhase { idle, offering, incoming, preparing, watching }

/// Lời mời xem/nghe chung.
class WatchOffer {
  const WatchOffer({required this.id, required this.name, required this.size, required this.mime});

  final String id;
  final String name;
  final int size;
  final String mime;

  bool get audioOnly => mime.startsWith('audio/');

  static WatchOffer? tryParse(Map<String, dynamic> m) {
    final id = m['id'];
    final name = m['name'];
    final size = m['size'];
    final mime = m['mime'];
    if (id is! String || id.isEmpty || id.length > 64) return null;
    if (name is! String || name.length > 200) return null;
    if (size is! int || size <= 0) return null;
    if (mime is! String || !(mime.startsWith('video/') || mime.startsWith('audio/'))) return null;
    return WatchOffer(id: id, name: name, size: size, mime: mime);
  }
}

/// Xem phim / nghe nhạc chung trong cuộc gọi danh bạ (P2P, tệp ở máy chủ tệp, người kia phát trực tiếp qua kênh `media`).
///
/// Tin điều khiển đi qua DataChannel JSON `cham` (`watch.*`); byte tệp đi qua kênh nhị phân `media`.
/// Chỉ chạy khi gọi P2P trực tiếp và KHÔNG ở chế độ riêng tư (tránh đẩy video nặng qua TURN).
class WatchTogetherController extends ChangeNotifier {
  WatchTogetherController({
    required CallService call,
    required RoomSource room,
    required WatchRuntime runtime,
    bool Function()? relayOnly,
    TimerFactory? timerFactory,
    String Function()? idGen,
  })  : _call = call,
        _room = room,
        _runtime = runtime,
        _relayOnly = relayOnly ?? (() => false),
        _timer = timerFactory ?? Timer.new,
        _idGen = idGen ?? (() => DateTime.now().microsecondsSinceEpoch.toString()) {
    _dataSub = _call.dataMessages.listen(_onData);
    _room.addListener(_onRoomChanged);
    _lastRoom = _room.roomName;
  }

  static const heartbeat = Duration(seconds: 3);
  static const offerTimeout = Duration(seconds: 60);
  /// Gửi lại lời mời định kỳ cho tới khi có trả lời (kênh dữ liệu có thể vừa mở, tin đầu có thể rơi).
  static const resendEvery = Duration(seconds: 3);

  final CallService _call;
  final RoomSource _room;
  final WatchRuntime _runtime;
  final bool Function() _relayOnly;
  final TimerFactory _timer;
  final String Function() _idGen;

  late final StreamSubscription<Map<String, dynamic>> _dataSub;
  final StreamController<String> _notices = StreamController<String>.broadcast();

  WatchPhase _phase = WatchPhase.idle;
  WatchOffer? _offer;
  PickedMedia? _picked;
  bool _isHost = false;
  WatchSession? _session;
  Timer? _beat;
  Timer? _offerTimer;
  Timer? _resendTimer;
  String? _lastRoom;
  bool _applying = false;
  bool _disposed = false;

  WatchPhase get phase => _phase;
  WatchOffer? get offer => _offer;
  bool get isHost => _isHost;
  WatchPlayer? get player => _session?.player;

  /// `WATCH_*` mã thông báo cho UI.
  Stream<String> get notices => _notices.stream;

  BinaryChannel? get _bin => _call is BinaryChannel ? _call as BinaryChannel : null;

  /// Lý do chưa dùng được, hoặc null nếu dùng được ngay.
  String? get unavailableReason {
    if (_relayOnly()) return 'WATCH_PRIVACY';
    final b = _bin;
    if (b == null || !b.binaryOpen) return 'WATCH_NO_CHANNEL';
    return null;
  }

  // --- hành động của người dùng ---------------------------------------------------

  /// Chọn tệp rồi mời người kia. Trả mã lỗi nếu không làm được.
  Future<String?> startOffer({bool audio = false, PickedMedia? picked}) async {
    if (_phase != WatchPhase.idle) return 'WATCH_BUSY';
    final why = unavailableReason;
    if (why != null) return why;
    final media = picked ?? await _runtime.pick(audio: audio);
    if (media == null) return null;
    if (_phase != WatchPhase.idle) return 'WATCH_BUSY';
    if (mimeForName(media.name) == 'application/octet-stream') return 'WATCH_ERROR'; // định dạng chưa hỗ trợ
    final id = _idGen();
    _picked = media;
    _offer = WatchOffer(id: id, name: media.name, size: media.size, mime: mimeForName(media.name));
    _isHost = true;
    _phase = WatchPhase.offering;
    if (!_sendOffer()) {
      // Kênh chưa mở: báo ngay thay vì để người dùng chờ vô ích.
      _offer = null;
      _picked = null;
      _isHost = false;
      _phase = WatchPhase.idle;
      _notify();
      return 'WATCH_NO_CHANNEL';
    }
    _scheduleResend();
    _offerTimer = _timer(offerTimeout, () {
      _offerTimer = null;
      if (_phase == WatchPhase.offering) {
        _send('watch.stop');
        _emit('WATCH_NO_ANSWER');
        _teardown();
      }
    });
    _notify();
    return null;
  }

  bool _sendOffer() {
    final o = _offer;
    if (o == null) return false;
    return _call.sendData(<String, dynamic>{'type': 'watch.offer', 'id': o.id, 'name': o.name, 'size': o.size, 'mime': o.mime});
  }

  void _scheduleResend() {
    _resendTimer?.cancel();
    _resendTimer = _timer(resendEvery, () {
      _resendTimer = null;
      if (_disposed || _phase != WatchPhase.offering) return;
      _sendOffer(); // cùng id: bên nhận bỏ qua nếu đã có
      _scheduleResend();
    });
  }

  /// Người nhận đồng ý xem.
  Future<void> accept() async {
    final o = _offer;
    final b = _bin;
    if (_phase != WatchPhase.incoming || o == null || b == null) return;
    _phase = WatchPhase.preparing;
    _notify();
    try {
      final s = await _runtime.openViewer(b, size: o.size, mime: o.mime);
      if (_offer?.id != o.id || _phase != WatchPhase.preparing) {
        await s.close();
        return;
      }
      _session = s;
      _send('watch.accept');
      await s.player.init();
      if (_offer?.id != o.id) return;
      s.player.changes.addListener(_notify);
      _phase = WatchPhase.watching;
      _notify();
    } on Object catch (e) {
      debugPrint('watch accept failed: $e');
      if (_offer?.id == o.id) {
        _send('watch.stop');
        _emit('WATCH_ERROR');
        await _teardownAsync();
      }
    }
  }

  void decline() {
    if (_phase != WatchPhase.incoming) return;
    _send('watch.decline');
    _teardown();
  }

  /// Dừng (cả hai bên đều dừng được). Hủy lời mời nếu chưa ai nhận.
  void stop() {
    if (_phase == WatchPhase.idle) return;
    _send('watch.stop');
    _teardown();
  }

  Future<void> togglePlay() async {
    final p = player;
    if (p == null || _phase != WatchPhase.watching) return;
    if (p.playing) {
      await p.pause();
    } else {
      await p.play();
    }
    _sendState();
  }

  Future<void> seekTo(int ms) async {
    final p = player;
    if (p == null || _phase != WatchPhase.watching) return;
    await p.seekTo(ms.clamp(0, p.durationMs).toInt());
    _sendState();
  }

  // --- tin từ đối phương -------------------------------------------------------------

  void _onData(Map<String, dynamic> m) {
    final type = m['type'];
    if (type is! String || !type.startsWith('watch.')) return;
    switch (type) {
      case 'watch.offer':
        final o = WatchOffer.tryParse(m);
        if (o == null) return;
        if (_offer?.id == o.id && _phase != WatchPhase.idle) return; // lời mời gửi lại: đã xử lý
        if (_phase != WatchPhase.idle) {
          // Đang bận: từ chối thẳng để bên kia khỏi chờ.
          _call.sendData(<String, dynamic>{'type': 'watch.decline', 'id': o.id});
          return;
        }
        _offer = o;
        _isHost = false;
        _phase = WatchPhase.incoming;
        _emit('WATCH_INCOMING'); // báo thêm bằng thông báo nổi + rung, phòng khi thẻ lời mời bị che
        _notify();
      case 'watch.accept':
        if (!_mine(m) || _phase != WatchPhase.offering) return;
        _resendTimer?.cancel();
        _resendTimer = null;
        unawaited(_startHosting());
      case 'watch.decline':
        if (!_mine(m) || _phase != WatchPhase.offering) return;
        _resendTimer?.cancel();
        _resendTimer = null;
        _emit('WATCH_DECLINED');
        _teardown();
      case 'watch.stop':
        if (_offer == null || m['id'] != _offer!.id) return;
        if (_phase != WatchPhase.idle) {
          _emit('WATCH_STOPPED_BY_PEER');
          _teardown();
        }
      case 'watch.state':
        if (_phase != WatchPhase.watching || !_mine(m)) return;
        final playing = m['playing'];
        final pos = m['pos'];
        if (playing is! bool || pos is! int) return;
        unawaited(_applyRemote(playing, pos));
    }
  }

  bool _mine(Map<String, dynamic> m) => _offer != null && m['id'] == _offer!.id;

  Future<void> _startHosting() async {
    final o = _offer;
    final media = _picked;
    final b = _bin;
    if (o == null || media == null || b == null) return;
    _offerTimer?.cancel();
    _offerTimer = null;
    try {
      final s = await _runtime.openHost(b, media);
      if (_offer?.id != o.id) {
        await s.close();
        return;
      }
      _session = s;
      await s.player.init();
      if (_offer?.id != o.id) return;
      s.player.changes.addListener(_notify);
      _phase = WatchPhase.watching;
      _notify();
      await s.player.play();
      _sendState();
      _scheduleBeat();
    } on Object catch (e) {
      debugPrint('watch host failed: $e');
      if (_offer?.id == o.id) {
        _send('watch.stop');
        _emit('WATCH_ERROR');
        await _teardownAsync();
      }
    }
  }

  Future<void> _applyRemote(bool playing, int pos) async {
    final p = player;
    if (p == null) return;
    _applying = true;
    try {
      final target = driftTarget(localMs: p.positionMs, remoteMs: pos, thresholdMs: playing ? 800 : 250);
      if (target != null) await p.seekTo(target);
      if (playing && !p.playing) {
        await p.play();
      } else if (!playing && p.playing) {
        await p.pause();
      }
    } finally {
      _applying = false;
    }
  }

  // --- tiện ích ---------------------------------------------------------------------------

  void _send(String type) {
    final id = _offer?.id;
    if (id == null) return;
    _call.sendData(<String, dynamic>{'type': type, 'id': id});
  }

  void _sendState() {
    final p = player;
    final id = _offer?.id;
    if (p == null || id == null || _applying) return;
    _call.sendData(<String, dynamic>{'type': 'watch.state', 'id': id, 'playing': p.playing, 'pos': p.positionMs});
  }

  void _scheduleBeat() {
    _beat?.cancel();
    _beat = _timer(heartbeat, () {
      _beat = null;
      if (_phase != WatchPhase.watching) return;
      if (_isHost) _sendState(); // chủ tệp là chuẩn thời gian
      _scheduleBeat();
    });
  }

  void _onRoomChanged() {
    final room = _room.roomName;
    if (room == _lastRoom) return;
    _lastRoom = room;
    if (_phase != WatchPhase.idle) _teardown(); // hết/đổi cuộc gọi: dọn, không cần báo (kênh đã đóng)
  }

  void _teardown() => unawaited(_teardownAsync());

  Future<void> _teardownAsync() async {
    _beat?.cancel();
    _beat = null;
    _offerTimer?.cancel();
    _offerTimer = null;
    _resendTimer?.cancel();
    _resendTimer = null;
    final s = _session;
    _session = null;
    _offer = null;
    _picked = null;
    _isHost = false;
    _phase = WatchPhase.idle;
    _notify();
    if (s != null) {
      s.player.changes.removeListener(_notify);
      try {
        await s.close();
      } on Object catch (e) {
        debugPrint('watch close ignored: $e');
      }
    }
  }

  void _emit(String code) {
    if (!_notices.isClosed) _notices.add(code);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _room.removeListener(_onRoomChanged);
    unawaited(_dataSub.cancel());
    _beat?.cancel();
    _offerTimer?.cancel();
    _resendTimer?.cancel();
    final s = _session;
    _session = null;
    if (s != null) unawaited(s.close());
    unawaited(_notices.close());
    super.dispose();
  }
}
