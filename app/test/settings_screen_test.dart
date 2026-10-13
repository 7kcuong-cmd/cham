import 'package:cham/screens/settings_screen.dart';
import 'package:cham/state/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

class _SpySession extends SessionController {
  _SpySession({required super.auth, required super.api, super.deviceLanguage});

  final List<String> languages = <String>[];

  @override
  Future<bool> updateLanguage(String language) {
    languages.add(language);
    return super.updateLanguage(language);
  }
}

void main() {
  late FakeAuthService auth;
  late FakeApiClient api;
  late _SpySession session;

  setUp(() async {
    auth = FakeAuthService(signedIn: true);
    api = FakeApiClient();
    session = _SpySession(auth: auth, api: api, deviceLanguage: () => 'vi');
    await session.init();
  });

  tearDown(() => session.dispose());

  Future<void> pump(WidgetTester tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(harness(
      session: session,
      home: Scaffold(body: SettingsScreen(versionLoader: () async => '1.2.3')),
    ));
    await tester.pumpAndSettle();
  }

  group('isValidDisplayName', () {
    test('1–30 ký tự sau trim, không ký tự điều khiển', () {
      expect(isValidDisplayName('Linh'), isTrue);
      expect(isValidDisplayName('  Linh  '), isTrue);
      expect(isValidDisplayName('a' * 30), isTrue);
      expect(isValidDisplayName('a' * 31), isFalse);
      expect(isValidDisplayName('   '), isFalse);
      expect(isValidDisplayName(''), isFalse);
      expect(isValidDisplayName('a\u0007b'), isFalse);
      expect(isValidDisplayName('Nguyễn Thị Ánh'), isTrue);
    });
  });

  testWidgets('hiện các hàng, tên hiện tại, ngôn ngữ và phiên bản', (tester) async {
    await pump(tester);
    expect(find.text('Tên hiển thị'), findsOneWidget);
    expect(find.text('Minh'), findsOneWidget);
    expect(find.text('Ngôn ngữ'), findsOneWidget);
    expect(find.text('Tiếng Việt'), findsOneWidget);
    expect(find.text('Đăng xuất'), findsOneWidget);
    expect(find.text('Phiên bản 1.2.3 · local'), findsOneWidget);
    // TERMS_URL / PRIVACY_URL rỗng → ẩn
    expect(find.text('Điều khoản'), findsNothing);
    expect(find.text('Quyền riêng tư'), findsNothing);
  });

  testWidgets('1. tên 31 ký tự → hiện displayNameInvalid, không gọi API', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Tên hiển thị'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a' * 31);
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();

    expect(find.text('Tên từ 1 đến 30 ký tự'), findsOneWidget);
    expect(api.log.where((e) => e.startsWith('updateMe')), isEmpty);

    // sửa lại cho hợp lệ → gọi API với tên đã trim
    await tester.enterText(find.byType(TextField), '  Linh ');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();

    expect(api.log.where((e) => e.startsWith('updateMe')).single, contains('displayName: Linh)'));
    expect(session.user?.displayName, 'Linh');
  });

  testWidgets('2. chọn English → updateLanguage("en"); giao diện đổi ngay', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Ngôn ngữ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(session.languages, ['en']);
    expect(api.log.last, contains('language: en'));
    expect(session.locale?.languageCode, 'en');
  });

  testWidgets('chọn lại đúng ngôn ngữ hiện tại → không gọi API', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Ngôn ngữ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tiếng Việt').last);
    await tester.pumpAndSettle();
    expect(session.languages, isEmpty);
  });

  testWidgets('API lỗi khi đổi tên → hiện chuỗi lỗi theo mã', (tester) async {
    api.onUpdateMe = ({birthYear, language, displayName}) async =>
        throw apiError('RATE_LIMITED', status: 429);
    await pump(tester);
    await tester.tap(find.text('Tên hiển thị'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Linh');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();

    expect(find.text('Bạn thao tác hơi nhanh, chờ một chút nhé.'), findsOneWidget);
    expect(session.user?.displayName, 'Minh');
  });

  testWidgets('Đăng xuất → SessionController.signOut', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Đăng xuất'));
    await tester.pumpAndSettle();
    expect(auth.signOutCalls, 1);
    expect(session.status, SessionStatus.signedOut);
  });
}
