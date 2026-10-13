import 'dart:async';

import 'package:web_socket_channel/io.dart';

/// Lớp mỏng quanh một kết nối WebSocket để [WsClient] test được mà không cần
/// mạng (T-011 ghi `WebSocketChannel Function(Uri, Map)`; đổi sang giao diện mỏng
/// này vì `WebSocketChannel` có nhiều thành viên khó giả – xem nhật ký).
abstract class WsTransport {
  /// Hoàn thành khi bắt tay xong; lỗi nếu không kết nối được.
  Future<void> get ready;

  /// Chỉ các frame text.
  Stream<String> get incoming;

  void send(String text);

  /// Mã đóng nhận từ server (có giá trị sau khi [incoming] kết thúc).
  int? get closeCode;

  Future<void> close();
}

typedef WsConnector = WsTransport Function(Uri uri, Map<String, String> headers);

/// Chu kỳ ping phía client. `dart:io` gửi frame ping mỗi chu kỳ và ĐÓNG kết nối nếu không có
/// pong trước chu kỳ kế tiếp (server `ws` tự trả pong). Nhờ đó mạng đổi/chết mà không có FIN
/// vẫn bị phát hiện trong tối đa ~2 chu kỳ (<= 40 s) và [WsClient] kết nối lại theo backoff.
/// API.md không có thông điệp ping ở tầng ứng dụng; đây là ping của giao thức WebSocket.
const Duration kWsPingInterval = Duration(seconds: 20);

/// Bản thật dựa trên `IOWebSocketChannel` (dart:io). Token đi qua header
/// `Authorization`, KHÔNG qua query string (API.md §2.1).
class IoWsTransport implements WsTransport {
  IoWsTransport(Uri uri, Map<String, String> headers)
      : _channel = IOWebSocketChannel.connect(
          uri,
          headers: headers,
          pingInterval: kWsPingInterval,
        );

  final IOWebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<String> get incoming =>
      _channel.stream.where((e) => e is String).cast<String>();

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  int? get closeCode => _channel.closeCode;

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close(1000);
    } on Object {
      // đã đóng
    }
  }
}

WsTransport defaultWsConnector(Uri uri, Map<String, String> headers) =>
    IoWsTransport(uri, headers);
