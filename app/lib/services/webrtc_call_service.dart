import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../config/env.dart';
import '../models/match_found.dart';
import '../models/ws_messages.dart';
import '../theme/tokens.dart';
import '../security/ice_guard.dart';
import '../security/shield_controller.dart';
import '../state/privacy_settings.dart';
import 'beauty.dart';
import 'call_quality.dart';
import 'call_service.dart';
import 'ws_client.dart';

/// Gọi video P2P bằng WebRTC (flutter_webrtc), không qua máy chủ media.
///
/// - Server chỉ ghép cặp và chuyển tiếp tín hiệu `rtc.signal` (offer/answer/candidate/bye) qua WebSocket hiện có.
/// - `match.found.rtc` cho biết bên nào tạo offer (`initiator`) và danh sách STUN/TURN.
/// - Video/âm thanh đi thẳng giữa hai máy (ICE; cần TURN khi NAT đối xứng/CGNAT).
/// - Có DataChannel `cham` (JSON) để truyền tin thời gian thực giữa hai máy: xem [dataMessages]/[sendData].
///   LƯU Ý: điểm thưởng, phí và kết quả game vẫn do server xác nhận (game.* qua WebSocket) – kênh P2P chỉ để
///   giảm độ trễ hiển thị, KHÔNG thay trọng tài.
///
/// CHƯA biên dịch với SDK thật khi viết; đối chiếu API flutter_webrtc 1.x nếu CI báo lỗi tên lớp.
class WebRtcCallService implements CallService, BinaryChannel, QualityAware, FrameCapturable {
  WebRtcCallService(this._ws) {
    _sigSub = _ws.messages.listen(_onServerMessage);
    BeautySettings.instance.addListener(_onBeautyChanged);
  }

  final WsClient _ws;
  late final StreamSubscription<ServerMessage> _sigSub;

  final StreamController<CallEvent> _events = StreamController<CallEvent>.broadcast();
  final StreamController<Map<String, dynamic>> _data = StreamController<Map<String, dynamic>>.broadcast();
  final ValueNotifier<rtc.RTCVideoRenderer?> _remote = ValueNotifier<rtc.RTCVideoRenderer?>(null);
  final ValueNotifier<rtc.RTCVideoRenderer?> _local = ValueNotifier<rtc.RTCVideoRenderer?>(null);

  rtc.RTCPeerConnection? _pc;
  rtc.MediaStream? _localStream;
  rtc.RTCDataChannel? _channel;
  void _onBeautyChanged() => unawaited(BeautySettings.instance.applyTo(_localStream));

  rtc.RTCDataChannel? _media; // kênh nhị phân "media" (xem/nghe chung)
  final StreamController<Uint8List> _binary = StreamController<Uint8List>.broadcast();
  String? _room;
  bool _remoteSet = false;
  bool _remoteReadySent = false;
  bool _iceConnected = false;
  bool _hasRemoteVideo = false;
  bool _byeSent = false;

  // --- chất lượng khi đi qua relay (call_quality.dart) ---
  CallProfile _profile = CallProfile.swipe;
  CallQualityConfig _qcfg = const CallQualityConfig();
  RelayGovernor? _gov;
  Timer? _qualityTimer;
  Stopwatch _clock = Stopwatch();
  CallQualityLevel _appliedLevel = CallQualityLevel.full;
  CallPath _lastPath = CallPath.unknown;
  bool _initiator = false;
  bool _qualityBusy = false;
  int _qualityTicks = 0;
  int _p2pStable = 0;
  int _restarts = 0;

  @override
  set callProfile(CallProfile profile) => _profile = profile;

  // --- chống dò IP (CHONG-QUET-IP-P2P.md) ---
  IceGuard _guard = IceGuard();
  bool _guardOn = false;
  bool _relayPolicy = false;
  bool _anomalyFired = false;
  Timer? _statsTimer;
  int _statsTicks = 0;

  /// Đã gắn track camera/mic và (bên mời) gửi offer. Trước đó KHÔNG xử lý tín hiệu: nếu bên trả lời đặt remote offer
  /// trước khi `addTrack`, answer ra recvonly và hình của mình không bao giờ tới đối phương.
  bool _setupDone = false;
  int _epoch = 0;
  Timer? _graceTimer;

  // --- tự nối lại khi mạng ngắt (giữ phòng, thử ICE restart định kỳ) ---
  /// Cửa sổ tự nối lại: quá thời gian này mà chưa nối được mới báo [Disconnected].
  static const reconnectWindow = Duration(seconds: 20);
  static const reconnectEvery = Duration(seconds: 4);
  Timer? _reconnectTimer;
  Stopwatch? _reconnectClock;
  bool _reconnecting = false;
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  Timer? _netDebounce;
  Future<void> _chain = Future<void>.value();
  final List<RtcSignal> _early = <RtcSignal>[]; // tín hiệu đến trước khi joinMatch kịp chạy
  final List<rtc.RTCIceCandidate> _pendingCandidates = <rtc.RTCIceCandidate>[];

  @override
  Stream<CallEvent> get events => _events.stream;

  @override
  Stream<Map<String, dynamic>> get dataMessages => _data.stream;

  @override
  bool sendData(Map<String, dynamic> message) {
    final ch = _channel;
    if (ch == null || ch.state != rtc.RTCDataChannelState.RTCDataChannelOpen) return false;
    ch.send(rtc.RTCDataChannelMessage(jsonEncode(message)));
    return true;
  }

  @override
  Stream<Uint8List> get binaryMessages => _binary.stream;

  @override
  bool get binaryOpen => _media?.state == rtc.RTCDataChannelState.RTCDataChannelOpen;

  @override
  int get binaryBuffered => _media?.bufferedAmount ?? 0;

  @override
  bool sendBinary(Uint8List data) {
    final ch = _media;
    if (ch == null || ch.state != rtc.RTCDataChannelState.RTCDataChannelOpen) return false;
    ch.send(rtc.RTCDataChannelMessage.fromBinary(data));
    return true;
  }

  @override
  Future<void> join(String url, String token) {
    throw UnsupportedError('WebRtcCallService cần joinMatch (match.found.rtc)');
  }

  @override
  Future<void> joinMatch(MatchFound match) async {
    await leave();
    final info = match.rtc;
    if (info == null) {
      throw StateError('match.found không có cấu hình rtc – server chưa chạy CALL_PROVIDER=p2p');
    }
    final epoch = ++_epoch;
    _room = match.roomName;
    _remoteSet = false;
    _remoteReadySent = false;
    _iceConnected = false;
    _hasRemoteVideo = false;
    _byeSent = false;
    _setupDone = false;
    _userCamOn = true;
    _pendingCandidates.clear();
    _guardOn = Env.iceGuard && ShieldController.instance.enabled;
    _guard = IceGuard(strictIpv6: Env.iceGuardStrictIpv6);
    _anomalyFired = false;
    _statsTimer?.cancel();
    _statsTicks = 0;

    // Khiên đang bật (vừa gặp đối phương bất thường) và server có TURN: đi qua relay để không lộ IP.
    final shieldRelay = _guardOn &&
        ShieldController.instance.shieldActive &&
        PrivacySettings.iceConfig(info.iceServers, relayOnly: true) != null;
    final relayOnly = PrivacySettings.instance.relayOnly || shieldRelay;
    _relayPolicy = relayOnly;
    // Build bật RELAY (relay dự phòng cho mọi người): giữ nguyên danh sách server cấp.
    final hasTurn = info.iceServers.any(_isTurn);
    final keepTurn = (Env.relay || (Env.turnFallback && hasTurn)) && !relayOnly;
    final ice = keepTurn
        ? <String, dynamic>{'iceServers': info.iceServers}
        : PrivacySettings.iceConfig(info.iceServers, relayOnly: relayOnly);
    if (ice == null) {
      // Bật chế độ riêng tư nhưng máy chủ không có TURN: thà không gọi còn hơn lộ IP.
      _events.add(const NetworkPoor());
      return;
    }
    final pc = await rtc.createPeerConnection(<String, dynamic>{
      ...ice,
      'sdpSemantics': 'unified-plan',
    });
    if (epoch != _epoch) {
      await pc.close();
      return;
    }
    _pc = pc;
    _initiator = info.initiator;
    _watchNetwork(epoch);
    if (_guardOn) _startStats(epoch);
    if (keepTurn && hasTurn && Env.turnFallback) _startQuality(epoch);

    pc.onIceCandidate = (rtc.RTCIceCandidate c) {
      if (epoch != _epoch || c.candidate == null || _anomalyFired) return;
      var line = c.candidate!;
      if (_guardOn) {
        final clean = _guard.sanitizeOutgoing(line, relayOnly: _relayPolicy);
        if (clean == null) return; // L0: không đưa ứng viên này cho đối phương
        line = clean;
      }
      _signal('candidate', <String, dynamic>{
        'candidate': line,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onTrack = (rtc.RTCTrackEvent e) {
      if (epoch != _epoch || e.track.kind != 'video' || e.streams.isEmpty) return;
      unawaited(_attachRemote(epoch, e.streams.first));
    };
    pc.onConnectionState = (rtc.RTCPeerConnectionState s) {
      if (epoch != _epoch) return;
      switch (s) {
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _graceTimer?.cancel();
          _endReconnect(restored: true);
          _iceConnected = true;
          _guard.noteIceConnected();
          _maybeReady();
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // Mạng ngắt/chập chờn: KHÔNG bỏ cuộc ngay. Giữ phòng, thử nối lại (ICE restart) trong [reconnectWindow].
          _graceTimer?.cancel();
          if (_iceConnected) {
            _beginReconnect(epoch);
          } else {
            // Chưa từng nối được: để HybridCallService quyết định đường dự phòng như trước.
            _graceTimer = Timer(const Duration(seconds: 6), () {
              if (epoch == _epoch) _events.add(const Disconnected());
            });
          }
        default:
          break;
      }
    };
    pc.onDataChannel = (rtc.RTCDataChannel ch) {
      if (epoch == _epoch) _bindChannel(ch);
    };

    final stream = await rtc.navigator.mediaDevices.getUserMedia(<String, dynamic>{
      'audio': true,
      'video': <String, dynamic>{
        'facingMode': 'user',
        'width': <String, dynamic>{'ideal': 640},
        'height': <String, dynamic>{'ideal': 480},
        'frameRate': <String, dynamic>{'ideal': 24},
      },
    });
    if (epoch != _epoch) {
      await _disposeStream(stream);
      return;
    }
    _localStream = stream;
    await BeautySettings.instance.applyTo(stream);
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    final localRenderer = rtc.RTCVideoRenderer();
    await localRenderer.initialize();
    localRenderer.srcObject = stream;
    if (epoch != _epoch) {
      await localRenderer.dispose();
      return;
    }
    _local.value = localRenderer;

    if (info.initiator) {
      _bindChannel(await pc.createDataChannel('cham', rtc.RTCDataChannelInit()..ordered = true));
      _bindChannel(await pc.createDataChannel('media', rtc.RTCDataChannelInit()..ordered = true));
      final offer = await pc.createOffer(<String, dynamic>{});
      await pc.setLocalDescription(offer);
      if (epoch != _epoch) return;
      _signal('offer', <String, dynamic>{'sdp': _outSdp(offer.sdp), 'type': offer.type});
    }
    // Phát lại tín hiệu đến sớm (bên trả lời có thể nhận offer trước khi xong khởi tạo).
    _setupDone = true;
    final early = _early.where((s) => s.roomName == match.roomName).toList();
    _early.clear();
    for (final s in early) {
      _enqueue(s);
    }
  }

  void _bindChannel(rtc.RTCDataChannel ch) {
    if (ch.label == 'media') {
      _media = ch;
      ch.onMessage = (rtc.RTCDataChannelMessage m) {
        if (m.isBinary && !_binary.isClosed) _binary.add(m.binary);
      };
      return;
    }
    _channel = ch;
    ch.onMessage = (rtc.RTCDataChannelMessage m) {
      if (m.isBinary) return;
      try {
        final decoded = jsonDecode(m.text);
        if (decoded is Map && !_data.isClosed) _data.add(Map<String, dynamic>.from(decoded));
      } on FormatException {
        // bỏ tin hỏng
      }
    };
  }

  Future<void> _attachRemote(int epoch, rtc.MediaStream stream) async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    if (epoch != _epoch) {
      await renderer.dispose();
      return;
    }
    renderer.srcObject = stream;
    final old = _remote.value;
    _remote.value = renderer;
    if (old != null) unawaited(old.dispose());
    _hasRemoteVideo = true;
    _maybeReady();
  }

  /// Chỉ báo "đã thấy video" khi ICE đã nối XONG và có track video (track xuất hiện từ lúc đàm phán, trước khi nối được).
  void _maybeReady() {
    if (_remoteReadySent || !_iceConnected || !_hasRemoteVideo) return;
    _remoteReadySent = true;
    _guard.noteMedia();
    _events.add(const RemoteVideoReady());
  }

  void _signal(String kind, Map<String, dynamic> payload) {
    final room = _room;
    if (room == null) return;
    _ws.send('rtc.signal', <String, dynamic>{'roomName': room, 'kind': kind, 'payload': payload});
  }

  // --- chống dò IP --------------------------------------------------------------

  String? _outSdp(String? sdp) =>
      (sdp == null || !_guardOn) ? sdp : _guard.sanitizeSdp(sdp, outgoing: true, relayOnly: _relayPolicy);

  String? _inSdp(String? sdp) =>
      (sdp == null || !_guardOn) ? sdp : _guard.sanitizeSdp(sdp, outgoing: false);

  /// Nếu đã vượt ngưỡng bất thường: báo một lần, dừng gửi/nhận ứng viên và dừng đọc thống kê. `true` = đã cắt.
  bool _checkAnomaly() {
    if (_anomalyFired) return true;
    if (!_guardOn || !_guard.anomaly) return false;
    _anomalyFired = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    _events.add(PeerAnomaly(_guard.signals));
    return true;
  }

  void _startStats(int epoch) {
    _statsTimer?.cancel();
    _statsTicks = 0;
    // 1 giây/lần trong 20 giây đầu (lúc ICE dò), sau đó 5 giây/lần.
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (epoch != _epoch) return;
      _statsTicks++;
      if (_statsTicks > 20 && _statsTicks % 5 != 0) return;
      unawaited(_pollStats(epoch));
    });
  }

  Future<void> _pollStats(int epoch) async {
    final pc = _pc;
    if (pc == null || epoch != _epoch || _anomalyFired) return;
    try {
      final reports = await pc.getStats();
      if (epoch != _epoch || _anomalyFired) return;
      _guard.onStats(<StatReport>[
        for (final r in reports) StatReport(r.type, Map<String, dynamic>.from(r.values)),
      ]);
      _guard.tick();
      _checkAnomaly();
    } on Object catch (e) {
      debugPrint('getStats ignored: $e');
    }
  }

  // --- nhận tín hiệu --------------------------------------------------------------

  void _onServerMessage(ServerMessage m) {
    if (m is! RtcSignal) return;
    if (_room == null || m.roomName != _room) {
      if (_early.length < 64) _early.add(m);
      return;
    }
    _enqueue(m);
  }

  void _enqueue(RtcSignal s) {
    final epoch = _epoch;
    _chain = _chain.then((_) async {
      if (epoch != _epoch) return;
      try {
        await _handleSignal(s);
      } on Object catch (e) {
        debugPrint('rtc.signal ${s.kind} failed: $e');
      }
    });
  }

  Future<void> _handleSignal(RtcSignal s) async {
    if (_anomalyFired) return; // đã quyết định cắt: không xử lý thêm gì từ đối phương
    final pc = _pc;
    if (pc == null || !_setupDone) {
      // joinMatch chưa gắn xong track/kênh dữ liệu: giữ lại, joinMatch sẽ phát lại ở cuối.
      if (_early.length < 64) _early.add(s);
      return;
    }
    switch (s.kind) {
      case 'offer':
        await pc.setRemoteDescription(rtc.RTCSessionDescription(_inSdp(s.payload['sdp'] as String?), s.payload['type'] as String? ?? 'offer'));
        if (_checkAnomaly()) return;
        _remoteSet = true;
        await _flushCandidates(pc);
        final answer = await pc.createAnswer(<String, dynamic>{});
        await pc.setLocalDescription(answer);
        _signal('answer', <String, dynamic>{'sdp': _outSdp(answer.sdp), 'type': answer.type});
      case 'answer':
        await pc.setRemoteDescription(rtc.RTCSessionDescription(_inSdp(s.payload['sdp'] as String?), s.payload['type'] as String? ?? 'answer'));
        if (_checkAnomaly()) return;
        _remoteSet = true;
        await _flushCandidates(pc);
      case 'candidate':
        if (_guardOn) {
          final verdict = _guard.checkIncoming(s.payload['candidate'] as String?);
          if (_checkAnomaly() || verdict == IncomingVerdict.drop) return;
        }
        final cand = rtc.RTCIceCandidate(
          s.payload['candidate'] as String?,
          s.payload['sdpMid'] as String?,
          (s.payload['sdpMLineIndex'] as num?)?.toInt(),
        );
        if (_remoteSet) {
          await pc.addCandidate(cand);
        } else {
          _pendingCandidates.add(cand);
        }
      case 'bye':
        _guard.noteRemoteLeft();
        _events.add(const RemoteLeft());
    }
  }

  Future<void> _flushCandidates(rtc.RTCPeerConnection pc) async {
    final list = List<rtc.RTCIceCandidate>.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final c in list) {
      await pc.addCandidate(c);
    }
  }

  // --- chất lượng / relay ---------------------------------------------------------

  static bool _isTurn(Map<String, dynamic> server) {
    final u = server['urls'];
    final list = u is List ? u : <Object?>[u];
    return list.any((x) => x is String && (x.startsWith('turn:') || x.startsWith('turns:')));
  }

  /// Bắt đầu theo dõi đường truyền thực tế (1 s/lần lúc chưa ổn định) và áp dụng [RelayGovernor].
  void _startQuality(int epoch) {
    _stopQuality();
    _gov = RelayGovernor(profile: _profile, config: _qcfg);
    _clock = Stopwatch()..start();
    _appliedLevel = CallQualityLevel.full;
    _lastPath = CallPath.unknown;
    _qualityTicks = 0;
    _p2pStable = 0;
    _restarts = 0;
    _qualityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (epoch != _epoch) return;
      _qualityTicks++;
      // P2P đã ổn định thì chỉ cần liếc mỗi 5 s (đỡ tốn pin); chưa ổn định thì mỗi giây.
      if (_p2pStable >= 5 && _qualityTicks % 5 != 0) return;
      unawaited(_qualityTick(epoch));
    });
  }

  void _stopQuality() {
    _qualityTimer?.cancel();
    _qualityTimer = null;
    _gov = null;
    _clock.stop();
  }

  Future<void> _qualityTick(int epoch) async {
    final pc = _pc;
    final gov = _gov;
    if (pc == null || gov == null || epoch != _epoch || _qualityBusy) return;
    _qualityBusy = true;
    try {
      final reports = await pc.getStats();
      if (epoch != _epoch) return;
      final stats = <PathStat>[for (final r in reports) PathStat(r.id, r.type, Map<String, dynamic>.from(r.values))];
      final path = pathFromStats(stats);
      _p2pStable = path == CallPath.p2p ? _p2pStable + 1 : 0;
      final d = gov.evaluate(now: _clock.elapsed, path: path);

      if (d.level != _appliedLevel) await _applyLevel(d.level);
      if (path != _lastPath || d.notice != null) {
        _lastPath = path;
        _events.add(CallQualityChanged(level: d.level, path: path, notice: d.notice));
      }
      if (d.retryP2p && _initiator && _restarts < 3) {
        _restarts++;
        await _restartIce(epoch);
      }
      if (d.endCall) {
        _stopQuality();
        _events.add(const NetworkPoor()); // hiện thông báo mạng yếu + dừng cuộc gọi (SwipeController)
      }
    } on Object catch (e) {
      debugPrint('quality tick ignored: $e');
    } finally {
      _qualityBusy = false;
    }
  }

  /// Đổi giới hạn gửi (bitrate/độ phân giải/fps hoặc tắt hẳn video). Lỗi API thì dùng cách dự phòng: tắt track video.
  Future<void> _applyLevel(CallQualityLevel level) async {
    final pc = _pc;
    if (pc == null) return;
    _appliedLevel = level;
    final lim = SenderLimits.forLevel(level, _qcfg);
    try {
      for (final sender in await pc.getSenders()) {
        final kind = sender.track?.kind;
        if (kind == null) continue;
        final params = sender.parameters;
        final encs = params.encodings ?? <rtc.RTCRtpEncoding>[];
        if (encs.isEmpty) encs.add(rtc.RTCRtpEncoding());
        for (final e in encs) {
          if (kind == 'video') {
            e.active = lim.videoActive;
            if (lim.videoActive) {
              e.maxBitrate = lim.videoMaxBitrate;
              e.scaleResolutionDownBy = lim.scaleDown;
              e.maxFramerate = lim.maxFps;
            }
          } else {
            e.maxBitrate = lim.audioMaxBitrate;
          }
        }
        params.encodings = encs;
        await sender.setParameters(params);
      }
    } on Object catch (e) {
      debugPrint('setParameters failed, dùng cách dự phòng: $e');
    }
    // Dự phòng/đảm bảo: chỉ-tiếng thì track video không phát khung hình nào (camera người dùng bật/tắt riêng vẫn được tôn trọng).
    for (final t in _localStream?.getVideoTracks() ?? <rtc.MediaStreamTrack>[]) {
      t.enabled = lim.videoActive && _userCamOn;
    }
  }

  bool _userCamOn = true;

  @override
  Future<Uint8List?> captureRemoteFrame() async {
    final tracks = _remote.value?.srcObject?.getVideoTracks() ?? <rtc.MediaStreamTrack>[];
    if (tracks.isEmpty) return null;
    try {
      final buf = await tracks.first.captureFrame();
      return buf.asUint8List();
    } on Object {
      return null;
    }
  }

  /// Chụp một khung camera của mình (mặt lạ). flutter_webrtc trả PNG trên Android; lỗi/không có camera → null.
  @override
  Future<Uint8List?> captureLocalFrame() async {
    if (!_userCamOn) return null;
    final tracks = _localStream?.getVideoTracks() ?? <rtc.MediaStreamTrack>[];
    if (tracks.isEmpty) return null;
    try {
      final buf = await tracks.first.captureFrame();
      return buf.asUint8List();
    } on Object {
      return null;
    }
  }

  void _beginReconnect(int epoch) {
    if (_reconnectTimer != null || epoch != _epoch) return;
    _reconnecting = true;
    _events.add(const CallReconnecting());
    _reconnectClock = Stopwatch()..start();
    // Bên mời thử ngay rồi lặp lại; bên kia chờ offer mới.
    if (_initiator) unawaited(_restartIce(epoch));
    _reconnectTimer = Timer.periodic(reconnectEvery, (t) {
      if (epoch != _epoch) {
        t.cancel();
        return;
      }
      if ((_reconnectClock?.elapsed ?? Duration.zero) >= reconnectWindow) {
        _endReconnect(restored: false);
        _events.add(const Disconnected());
        return;
      }
      if (_initiator) unawaited(_restartIce(epoch));
    });
  }

  void _endReconnect({required bool restored}) {
    final was = _reconnecting;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectClock?.stop();
    _reconnectClock = null;
    _reconnecting = false;
    if (was && restored) _events.add(const CallReconnected());
  }

  /// Đổi mạng (Wi‑Fi ↔ 4G...): không chờ ICE tự phát hiện, thử ngay ICE restart (bên mời).
  void _watchNetwork(int epoch) {
    _netSub?.cancel();
    _netSub = Connectivity().onConnectivityChanged.listen((r) {
      if (epoch != _epoch || r.contains(ConnectivityResult.none)) return;
      _netDebounce?.cancel();
      _netDebounce = Timer(const Duration(milliseconds: 800), () {
        if (epoch == _epoch && _initiator && _iceConnected) unawaited(_restartIce(epoch));
      });
    });
  }

  /// Dò lại P2P khi đang đi qua relay: bên mời gửi offer mới với `iceRestart` (bên kia trả lời như thường).
  Future<void> _restartIce(int epoch) async {
    final pc = _pc;
    if (pc == null || epoch != _epoch) return;
    try {
      final offer = await pc.createOffer(<String, dynamic>{'iceRestart': true});
      await pc.setLocalDescription(offer);
      if (epoch != _epoch) return;
      _signal('offer', <String, dynamic>{'sdp': _outSdp(offer.sdp), 'type': offer.type});
    } on Object catch (e) {
      debugPrint('ICE restart ignored: $e');
    }
  }

  // --- dọn dẹp ------------------------------------------------------------------

  /// [silent]: không gửi `bye` cho đối phương (dùng khi chuyển sang LiveKit mà hai bên vẫn trong cuộc gọi).
  @override
  Future<void> leave({bool silent = false}) async {
    final hadRoom = _room != null;
    if (!silent && hadRoom && !_byeSent && _pc != null) {
      _byeSent = true;
      _signal('bye', <String, dynamic>{});
    }
    _epoch++;
    _graceTimer?.cancel();
    _graceTimer = null;
    _endReconnect(restored: false);
    _netSub?.cancel();
    _netSub = null;
    _netDebounce?.cancel();
    _netDebounce = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _stopQuality();
    final pc = _pc;
    final stream = _localStream;
    final channel = _channel;
    final media = _media;
    _media = null;
    final remote = _remote.value;
    final local = _local.value;
    _pc = null;
    _localStream = null;
    _channel = null;
    _room = null;
    _remoteSet = false;
    _remoteReadySent = false;
    _iceConnected = false;
    _hasRemoteVideo = false;
    _setupDone = false;
    _pendingCandidates.clear();
    _early.clear();
    _remote.value = null;
    _local.value = null;
    try {
      await channel?.close();
      await media?.close();
      if (stream != null) await _disposeStream(stream);
      await pc?.close();
      await remote?.dispose();
      await local?.dispose();
    } on Object catch (e) {
      debugPrint('WebRTC leave ignored error: $e');
    }
  }

  Future<void> _disposeStream(rtc.MediaStream stream) async {
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  }

  // --- giao diện / điều khiển -----------------------------------------------------

  @override
  Widget remoteView() {
    return ValueListenableBuilder<rtc.RTCVideoRenderer?>(
      valueListenable: _remote,
      builder: (context, renderer, _) {
        if (renderer == null) return const ColoredBox(color: AppColors.surface);
        return rtc.RTCVideoView(renderer, objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
      },
    );
  }

  @override
  Widget localView() {
    return ValueListenableBuilder<rtc.RTCVideoRenderer?>(
      valueListenable: _local,
      builder: (context, renderer, _) {
        if (renderer == null) return const ColoredBox(color: AppColors.surface);
        return rtc.RTCVideoView(
          renderer,
          mirror: true,
          objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
      },
    );
  }

  @override
  Future<void> setMicEnabled(bool on) async {
    for (final t in _localStream?.getAudioTracks() ?? <rtc.MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> setCameraEnabled(bool on) async {
    _userCamOn = on;
    if (_appliedLevel == CallQualityLevel.audioOnly) return; // đang chỉ-tiếng: giữ tắt, bật lại khi về P2P
    for (final t in _localStream?.getVideoTracks() ?? <rtc.MediaStreamTrack>[]) {
      t.enabled = on;
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <rtc.MediaStreamTrack>[];
    if (tracks.isEmpty) return;
    try {
      await rtc.Helper.switchCamera(tracks.first);
    } on Object catch (e) {
      debugPrint('switchCamera failed: $e');
    }
  }

  @override
  Future<void> dispose() async {
    _stopQuality();
    BeautySettings.instance.removeListener(_onBeautyChanged);
    await leave();
    await _sigSub.cancel();
    await _events.close();
    await _data.close();
    _remote.dispose();
    _local.dispose();
  }
}
