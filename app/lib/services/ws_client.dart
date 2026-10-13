import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ws_messages.dart';
import 'auth_service.dart';
import 'ws_transport.dart';

enum WsConnState { disconnected, connecting, connected, closedPermanently }

/// Client WebSocket – API.md §2.1, §2.2, §2.5.
///
/// - Token trong header `Authorization: Bearer`.
/// - `connected` chỉ sau khi nhận `session.ready`.
/// - Xử lý mã đóng theo bảng §2.5 (4401/4403/4404/4409/4429 + backoff).
/// - `send` khi chưa `connected` → bỏ (không xếp hàng); controller tự gửi lại
///   sau `session.ready`.
class WsClient {
  WsClient({
    required this.url,
    required this.auth,
    WsConnector? connector,
    Duration Function(int attempt)? backoff,
    Duration rateLimitedDelay = const Duration(seconds: 30),
    Duration handshakeTimeout = const Duration(seconds: 15),
  })  : _connector = connector ?? defaultWsConnector,
        _backoff = backoff ?? defaultBackoff,
        _rateLimitedDelay = rateLimitedDelay,
        _handshakeTimeout = handshakeTimeout;

  final String url;
  final AuthService auth;
  final WsConnector _connector;
  final Duration Function(int attempt) _backoff;
  final Duration _rateLimitedDelay;
  final Duration _handshakeTimeout;

  /// 1, 2, 4, 8, 16, 30, 30… giây (API.md §2.7 mục 6).
  static Duration defaultBackoff(int attempt) {
    const seconds = <int>[1, 2, 4, 8, 16, 30];
    final index = attempt < 0 ? 0 : (attempt >= seconds.length ? seconds.length - 1 : attempt);
    return Duration(seconds: seconds[index]);
  }

  /// Gọi khi server đóng 4404 (chưa có hồ sơ): nên gọi `POST /v1/auth/session`.
  /// WsClient chờ xong rồi mới kết nối lại.
  Future<void> Function()? onNeedsSessionRefresh;

  final StreamController<ServerMessage> _messages = StreamController<ServerMessage>.broadcast();
  final StreamController<WsConnState> _states = StreamController<WsConnState>.broadcast();

  WsConnState _state = WsConnState.disconnected;
  WsTransport? _transport;
  StreamSubscription<String>? _sub;
  Timer? _retryTimer;
  int _generation = 0;
  int _attempt = 0;
  int _reqCounter = 0;
  bool _wantConnected = false;
  bool _retried401 = false;
  bool _forceRefreshToken = false;
  int _count404 = 0;
  bool _disposed = false;

  Stream<ServerMessage> get messages => _messages.stream;
  Stream<WsConnState> get state => _states.stream;
  WsConnState get currentState => _state;
  bool get isConnected => _state == WsConnState.connected;

  /// Bắt đầu kết nối (idempotent). Đang chờ backoff → kết nối ngay.
  Future<void> connect() async {
    if (_disposed) return;
    _wantConnected = true;
    if (_state == WsConnState.connecting || _state == WsConnState.connected) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    _retried401 = false;
    _count404 = 0;
    await _open();
  }

  /// Gửi một thông điệp (`reqId` = `c-<số tăng dần>`). Chưa `connected` → bỏ.
  void send(String type, [Map<String, dynamic> data = const <String, dynamic>{}]) {
    final transport = _transport;
    if (_state != WsConnState.connected || transport == null) return;
    transport.send(encodeClient(type, data, 'c-${++_reqCounter}'));
  }

  /// Đóng hẳn và không tự kết nối lại (đăng xuất, thoát app).
  Future<void> close() async {
    _wantConnected = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _generation++;
    final transport = _transport;
    _transport = null;
    await _sub?.cancel();
    _sub = null;
    _setState(WsConnState.disconnected);
    await transport?.close();
  }

  Future<void> dispose() async {
    await close();
    _disposed = true;
    await _messages.close();
    await _states.close();
  }

  // --- nội bộ ---------------------------------------------------------------

  Future<void> _open() async {
    final gen = ++_generation;
    _setState(WsConnState.connecting);

    final String? token;
    try {
      token = await auth.getIdToken(forceRefresh: _forceRefreshToken);
    } on Object catch (e) {
      debugPrint('ws: getIdToken failed: $e');
      if (gen == _generation) _scheduleRetry(_backoff(_attempt++));
      return;
    }
    _forceRefreshToken = false;
    if (gen != _generation) return;
    if (token == null) {
      _failPermanently(const ServerError('UNAUTHENTICATED', 'No token'));
      return;
    }

    final WsTransport transport;
    try {
      transport = _connector(Uri.parse(url), <String, String>{'Authorization': 'Bearer $token'});
    } on Object catch (e) {
      debugPrint('ws: connector failed: $e');
      _scheduleRetry(_backoff(_attempt++));
      return;
    }
    _transport = transport;

    // Lắng nghe NGAY (trước khi `ready`) để không lỡ frame lỗi + mã đóng 440x.
    _sub = transport.incoming.listen(
      (raw) => _onData(gen, raw),
      onError: (Object e) => debugPrint('ws: stream error: $e'),
      onDone: () => _onDone(gen, transport),
    );

    try {
      await transport.ready.timeout(_handshakeTimeout);
    } on Object catch (e) {
      debugPrint('ws: handshake failed: $e');
      if (gen != _generation) return;
      await _teardown(transport);
      _scheduleRetry(_backoff(_attempt++));
    }
  }

  void _onData(int gen, String raw) {
    if (gen != _generation) return;
    final message = ServerMessage.parse(raw);
    if (message is SessionReady) {
      _attempt = 0;
      _retried401 = false;
      _count404 = 0;
      _setState(WsConnState.connected);
    }
    // `error UNAUTHENTICATED` đi kèm mã đóng 4401: WsClient tự thử làm mới token
    // một lần nên không chuyển tiếp (chỉ phát lỗi này khi đã thất bại hẳn).
    if (message is ServerError && message.code == 'UNAUTHENTICATED') return;
    if (!_messages.isClosed) _messages.add(message);
  }

  Future<void> _onDone(int gen, WsTransport transport) async {
    if (gen != _generation) return;
    final code = transport.closeCode;
    await _teardown(transport);
    if (!_wantConnected) {
      _setState(WsConnState.disconnected);
      return;
    }
    await _handleClose(code);
  }

  Future<void> _teardown(WsTransport transport) async {
    _generation++; // vô hiệu hóa callback cũ
    if (identical(_transport, transport)) _transport = null;
    await _sub?.cancel();
    _sub = null;
    unawaited(transport.close());
  }

  /// Bảng mã đóng – API.md §2.5.
  Future<void> _handleClose(int? code) async {
    switch (code) {
      case 4401:
        if (!_retried401) {
          _retried401 = true;
          _forceRefreshToken = true; // getIdToken(forceRefresh: true)
          await _open();
        } else {
          _failPermanently(const ServerError('UNAUTHENTICATED', 'Token rejected twice'));
        }
      case 4403:
      case 4409:
        _failPermanently(null);
      case 4404:
        if (++_count404 > 3) {
          _failPermanently(null);
          return;
        }
        _setState(WsConnState.disconnected);
        try {
          await onNeedsSessionRefresh?.call();
        } on Object catch (e) {
          debugPrint('ws: session refresh failed: $e');
        }
        if (_wantConnected && _state == WsConnState.disconnected) await _open();
      case 4429:
        _scheduleRetry(_rateLimitedDelay);
      default:
        // 1000, 1001, 1006, mất mạng...: backoff
        _scheduleRetry(_backoff(_attempt++));
    }
  }

  void _scheduleRetry(Duration delay) {
    if (!_wantConnected || _disposed) return;
    _setState(WsConnState.disconnected);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_wantConnected && _state == WsConnState.disconnected) {
        unawaited(_open());
      }
    });
  }

  void _failPermanently(ServerError? error) {
    _retryTimer?.cancel();
    _retryTimer = null;
    _setState(WsConnState.closedPermanently);
    if (error != null && !_messages.isClosed) _messages.add(error);
  }

  void _setState(WsConnState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }
}

/// Báo trạng thái ứng dụng cho server (API-GD2-4 §3.2 `presence.update`, không có phản hồi).
/// Là extension (không phải thành viên lớp) để các bản giả của [WsClient] trong test
/// không phải thay đổi.
extension WsPresence on WsClient {
  void sendPresence(bool foreground) {
    send('presence.update', <String, dynamic>{
      'state': foreground ? 'foreground' : 'background',
    });
  }
}
