import 'dart:convert';

import 'package:cham/models/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

// Các mẫu JSON sao chép từ API.md §2.4.
const _sessionReady =
    '{ "type": "session.ready", "data": { "userId": "Xk3vN0aQp1L7cWm2RtY8bA", "serverTime": "2026-10-05T09:30:00.000Z" } }';
const _queueJoined =
    '{ "type": "queue.joined", "reqId": "c-1", "data": { "queuedAt": "2026-10-05T09:30:01.120Z" } }';
const _matchFound = '''
{
  "type": "match.found",
  "data": {
    "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11",
    "livekitUrl": "wss://cham-xxxx.livekit.cloud",
    "token": "eyJhbGciOiJIUzI1NiJ9...",
    "tokenExpiresAt": "2026-10-05T09:40:05.000Z",
    "peer": { "id": "Q9pLm2vX0aB7cWn3RtY1kZ", "displayName": "Anna", "language": "en" }
  }
}''';
const _callEnded =
    '{ "type": "call.ended", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "reason": "peer_left" } }';
const _rateLimited =
    '{ "type": "error", "reqId": "c-9", "data": { "code": "RATE_LIMITED", "message": "Too many messages", "retryAfterSec": 4 } }';

void main() {
  test('session.ready', () {
    final m = ServerMessage.parse(_sessionReady);
    expect(m, isA<SessionReady>());
    expect((m as SessionReady).userId, 'Xk3vN0aQp1L7cWm2RtY8bA');
  });

  test('queue.joined (có reqId)', () {
    final m = ServerMessage.parse(_queueJoined);
    expect(m, isA<QueueJoined>());
    expect((m as QueueJoined).queuedAt, DateTime.utc(2026, 10, 5, 9, 30, 1, 120));
    expect(m.reqId, 'c-1');
  });

  test('queue.left', () {
    expect(ServerMessage.parse('{"type":"queue.left","reqId":"c-2","data":{}}'), isA<QueueLeft>());
  });

  test('match.found', () {
    final m = ServerMessage.parse(_matchFound);
    expect(m, isA<MatchFoundEvent>());
    final match = (m as MatchFoundEvent).match;
    expect(match.roomName, 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11');
    expect(match.livekitUrl, 'wss://cham-xxxx.livekit.cloud');
    expect(match.token, startsWith('eyJ'));
    expect(match.tokenExpiresAt, DateTime.utc(2026, 10, 5, 9, 40, 5));
    expect(match.peer.id, 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(match.peer.displayName, 'Anna');
    expect(match.peer.language, 'en');
  });

  test('call.ended', () {
    final m = ServerMessage.parse(_callEnded);
    expect(m, isA<CallEnded>());
    expect((m as CallEnded).roomName, 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11');
    expect(m.reason, CallEnded.peerLeft);
  });

  test('call.ended với reason lạ vẫn được giữ nguyên chuỗi', () {
    final m = ServerMessage.parse(
        '{"type":"call.ended","data":{"roomName":"r_x","reason":"something_new"}}');
    expect((m as CallEnded).reason, 'something_new');
  });

  test('error có retryAfterSec', () {
    final m = ServerMessage.parse(_rateLimited);
    expect(m, isA<ServerError>());
    final e = m as ServerError;
    expect(e.code, 'RATE_LIMITED');
    expect(e.retryAfterSec, 4);
    expect(e.reqId, 'c-9');
  });

  test('error không có retryAfterSec', () {
    final e = ServerMessage.parse('{"type":"error","data":{"code":"NOT_IN_CALL","message":"x"}}')
        as ServerError;
    expect(e.code, 'NOT_IN_CALL');
    expect(e.retryAfterSec, isNull);
  });

  test('trường thừa trong data bị bỏ qua', () {
    final m = ServerMessage.parse(
        '{"type":"session.ready","data":{"userId":"u","serverTime":"x","future":123},"extra":1}');
    expect(m, isA<SessionReady>());
  });

  group('không bao giờ ném, trả UnknownMessage', () {
    test('match.found thiếu data.peer', () {
      final map = jsonDecode(_matchFound) as Map<String, dynamic>;
      (map['data'] as Map<String, dynamic>).remove('peer');
      final m = ServerMessage.parse(jsonEncode(map));
      expect(m, isA<UnknownMessage>());
      expect((m as UnknownMessage).type, 'match.found');
    });

    test('match.found với peer thiếu displayName', () {
      final map = jsonDecode(_matchFound) as Map<String, dynamic>;
      ((map['data'] as Map<String, dynamic>)['peer'] as Map<String, dynamic>).remove('displayName');
      expect(ServerMessage.parse(jsonEncode(map)), isA<UnknownMessage>());
    });

    test('"not json"', () {
      expect(ServerMessage.parse('not json'), isA<UnknownMessage>());
    });

    test('JSON không phải đối tượng', () {
      expect(ServerMessage.parse('[1,2,3]'), isA<UnknownMessage>());
      expect(ServerMessage.parse('"hello"'), isA<UnknownMessage>());
      expect(ServerMessage.parse('null'), isA<UnknownMessage>());
    });

    test('thiếu type hoặc thiếu data', () {
      expect(ServerMessage.parse('{"data":{}}'), isA<UnknownMessage>());
      expect(ServerMessage.parse('{"type":"queue.left"}'), isA<UnknownMessage>());
      expect(ServerMessage.parse('{"type":"queue.left","data":"x"}'), isA<UnknownMessage>());
    });

    test('type không có trong hợp đồng', () {
      final m = ServerMessage.parse('{"type":"hello.world","data":{}}');
      expect(m, isA<UnknownMessage>());
      expect((m as UnknownMessage).type, 'hello.world');
    });

    test('call.ended thiếu reason / error thiếu code / queue.joined sai ngày', () {
      expect(ServerMessage.parse('{"type":"call.ended","data":{"roomName":"r_x"}}'),
          isA<UnknownMessage>());
      expect(ServerMessage.parse('{"type":"error","data":{"message":"x"}}'), isA<UnknownMessage>());
      expect(ServerMessage.parse('{"type":"queue.joined","data":{"queuedAt":"not a date"}}'),
          isA<UnknownMessage>());
    });
  });

  group('encodeClient', () {
    test('có reqId', () {
      final map = jsonDecode(encodeClient('call.next', {'roomName': 'r_x'}, 'c-4')) as Map;
      expect(map, {
        'type': 'call.next',
        'reqId': 'c-4',
        'data': {'roomName': 'r_x'},
      });
    });

    test('không có reqId → không có khóa reqId; data luôn là đối tượng', () {
      final map = jsonDecode(encodeClient('queue.join', {})) as Map;
      expect(map, {'type': 'queue.join', 'data': {}});
    });
  });
}
