import 'package:cham/screens/sign_in_screen.dart';
import 'package:cham/state/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

void main() {
  late FakeAuthService auth;
  late FakeApiClient api;
  late SessionController session;

  setUp(() {
    auth = FakeAuthService();
    api = FakeApiClient();
    session = SessionController(auth: auth, api: api, deviceLanguage: () => 'vi');
  });

  tearDown(() => session.dispose());

  Future<void> pump(WidgetTester tester, SignInScreen screen) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(home: screen, session: session));
    await tester.pumpAndSettle();
  }

  testWidgets('chế độ dev: ô uid + nút Đăng nhập dev + nhãn DEV, không có nút Google', (tester) async {
    await pump(tester, const SignInScreen(devMode: true));
    expect(find.text('DEV'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('uid thử nghiệm (vd. alice)'), findsOneWidget);
    expect(find.text('Đăng nhập dev'), findsOneWidget);
    expect(find.text('Tiếp tục với Google'), findsNothing);
    expect(find.text('Gặp người mới, chỉ một chạm'), findsOneWidget);
    expect(
      find.text('Tiếp tục nghĩa là bạn đủ 18 tuổi và đồng ý với Điều khoản và Quyền riêng tư.'),
      findsOneWidget,
    );
  });

  testWidgets('dev: uid sai định dạng → báo lỗi, không đăng nhập', (tester) async {
    await pump(tester, const SignInScreen(devMode: true));
    await tester.enterText(find.byType(TextField), 'a b');
    await tester.tap(find.text('Đăng nhập dev'));
    await tester.pumpAndSettle();

    expect(find.textContaining('uid chỉ gồm chữ, số'), findsOneWidget);
    expect(auth.lastDevUid, isNull);
    expect(api.log, isEmpty);
  });

  testWidgets('dev: uid hợp lệ → signInDev rồi tạo phiên', (tester) async {
    await pump(tester, const SignInScreen(devMode: true));
    await tester.enterText(find.byType(TextField), '  alice ');
    await tester.tap(find.text('Đăng nhập dev'));
    await tester.pumpAndSettle();

    expect(auth.lastDevUid, 'alice');
    expect(api.log, ['createSession(vi)']);
    expect(session.status, SessionStatus.ready);
  });

  testWidgets('chế độ firebase: nút Google; Apple chỉ khi iOS', (tester) async {
    await pump(tester, const SignInScreen(devMode: false, showApple: false));
    expect(find.text('Tiếp tục với Google'), findsOneWidget);
    expect(find.text('Tiếp tục với Apple'), findsNothing);
    expect(find.text('DEV'), findsNothing);

    await pump(tester, const SignInScreen(devMode: false, showApple: true));
    expect(find.text('Tiếp tục với Apple'), findsOneWidget);
  });

  testWidgets('bấm Google → đăng nhập; người dùng hủy (không đăng nhập) → không tạo phiên', (tester) async {
    auth.signInShouldSucceed = false; // mô phỏng người dùng hủy hộp thoại
    await pump(tester, const SignInScreen(devMode: false, showApple: false));
    await tester.tap(find.text('Tiếp tục với Google'));
    await tester.pumpAndSettle();
    expect(api.log, isEmpty);
    expect(session.status, SessionStatus.loading);

    auth.signInShouldSucceed = true;
    await tester.tap(find.text('Tiếp tục với Google'));
    await tester.pumpAndSettle();
    expect(api.log, ['createSession(vi)']);
  });

  testWidgets('lỗi mạng khi tạo phiên → hiện SnackBar errorNetwork', (tester) async {
    api.onCreateSession = (lang) async => throw apiError('NETWORK');
    await pump(tester, const SignInScreen(devMode: true));
    await tester.enterText(find.byType(TextField), 'alice');
    await tester.tap(find.text('Đăng nhập dev'));
    await tester.pumpAndSettle();

    expect(find.text('Không có kết nối mạng.'), findsOneWidget);
  });

  testWidgets('bản tiếng Anh', (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      home: const SignInScreen(devMode: false, showApple: false),
      session: session,
      locale: const Locale('en'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Meet someone new in one touch'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}
