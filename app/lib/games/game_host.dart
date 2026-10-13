import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// Máy chủ tĩnh cục bộ 127.0.0.1 phục vụ một game đã cài + `/__cham/sdk.js`.
/// CSP chặn mọi truy cập mạng từ game (`connect-src 'none'`).
class GameHost {
  GameHost({required this.dir, Future<String> Function()? sdkLoader})
      : _sdk = sdkLoader ?? (() => rootBundle.loadString('assets/games/cham-sdk.js'));

  final String dir;
  final Future<String> Function() _sdk;
  HttpServer? _server;

  static const csp = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
      "img-src 'self' data: blob:; media-src 'self' data: blob:; font-src 'self' data:; connect-src 'none'; "
      "frame-src 'none'; form-action 'none'; base-uri 'none'";

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'application/javascript; charset=utf-8',
    'css': 'text/css; charset=utf-8',
    'json': 'application/json; charset=utf-8',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'svg': 'image/svg+xml',
    'webp': 'image/webp',
    'mp3': 'audio/mpeg',
    'ogg': 'audio/ogg',
    'wav': 'audio/wav',
    'woff2': 'font/woff2',
  };

  int get port => _server!.port;

  Future<Uri> start(String entry) async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = s;
    unawaited(s.forEach(_handle));
    return Uri.parse('http://127.0.0.1:${s.port}/$entry');
  }

  /// Chuẩn hoá đường dẫn; null nếu thoát khỏi thư mục game.
  static String? safeRel(String path) {
    final segs = Uri.decodeComponent(path).split('/').where((e) => e.isNotEmpty).toList();
    if (segs.any((e) => e == '..' || e == '.' || e.contains('\\'))) return null;
    return segs.join('/');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    res.headers
      ..set('Content-Security-Policy', csp)
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('Cache-Control', 'no-store');
    try {
      if (req.method != 'GET') {
        res.statusCode = 405;
      } else if (req.uri.path == '/__cham/sdk.js') {
        res.headers.contentType = ContentType.parse(_types['js']!);
        res.write(await _sdk());
      } else {
        final rel = safeRel(req.uri.path);
        final f = rel == null || rel.isEmpty ? null : File('$dir/$rel');
        if (f == null || !await f.exists()) {
          res.statusCode = 404;
        } else {
          final ext = rel!.contains('.') ? rel.split('.').last.toLowerCase() : '';
          res.headers.set('Content-Type', _types[ext] ?? 'application/octet-stream');
          await res.addStream(f.openRead());
        }
      }
    } on Object {
      res.statusCode = 500;
    } finally {
      await res.close();
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}
