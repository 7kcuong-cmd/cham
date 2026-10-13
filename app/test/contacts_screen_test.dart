import 'dart:async';

import 'package:cham/screens/contacts_screen.dart';
import 'package:cham/services/push_service.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:cham/state/invite_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

/// Thông báo đẩy giả: chỉ để điều khiển `notificationsEnabled`.
class _FakePush implements PushService {
  _FakePush({bool enabled = true}) : _enabled = ValueNotifier<bool>(enabled);

  final ValueNotifier<bool> _enabled;

  @override
  Future<void> start() async {}

  @override
  Stream<String> get openedInviteIds => const Stream<String>.empty();

  @override
  ValueListenable<bool> get notificationsEnabled => _enabled;

  @override
  Future<void> unregister() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late FakePermissionGateway perms;
  late FakeRoom room;
  late FakeTimers timers;
  late ContactsController contacts;
  late InviteController invites;

  Widget app({
    Locale locale = const Locale('vi'),
    double textScale = 1.0,
    PushService? push,
  }) =>
      harness(
        contacts: contacts,
        invites: invites,
        push: push ?? _FakePush(),
        locale: locale,
        textScale: textScale,
        home: const Scaffold(body: ContactsScreen()),
      );

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient()..emitState(WsConnState.connected);
    perms = FakePermissionGateway();
    room = FakeRoom();
    timers = FakeTimers();
    contacts = ContactsController(api: api, ws: ws, room: room);
    invites = InviteController(
      ws: ws,
      permissions: perms,
      swipe: room,
      timerFactory: timers.create,
    );
  });

  tearDown(() {
    invites.dispose();
    contacts.dispose();
  });

  testWidgets('tải danh bạ khi mở: tên, chip ngôn ngữ, nút gọi', (tester) async {
    api.onGetContacts = () async => [
          makeContact(id: 'a', name: 'Anna', language: 'en', online: true),
          makeContact(id: 'b', name: 'Bình', language: 'vi'),
        ];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(api.log, contains('getContacts'));
    expect(find.text('Danh bạ'), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Bình'), findsOneWidget);
    expect(find.text('EN'), findsOneWidget);
    expect(find.text('VI'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsNWidgets(2));
    expect(find.byTooltip('Gọi'), findsNWidgets(2));
  });

  testWidgets('danh sách rỗng: biểu tượng + lời giải thích', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.people_outline_rounded), findsOneWidget);
    expect(find.textContaining('Chưa có bạn nào'), findsOneWidget);
  });

  testWidgets('lỗi mạng khi tải: hiện lỗi dịch + nút Thử lại; thử lại thành công', (tester) async {
    api.onGetContacts = () async => throw apiError('NETWORK');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Không có kết nối mạng.'), findsOneWidget);

    api.onGetContacts = () async => [makeContact(name: 'Anna')];
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Anna'), findsOneWidget);
  });

  testWidgets('bấm nút gọi → call.invite {contactId}', (tester) async {
    api.onGetContacts = () async => [makeContact(id: kPeerId, name: 'Anna')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.videocam_rounded));
    await tester.pump();
    await tester.pump();
    expect(ws.sent.single.type, 'call.invite');
    expect(ws.sent.single.data, {'contactId': kPeerId});
  });

  testWidgets('đang có lời mời đi: nút gọi bị vô hiệu', (tester) async {
    api.onGetContacts = () async => [makeContact(id: kPeerId, name: 'Anna')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await invites.invite(makeContact(id: 'khac', name: 'Khác'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.videocam_rounded));
    await tester.pump();
    expect(ws.sent.where((m) => m.type == 'call.invite'), hasLength(1));
  });

  testWidgets('nhấn giữ → sheet Xóa / Chặn / Hủy; xóa có hộp thoại xác nhận rồi gọi API', (tester) async {
    api.onGetContacts = () async => [makeContact(id: 'a', name: 'Anna')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Anna'));
    await tester.pumpAndSettle();
    expect(find.text('Xóa khỏi danh bạ'), findsOneWidget);
    expect(find.text('Chặn Anna'), findsOneWidget);
    expect(find.text('Hủy'), findsOneWidget);

    await tester.tap(find.text('Xóa khỏi danh bạ'));
    await tester.pumpAndSettle();
    expect(find.text('Xóa Anna khỏi danh bạ?'), findsOneWidget);
    expect(find.text('Hai bạn sẽ không còn trong danh bạ của nhau.'), findsOneWidget);

    await tester.tap(find.text('Xóa'));
    await tester.pumpAndSettle();
    expect(api.log, contains('removeContact(a)'));
    expect(find.text('Anna'), findsNothing);
  });

  testWidgets('hủy hộp thoại xóa thì không gọi API', (tester) async {
    api.onGetContacts = () async => [makeContact(id: 'a', name: 'Anna')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xóa khỏi danh bạ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(api.log.where((e) => e.startsWith('removeContact')), isEmpty);
    expect(find.text('Anna'), findsOneWidget);
  });

  testWidgets('nhấn giữ → Chặn: xác nhận rồi POST /v1/blocks và gỡ khỏi danh sách', (tester) async {
    api.onGetContacts = () async => [makeContact(id: 'a', name: 'Anna')];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chặn Anna'));
    await tester.pumpAndSettle();
    expect(find.text('Chặn Anna?'), findsOneWidget);
    await tester.tap(find.text('Chặn'));
    await tester.pumpAndSettle();

    expect(api.log, contains('block(a)'));
    expect(find.text('Anna'), findsNothing);
    expect(find.text('Đã chặn.'), findsOneWidget);
  });

  testWidgets('chưa cấp quyền thông báo: nhắc bật thông báo', (tester) async {
    await tester.pumpWidget(app(push: _FakePush(enabled: false)));
    await tester.pumpAndSettle();
    expect(find.text('Bật thông báo để không lỡ cuộc gọi từ bạn bè.'), findsOneWidget);
  });

  testWidgets('đã cấp quyền thông báo: không nhắc', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('Bật thông báo'), findsNothing);
  });

  testWidgets('màn 320 dp, bản en, chữ 1,3, tên dài: không tràn', (tester) async {
    useNarrowSurface(tester);
    api.onGetContacts = () async => [
          makeContact(id: 'a', name: 'Nguyễn Thị Thanh Hằng Phương Anh', language: 'vi', online: true),
        ];
    await tester.pumpWidget(app(locale: const Locale('en'), textScale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('Contacts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('en: danh sách rỗng dùng chuỗi tiếng Anh', (tester) async {
    await tester.pumpWidget(app(locale: const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No contacts yet'), findsOneWidget);
  });
}
