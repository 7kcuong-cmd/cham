import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/email_auth.dart';

/// `offline`: đã đăng nhập nhưng chưa tải được hồ sơ (lỗi mạng/server lúc mở app) → màn "thử lại",
/// KHÔNG đẩy người dùng về màn đăng nhập.
enum SessionStatus { loading, signedOut, offline, needsBirthYear, underage, banned, ready }

/// Ngôn ngữ máy nếu là `vi`/`en`, ngược lại `en` (T-010).
String defaultDeviceLanguage() {
  final code = PlatformDispatcher.instance.locale.languageCode;
  return (code == 'vi' || code == 'en') ? code : 'en';
}

/// Trạng thái phiên: đăng nhập, hồ sơ, năm sinh, ngôn ngữ giao diện.
class SessionController extends ChangeNotifier {
  SessionController({
    required this.auth,
    required this.api,
    String Function()? deviceLanguage,
    this.emailAuth,
  }) : _deviceLanguage = deviceLanguage ?? defaultDeviceLanguage;

  final AuthService auth;

  /// Có giá trị khi bản build bật đăng nhập bằng email (`EMAIL_AUTH=true`).
  final EmailAuthPort? emailAuth;
  final ApiClient api;
  final String Function() _deviceLanguage;

  SessionStatus _status = SessionStatus.loading;
  AppUser? _user;
  String? _errorCode;
  bool _busy = false;
  bool _askInterests = false;
  bool _disposed = false;
  final StreamController<String> _errors = StreamController<String>.broadcast();

  /// Được ChamApp gán: dọn hàng chờ/cuộc gọi/WebSocket trước khi đăng xuất.
  Future<void> Function()? beforeSignOut;

  SessionStatus get status => _status;
  AppUser? get user => _user;
  String? get errorCode => _errorCode;

  /// Người dùng mới chưa chọn sở thích: hiện màn chọn nhóm sau khi hoàn tất hồ sơ.
  bool get askInterests => _askInterests && _user != null;

  /// Đang đăng nhập / gửi năm sinh (vô hiệu hóa nút, hiện vòng xoay).
  bool get busy => _busy;

  /// Mã lỗi để màn hình hiện SnackBar (xem `errorText`).
  Stream<String> get errors => _errors.stream;

  /// Locale giao diện: ngôn ngữ của user khi đã có user, ngược lại `null` (theo máy).
  Locale? get locale => _user == null ? null : Locale(_user!.language);

  Future<void> init() async {
    try {
      await auth.init();
    } on Exception catch (e) {
      debugPrint('auth.init failed: $e');
    }
    if (!auth.isSignedIn) {
      _setStatus(SessionStatus.signedOut);
      return;
    }
    await refresh();
  }

  /// `POST /v1/auth/session` rồi suy ra trạng thái.
  Future<void> refresh() async {
    try {
      final result = await api.createSession(language: _deviceLanguage());
      _user = result.user;
      _askInterests = result.isNew && result.user.interests.isEmpty;
      _errorCode = null;
      _setStatus(result.user.profileComplete
          ? SessionStatus.ready
          : SessionStatus.needsBirthYear);
    } on ApiException catch (e) {
      await _handleApiError(e);
    }
  }

  Future<void> signInGoogle() => _signIn(auth.signInWithGoogle);
  Future<void> signInApple() => _signIn(auth.signInWithApple);
  Future<void> signInDev(String uid) => _signIn(() => auth.signInDev(uid));

  Future<void> requestEmailCode(String email) async {
    final e = emailAuth;
    if (e == null) throw const ApiException(code: 'FEATURE_DISABLED');
    await e.requestEmailCode(email, language: _deviceLanguage());
  }

  /// `true` nếu đăng nhập xong (hồ sơ đã tải); `false` nếu mã sai/hết hạn hoặc lỗi.
  Future<bool> signInEmail(String email, String code) async {
    final e = emailAuth;
    if (e == null || _busy) return false;
    _setBusy(true);
    try {
      await e.verifyEmailCode(email, code);
      await refresh();
      return auth.isSignedIn;
    } on ApiException {
      return false;
    } on Exception catch (err) {
      debugPrint('email sign-in failed: $err');
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _signIn(Future<void> Function() action) async {
    if (_busy) return;
    _setBusy(true);
    try {
      await action();
      if (auth.isSignedIn) await refresh();
    } on ApiException catch (e) {
      _emitError(e.code);
    } on Exception catch (e) {
      debugPrint('sign-in failed: $e');
      _emitError('AUTH_FAILED');
    } finally {
      _setBusy(false);
    }
  }

  /// `PUT /v1/me {birthYear}` – DESIGN.md S2.
  Future<void> submitBirthYear(int year) async {
    if (_busy) return;
    _setBusy(true);
    try {
      final updated = await api.updateMe(birthYear: year);
      _user = updated;
      _setStatus(updated.profileComplete ? SessionStatus.ready : SessionStatus.needsBirthYear);
    } on ApiException catch (e) {
      if (e.code == 'BIRTH_YEAR_LOCKED') {
        await refresh();
      } else {
        await _handleApiError(e);
      }
    } finally {
      _setBusy(false);
    }
  }

  /// Trả `true` nếu thành công. Đổi `locale` ngay vì [locale] lấy từ [user].
  Future<bool> updateLanguage(String language) async {
    return _updateProfile(() => api.updateMe(language: language));
  }

  /// Lưu sở thích (đăng ký lần đầu hoặc sửa trong cài đặt). Thành công thì đóng màn chọn.
  Future<bool> submitInterests(List<String> ids) async {
    if (_busy) return false;
    _setBusy(true);
    try {
      final ok = await _updateProfile(() => api.updateMe(interests: ids));
      if (ok) {
        _askInterests = false;
        notifyListeners();
      }
      return ok;
    } finally {
      _setBusy(false);
    }
  }

  /// Bỏ qua bước chọn sở thích (có thể chọn lại sau).
  void skipInterests() {
    _askInterests = false;
    notifyListeners();
  }

  Future<bool> updateDisplayName(String name) async {
    return _updateProfile(() => api.updateMe(displayName: name));
  }

  Future<bool> _updateProfile(Future<AppUser> Function() call) async {
    try {
      _user = await call();
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      await _handleApiError(e);
      return false;
    }
  }

  Future<void> signOut() async {
    try {
      await beforeSignOut?.call();
    } on Exception catch (e) {
      debugPrint('beforeSignOut failed: $e');
    }
    try {
      await auth.signOut();
    } on Exception catch (e) {
      debugPrint('auth.signOut failed: $e');
    }
    _user = null;
    _errorCode = null;
    _setStatus(SessionStatus.signedOut);
  }

  Future<void> _handleApiError(ApiException e) async {
    switch (e.code) {
      case 'UNDERAGE':
        _setStatus(SessionStatus.underage);
      case 'ACCOUNT_BANNED':
        _setStatus(SessionStatus.banned);
      case 'UNAUTHENTICATED':
        await signOut();
      default:
        _errorCode = e.code;
        _emitError(e.code);
        // Lỗi mạng lúc khởi động (hoặc lúc bấm "Thử lại"): thoát khỏi màn "loading" nhưng giữ đăng nhập.
        if (_status == SessionStatus.loading || _status == SessionStatus.offline) {
          _setStatus(auth.isSignedIn ? SessionStatus.offline : SessionStatus.signedOut);
        }
        notifyListeners();
    }
  }

  void _emitError(String code) {
    _errorCode = code;
    if (!_errors.isClosed) _errors.add(code);
  }

  void _setStatus(SessionStatus s) {
    _status = s;
    notifyListeners();
  }

  void _setBusy(bool v) {
    _busy = v;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _errors.close();
    super.dispose();
  }
}
