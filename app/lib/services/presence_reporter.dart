import 'dart:async';

import '../models/ws_messages.dart';
import 'ws_client.dart';

/// Báo `presence.update` cho server (API-GD2-4 §3.2): `background` khi app xuống nền,
/// `foreground` khi lên lại. Phiên WS mới mặc định là `foreground` ở server, nên nếu app đang ở
/// nền mà WS kết nối lại (nhận `session.ready`) thì gửi lại `background`.
class PresenceReporter {
  PresenceReporter(this._ws) {
    _sub = _ws.messages.listen((m) {
      if (m is SessionReady && !_foreground) _ws.sendPresence(false);
    });
  }

  final WsClient _ws;
  late final StreamSubscription<ServerMessage> _sub;
  bool _foreground = true;

  bool get foreground => _foreground;

  /// Gọi từ vòng đời ứng dụng. Chỉ gửi khi trạng thái thật sự đổi.
  void setForeground(bool foreground) {
    if (_foreground == foreground) return;
    _foreground = foreground;
    _ws.sendPresence(foreground);
  }

  Future<void> dispose() => _sub.cancel();
}
