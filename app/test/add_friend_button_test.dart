import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/contacts_controller.dart';
import 'package:cham/widgets/add_friend_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late FakeRoom room;
  late ContactsController contacts;

  Widget app({Locale locale = const Locale('vi')}) => harness(
        contacts: contacts,
        locale: locale,
        home: Scaffold(
          body: Center(child: AddFriendButton(peer: makeMatch().peer)),
        ),
      );

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    room = FakeRoom(room: kRoom, peer: makeMatch().peer);
    contacts = ContactsController(api: api, ws: ws, room: room);
  });

  tearDown(() => contacts.dispose());

  testWidgets('ban đầu: biểu tượng thêm bạn, tooltip "Thêm bạn"; bấm → contact.add', (tester) async {
    await tester.pumpWidget(app());
    expect(find.byIcon(Icons.person_add_rounded), findsOneWidget);
    expect(find.byTooltip('Thêm bạn'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.person_add_rounded));
    await tester.pump();
    expect(ws.sent.single.type, 'contact.add');
    expect(ws.sent.single.data, {'roomName': kRoom});
  });

  testWidgets('contact.pending → đồng hồ cát, vô hiệu (bấm không gửi thêm)', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(const ContactPending(kRoom));
    await tester.pump();
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    expect(find.byIcon(Icons.person_add_rounded), findsNothing);

    await tester.tap(find.byIcon(Icons.hourglass_top_rounded));
    await tester.pump();
    expect(ws.sent, isEmpty);
  });

  testWidgets('contact.requested → vẫn bấm được, viền nhấp nháy rồi tắt', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(const ContactRequested(kRoom));
    await tester.pump();
    expect(find.byIcon(Icons.person_add_rounded), findsOneWidget);
    expect(contacts.addFriendState, AddFriendState.requested);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 3)); // nhấp nháy xong
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.person_add_rounded));
    await tester.pump();
    expect(ws.sent.single.type, 'contact.add');
  });

  testWidgets('contact.added → "đã là bạn" (how_to_reg), vô hiệu', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(ContactAdded(kRoom, makeContact()));
    await tester.pump();
    expect(find.byIcon(Icons.how_to_reg_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.how_to_reg_rounded));
    await tester.pump();
    expect(ws.sent, isEmpty);
  });

  testWidgets('đã là bạn từ trước (có trong danh bạ) → ẩn nút', (tester) async {
    api.onGetContacts = () async => [makeContact()];
    await contacts.load();
    await tester.pumpWidget(app());
    expect(find.byIcon(Icons.person_add_rounded), findsNothing);
    expect(find.byType(AddFriendButton), findsOneWidget);
    expect(tester.getSize(find.byType(AddFriendButton)), Size.zero);
  });

  testWidgets('bản en: tooltip "Add friend"', (tester) async {
    await tester.pumpWidget(app(locale: const Locale('en')));
    expect(find.byTooltip('Add friend'), findsOneWidget);
  });
}
