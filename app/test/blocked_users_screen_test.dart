import 'package:cham/models/api_error.dart';
import 'package:cham/models/blocked_user.dart';
import 'package:cham/screens/blocked_users_screen.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

BlockedUser _b(String id, String name) =>
    BlockedUser(userId: id, displayName: name, createdAt: DateTime.utc(2026, 10, 5));

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late FakeRoom room;
  late ContactsController contacts;

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    room = FakeRoom();
    contacts = ContactsController(api: api, ws: ws, room: room);
  });

  tearDown(() => contacts.dispose());

  Future<void> open(WidgetTester tester, {String lang = 'vi', double scale = 1.0}) async {
    await tester.pumpWidget(harness(
      contacts: contacts,
      locale: Locale(lang),
      textScale: scale,
      home: const BlockedUsersScreen(),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('danh sách rỗng: "Bạn chưa chặn ai."', (tester) async {
    await open(tester);
    expect(find.text('Người đã chặn'), findsOneWidget);
    expect(find.text('Bạn chưa chặn ai.'), findsOneWidget);
  });

  testWidgets('bỏ chặn: hỏi xác nhận, đồng ý thì gọi API và xóa khỏi danh sách', (tester) async {
    api.onGetBlocks = () async => [_b('u1', 'Hùng'), _b('u2', 'Lan')];
    await open(tester);
    expect(find.text('Hùng'), findsOneWidget);

    await tester.tap(find.text('Bỏ chặn').first);
    await tester.pumpAndSettle();
    expect(find.text('Bỏ chặn Hùng?'), findsOneWidget);

    await tester.tap(find.text('Bỏ chặn').last);
    await tester.pumpAndSettle();
    expect(api.log, contains('unblock(u1)'));
    expect(find.text('Hùng'), findsNothing);
    expect(find.text('Lan'), findsOneWidget);
  });

  testWidgets('hủy xác nhận: không gọi API', (tester) async {
    api.onGetBlocks = () async => [_b('u1', 'Hùng')];
    await open(tester);
    await tester.tap(find.text('Bỏ chặn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();
    expect(api.log.where((e) => e.startsWith('unblock')), isEmpty);
    expect(find.text('Hùng'), findsOneWidget);
  });

  testWidgets('bỏ chặn lỗi: báo lỗi, người đó vẫn trong danh sách', (tester) async {
    api.onGetBlocks = () async => [_b('u1', 'Hùng')];
    api.onUnblock = (id) async => throw const ApiException(code: 'NETWORK');
    await open(tester);
    await tester.tap(find.text('Bỏ chặn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bỏ chặn').last);
    await tester.pumpAndSettle();
    expect(find.text('Không có kết nối mạng.'), findsOneWidget);
    expect(find.text('Hùng'), findsOneWidget);
  });

  testWidgets('en, 320dp, chữ 1,3: không tràn', (tester) async {
    useNarrowSurface(tester);
    api.onGetBlocks = () async => [_b('u1', 'A very long blocked display name here')];
    await open(tester, lang: 'en', scale: 1.3);
    expect(find.text('Blocked people'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
