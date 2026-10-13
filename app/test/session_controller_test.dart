import 'package:cham/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

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

  test('chưa đăng nhập → signedOut', () async {
    await session.init();
    expect(session.status, SessionStatus.signedOut);
    expect(api.log, isEmpty);
  });

  test('đã đăng nhập, hồ sơ đủ → ready', () async {
    auth.signedIn = true;
    await session.init();
    expect(session.status, SessionStatus.ready);
    expect(api.log, ['createSession(vi)']);
  });

  test('profileComplete=false → needsBirthYear; submitBirthYear(1990) → ready', () async {
    api.onCreateSession = (lang) async => (user: makeUser(), isNew: true);
    await session.signInDev('alice');
    expect(auth.lastDevUid, 'alice');
    expect(session.status, SessionStatus.needsBirthYear);

    await session.submitBirthYear(1990);
    expect(session.status, SessionStatus.ready);
    expect(session.user?.birthYear, 1990);
  });

  test('submitBirthYear(2010) nhận UNDERAGE → underage', () async {
    api.onCreateSession = (lang) async => (user: makeUser(), isNew: true);
    api.onUpdateMe = ({birthYear, language, displayName}) async =>
        throw apiError('UNDERAGE', status: 403);
    await session.signInDev('kid');

    await session.submitBirthYear(2010);
    expect(session.status, SessionStatus.underage);
  });

  test('BIRTH_YEAR_LOCKED → làm mới phiên', () async {
    api.onCreateSession = (lang) async => (user: makeUser(birthYear: 1995), isNew: false);
    api.onUpdateMe = ({birthYear, language, displayName}) async =>
        throw apiError('BIRTH_YEAR_LOCKED', status: 409);
    auth.signedIn = true;
    await session.init();
    final before = api.log.length;

    await session.submitBirthYear(1990);
    expect(api.log.length, greaterThan(before));
    expect(session.status, SessionStatus.ready);
  });

  test('createSession ném UNDERAGE → underage; ACCOUNT_BANNED → banned', () async {
    auth.signedIn = true;
    api.onCreateSession = (lang) async => throw apiError('UNDERAGE', status: 403);
    await session.refresh();
    expect(session.status, SessionStatus.underage);

    api.onCreateSession = (lang) async => throw apiError('ACCOUNT_BANNED', status: 403);
    await session.refresh();
    expect(session.status, SessionStatus.banned);
  });

  test('UNAUTHENTICATED → đăng xuất', () async {
    auth.signedIn = true;
    api.onCreateSession = (lang) async => throw apiError('UNAUTHENTICATED', status: 401);
    await session.init();
    expect(session.status, SessionStatus.signedOut);
    expect(auth.signOutCalls, 1);
  });

  test('lỗi mạng lúc khởi động khi đã đăng nhập → offline (giữ đăng nhập) và phát mã lỗi', () async {
    auth.signedIn = true;
    api.onCreateSession = (lang) async => throw apiError('NETWORK');
    final errors = <String>[];
    session.errors.listen(errors.add);

    await session.init();
    await Future<void>.delayed(Duration.zero);

    expect(session.status, SessionStatus.offline);
    expect(auth.signOutCalls, 0);
    expect(session.errorCode, 'NETWORK');
    expect(errors, ['NETWORK']);

    // Bấm "Thử lại": hết lỗi mạng → vào thẳng ready, không phải đăng nhập lại.
    api.onCreateSession = null;
    await session.refresh();
    expect(session.status, SessionStatus.ready);
  });

  test('lỗi mạng lúc mở khi chưa đăng nhập vẫn là signedOut', () async {
    auth.signedIn = false;
    await session.init();
    expect(session.status, SessionStatus.signedOut);
  });

  test('signOut → signedOut, gọi beforeSignOut và auth.signOut', () async {
    auth.signedIn = true;
    await session.init();
    var hook = 0;
    session.beforeSignOut = () async => hook++;

    await session.signOut();

    expect(session.status, SessionStatus.signedOut);
    expect(session.user, isNull);
    expect(hook, 1);
    expect(auth.signOutCalls, 1);
  });

  test('updateLanguage đổi locale ngay; updateDisplayName cập nhật user', () async {
    auth.signedIn = true;
    await session.init();
    expect(session.locale?.languageCode, 'vi');

    expect(await session.updateLanguage('en'), isTrue);
    expect(session.locale?.languageCode, 'en');

    expect(await session.updateDisplayName('Linh'), isTrue);
    expect(session.user?.displayName, 'Linh');
  });

  test('ngôn ngữ gửi lên createSession lấy từ máy', () async {
    final s = SessionController(auth: auth, api: api, deviceLanguage: () => 'en');
    await s.signInDev('alice');
    expect(api.log.first, 'createSession(en)');
    s.dispose();
  });
}
