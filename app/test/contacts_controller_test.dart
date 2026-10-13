import 'package:cham/models/blocked_user.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late FakeRoom room;
  late ContactsController c;

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    room = FakeRoom();
    c = ContactsController(api: api, ws: ws, room: room);
  });

  tearDown(() => c.dispose());

  test('load: lấy danh sách từ API, loaded=true, isContact đúng', () async {
    api.onGetContacts = () async => [makeContact(id: 'a', name: 'An'), makeContact(id: 'b', name: 'Bo')];
    await c.load();
    expect(c.loaded, isTrue);
    expect(c.loadError, isNull);
    expect(c.contacts.map((x) => x.displayName), ['An', 'Bo']);
    expect(c.isContact('a'), isTrue);
    expect(c.isContact('zzz'), isFalse);
  });

  test('load lỗi mạng: giữ danh sách cũ, loadError=NETWORK', () async {
    api.onGetContacts = () async => [makeContact(id: 'a')];
    await c.load();
    api.onGetContacts = () async => throw apiError('NETWORK');
    await c.load();
    expect(c.loadError, 'NETWORK');
    expect(c.contacts, hasLength(1));
    expect(c.loading, isFalse);
  });

  test('remove: gọi API rồi xóa khỏi danh sách', () async {
    api.onGetContacts = () async => [makeContact(id: 'a'), makeContact(id: 'b')];
    await c.load();
    final error = await c.remove('a');
    expect(error, isNull);
    expect(api.log, contains('removeContact(a)'));
    expect(c.contacts.map((x) => x.id), ['b']);
  });

  test('remove lỗi: trả mã lỗi, danh sách không đổi', () async {
    api.onGetContacts = () async => [makeContact(id: 'a')];
    await c.load();
    api.onRemoveContact = (_) async => throw apiError('NETWORK');
    expect(await c.remove('a'), 'NETWORK');
    expect(c.contacts, hasLength(1));
  });

  test('block: gọi POST /v1/blocks và gỡ khỏi danh bạ', () async {
    api.onGetContacts = () async => [makeContact(id: 'a')];
    await c.load();
    expect(await c.block('a'), isNull);
    expect(api.log, contains('block(a)'));
    expect(c.contacts, isEmpty);
  });

  test('loadBlocked + unblock: bỏ khỏi danh sách chặn, không đụng danh bạ', () async {
    api.onGetBlocks = () async => [
          BlockedUser(userId: 'x', displayName: 'Xa', createdAt: DateTime.utc(2026, 10, 5)),
          BlockedUser(userId: 'y', displayName: 'Yi', createdAt: DateTime.utc(2026, 10, 4)),
        ];
    api.onGetContacts = () async => [makeContact(id: 'a')];
    await c.load();
    await c.loadBlocked();
    expect(c.blocked.map((b) => b.userId), ['x', 'y']);

    expect(await c.unblock('x'), isNull);
    expect(api.log, contains('unblock(x)'));
    expect(c.blocked.map((b) => b.userId), ['y']);
    expect(c.contacts, hasLength(1)); // bỏ chặn không khôi phục danh bạ
  });

  test('ContactAdded thêm phần tử, không trùng khi nhận hai lần', () async {
    room.enter(kRoom);
    ws.emit(ContactAdded(kRoom, makeContact(id: 'p1', name: 'Anna')));
    await _settle();
    ws.emit(ContactAdded(kRoom, makeContact(id: 'p1', name: 'Anna', online: true)));
    await _settle();
    expect(c.contacts, hasLength(1));
    expect(c.contacts.single.online, isTrue); // bản mới thay bản cũ
    expect(c.isContact('p1'), isTrue);
  });

  group('nút Thêm bạn', () {
    test('requestAdd gửi contact.add đúng phòng; ngoài cuộc gọi thì không gửi', () async {
      c.requestAdd();
      expect(ws.sent, isEmpty);
      room.enter(kRoom);
      c.requestAdd();
      expect(ws.sent.single.type, 'contact.add');
      expect(ws.sent.single.data, {'roomName': kRoom});
    });

    test('idle → pending → added (+ sự kiện toast có tên đối phương)', () async {
      room.enter(kRoom);
      final events = <FriendEvent>[];
      final sub = c.events.listen(events.add);
      expect(c.addFriendState, AddFriendState.idle);

      ws.emit(const ContactPending(kRoom));
      await _settle();
      expect(c.addFriendState, AddFriendState.pending);

      ws.emit(ContactAdded(kRoom, makeContact(id: 'p1', name: 'Anna')));
      await _settle();
      expect(c.addFriendState, AddFriendState.added);

      expect(events.map((e) => e.kind), [FriendEventKind.pending, FriendEventKind.added]);
      expect(events.first.name, 'Anna'); // tên từ peer của phòng
      expect(events.last.name, 'Anna');
      await sub.cancel();
    });

    test('đối phương bấm trước: requested; sau đó mình bấm → added', () async {
      room.enter(kRoom);
      ws.emit(const ContactRequested(kRoom));
      await _settle();
      expect(c.addFriendState, AddFriendState.requested);
      ws.emit(ContactAdded(kRoom, makeContact()));
      await _settle();
      expect(c.addFriendState, AddFriendState.added);
    });

    test('thông điệp của phòng khác bị bỏ qua', () async {
      room.enter(kRoom);
      ws.emit(const ContactPending('r_khac'));
      await _settle();
      expect(c.addFriendState, AddFriendState.idle);
    });

    test('đổi phòng hoặc hết cuộc gọi → quay về idle', () async {
      room.enter(kRoom);
      ws.emit(const ContactPending(kRoom));
      await _settle();
      expect(c.addFriendState, AddFriendState.pending);
      room.enter('r_moi');
      expect(c.addFriendState, AddFriendState.idle);
      ws.emit(const ContactPending('r_moi'));
      await _settle();
      room.leave();
      expect(c.addFriendState, AddFriendState.idle);
    });

    test('CONTACT_LIMIT báo lỗi qua events', () async {
      room.enter(kRoom);
      final events = <FriendEvent>[];
      final sub = c.events.listen(events.add);
      ws.emit(const ServerError('CONTACT_LIMIT', 'full'));
      await _settle();
      expect(events.single.kind, FriendEventKind.error);
      expect(events.single.errorCode, 'CONTACT_LIMIT');
      await sub.cancel();
    });

    test('đã thành bạn thì requestAdd không gửi nữa', () async {
      room.enter(kRoom);
      ws.emit(ContactAdded(kRoom, makeContact()));
      await _settle();
      c.requestAdd();
      expect(ws.sent, isEmpty);
    });
  });

  test('reset xóa danh bạ và danh sách chặn', () async {
    api.onGetContacts = () async => [makeContact(id: 'a')];
    await c.load();
    c.reset();
    expect(c.contacts, isEmpty);
    expect(c.loaded, isFalse);
  });
}
