import 'dart:convert';

import 'package:cham/models/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

String _env(String type, Map<String, dynamic> data) => jsonEncode(<String, dynamic>{'type': type, 'data': data});

void main() {
  test('call.missed: đọc đủ trường', () {
    final m = ServerMessage.parse(_env('call.missed', <String, dynamic>{
      'inviteId': 'i1',
      'fromUserId': 'u1',
      'name': 'Lan',
      'at': '2026-10-12T08:30:00.000Z',
    }));
    expect(m, isA<CallMissed>());
    m as CallMissed;
    expect(m.inviteId, 'i1');
    expect(m.fromUserId, 'u1');
    expect(m.name, 'Lan');
    expect(m.at.toUtc().hour, 8);
  });

  test('call.missed: thiếu tên vẫn đọc được; thiếu id/thời gian → UnknownMessage', () {
    final ok = ServerMessage.parse(_env('call.missed', <String, dynamic>{'inviteId': 'i', 'fromUserId': 'u', 'at': '2026-10-12T08:30:00.000Z'}));
    expect((ok as CallMissed).name, '');
    expect(ServerMessage.parse(_env('call.missed', <String, dynamic>{'fromUserId': 'u', 'at': '2026-10-12T08:30:00.000Z'})), isA<UnknownMessage>());
    expect(ServerMessage.parse(_env('call.missed', <String, dynamic>{'inviteId': 'i', 'fromUserId': 'u', 'at': 'x'})), isA<UnknownMessage>());
  });
}
