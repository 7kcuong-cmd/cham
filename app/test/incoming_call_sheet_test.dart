import 'package:cham/l10n/app_localizations.dart';
import 'package:cham/models/invite.dart';
import 'package:cham/models/match_found.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/invite_controller.dart';
import 'package:cham/widgets/call_overlays.dart';
import 'package:cham/widgets/incoming_call_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeWsClient ws;
  late FakePermissionGateway perms;
  late FakeRoom room;
  late DateTime clock;
  late FakeTimers timers;
  late InviteController invites;

  IncomingInvite incoming({String name = 'Minh', int seconds = 30}) => IncomingInvite(
        inviteId: 'inv-1',
        from: Peer(id: kSelfId, displayName: name, language: 'vi'),
        expiresAt: clock.add(Duration(seconds: seconds)),
      );

  Widget sheet({Locale locale = const Locale('vi'), double textScale = 1.0}) => harness(
        invites: invites,
        locale: locale,
        textScale: textScale,
        home: Scaffold(body: IncomingCallSheet(now: () => clock)),
      );

  setUp(() {
    ws = FakeWsClient()..emitState(WsConnState.connected);
    perms = FakePermissionGateway();
    room = FakeRoom();
    clock = DateTime.utc(2026, 10, 6, 9, 30);
    timers = FakeTimers();
    invites = InviteController(
      ws: ws,
      permissions: perms,
      swipe: room,
      timerFactory: timers.create,
      now: () => clock,
    );
  });

  tearDown(() => invites.dispose());

  testWidgets('hiện "{name} đang gọi", đếm ngược 0:30, hai nút Từ chối / Nghe', (tester) async {
    await tester.pumpWidget(sheet());
    ws.emit(CallInviteIncoming(incoming()));
    await tester.pump();

    expect(find.text('Minh đang gọi'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('Từ chối'), findsOneWidget);
    expect(find.text('Nghe'), findsOneWidget);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
  });

  testWidgets('nút tròn 64 dp', (tester) async {
    await tester.pumpWidget(sheet());
    ws.emit(CallInviteIncoming(incoming()));
    await tester.pump();
    final decline = find.ancestor(
      of: find.byIcon(Icons.call_end_rounded),
      matching: find.byType(SizedBox),
    );
    expect(tester.getSize(decline.first), const Size(64, 64));
  });

  testWidgets('đồng hồ máy lệch (expiresAt quá xa): không hiện đếm ngược', (tester) async {
    await tester.pumpWidget(sheet());
    ws.emit(CallInviteIncoming(incoming(seconds: 7200)));
    await tester.pump();
    expect(find.text('Minh đang gọi'), findsOneWidget);
    expect(find.textContaining(':'), findsNothing);
  });

  testWidgets('bấm Từ chối → gửi call.decline đúng inviteId', (tester) async {
    await tester.pumpWidget(sheet());
    ws.emit(CallInviteIncoming(incoming()));
    await tester.pump();
    await tester.tap(find.text('Từ chối'));
    await tester.pump();
    expect(ws.sent.single.type, 'call.decline');
    expect(ws.sent.single.data, {'inviteId': 'inv-1'});
  });

  testWidgets('bấm Nghe (đã có quyền) → call.accept, hiện "Đang kết nối…"', (tester) async {
    await tester.pumpWidget(sheet());
    ws.emit(CallInviteIncoming(incoming()));
    await tester.pump();
    await tester.tap(find.text('Nghe'));
    await tester.pump();
    await tester.pump();
    expect(ws.sent.single.type, 'call.accept');
    expect(ws.sent.single.data, {'inviteId': 'inv-1'});
    expect(find.text('Đang kết nối…'), findsOneWidget);
    expect(find.text('Nghe'), findsNothing);
  });

  testWidgets('màn 320 dp, bản en, chữ 1,3, tên dài: không tràn', (tester) async {
    useNarrowSurface(tester);
    await tester.pumpWidget(sheet(locale: const Locale('en'), textScale: 1.3));
    ws.emit(CallInviteIncoming(incoming(name: 'Nguyễn Thị Thanh Hằng Phương Anh')));
    await tester.pump();
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('CallOverlays', () {
    Widget overlays() => harness(
          invites: invites,
          home: CallOverlays(
            now: () => clock,
            child: const Scaffold(body: Center(child: Text('nền'))),
          ),
        );

    testWidgets('không có lời mời: chỉ thấy nội dung bên dưới', (tester) async {
      await tester.pumpWidget(overlays());
      expect(find.text('nền'), findsOneWidget);
      expect(find.byType(IncomingCallSheet), findsNothing);
    });

    testWidgets('có call.invite → phủ màn hình cuộc gọi đến', (tester) async {
      await tester.pumpWidget(overlays());
      ws.emit(CallInviteIncoming(incoming()));
      await tester.pump();
      expect(find.byType(IncomingCallSheet), findsOneWidget);
      expect(find.text('Minh đang gọi'), findsOneWidget);
    });

    testWidgets('đang gọi đi: hiện "Đang gọi Anna…" và nút Hủy cuộc gọi; huỷ → call.invite.cancel', (tester) async {
      await tester.pumpWidget(overlays());
      await invites.invite(makeContact());
      ws.emit(CallInviting(OutgoingInvite(
        inviteId: 'out-1',
        contactId: kPeerId,
        expiresAt: clock.add(const Duration(seconds: 30)),
        calleeOnline: true,
      )));
      await tester.pump();
      expect(find.text('Đang gọi Anna…'), findsOneWidget);
      expect(find.text('Hủy cuộc gọi'), findsOneWidget);

      await tester.tap(find.text('Hủy cuộc gọi'));
      await tester.pump();
      expect(ws.sent.last.type, 'call.invite.cancel');
      expect(ws.sent.last.data, {'inviteId': 'out-1'});
      expect(find.text('Đang gọi Anna…'), findsNothing);
    });

    testWidgets('lời mời đi bị từ chối → SnackBar "Cuộc gọi bị từ chối."', (tester) async {
      await tester.pumpWidget(overlays());
      await invites.invite(makeContact());
      ws.emit(CallInviting(OutgoingInvite(
        inviteId: 'out-1',
        contactId: kPeerId,
        expiresAt: clock.add(const Duration(seconds: 30)),
        calleeOnline: true,
      )));
      await tester.pump();
      ws.emit(const CallInviteEnded('out-1', CallInviteEnded.declined));
      await tester.pump();
      await tester.pump();
      expect(find.text('Cuộc gọi bị từ chối.'), findsOneWidget);
    });

    testWidgets('bản en: "{name} is calling"', (tester) async {
      await tester.pumpWidget(harness(
        invites: invites,
        locale: const Locale('en'),
        home: CallOverlays(now: () => clock, child: const Scaffold(body: SizedBox())),
      ));
      ws.emit(CallInviteIncoming(incoming()));
      await tester.pump();
      expect(find.text('Minh is calling'), findsOneWidget);
    });
  });

  group('inviteNoticeText', () {
    testWidgets('ánh xạ lý do → chuỗi dịch (vi)', (tester) async {
      late String declined, timeoutOut, timeoutIn, busy, failed, cancelled, network;
      await tester.pumpWidget(harness(
        home: Builder(builder: (context) {
          final l10n = AppLocalizations.of(context);
          declined = inviteNoticeText(l10n, const InviteEndedNotice('declined', outgoing: true));
          timeoutOut = inviteNoticeText(l10n, const InviteEndedNotice('timeout', outgoing: true));
          timeoutIn = inviteNoticeText(l10n, const InviteEndedNotice('timeout', outgoing: false));
          busy = inviteNoticeText(l10n, const InviteEndedNotice('busy', outgoing: true));
          failed = inviteNoticeText(l10n, const InviteEndedNotice('failed', outgoing: true));
          cancelled = inviteNoticeText(l10n, const InviteEndedNotice('cancelled', outgoing: false));
          network = inviteNoticeText(l10n, const InviteErrorNotice('NETWORK'));
          return const SizedBox();
        }),
      ));
      expect(declined, 'Cuộc gọi bị từ chối.');
      expect(timeoutOut, 'Không có người trả lời.');
      expect(timeoutIn, 'Cuộc gọi đã kết thúc.');
      expect(busy, 'Người này đang bận.');
      expect(failed, 'Không thể kết nối cuộc gọi.');
      expect(cancelled, 'Cuộc gọi đã kết thúc.');
      expect(network, 'Không có kết nối mạng.');
    });
  });
}
