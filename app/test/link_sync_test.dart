import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:cham/models/chat_message.dart';
import 'package:cham/services/link_channel.dart';
import 'package:cham/services/link_sync.dart';

class _Pipe implements LinkTransport {
  final StreamController<String> _in = StreamController<String>.broadcast();
  _Pipe? other;
  final List<String> seen = <String>[];

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String text) {
    seen.add(text);
    scheduleMicrotask(() => other?._in.add(text));
  }

  @override
  Future<void> close() async {}
}

class _Chat implements LinkChatPort {
  final Map<String, List<ChatMessage>> data = <String, List<ChatMessage>>{};
  final StreamController<ChatMessage> ctl = StreamController<ChatMessage>.broadcast();
  final List<(String, String)> sent = <(String, String)>[];

  @override
  Future<Map<String, String>> names() async => {for (final k in data.keys) k: 'Tên $k'};
  @override
  Future<List<String>> peers() async => data.keys.toList();
  @override
  Future<List<ChatMessage>> load(String p) async => data[p] ?? <ChatMessage>[];
  @override
  Stream<ChatMessage> get changes => ctl.stream;
  @override
  Future<bool> send(String p, String t) async {
    sent.add((p, t));
    return true;
  }
}

ChatMessage msg(String id, String peer, int s) => ChatMessage(
    id: id, peerId: peer, mine: false, text: 'tin $id', at: DateTime.utc(2026, 10, 9, 0, 0, s), status: ChatStatus.received);

Future<(LinkChannel, LinkChannel, _Pipe)> pair() async {
  final a = _Pipe();
  final b = _Pipe();
  a.other = b;
  b.other = a;
  final ca = LinkChannel(a);
  final cb = LinkChannel(b);
  await Future.wait([ca.start(), cb.start()]);
  await Future.wait([ca.ready, cb.ready]);
  return (ca, cb, a);
}

void main() {
  test('hai bên ra cùng mã 6 số và bản mã không lộ nội dung', () async {
    final (ca, cb, wire) = await pair();
    expect(ca.shortCode, cb.shortCode);
    expect(ca.shortCode!.length, 6);
    final got = cb.messages.first;
    await ca.send({'t': 'x', 'secret': 'xin-chao-bi-mat'});
    expect((await got)['secret'], 'xin-chao-bi-mat');
    expect(wire.seen.any((s) => s.contains('xin-chao-bi-mat')), isFalse);
  });

  test('đồng bộ toàn bộ lịch sử theo từng đoạn, rồi nhận tin mới và gửi tin', () async {
    final (phoneCh, webCh, _) = await pair();
    final chat = _Chat();
    chat.data['p1'] = [for (var i = 0; i < 5; i++) msg('a$i', 'p1', i)];
    chat.data['p2'] = [msg('b0', 'p2', 9)];
    final host = LinkHost(channel: phoneCh, chat: chat, chunkSize: 2)..approve();
    final web = LinkClient(webCh);

    expect(await web.sync(), 6);
    expect(web.nameOf('p1'), 'Tên p1');
    expect(web.messages('p1').length, 5);
    expect(web.messages('p2').single.text, 'tin b0');

    final changed = web.changed.first;
    chat.ctl.add(msg('n1', 'p1', 20));
    await changed;
    expect(web.messages('p1').last.id, 'n1');

    expect(await web.send('p2', 'chào'), isTrue);
    expect(chat.sent.single, ('p2', 'chào'));
    await host.dispose();
  });

  test('chưa approve thì điện thoại không trả lời web', () async {
    final (phoneCh, webCh, _) = await pair();
    LinkHost(channel: phoneCh, chat: _Chat());
    final web = LinkClient(webCh);
    final r = web.sync().timeout(const Duration(milliseconds: 200), onTimeout: () => -1);
    expect(await r, -1);
  });

  test('QR: điện thoại chỉ chấp nhận đúng khóa web trong mã QR', () async {
    final a = _Pipe();
    final b = _Pipe();
    a.other = b;
    b.other = a;
    final web = LinkChannel(a);
    await web.start();
    final qr = LinkPairing('abc_DEF-123', web.localFingerprint!);
    final parsed = LinkPairing.parse(qr.qrPayload)!;
    final phone = LinkChannel(b, expectedPeerFingerprint: parsed.fingerprint);
    await phone.start();
    await web.hello();
    await Future.wait([web.ready, phone.ready]);
    expect(phone.shortCode, web.shortCode);
  });

  test('QR: khóa lạ (kẻ chen giữa) bị từ chối', () async {
    final a = _Pipe();
    final b = _Pipe();
    a.other = b;
    b.other = a;
    final attacker = LinkChannel(a);
    await attacker.start();
    final phone = LinkChannel(b, expectedPeerFingerprint: 'van-tay-cua-web-that');
    await phone.start();
    await attacker.hello();
    await expectLater(phone.ready, throwsA(isA<StateError>()));
    await expectLater(phone.send({'t': 'x'}), throwsA(isA<StateError>()));
  });

  test('LinkPairing.parse từ chối chuỗi sai', () {
    expect(LinkPairing.parse('hello'), isNull);
    expect(LinkPairing.parse('cham-link:2:a:b'), isNull);
    expect(LinkPairing.parse('cham-link:1:a b:c'), isNull);
  });
}
