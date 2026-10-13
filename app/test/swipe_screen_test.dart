import 'package:cham/models/ws_messages.dart';
import 'package:cham/screens/swipe_screen.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/permission_gateway.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/safety_controller.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakePermissionGateway perms;
  late SwipeController swipe;

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    perms = FakePermissionGateway();
    swipe = SwipeController(
      ws: ws,
      call: call,
      permissions: perms,
      refreshSession: () async {},
    );
  });

  tearDown(() => swipe.dispose());

  Future<void> pumpScreen(WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      home: const Scaffold(body: SwipeScreen()),
      swipe: swipe,
      safety: SafetyController(api: FakeApiClient(), swipe: swipe),
      call: call,
    ));
  }

  Future<void> goInCall(WidgetTester tester) async {
    await swipe.activate();
    ws.emit(const SessionReady('u1'));
    await tester.pump();
    ws.emit(MatchFoundEvent(makeMatch(peerName: 'Anna')));
    await tester.pump();
    call.emit(const RemoteVideoReady());
    await tester.pump();
  }

  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('searching: vòng nhịp đập + "Đang tìm người phù hợp…"', (tester) async {
    await pumpScreen(tester);
    await swipe.activate();
    await tester.pump();
    expect(find.text('Đang tìm người phù hợp…'), findsOneWidget);
    expect(find.text('Ít người đang online, chờ thêm chút nhé.'), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('connecting rồi inCall: tên, chip ngôn ngữ, khiên, mic/camera, gợi ý vuốt', (tester) async {
    await pumpScreen(tester);
    await swipe.activate();
    ws.emit(const SessionReady('u1'));
    await tester.pump();
    ws.emit(MatchFoundEvent(makeMatch(peerName: 'Anna')));
    await tester.pump();

    expect(swipe.status, SwipeStatus.connecting);
    expect(find.text('Anna'), findsWidgets); // tên ở giữa + thanh trên
    expect(find.byIcon(Icons.shield_rounded), findsOneWidget);

    call.emit(const RemoteVideoReady());
    await tester.pump();

    expect(swipe.status, SwipeStatus.inCall);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('EN'), findsOneWidget);
    expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
    expect(find.byIcon(Icons.videocam_rounded), findsOneWidget);
    expect(find.text('Vuốt lên để gặp người khác'), findsOneWidget);
    // GĐ1: ẩn tim / bình luận / thêm bạn
    expect(find.byIcon(Icons.favorite_rounded), findsNothing);
    expect(find.byIcon(Icons.person_add_rounded), findsNothing);
    await disposeTree(tester);
  });

  testWidgets('chạm nút mic / camera đổi trạng thái và gọi CallService', (tester) async {
    await pumpScreen(tester);
    await goInCall(tester);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    expect(swipe.micOn, isFalse);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
    expect(call.micCalls, [false]);

    await tester.tap(find.byIcon(Icons.videocam_rounded));
    await tester.pump();
    expect(swipe.camOn, isFalse);
    expect(call.cameraCalls, [false]);
    await disposeTree(tester);
  });

  testWidgets('vuốt lên → hiệu ứng 250 ms rồi leave() + call.next {roomName}', (tester) async {
    await pumpScreen(tester);
    await goInCall(tester);
    final room = swipe.current!.roomName;
    ws.sent.clear();

    await tester.fling(find.byType(SwipeScreen), const Offset(0, -400), 1200);
    await tester.pump(); // bắt đầu hoạt ảnh
    await tester.pump(const Duration(milliseconds: 300)); // hết 250 ms
    await tester.pump(); // next() hoàn tất

    expect(call.leaveCalls, 1);
    expect(ws.sent.single.type, 'call.next');
    expect(ws.sent.single.data, {'roomName': room});
    expect(swipe.status, SwipeStatus.searching);
    expect(find.text('Đang tìm người phù hợp…'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('vuốt xuống không làm gì ở GĐ1', (tester) async {
    await pumpScreen(tester);
    await goInCall(tester);
    ws.sent.clear();

    await tester.fling(find.byType(SwipeScreen), const Offset(0, 400), 1200);
    await tester.pump(const Duration(milliseconds: 300));

    expect(ws.sent, isEmpty);
    expect(swipe.status, SwipeStatus.inCall);
    await disposeTree(tester);
  });

  testWidgets('offline: dải "Đang kết nối lại…"', (tester) async {
    await pumpScreen(tester);
    await goInCall(tester);
    ws.emitState(WsConnState.connected);
    await tester.pump();
    ws.emitState(WsConnState.disconnected);
    await tester.pump();

    expect(swipe.status, SwipeStatus.offline);
    expect(find.text('Đang kết nối lại…'), findsOneWidget);
    await disposeTree(tester);
  });

  testWidgets('SESSION_REPLACED → thông báo bị thay bởi thiết bị khác', (tester) async {
    await pumpScreen(tester);
    await swipe.activate();
    ws.emit(const SessionReady('u1'));
    await tester.pump();
    ws.emit(const ServerError('SESSION_REPLACED', 'x'));
    await tester.pump();

    expect(swipe.status, SwipeStatus.blockedPermanently);
    expect(find.text('Bạn đang dùng Chạm trên thiết bị khác.'), findsWidgets);
    await disposeTree(tester);
  });

  testWidgets('chưa có quyền: nút Cho phép → xin quyền; từ chối vĩnh viễn → Mở Cài đặt', (tester) async {
    perms
      ..granted = false
      ..requestOutcome = PermissionOutcome.permanentlyDenied;
    await pumpScreen(tester);
    await swipe.activate();
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Cho phép'));
    await tester.pump();
    expect(perms.requestCalls, 1);
    expect(find.widgetWithText(FilledButton, 'Mở Cài đặt'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Mở Cài đặt'));
    await tester.pump();
    expect(perms.openSettingsCalls, 1);
    await disposeTree(tester);
  });
}
