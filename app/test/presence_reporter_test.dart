import 'dart:async';

import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/presence_reporter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeWsClient ws;
  late PresenceReporter reporter;

  setUp(() {
    ws = FakeWsClient();
    reporter = PresenceReporter(ws);
  });

  tearDown(() => reporter.dispose());

  test('xuống nền / lên lại gửi presence.update đúng state', () {
    reporter.setForeground(false);
    reporter.setForeground(true);
    expect(ws.sent.map((m) => m.type), <String>['presence.update', 'presence.update']);
    expect(ws.sent[0].data, <String, dynamic>{'state': 'background'});
    expect(ws.sent[1].data, <String, dynamic>{'state': 'foreground'});
  });

  test('chỉ gửi khi trạng thái thật sự đổi', () {
    reporter.setForeground(true);
    reporter.setForeground(false);
    reporter.setForeground(false);
    expect(ws.sent, hasLength(1));
    expect(reporter.foreground, isFalse);
  });

  test('WS kết nối lại khi đang ở nền: gửi lại background sau session.ready', () async {
    reporter.setForeground(false);
    ws.sent.clear();
    ws.emit(const SessionReady('u1'));
    await _settle();
    expect(ws.sent, hasLength(1));
    expect(ws.sent.single.data['state'], 'background');
  });

  test('session.ready khi đang ở nền trước: không gửi gì', () async {
    ws.emit(const SessionReady('u1'));
    await _settle();
    expect(ws.sent, isEmpty);
  });
}
