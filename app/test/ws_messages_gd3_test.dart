import 'package:cham/models/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

// Mẫu JSON sao chép nguyên văn từ API-GD2-4.md §3.5.
const _commentReceived =
    '{ "type": "comment.received", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "commentId": "5a0c0e0e-1b2c-4d3e-8f40-516273849a0b", "text": "Xin chào ***", "sentAt": "2026-10-06T09:30:05.000Z" } }';
const _commentSent =
    '{ "type": "comment.sent", "reqId": "c-22", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "commentId": "5a0c0e0e-1b2c-4d3e-8f40-516273849a0b", "text": "Xin chào ***", "sentAt": "2026-10-06T09:30:05.000Z" } }';
const _heartReceived =
    '{ "type": "heart.received", "data": { "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "count": 3 } }';
const _giftDrop =
    '{ "type": "gift.drop", "data": { "giftId": "9d7c3e2a-6b5f-4a1e-9c8d-7e6f5a4b3c2d", "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "points": 12, "expiresAt": "2026-10-06T09:31:20.000Z" } }';
const _giftClaimed =
    '{ "type": "gift.claimed", "reqId": "c-23", "data": { "giftId": "9d7c3e2a-6b5f-4a1e-9c8d-7e6f5a4b3c2d", "points": 12, "balance": 152 } }';
const _walletUpdated =
    '{ "type": "wallet.updated", "data": { "balance": 152, "delta": 12, "reason": "gift" } }';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';

void main() {
  test('comment.received', () {
    final m = ServerMessage.parse(_commentReceived);
    expect(m, isA<CommentReceived>());
    final c = (m as CommentReceived).comment;
    expect(c.roomName, _room);
    expect(c.commentId, '5a0c0e0e-1b2c-4d3e-8f40-516273849a0b');
    expect(c.text, 'Xin chào ***');
    expect(c.sentAt, DateTime.utc(2026, 10, 6, 9, 30, 5));
    expect(m.reqId, isNull);
  });

  test('comment.sent (có reqId, text là bản đã lọc)', () {
    final m = ServerMessage.parse(_commentSent);
    expect(m, isA<CommentSent>());
    expect((m as CommentSent).comment.text, 'Xin chào ***');
    expect(m.reqId, 'c-22');
  });

  test('heart.received', () {
    final m = ServerMessage.parse(_heartReceived);
    expect(m, isA<HeartReceived>());
    expect((m as HeartReceived).roomName, _room);
    expect(m.count, 3);
  });

  test('gift.drop', () {
    final m = ServerMessage.parse(_giftDrop);
    expect(m, isA<GiftDrop>());
    final g = (m as GiftDrop).gift;
    expect(g.giftId, '9d7c3e2a-6b5f-4a1e-9c8d-7e6f5a4b3c2d');
    expect(g.roomName, _room);
    expect(g.points, 12);
    expect(g.expiresAt, DateTime.utc(2026, 10, 6, 9, 31, 20));
  });

  test('gift.claimed', () {
    final m = ServerMessage.parse(_giftClaimed);
    expect(m, isA<GiftClaimed>());
    final c = m as GiftClaimed;
    expect(c.giftId, '9d7c3e2a-6b5f-4a1e-9c8d-7e6f5a4b3c2d');
    expect(c.points, 12);
    expect(c.balance, 152);
    expect(c.reqId, 'c-23');
  });

  test('wallet.updated', () {
    final m = ServerMessage.parse(_walletUpdated);
    expect(m, isA<WalletUpdated>());
    final w = m as WalletUpdated;
    expect(w.balance, 152);
    expect(w.delta, 12);
    expect(w.reason, 'gift');
  });

  test('số nguyên viết dạng 12.0 vẫn được chấp nhận', () {
    final m = ServerMessage.parse(
      '{"type":"wallet.updated","data":{"balance":152.0,"delta":-5.0,"reason":"unlock"}}',
    );
    expect(m, isA<WalletUpdated>());
    expect((m as WalletUpdated).delta, -5);
  });

  group('thiếu trường bắt buộc → UnknownMessage', () {
    const cases = <String, String>{
      'comment.received thiếu text':
          '{"type":"comment.received","data":{"roomName":"$_room","commentId":"c","sentAt":"2026-10-06T09:30:05.000Z"}}',
      'comment.sent sentAt sai':
          '{"type":"comment.sent","data":{"roomName":"$_room","commentId":"c","text":"a","sentAt":"x"}}',
      'heart.received thiếu count': '{"type":"heart.received","data":{"roomName":"$_room"}}',
      'heart.received count là chuỗi':
          '{"type":"heart.received","data":{"roomName":"$_room","count":"3"}}',
      'gift.drop thiếu points':
          '{"type":"gift.drop","data":{"giftId":"g","roomName":"$_room","expiresAt":"2026-10-06T09:31:20.000Z"}}',
      'gift.claimed thiếu balance': '{"type":"gift.claimed","data":{"giftId":"g","points":3}}',
      'wallet.updated thiếu reason': '{"type":"wallet.updated","data":{"balance":1,"delta":1}}',
    };
    cases.forEach((name, raw) {
      test(name, () {
        expect(ServerMessage.parse(raw), isA<UnknownMessage>());
      });
    });
  });
}
