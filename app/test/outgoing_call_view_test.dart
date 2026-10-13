import 'package:cham/models/invite.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/invite_controller.dart';
import 'package:cham/widgets/outgoing_call_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

/// `OutgoingCallView` có hoạt ảnh lặp vô hạn nên KHÔNG dùng `pumpAndSettle`: chỉ `pump` cố định.
void main() {
  late FakeWsClient ws;
  late FakeRoom room;
  late FakeTimers timers;
  late InviteController invites;

  Widget view({Locale locale = const Locale('vi'), double textScale = 1.0}) => harness(
        invites: invites,
        locale: locale,
        textScale: textScale,
        home: const Scaffold(body: OutgoingCallView()),
      );

  setUp(() {
    ws = FakeWsClient()..emitState(WsConnState.connected);
    room = FakeRoom();
    timers = FakeTimers();
    invites = InviteController(
      ws: ws,
      permissions: FakePermissionGateway(),
      swipe: room,
      timerFactory: timers.create,
    );
  });

  tearDown(() => invites.dispose());

  testWidgets('chưa gọi ai: không hiện gì', (tester) async {
    await tester.pumpWidget(view());
    expect(find.text('Hủy cuộc gọi'), findsNothing);
  });

  testWidgets('đang gọi: tên, "Đang gọi {name}…", nút Hủy gửi call.invite.cancel', (tester) async {
    await tester.pumpWidget(view());
    expect(await invites.invite(makeContact(name: 'Anna')), isTrue);
    await tester.pump();
    ws.emit(CallInviting(OutgoingInvite(
      inviteId: 'inv-1',
      contactId: kPeerId,
      expiresAt: DateTime.now().add(const Duration(seconds: 30)),
      calleeOnline: true,
    )));
    await tester.pump();

    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Đang gọi Anna…'), findsOneWidget);
    expect(find.text('Hủy cuộc gọi'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(ws.sentTypes, contains('call.invite.cancel'));
    expect(invites.status, InviteStatus.none);
  });

  testWidgets('en, 320dp, chữ 1,3, tên rất dài: không tràn', (tester) async {
    useNarrowSurface(tester);
    await tester.pumpWidget(view(locale: const Locale('en'), textScale: 1.3));
    expect(await invites.invite(makeContact(name: 'A very long contact display name indeed')), isTrue);
    await tester.pump();
    expect(find.text('Cancel call'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
