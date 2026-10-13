import 'package:cham/models/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

// Mẫu JSON sao chép nguyên văn từ API-GD2-4.md §3.5.
const _contactPending =
    '{ "type": "contact.pending", "reqId": "c-20", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11" } }';
const _contactRequested =
    '{ "type": "contact.requested", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11" } }';
const _contactAdded =
    '{ "type": "contact.added", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "contact": { "id": "Q9pLm2vX0aB7cWn3RtY1kZ", "displayName": "Anna", "language": "en", "online": true, "addedAt": "2026-10-06T09:30:00.000Z" } } }';
const _callInvite =
    '{ "type": "call.invite", "data": { "inviteId": "0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "from": { "id": "Xk3vN0aQp1L7cWm2RtY8bA", "displayName": "Minh", "language": "vi" }, "expiresAt": "2026-10-06T09:30:30.000Z" } }';
const _callInviting =
    '{ "type": "call.inviting", "reqId": "c-21", "data": { "inviteId": "0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "contactId": "Q9pLm2vX0aB7cWn3RtY1kZ", "expiresAt": "2026-10-06T09:30:30.000Z", "calleeOnline": false } }';
const _callInviteEnded =
    '{ "type": "call.invite.ended", "data": { "inviteId": "0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b", "reason": "timeout" } }';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';

void main() {
  test('contact.pending (có reqId)', () {
    final m = ServerMessage.parse(_contactPending);
    expect(m, isA<ContactPending>());
    expect((m as ContactPending).roomName, _room);
    expect(m.reqId, 'c-20');
  });

  test('contact.requested', () {
    final m = ServerMessage.parse(_contactRequested);
    expect(m, isA<ContactRequested>());
    expect((m as ContactRequested).roomName, _room);
    expect(m.reqId, isNull);
  });

  test('contact.added mang hồ sơ người kia', () {
    final m = ServerMessage.parse(_contactAdded);
    expect(m, isA<ContactAdded>());
    final added = m as ContactAdded;
    expect(added.roomName, _room);
    expect(added.contact.id, 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(added.contact.displayName, 'Anna');
    expect(added.contact.language, 'en');
    expect(added.contact.online, isTrue);
    expect(added.contact.addedAt, DateTime.utc(2026, 10, 6, 9, 30));
  });

  test('call.invite (server → người được mời)', () {
    final m = ServerMessage.parse(_callInvite);
    expect(m, isA<CallInviteIncoming>());
    final inv = (m as CallInviteIncoming).invite;
    expect(inv.inviteId, '0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b');
    expect(inv.from.id, 'Xk3vN0aQp1L7cWm2RtY8bA');
    expect(inv.from.displayName, 'Minh');
    expect(inv.from.language, 'vi');
    expect(inv.expiresAt, DateTime.utc(2026, 10, 6, 9, 30, 30));
  });

  test('call.inviting', () {
    final m = ServerMessage.parse(_callInviting);
    expect(m, isA<CallInviting>());
    final inv = (m as CallInviting).invite;
    expect(inv.inviteId, '0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b');
    expect(inv.contactId, 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(inv.expiresAt, DateTime.utc(2026, 10, 6, 9, 30, 30));
    expect(inv.calleeOnline, isFalse);
    expect(m.reqId, 'c-21');
  });

  test('call.invite.ended + 5 hằng số lý do', () {
    final m = ServerMessage.parse(_callInviteEnded);
    expect(m, isA<CallInviteEnded>());
    expect((m as CallInviteEnded).reason, CallInviteEnded.timeout);
    expect(
      <String>[
        CallInviteEnded.declined,
        CallInviteEnded.cancelled,
        CallInviteEnded.timeout,
        CallInviteEnded.busy,
        CallInviteEnded.failed,
      ],
      <String>['declined', 'cancelled', 'timeout', 'busy', 'failed'],
    );
  });

  group('thiếu trường bắt buộc → UnknownMessage (không ném)', () {
    const cases = <String, String>{
      'contact.pending thiếu roomName': '{"type":"contact.pending","data":{}}',
      'contact.requested roomName sai kiểu': '{"type":"contact.requested","data":{"roomName":5}}',
      'contact.added thiếu contact': '{"type":"contact.added","data":{"roomName":"$_room"}}',
      'contact.added contact thiếu online':
          '{"type":"contact.added","data":{"roomName":"$_room","contact":{"id":"a","displayName":"b","language":"en","addedAt":"2026-10-06T09:30:00.000Z"}}}',
      'call.invite thiếu from':
          '{"type":"call.invite","data":{"inviteId":"x","expiresAt":"2026-10-06T09:30:30.000Z"}}',
      'call.invite expiresAt sai định dạng':
          '{"type":"call.invite","data":{"inviteId":"x","from":{"id":"a","displayName":"b","language":"vi"},"expiresAt":"hôm qua"}}',
      'call.inviting thiếu calleeOnline':
          '{"type":"call.inviting","data":{"inviteId":"x","contactId":"y","expiresAt":"2026-10-06T09:30:30.000Z"}}',
      'call.invite.ended thiếu reason': '{"type":"call.invite.ended","data":{"inviteId":"x"}}',
    };
    cases.forEach((name, raw) {
      test(name, () {
        expect(ServerMessage.parse(raw), isA<UnknownMessage>());
      });
    });
  });

  test('type lạ vẫn là UnknownMessage', () {
    final m = ServerMessage.parse('{"type":"contact.exploded","data":{}}');
    expect(m, isA<UnknownMessage>());
    expect((m as UnknownMessage).type, 'contact.exploded');
  });

  test('GĐ1 không đổi: match.found vẫn parse đúng 3 trường peer', () {
    const raw = '{"type":"call.ended","data":{"roomName":"$_room","reason":"peer_left"}}';
    expect(ServerMessage.parse(raw), isA<CallEnded>());
  });
}
