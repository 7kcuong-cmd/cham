import 'dart:convert';
import 'dart:io';

import 'package:cham/app.dart';
import 'package:cham/config/env.dart';
import 'package:cham/config/firebase_options.dart';
import 'package:cham/l10n_errors.dart';
import 'package:cham/l10n/app_localizations.dart';
import 'package:cham/state/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _pumpApp(
  WidgetTester tester, {
  Locale? locale,
  bool signedIn = true,
  FakeApiClient? api,
  FakePermissionGateway? perms,
  bool settle = true,
}) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final auth = FakeAuthService(signedIn: signedIn);
  final fakeApi = api ?? FakeApiClient();
  final session = SessionController(auth: auth, api: fakeApi, deviceLanguage: () => 'vi');
  addTearDown(session.dispose);

  await tester.pumpWidget(ChamApp(
    auth: auth,
    api: fakeApi,
    session: session,
    ws: FakeWsClient(),
    call: FakeCallService(),
    permissions: perms ?? FakePermissionGateway(granted: false),
    localeOverride: locale,
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // Có hoạt ảnh lặp vô hạn (vòng "đang tìm") nên không thể pumpAndSettle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

Finder _inNavBar(String text) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(text));

void main() {
  testWidgets('locale vi: thanh dưới có "Lướt" và "Cài đặt"', (tester) async {
    await _pumpApp(tester, locale: const Locale('vi'));
    expect(_inNavBar('Lướt'), findsOneWidget);
    expect(_inNavBar('Cài đặt'), findsOneWidget);
  });

  testWidgets('locale en: thanh dưới có "Swipe" và "Settings"', (tester) async {
    await _pumpApp(tester, locale: const Locale('en'));
    expect(_inNavBar('Swipe'), findsOneWidget);
    expect(_inNavBar('Settings'), findsOneWidget);
  });

  testWidgets('chưa cấp quyền → tab Lướt hiện yêu cầu camera/micro', (tester) async {
    await _pumpApp(tester, locale: const Locale('vi'));
    expect(find.text('Cho phép camera và micro'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Cho phép'), findsOneWidget);
  });

  testWidgets('đã có quyền → tab Lướt hiện "đang tìm"', (tester) async {
    await _pumpApp(
      tester,
      locale: const Locale('vi'),
      perms: FakePermissionGateway(granted: true),
      settle: false,
    );
    expect(find.text('Đang tìm người phù hợp…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); // dọn hoạt ảnh
  });

  testWidgets('chưa đăng nhập → màn đăng nhập (dev: ô uid + nút Đăng nhập dev)', (tester) async {
    await _pumpApp(tester, locale: const Locale('vi'), signedIn: false);
    expect(find.text('Chạm'), findsWidgets);
    expect(find.text('Gặp người mới, chỉ một chạm'), findsOneWidget);
    if (Env.isDev) {
      expect(find.text('Đăng nhập dev'), findsOneWidget);
      expect(find.text('DEV'), findsOneWidget);
    }
  });

  testWidgets('hồ sơ chưa có năm sinh → màn Năm sinh', (tester) async {
    final api = FakeApiClient()
      ..onCreateSession = (lang) async => (user: makeUser(), isNew: true);
    await _pumpApp(tester, locale: const Locale('vi'), api: api);
    expect(find.text('Bạn sinh năm nào?'), findsOneWidget);
  });

  testWidgets('UNDERAGE → màn Chưa đủ tuổi; ACCOUNT_BANNED → màn khóa', (tester) async {
    final api = FakeApiClient()
      ..onCreateSession = (lang) async => throw apiError('UNDERAGE', status: 403);
    await _pumpApp(tester, locale: const Locale('vi'), api: api);
    expect(find.text('Chạm chưa dành cho bạn'), findsOneWidget);
    expect(find.text('Bạn cần đủ 18 tuổi để dùng Chạm.'), findsOneWidget);
  });

  testWidgets('lỗi mạng lúc mở app (đã đăng nhập) → màn offline, "Thử lại" vào thẳng app', (tester) async {
    var fail = true;
    final api = FakeApiClient()
      ..onCreateSession = (lang) async {
        if (fail) throw apiError('NETWORK');
        return (user: makeUser(birthYear: 1995), isNew: false);
      };
    await _pumpApp(tester, locale: const Locale('vi'), api: api);
    expect(find.text('Không có kết nối mạng.'), findsOneWidget);
    expect(find.text('Đăng nhập dev'), findsNothing);

    fail = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Không có kết nối mạng.'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  testWidgets('ACCOUNT_BANNED → màn khóa tài khoản', (tester) async {
    final api = FakeApiClient()
      ..onCreateSession = (lang) async => throw apiError('ACCOUNT_BANNED', status: 403);
    await _pumpApp(tester, locale: const Locale('vi'), api: api);
    expect(find.text('Tài khoản đã bị khóa.'), findsOneWidget);
    expect(find.text('Đăng xuất'), findsOneWidget);
  });

  test('mọi khóa trong app_vi.arb có trong app_en.arb và ngược lại; mọi khóa có @mô tả', () {
    Map<String, dynamic> load(String path) =>
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final vi = load('lib/l10n/app_vi.arb');
    final en = load('lib/l10n/app_en.arb');

    Set<String> keys(Map<String, dynamic> m) =>
        m.keys.where((k) => !k.startsWith('@')).toSet();

    expect(keys(vi).difference(keys(en)), isEmpty, reason: 'thiếu trong app_en.arb');
    expect(keys(en).difference(keys(vi)), isEmpty, reason: 'thiếu trong app_vi.arb');
    for (final k in keys(vi)) {
      expect(vi.containsKey('@$k'), isTrue, reason: 'app_vi.arb thiếu @$k');
      expect((vi[k] as String).trim(), isNotEmpty, reason: 'vi.$k rỗng');
      expect((en[k] as String).trim(), isNotEmpty, reason: 'en.$k rỗng');
    }
  });

  test('mọi tham số {x} trong chuỗi vi cũng có trong chuỗi en', () {
    Map<String, dynamic> load(String path) =>
        jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    final vi = load('lib/l10n/app_vi.arb');
    final en = load('lib/l10n/app_en.arb');
    final re = RegExp(r'\{(\w+)\}');
    for (final k in vi.keys.where((k) => !k.startsWith('@'))) {
      final a = re.allMatches(vi[k] as String).map((m) => m.group(1)).toSet();
      final b = re.allMatches(en[k] as String).map((m) => m.group(1)).toSet();
      expect(a, b, reason: 'tham số khác nhau ở khóa $k');
    }
  });

  testWidgets('errorText theo bảng DESIGN.md §5', (tester) async {
    late AppLocalizations l;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(builder: (context) {
        l = AppLocalizations.of(context);
        return const SizedBox.shrink();
      }),
    ));
    expect(errorText(l, 'UNAUTHENTICATED'), l.errorSessionExpired);
    expect(errorText(l, 'RATE_LIMITED'), l.errorRateLimited);
    expect(errorText(l, 'ACCOUNT_BANNED'), l.errorBanned);
    expect(errorText(l, 'SESSION_REPLACED'), l.errorSessionReplaced);
    expect(errorText(l, 'CALL_PROVIDER_ERROR'), l.errorCallUnavailable);
    expect(errorText(l, 'NETWORK'), l.errorNetwork);
    expect(errorText(l, 'INTERNAL'), l.errorGeneric);
    expect(errorText(l, 'BAD_REQUEST'), l.errorGeneric);
    expect(errorText(l, 'ANYTHING_ELSE'), l.errorGeneric);
  });

  group('firebaseOptions', () {
    test('thiếu biến → liệt kê đúng tên theo nền tảng', () {
      expect(
        missingFirebaseVars(platform: TargetPlatform.android),
        ['FIREBASE_API_KEY', 'FIREBASE_PROJECT_ID', 'FIREBASE_MESSAGING_SENDER_ID', 'FIREBASE_APP_ID_ANDROID'],
      );
      expect(
        missingFirebaseVars(platform: TargetPlatform.iOS),
        [
          'FIREBASE_API_KEY',
          'FIREBASE_PROJECT_ID',
          'FIREBASE_MESSAGING_SENDER_ID',
          'FIREBASE_APP_ID_IOS',
          'FIREBASE_IOS_BUNDLE_ID',
        ],
      );
    });

    test('đủ biến → không thiếu gì', () {
      expect(
        missingFirebaseVars(
          platform: TargetPlatform.android,
          apiKey: 'k',
          projectId: 'p',
          messagingSenderId: 's',
          appIdAndroid: 'a',
        ),
        isEmpty,
      );
    });

    test('firebaseOptionsFromEnv ném StateError khi chưa --dart-define', () {
      expect(
        firebaseOptionsFromEnv,
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Missing FIREBASE_* dart-define'))),
      );
    });
  });
}
