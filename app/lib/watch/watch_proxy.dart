import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/call_service.dart';
import 'watch_protocol.dart';

/// Phía NGƯỜI XEM: máy chủ HTTP cục bộ (127.0.0.1) trả byte lấy từ máy chủ tệp qua kênh `media`.
/// Trình phát (`video_player`) mở `http://127.0.0.1:<cổng>/...` như một URL thường và tự gửi `Range`.
class WatchProxy {
  WatchProxy({required BinaryChannel channel, required this.size, required this.mime})
      : _channel = channel;

  final BinaryChannel _channel;
  final int size;
  final String mime;

  HttpServer? _server;
  StreamSubscription<Uint8List>? _sub;
  final Map<int, HttpResponse> _pending = <int, HttpResponse>{};
  int _nextId = 1;
  String _path = '/m';

  /// URL để đưa cho trình phát.
  Future<Uri> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _path = '/m/${DateTime.now().microsecondsSinceEpoch}';
    _sub = _channel.binaryMessages.listen(_onBytes);
    server.listen(_onRequest, onError: (Object _) {});
    return Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: _path);
  }

  Future<void> _onRequest(HttpRequest req) async {
    final res = req.response;
    if (req.uri.path != _path || (req.method != 'GET' && req.method != 'HEAD')) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final range = parseHttpRange(req.headers.value(HttpHeaders.rangeHeader), size);
    int start;
    int length;
    switch (range) {
      case FullRange():
        start = 0;
        length = size;
        res.statusCode = HttpStatus.ok;
      case PartialRange(start: final s, length: final l):
        start = s;
        length = l;
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-${s + l - 1}/$size');
      case BadRange():
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        return;
    }
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, mime)
      ..contentLength = length;
    if (req.method == 'HEAD' || length == 0) {
      await res.close();
      return;
    }
    if (!_channel.binaryOpen) {
      await res.close();
      return;
    }
    final id = _nextId++;
    _pending[id] = res;
    // Trình phát đóng kết nối (tua, thoát): báo chủ dừng đọc.
    unawaited(res.done.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (_pending.remove(id) != null) _channel.sendBinary(encodeFrame(FrameType.cancel, id));
    }));
    _channel.sendBinary(encodeReq(id, start, length));
  }

  void _onBytes(Uint8List bytes) {
    final f = decodeFrame(bytes);
    if (f == null) return;
    final res = _pending[f.id];
    if (res == null) return;
    switch (f.type) {
      case FrameType.data:
        try {
          res.add(f.payload);
        } on Object {
          _pending.remove(f.id);
        }
      case FrameType.end:
        _pending.remove(f.id);
        unawaited(res.close().then<void>((_) {}, onError: (Object _) {}));
      case FrameType.err:
        _pending.remove(f.id);
        unawaited(res.close().then<void>((_) {}, onError: (Object _) {}));
      case FrameType.req || FrameType.cancel:
        break;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    for (final res in _pending.values.toList()) {
      unawaited(res.close().then<void>((_) {}, onError: (Object _) {}));
    }
    _pending.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
