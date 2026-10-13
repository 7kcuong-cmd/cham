import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/link_channel.dart';

/// Nối tới cầu `/v1/link` của server và dựng [LinkChannel] mã hóa đầu cuối bên trên.
/// Dùng được cả trên web lẫn điện thoại (không phụ thuộc `dart:io`).
class LinkSession implements LinkTransport {
  LinkSession._(this._ws, this.channel);

  final WebSocketChannel _ws;
  final LinkChannel channel;
  final StreamController<String> _in = StreamController<String>.broadcast();
  final Completer<String> _code = Completer<String>();
  final Completer<void> _paired = Completer<void>();

  /// Mã phòng do server cấp (chỉ phía web).
  Future<String> get code => _code.future;

  /// Hai bên đã vào cùng phòng.
  Future<void> get paired => _paired.future;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String text) => _ws.sink.add(text);

  @override
  Future<void> close() async {
    await _ws.sink.close();
    if (!_in.isClosed) await _in.close();
  }

  /// Phía WEB: xin mã; sau [start] có `channel.localFingerprint` để đưa vào QR.
  static Future<LinkSession> openWeb(Uri linkUrl) => _open(linkUrl.replace(queryParameters: {'role': 'web'}), null);

  /// Phía ĐIỆN THOẠI: vào phòng theo mã trong QR và chỉ tin khóa web có đúng dấu vân tay trong QR.
  static Future<LinkSession> openPhone(Uri linkUrl, LinkPairing p) =>
      _open(linkUrl.replace(queryParameters: {'role': 'phone', 'code': p.code}), p.fingerprint);

  static Future<LinkSession> _open(Uri url, String? expectedFp) async {
    final ws = WebSocketChannel.connect(url);
    late LinkSession s;
    final proxy = _Proxy();
    final channel = LinkChannel(proxy, expectedPeerFingerprint: expectedFp);
    s = LinkSession._(ws, channel);
    proxy.owner = s;
    ws.stream.listen((raw) {
      Object? j;
      try {
        j = jsonDecode(raw as String);
      } on Object {
        return;
      }
      if (j is! Map) return;
      switch (j['type']) {
        case 'link.code':
          if (j['code'] is String && !s._code.isCompleted) s._code.complete(j['code'] as String);
        case 'link.paired':
          if (!s._paired.isCompleted) s._paired.complete();
          unawaited(channel.hello()); // hello gửi trước lúc bên kia vào phòng đã bị bỏ
        case 'link.msg':
          if (j['data'] is String) s._in.add(j['data'] as String);
      }
    }, onDone: () {
      if (!s._paired.isCompleted) s._paired.completeError(StateError('Đóng kết nối trước khi ghép nối'));
      if (!s._code.isCompleted) s._code.completeError(StateError('Đóng kết nối'));
      if (!s._in.isClosed) unawaited(s._in.close());
    }, onError: (Object _) {});
    s._code.future.catchError((Object _) => '');
    s._paired.future.catchError((Object _) {});
    await channel.start();
    return s;
  }
}

/// Cầu nối để [LinkChannel] (tạo trước) dùng [LinkSession] (tạo sau).
class _Proxy implements LinkTransport {
  LinkSession? owner;

  @override
  Stream<String> get incoming => owner!.incoming;

  @override
  void send(String text) => owner!.send(text);

  @override
  Future<void> close() => owner!.close();
}
