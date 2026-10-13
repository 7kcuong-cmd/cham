import 'package:cham/state/safety_controller.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:cham/widgets/safety_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakeApiClient api;
  late SwipeController swipe;
  late SafetyController safety;

  final peer = makeMatch().peer;
  const room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    api = FakeApiClient();
    swipe = SwipeController(
      ws: ws,
      call: call,
      permissions: FakePermissionGateway(),
      refreshSession: () async {},
    );
    safety = SafetyController(api: api, swipe: swipe);
  });

  tearDown(() => swipe.dispose());

  Future<void> openSheet(WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      swipe: swipe,
      safety: safety,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showSafetySheet(context, peer: peer, roomName: room),
              child: const Text('open-sheet'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
  }

  testWidgets('1. mở sheet → mic tắt; đóng → mic bật lại', (tester) async {
    expect(swipe.micOn, isTrue);
    await openSheet(tester);

    expect(find.text('An toàn'), findsOneWidget);
    expect(swipe.micOn, isFalse);
    expect(call.micCalls, [false]);

    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();

    expect(find.text('An toàn'), findsNothing);
    expect(swipe.micOn, isTrue);
    expect(call.micCalls, [false, true]);
  });

  testWidgets('1b. mic đã tắt từ trước → đóng sheet vẫn tắt', (tester) async {
    await swipe.setMic(false);
    call.micCalls.clear();
    await openSheet(tester);
    expect(swipe.micOn, isFalse);

    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();

    expect(swipe.micOn, isFalse);
    expect(call.micCalls, isNot(contains(true)));
  });

  testWidgets('hiện tên đối phương ở hai hàng Báo cáo / Chặn', (tester) async {
    await openSheet(tester);
    expect(find.text('Báo cáo Anna'), findsOneWidget);
    expect(find.text('Chặn Anna'), findsOneWidget);
  });

  testWidgets('2. nút Gửi báo cáo vô hiệu tới khi chọn lý do; ô "Chặn luôn" mặc định được tích',
      (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Báo cáo Anna'));
    await tester.pumpAndSettle();

    final submit = find.widgetWithText(FilledButton, 'Gửi báo cáo');
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('Chặn luôn người này'), findsOneWidget);

    await tester.tap(find.text('Spam / quảng cáo'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
  });

  testWidgets('3. hiển thị đúng 6 lý do theo khóa dịch', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Báo cáo Anna'));
    await tester.pumpAndSettle();

    for (final label in const [
      'Khỏa thân / nội dung tình dục',
      'Quấy rối / thù ghét',
      'Có vẻ dưới 18 tuổi',
      'Spam / quảng cáo',
      'Bạo lực / đe dọa',
      'Lý do khác',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('Vì sao bạn báo cáo?'), findsOneWidget);
  });

  testWidgets('ghi chú giới hạn 500 ký tự', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Báo cáo Anna'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a' * 600);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLength, 500);
    expect(field.controller!.text.length, 500);
  });

  testWidgets('gửi báo cáo + chặn: gọi report rồi block với đúng peer/lý do/phòng', (tester) async {
    String? reportedReason, reportedRoom, reportedNote;
    api.onReport = (userId, reason, roomName, note) async {
      reportedReason = reason;
      reportedRoom = roomName;
      reportedNote = note;
    };
    await openSheet(tester);
    await tester.tap(find.text('Báo cáo Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam / quảng cáo'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'quảng cáo');
    await tester.tap(find.widgetWithText(FilledButton, 'Gửi báo cáo'));
    await tester.pumpAndSettle();

    expect(reportedReason, 'spam');
    expect(reportedRoom, room);
    expect(reportedNote, 'quảng cáo');
    expect(api.log, ['report(${peer.id}, spam)', 'block(${peer.id})']);
    expect(find.text('Đã gửi báo cáo. Cảm ơn bạn.'), findsOneWidget);
    expect(find.text('Vì sao bạn báo cáo?'), findsNothing); // sheet đã đóng
    expect(swipe.micOn, isTrue);
  });

  testWidgets('RATE_LIMITED → hiện errorRateLimited, sheet vẫn mở để thử lại', (tester) async {
    api.onReport = (userId, reason, roomName, note) async =>
        throw apiError('RATE_LIMITED', status: 429, retryAfterSec: 5);
    await openSheet(tester);
    await tester.tap(find.text('Báo cáo Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lý do khác'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Gửi báo cáo'));
    await tester.pumpAndSettle();

    expect(find.text('Bạn thao tác hơi nhanh, chờ một chút nhé.'), findsOneWidget);
    expect(find.text('Vì sao bạn báo cáo?'), findsOneWidget);
    expect(api.log.any((e) => e.startsWith('block')), isFalse);
    final submit = find.widgetWithText(FilledButton, 'Gửi báo cáo');
    expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
  });

  testWidgets('Chặn: hộp thoại xác nhận → api.block, không next()', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Chặn Anna'));
    await tester.pumpAndSettle();

    expect(find.text('Chặn Anna?'), findsOneWidget);
    expect(find.text('Hai bạn sẽ không bao giờ được ghép với nhau nữa.'), findsOneWidget);

    await tester.tap(find.text('Hủy').last); // hủy hộp thoại, không đóng sheet
    await tester.pumpAndSettle();
    expect(api.log, isEmpty);

    await tester.tap(find.text('Chặn Anna'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Chặn'));
    await tester.pumpAndSettle();

    expect(api.log, ['block(${peer.id})']);
    expect(ws.sent, isEmpty); // không gọi next() → không có call.next
    expect(find.text('Đã chặn.'), findsOneWidget);
  });
}
