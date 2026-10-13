import 'package:cham/screens/birth_year_screen.dart';
import 'package:cham/state/session_controller.dart';
import 'package:cham/utils/age.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeApiClient api;
  late SessionController session;

  setUp(() {
    api = FakeApiClient();
    session = SessionController(auth: FakeAuthService(signedIn: true), api: api);
  });

  tearDown(() => session.dispose());

  Finder continueButton() => find.widgetWithText(FilledButton, 'Tiếp tục');

  Future<void> pump(WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      home: const BirthYearScreen(nowYear: 2026),
      session: session,
    ));
    await tester.pumpAndSettle();
  }

  Future<int> scrollAndOpenDialog(WidgetTester tester) async {
    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(continueButton());
    await tester.pumpAndSettle();
    final title = tester.widget<Text>(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.textContaining('Xác nhận năm sinh'),
    ));
    return int.parse(RegExp(r'\d{4}').firstMatch(title.data!)!.group(0)!);
  }

  testWidgets('hiện tiêu đề; chưa chọn sẵn năm nào; nút Tiếp tục vô hiệu', (tester) async {
    await pump(tester);
    expect(find.text('Bạn sinh năm nào?'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(tester.widget<FilledButton>(continueButton()).onPressed, isNull);
  });

  testWidgets('sau khi cuộn chọn năm, nút Tiếp tục được bật', (tester) async {
    await pump(tester);
    await tester.drag(find.byType(ListWheelScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(continueButton()).onPressed, isNotNull);
  });

  testWidgets('Tiếp tục → hộp thoại có năm đã chọn; Hủy → không gọi submitBirthYear', (tester) async {
    await pump(tester);
    final year = await scrollAndOpenDialog(tester);
    expect(birthYearChoices(2026), contains(year));
    expect(find.text('Bạn sẽ không thể sửa lại.'), findsOneWidget);

    await tester.tap(find.text('Hủy'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(api.log.where((e) => e.startsWith('updateMe')), isEmpty);
    expect(session.status, SessionStatus.loading); // chưa đổi gì
  });

  testWidgets('Xác nhận → gọi đúng năm đã chọn', (tester) async {
    await pump(tester);
    final year = await scrollAndOpenDialog(tester);

    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();

    expect(api.log.where((e) => e.startsWith('updateMe')).single, startsWith('updateMe(birthYear: $year,'));
    expect(session.status, SessionStatus.ready);
  });

  testWidgets('server trả UNDERAGE → chuyển sang trạng thái underage', (tester) async {
    api.onUpdateMe = ({birthYear, language, displayName}) async =>
        throw apiError('UNDERAGE', status: 403);
    await pump(tester);
    await scrollAndOpenDialog(tester);

    await tester.tap(find.text('Xác nhận'));
    await tester.pumpAndSettle();

    expect(session.status, SessionStatus.underage);
  });

  testWidgets('bản tiếng Anh dùng chuỗi en', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      home: const BirthYearScreen(nowYear: 2026),
      session: session,
      locale: const Locale('en'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('What year were you born?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Continue'), findsOneWidget);
  });
}
