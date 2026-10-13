import 'package:cham/models/call_extras.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/call_extras_controller.dart';
import 'package:cham/widgets/gift_drop_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeWsClient ws;
  late FakeRoom room;
  late FakeTimers timers;
  late DateTime clock;
  late CallExtrasController extras;

  GiftOffer gift({int points = 12, int seconds = 20}) => GiftOffer(
        giftId: 'g1',
        roomName: kRoom,
        points: points,
        expiresAt: clock.add(Duration(seconds: seconds)),
      );

  Widget app({Locale locale = const Locale('vi'), double textScale = 1.0}) => harness(
        extras: extras,
        locale: locale,
        textScale: textScale,
        home: Scaffold(
          body: Align(
            alignment: const Alignment(0, -0.35),
            child: GiftDropCard(now: () => clock),
          ),
        ),
      );

  setUp(() {
    ws = FakeWsClient();
    room = FakeRoom(room: kRoom);
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 6, 9, 30);
    extras = CallExtrasController(ws: ws, room: room, timerFactory: timers.create, now: () => clock);
  });

  tearDown(() => extras.dispose());

  testWidgets('không có quà thì không hiện gì', (tester) async {
    await tester.pumpWidget(app());
    expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
  });

  testWidgets('gift.drop → thẻ 160x96 có "Quà 12 điểm!" và nút Nhận', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(GiftDrop(gift()));
    await tester.pump();
    expect(find.text('Quà 12 điểm!'), findsOneWidget);
    expect(find.text('Nhận'), findsOneWidget);
    expect(find.byIcon(Icons.card_giftcard_rounded), findsOneWidget);
    final card = tester.getSize(
      find.ancestor(of: find.byIcon(Icons.card_giftcard_rounded), matching: find.byType(Container)).first,
    );
    expect(card, const Size(160, 96));
  });

  testWidgets('bấm Nhận gửi gift.claim; gift.claimed → "+12 điểm"; hết 1,5 s thì ẩn', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(GiftDrop(gift()));
    await tester.pump();

    await tester.tap(find.text('Nhận'));
    await tester.pump();
    expect(ws.sent.single.type, 'gift.claim');
    expect(ws.sent.single.data, {'giftId': 'g1'});
    // Đang chờ phản hồi: nút bị khóa, bấm lại không gửi thêm.
    await tester.tap(find.text('Nhận'));
    await tester.pump();
    expect(ws.sent, hasLength(1));

    ws.emit(const GiftClaimed('g1', 12, 152));
    await tester.pump();
    expect(find.text('+12 điểm'), findsOneWidget);
    expect(find.text('Nhận'), findsNothing);

    timers.fire(CallExtrasController.claimedDisplay);
    await tester.pump();
    expect(find.text('+12 điểm'), findsNothing);
    expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
  });

  testWidgets('hết hạn → thẻ tự ẩn', (tester) async {
    await tester.pumpWidget(app());
    ws.emit(GiftDrop(gift(seconds: 20)));
    await tester.pump();
    expect(find.byIcon(Icons.card_giftcard_rounded), findsOneWidget);
    timers.fire(const Duration(seconds: 20));
    await tester.pump();
    expect(find.byIcon(Icons.card_giftcard_rounded), findsNothing);
  });

  testWidgets('màn 320 dp, bản en, chữ 1,3: không tràn', (tester) async {
    useNarrowSurface(tester);
    await tester.pumpWidget(app(locale: const Locale('en'), textScale: 1.3));
    ws.emit(GiftDrop(gift(points: 120)));
    await tester.pump();
    expect(find.text('120-point gift!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
