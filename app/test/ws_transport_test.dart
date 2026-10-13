import 'dart:async';
import 'dart:io';

import 'package:cham/services/ws_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kiểm thử IoWsTransport với một máy chủ WebSocket thật trên loopback (không cần mạng ngoài).
void main() {
  test('chu kỳ ping phía client nằm trong khoảng hợp lý', () {
    expect(kWsPingInterval.inSeconds, inInclusiveRange(5, 30));
  });

  test('gửi header Authorization, nhận text, gửi text, nhận mã đóng của server', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    final gotAuth = Completer<String?>();
    final gotText = Completer<String>();
    server.listen((request) async {
      gotAuth.complete(request.headers.value('authorization'));
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        if (data is String && !gotText.isCompleted) gotText.complete(data);
      });
      socket.add('hello');
      await gotText.future;
      await socket.close(4401, 'bye');
    });

    final transport = IoWsTransport(
      Uri.parse('ws://127.0.0.1:${server.port}/v1/ws'),
      <String, String>{'Authorization': 'Bearer dev:alice'},
    );
    final received = <String>[];
    final done = Completer<void>();
    transport.incoming.listen(received.add, onDone: done.complete);

    await transport.ready.timeout(const Duration(seconds: 5));
    transport.send('ping-from-client');
    await done.future.timeout(const Duration(seconds: 5));

    expect(await gotAuth.future, 'Bearer dev:alice');
    expect(await gotText.future, 'ping-from-client');
    expect(received, <String>['hello']);
    expect(transport.closeCode, 4401);
    await transport.close();
  });
}
