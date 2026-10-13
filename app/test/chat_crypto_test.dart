import 'package:cham/models/chat_message.dart';
import 'package:cham/services/chat_crypto.dart';
import 'package:cham/services/chat_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mã hóa đầu cuối: A mã hóa, B giải mã; người thứ ba không giải mã được', () async {
    final a = ChatCrypto();
    final b = ChatCrypto();
    final c = ChatCrypto();
    await a.init(null);
    await b.init(null);
    await c.init(null);
    final body = await a.encrypt(await b.publicKeyBase64(), 'xin chào 👋');
    expect(await b.decrypt(await a.publicKeyBase64(), body), 'xin chào 👋');
    expect(body.contains('xin'), isFalse);
    await expectLater(c.decrypt(await a.publicKeyBase64(), body), throwsA(anything));
  });

  test('cùng hạt giống cho cùng khóa công khai', () async {
    final a = ChatCrypto();
    final seed = await a.init(null);
    final again = ChatCrypto();
    await again.init(seed);
    expect(await again.publicKeyBase64(), await a.publicKeyBase64());
  });

  test('MemoryChatStore: lưu, sắp theo thời gian, tin đang gửi', () async {
    final s = MemoryChatStore();
    final t0 = DateTime.utc(2026, 10, 9);
    await s.save(ChatMessage(id: 'b', peerId: 'p', mine: true, text: 'hai', at: t0.add(const Duration(seconds: 2)), status: ChatStatus.sending));
    await s.save(ChatMessage(id: 'a', peerId: 'p', mine: false, text: 'một', at: t0, status: ChatStatus.received));
    expect((await s.load('p')).map((m) => m.id), ['a', 'b']);
    expect((await s.pending()).map((m) => m.id), ['b']);
    expect(await s.has('p', 'a'), isTrue);
    await s.save((await s.load('p')).last.withStatus(ChatStatus.sent));
    expect(await s.pending(), isEmpty);
  });

  test('ChatMessage JSON khứ hồi', () {
    final m = ChatMessage(id: 'x', peerId: 'p', mine: true, text: 't', at: DateTime.utc(2026, 1, 1), status: ChatStatus.sent);
    final back = ChatMessage.tryParse(m.toJson());
    expect(back?.text, 't');
    expect(back?.status, ChatStatus.sent);
    expect(ChatMessage.tryParse({'id': 1}), isNull);
  });
}
