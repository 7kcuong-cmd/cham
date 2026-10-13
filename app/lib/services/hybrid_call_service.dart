import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/match_found.dart';
import '../models/ws_messages.dart';
import 'call_quality.dart';
import 'call_service.dart';
import 'webrtc_call_service.dart';
import 'ws_client.dart';

enum _Mode { p2p, livekit }

/// Gọi video thử P2P trước; không nối được thì tự chuyển sang LiveKit Cloud; vẫn hỏng thì báo [NetworkPoor].
///
/// Thứ tự: (1) WebRTC trực tiếp (STUN/TURN) – chờ tối đa [p2pTimeout];
/// (2) gửi `rtc.fallback` → server mở phòng LiveKit cùng tên, gửi token cho CẢ HAI bên → cả hai `join`;
/// (3) quá [fallbackTimeout] mà vẫn chưa thấy video → [NetworkPoor] ("hãy đổi mạng").
/// Server không có khóa LIVEKIT_* thì trả lỗi → vào thẳng bước (3).
class HybridCallService implements CallService, BinaryChannel, QualityAware, FrameCapturable {
  HybridCallService(
    WsClient ws, {
    CallService? p2p,
    CallService? livekit,
    this.p2pTimeout = const Duration(seconds: 6),
    this.fallbackTimeout = const Duration(seconds: 12),
    this.relay = true,
  })  : _ws = ws,
        _p2p = p2p ?? WebRtcCallService(ws),
        _lk = livekit ?? LiveKitCallService() {
    _subs
      ..add(_p2p.events.listen(_onP2pEvent))
      ..add(_lk.events.listen(_onLiveKitEvent))
      ..add(_ws.messages.listen(_onServerMessage));
  }

  @override
  set callProfile(CallProfile profile) {
    final p = _p2p;
    if (p is QualityAware) (p as QualityAware).callProfile = profile;
  }

  final WsClient _ws;
  final CallService _p2p;
  final CallService _lk;
  final Duration p2pTimeout;
  final Duration fallbackTimeout;

  /// `false`: CHỈ P2P trực tiếp, không dùng relay (LiveKit/TURN). Không nối được → báo [NetworkPoor] ngay.
  final bool relay;

  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];
  final StreamController<CallEvent> _events = StreamController<CallEvent>.broadcast();
  final ValueNotifier<_Mode> _mode = ValueNotifier<_Mode>(_Mode.p2p);

  String? _room;
  bool _ready = false;
  bool _fallbackStarted = false;
  int _epoch = 0;
  Timer? _timer;

  @override
  Stream<CallEvent> get events => _events.stream;

  @override
  Stream<Map<String, dynamic>> get dataMessages => _p2p.dataMessages;

  @override
  bool sendData(Map<String, dynamic> message) => _mode.value == _Mode.p2p && _p2p.sendData(message);

  // Kênh nhị phân chỉ có khi gọi P2P trực tiếp (không qua LiveKit) và bản P2P hỗ trợ.
  @override
  Future<Uint8List?> captureLocalFrame() async {
    final p = _p2p;
    if (_mode.value != _Mode.p2p || p is! FrameCapturable) return null;
    return (p as FrameCapturable).captureLocalFrame();
  }

  @override
  Future<Uint8List?> captureRemoteFrame() async {
    final p = _p2p;
    if (_mode.value != _Mode.p2p || p is! FrameCapturable) return null;
    return (p as FrameCapturable).captureRemoteFrame();
  }

  BinaryChannel? get _bin => _p2p is BinaryChannel ? _p2p as BinaryChannel : null;

  @override
  Stream<Uint8List> get binaryMessages => _bin?.binaryMessages ?? const Stream<Uint8List>.empty();

  @override
  bool get binaryOpen => _mode.value == _Mode.p2p && (_bin?.binaryOpen ?? false);

  @override
  bool sendBinary(Uint8List data) => _mode.value == _Mode.p2p && (_bin?.sendBinary(data) ?? false);

  @override
  int get binaryBuffered => _bin?.binaryBuffered ?? 0;

  @override
  Future<void> join(String url, String token) async {
    await leave();
    _mode.value = _Mode.livekit;
    await _lk.join(url, token);
  }

  @override
  Future<void> joinMatch(MatchFound match) async {
    await leave();
    final epoch = ++_epoch;
    if (match.rtc == null) {
      // Server chạy LiveKit thuần.
      _mode.value = _Mode.livekit;
      return _lk.join(match.livekitUrl, match.token);
    }
    _mode.value = _Mode.p2p;
    _room = match.roomName;
    _timer = Timer(p2pTimeout, () {
      if (epoch == _epoch && !_ready) unawaited(_startFallback(epoch));
    });
    try {
      await _p2p.joinMatch(match);
    } on Object catch (e) {
      debugPrint('P2P join failed: $e');
      if (epoch == _epoch && !_ready) unawaited(_startFallback(epoch));
    }
  }

  // --- sự kiện ----------------------------------------------------------------------

  void _onP2pEvent(CallEvent e) {
    if (_mode.value != _Mode.p2p) return; // đã chuyển sang LiveKit: bỏ qua mọi thứ của P2P
    switch (e) {
      case RemoteVideoReady():
        _ready = true;
        _timer?.cancel();
        _events.add(e);
      case Disconnected():
        if (!_ready) {
          unawaited(_startFallback(_epoch)); // ICE hỏng trước khi nối được
        } else {
          _events.add(e);
        }
      case RemoteLeft():
        // `bye` của đối phương. Nếu họ đang chuyển sang LiveKit thì rtc.fallback sẽ tới ngay; không bỏ cuộc gọi.
        if (_fallbackStarted) return;
        _events.add(e);
      case NetworkPoor():
        _timer?.cancel();
        _events.add(e);
      case CallQualityChanged():
      case CallReconnecting():
      case CallReconnected():
        _events.add(e);
      case PeerAnomaly():
        // Không chuyển sang LiveKit: đối phương đáng ngờ, cắt hẳn.
        _timer?.cancel();
        _events.add(e);
    }
  }

  void _onLiveKitEvent(CallEvent e) {
    if (_mode.value != _Mode.livekit) return;
    switch (e) {
      case RemoteVideoReady():
        _ready = true;
        _timer?.cancel();
        _events.add(e);
      default:
        _events.add(e);
    }
  }

  // --- dự phòng ---------------------------------------------------------------------

  Future<void> _startFallback(int epoch) async {
    if (epoch != _epoch || _fallbackStarted || _ready) return;
    if (!relay) {
      _fail(epoch);
      return;
    }
    final room = _room;
    if (room == null) return;
    _fallbackStarted = true;
    _timer?.cancel();
    // Hạn chót cho cả bước xin token + vào LiveKit + thấy video.
    _timer = Timer(fallbackTimeout, () {
      if (epoch == _epoch && !_ready) _fail(epoch);
    });
    _ws.send('rtc.fallback', <String, dynamic>{'roomName': room});
  }

  void _onServerMessage(ServerMessage m) {
    switch (m) {
      case final RtcFallback f:
        if (f.roomName != _room) return;
        unawaited(_switchToLiveKit(f));
      case final ServerError err:
        // Server không có LIVEKIT_* (CALL_PROVIDER_ERROR) trong lúc ta đang chờ token.
        if (_fallbackStarted && !_ready && _mode.value == _Mode.p2p && err.code == 'CALL_PROVIDER_ERROR') {
          _fail(_epoch);
        }
      default:
        break;
    }
  }

  Future<void> _switchToLiveKit(RtcFallback f) async {
    final epoch = _epoch;
    if (_mode.value == _Mode.livekit || _ready) return;
    _fallbackStarted = true; // bên kia kích hoạt trước: mình cũng chuyển
    _timer?.cancel();
    _timer = Timer(fallbackTimeout, () {
      if (epoch == _epoch && !_ready) _fail(epoch);
    });
    _mode.value = _Mode.livekit;
    try {
      final p2p = _p2p;
      // Im lặng: không gửi `bye`, vì đối phương cũng đang chuyển sang LiveKit trong cùng cuộc gọi.
      if (p2p is WebRtcCallService) {
        await p2p.leave(silent: true);
      } else {
        await p2p.leave();
      }
    } on Object catch (_) {}
    if (epoch != _epoch) return;
    try {
      await _lk.join(f.livekitUrl, f.token);
    } on Object catch (e) {
      debugPrint('LiveKit fallback join failed: $e');
      if (epoch == _epoch && !_ready) _fail(epoch);
    }
  }

  void _fail(int epoch) {
    if (epoch != _epoch) return;
    _timer?.cancel();
    _timer = null;
    _events.add(const NetworkPoor());
  }

  // --- giao diện / điều khiển -------------------------------------------------------

  CallService get _active => _mode.value == _Mode.livekit ? _lk : _p2p;

  @override
  Widget remoteView() => ValueListenableBuilder<_Mode>(
        valueListenable: _mode,
        builder: (context, m, _) => (m == _Mode.livekit ? _lk : _p2p).remoteView(),
      );

  @override
  Widget localView() => ValueListenableBuilder<_Mode>(
        valueListenable: _mode,
        builder: (context, m, _) => (m == _Mode.livekit ? _lk : _p2p).localView(),
      );

  @override
  Future<void> setMicEnabled(bool on) => _active.setMicEnabled(on);

  @override
  Future<void> setCameraEnabled(bool on) => _active.setCameraEnabled(on);

  @override
  Future<void> switchCamera() => _active.switchCamera();

  @override
  Future<void> leave() async {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _room = null;
    _ready = false;
    _fallbackStarted = false;
    await _p2p.leave();
    await _lk.leave();
    _mode.value = _Mode.p2p;
  }

  @override
  Future<void> dispose() async {
    await leave();
    for (final s in _subs) {
      await s.cancel();
    }
    await _p2p.dispose();
    await _lk.dispose();
    await _events.close();
    _mode.dispose();
  }
}
