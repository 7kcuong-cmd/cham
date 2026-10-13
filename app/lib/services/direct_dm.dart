import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../models/ws_messages.dart';
import 'ws_client.dart';

/// Kênh nhắn tin TRỰC TIẾP giữa hai bạn bè đang cùng online (WebRTC DataChannel, DTLS).
/// Server chỉ chuyển tín hiệu (`dm.rtc`); tin nhắn (đã mã hóa đầu cuối) đi thẳng giữa hai máy.
/// Không nối được / người kia offline → [send] trả `false` và [ChatController] dùng hộp thư trên server.
/// CHƯA THỬ TRÊN MÁY THẬT.
class DirectDm {
  DirectDm({
    required WsClient ws,
    required String? Function() myId,
    required bool Function() enabled,
    required void Function(String peerId, Map<String, dynamic> msg) onMessage,
    void Function(String peerId, Map<String, dynamic> msg)? onControl,
    List<String> stunUrls = const <String>['stun:stun.l.google.com:19302'],
  })  : _ws = ws,
        _myId = myId,
        _enabled = enabled,
        _onMessage = onMessage,
        _onControl = onControl,
        _stun = stunUrls {
    _sub = _ws.messages.listen((m) {
      if (m is DmRtcSignal) unawaited(_onSignal(m));
    });
  }

  static const connectTimeout = Duration(seconds: 6);
  static const ackTimeout = Duration(seconds: 2);
  static const idleClose = Duration(seconds: 90);

  final WsClient _ws;
  final String? Function() _myId;
  final bool Function() _enabled;
  final void Function(String peerId, Map<String, dynamic> msg) _onMessage;
  final void Function(String peerId, Map<String, dynamic> msg)? _onControl;
  final List<String> _stun;
  final Map<String, _Link> _links = <String, _Link>{};
  final Map<String, Completer<bool>> _acks = <String, Completer<bool>>{};
  StreamSubscription<ServerMessage>? _sub;

  /// Bên có id lớn hơn là "lịch sự": khi hai bên cùng chào, bên này nhường.
  bool _polite(String peer) => (_myId() ?? '').compareTo(peer) > 0;

  /// Gửi một thông điệp trực tiếp và chờ bên kia báo nhận. `false` = hãy dùng đường server.
  Future<bool> send(String peerId, String id, Map<String, dynamic> msg) async {
    if (!_enabled() || !_ws.isConnected) return false;
    final link = await _ensure(peerId);
    if (link == null) return false;
    final ack = Completer<bool>();
    _acks[id] = ack;
    try {
      link.channel!.send(rtc.RTCDataChannelMessage(jsonEncode(<String, dynamic>{'t': 'dm', 'id': id, ...msg})));
    } on Object {
      _acks.remove(id);
      return false;
    }
    link.touch(() => _close(peerId));
    final ok = await ack.future.timeout(ackTimeout, onTimeout: () => false);
    _acks.remove(id);
    return ok;
  }

  /// Đảm bảo có kênh mở (chờ tối đa [connectTimeout]).
  Future<bool> ensureOpen(String peerId) async {
    if (!_enabled() || !_ws.isConnected) return false;
    return (await _ensure(peerId)) != null;
  }

  /// Gửi một khung điều khiển (tệp...) qua kênh đang mở, không chờ báo nhận. `false` nếu kênh chưa mở.
  bool sendRaw(String peerId, Map<String, dynamic> msg) {
    final link = _links[peerId];
    if (link == null || !link.open) return false;
    try {
      link.channel!.send(rtc.RTCDataChannelMessage(jsonEncode(msg)));
      link.touch(() => _close(peerId));
      return true;
    } on Object {
      return false;
    }
  }

  /// Kênh trực tiếp tới [peerId] đang mở sẵn? (gửi qua đó ngay, không chờ kết nối)
  bool isOpen(String peerId) => _links[peerId]?.open ?? false;

  /// Chuẩn bị sẵn kênh khi mở màn trò chuyện (không chờ kết quả).
  void warmUp(String peerId) {
    if (_enabled() && _ws.isConnected) unawaited(_ensure(peerId));
  }

  Future<_Link?> _ensure(String peerId) async {
    var link = _links[peerId];
    if (link != null && link.open) return link;
    if (link == null) {
      link = _Link();
      _links[peerId] = link;
      try {
        await _startOffer(peerId, link);
      } on Object catch (e) {
        debugPrint('direct dm: offer failed: $e');
        await _close(peerId);
        return null;
      }
    }
    final ok = await link.opened.future.timeout(connectTimeout, onTimeout: () => false);
    if (!ok) {
      await _close(peerId);
      return null;
    }
    return link;
  }

  Future<rtc.RTCPeerConnection> _newPc(String peerId, _Link link) async {
    final pc = await rtc.createPeerConnection(<String, dynamic>{
      'iceServers': <Map<String, dynamic>>[
        <String, dynamic>{'urls': _stun},
      ],
    });
    link.pc = pc;
    pc.onIceCandidate = (rtc.RTCIceCandidate c) {
      if (c.candidate == null) return;
      _signal(peerId, 'candidate', <String, dynamic>{'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex});
    };
    pc.onConnectionState = (rtc.RTCPeerConnectionState s) {
      if (s == rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          s == rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        unawaited(_close(peerId, notifyPeer: false));
      }
    };
    pc.onDataChannel = (rtc.RTCDataChannel ch) => _bind(peerId, link, ch);
    return pc;
  }

  Future<void> _startOffer(String peerId, _Link link) async {
    final pc = await _newPc(peerId, link);
    _bind(peerId, link, await pc.createDataChannel('dm', rtc.RTCDataChannelInit()..ordered = true));
    final offer = await pc.createOffer(<String, dynamic>{});
    await pc.setLocalDescription(offer);
    _signal(peerId, 'offer', <String, dynamic>{'sdp': offer.sdp, 'type': offer.type});
  }

  void _bind(String peerId, _Link link, rtc.RTCDataChannel ch) {
    link.channel = ch;
    ch.onDataChannelState = (rtc.RTCDataChannelState s) {
      if (s == rtc.RTCDataChannelState.RTCDataChannelOpen) {
        link.open = true;
        if (!link.opened.isCompleted) link.opened.complete(true);
        link.touch(() => _close(peerId));
      } else if (s == rtc.RTCDataChannelState.RTCDataChannelClosed) {
        unawaited(_close(peerId, notifyPeer: false));
      }
    };
    ch.onMessage = (rtc.RTCDataChannelMessage m) {
      if (m.isBinary || m.text.length > 40000) return;
      Object? j;
      try {
        j = jsonDecode(m.text);
      } on FormatException {
        return;
      }
      if (j is! Map) return;
      link.touch(() => _close(peerId));
      final t = j['t'];
      final id = j['id'];
      if (t == 'ack' && id is String) {
        _acks[id]?.complete(true);
      } else if (t is String && t.startsWith('ft.')) {
        _onControl?.call(peerId, Map<String, dynamic>.from(j));
      } else if (t == 'dm' && id is String && id.length <= 64) {
        _onMessage(peerId, Map<String, dynamic>.from(j));
        try {
          ch.send(rtc.RTCDataChannelMessage(jsonEncode(<String, dynamic>{'t': 'ack', 'id': id})));
        } on Object {
          // bên kia sẽ tự chuyển sang đường server
        }
      }
    };
  }

  Future<void> _onSignal(DmRtcSignal m) async {
    final peer = m.fromUserId;
    try {
      switch (m.kind) {
        case 'bye':
          await _close(peer, notifyPeer: false);
        case 'offer':
          if (!_enabled()) {
            _signal(peer, 'bye', <String, dynamic>{});
            return;
          }
          var link = _links[peer];
          if (link != null && !link.open) {
            if (!_polite(peer)) return; // mình là bên chính: bỏ qua lời chào của bên kia
            await _close(peer, notifyPeer: false); // bên lịch sự nhường
            link = null;
          } else if (link != null) {
            await _close(peer, notifyPeer: false); // kênh cũ: thay bằng kênh mới
            link = null;
          }
          final l = _Link();
          _links[peer] = l;
          final pc = await _newPc(peer, l);
          await pc.setRemoteDescription(rtc.RTCSessionDescription(m.payload['sdp'] as String?, m.payload['type'] as String?));
          l.remoteSet = true;
          await _flush(l);
          final answer = await pc.createAnswer(<String, dynamic>{});
          await pc.setLocalDescription(answer);
          _signal(peer, 'answer', <String, dynamic>{'sdp': answer.sdp, 'type': answer.type});
        case 'answer':
          final l = _links[peer];
          if (l?.pc == null || l!.remoteSet) return;
          await l.pc!.setRemoteDescription(rtc.RTCSessionDescription(m.payload['sdp'] as String?, m.payload['type'] as String?));
          l.remoteSet = true;
          await _flush(l);
        case 'candidate':
          final l = _links[peer];
          if (l == null) return;
          final c = rtc.RTCIceCandidate(m.payload['candidate'] as String?, m.payload['sdpMid'] as String?, m.payload['sdpMLineIndex'] as int?);
          if (l.remoteSet && l.pc != null) {
            await l.pc!.addCandidate(c);
          } else {
            if (l.pending.length < 64) l.pending.add(c);
          }
      }
    } on Object catch (e) {
      debugPrint('direct dm: signal ${m.kind} failed: $e');
      await _close(peer);
    }
  }

  Future<void> _flush(_Link l) async {
    final list = List<rtc.RTCIceCandidate>.of(l.pending);
    l.pending.clear();
    for (final c in list) {
      await l.pc?.addCandidate(c);
    }
  }

  void _signal(String peer, String kind, Map<String, dynamic> payload) {
    _ws.send('dm.rtc', <String, dynamic>{'toUserId': peer, 'kind': kind, 'payload': payload});
  }

  Future<void> _close(String peer, {bool notifyPeer = true}) async {
    final l = _links.remove(peer);
    if (l == null) return;
    if (notifyPeer && _ws.isConnected) _signal(peer, 'bye', <String, dynamic>{});
    l.idle?.cancel();
    if (!l.opened.isCompleted) l.opened.complete(false);
    try {
      await l.channel?.close();
      await l.pc?.close();
    } on Object {
      // đã đóng
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    for (final p in _links.keys.toList()) {
      await _close(p);
    }
    for (final a in _acks.values) {
      if (!a.isCompleted) a.complete(false);
    }
  }
}

class _Link {
  rtc.RTCPeerConnection? pc;
  rtc.RTCDataChannel? channel;
  bool open = false;
  bool remoteSet = false;
  final Completer<bool> opened = Completer<bool>();
  final List<rtc.RTCIceCandidate> pending = <rtc.RTCIceCandidate>[];
  Timer? idle;

  void touch(void Function() onIdle) {
    idle?.cancel();
    idle = Timer(DirectDm.idleClose, onIdle);
  }
}
