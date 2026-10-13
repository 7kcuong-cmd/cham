import 'package:cham/models/chat_message.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/chat_crypto.dart';
import 'package:cham/services/chat_store.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

class _KeyApi extends FakeApiClient {
  String? key;

  @override
  Future<String?> getChatKey(String userId) async => key;
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _id(int n) => '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

void main() {
  late FakeWsClient ws;
  late _KeyApi api;
  late MemoryChatStore store;
  late ChatController chat;
  late String peerKey;
  var n = 0;

  setUp(() async {
    final peer = ChatCrypto();
    await peer.init(null);
    peerKey = await peer.publicKeyBase64();
    ws = FakeWsClient()..emitState(WsConnState.connected);
    api = _KeyApi()..key = peerKey;
    store = MemoryChatStore();
    n = 0;
    chat = ChatController(api: api, ws: ws, store: store, newId: () => _id(++n), useRatchet: false);
    await settle();
    ws.sent.clear();
  });

  tearDown(() => chat.dispose());

  test('gửi: đi qua server ngay (không chờ kênh trực tiếp), có dm.sent thì thành "đã gửi"', () async {
    await chat.open(kPeerId);
    expect(await chat.send(kPeerId, 'xin chào'), isTrue);
    await settle();
    final sends = ws.sent.where((m) => m.type == 'dm.send').toList();
    expect(sends, hasLength(1));
    expect(sends.single.data['toUserId'], kPeerId);
    expect(sends.single.data['msgId'], _id(1));
    expect(chat.thread(kPeerId).single.status, ChatStatus.sending);

    ws.emit(DmSent(_id(1), true));
    await settle();
    expect(chat.thread(kPeerId).single.status, ChatStatus.sent);
  });

  test('người kia báo đã đọc → "đã đọc"; dm.sent đến muộn không hạ cấp', () async {
    await chat.open(kPeerId);
    await chat.send(kPeerId, 'a');
    await settle();
    ws.emit(DmRead(kPeerId, [_id(1)]));
    await settle();
    expect(chat.thread(kPeerId).single.status, ChatStatus.read);
    ws.emit(DmSent(_id(1), true));
    await settle();
    expect(chat.thread(kPeerId).single.status, ChatStatus.read);
  });

  test('mở màn trò chuyện: báo đã đọc các tin chưa đọc, chỉ một lần', () async {
    await store.save(ChatMessage(id: _id(50), peerId: kPeerId, mine: false, text: 'hi', at: DateTime.utc(2026, 10, 9), status: ChatStatus.received));
    await chat.open(kPeerId);
    await settle();
    final reads = ws.sent.where((m) => m.type == 'dm.read').toList();
    expect(reads, hasLength(1));
    expect(reads.single.data, {'toUserId': kPeerId, 'msgIds': [_id(50)]});
    expect(chat.thread(kPeerId).single.status, ChatStatus.read);
    await chat.open(kPeerId);
    await settle();
    expect(ws.sent.where((m) => m.type == 'dm.read'), hasLength(1));
  });

  test('đang nhập: nhận dm.typing → isTyping; gửi dm.typing bị giới hạn 1 lần / 3 giây', () async {
    ws.emit(DmTyping(kPeerId));
    await settle();
    expect(chat.isTyping(kPeerId), isTrue);
    chat.notifyTyping(kPeerId);
    chat.notifyTyping(kPeerId);
    expect(ws.sent.where((m) => m.type == 'dm.typing'), hasLength(1));
  });

  test('người kia chưa có khóa → báo lỗi ngay; có khóa rồi thì bấm gửi lại được', () async {
    api.key = null;
    await chat.open(kPeerId);
    await chat.send(kPeerId, 'x');
    await settle();
    expect(chat.thread(kPeerId).single.status, ChatStatus.failed);
    expect(ws.sent.where((m) => m.type == 'dm.send'), isEmpty);

    api.key = peerKey;
    await chat.retry(_id(1), kPeerId);
    await settle();
    expect(ws.sent.where((m) => m.type == 'dm.send'), hasLength(1));
    expect(chat.thread(kPeerId).single.status, ChatStatus.sending);
  });
}
