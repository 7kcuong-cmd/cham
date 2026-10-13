import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_error.dart';

/// Nguồn token đăng nhập. Hai bản cài: Firebase và dev (`AUTH_MODE=dev`).
abstract class AuthService {
  /// Khôi phục phiên đã lưu (gọi một lần lúc mở app, trước khi đọc [isSignedIn]).
  Future<void> init();

  /// Người dùng hủy hộp thoại → trả về bình thường và [isSignedIn] vẫn `false`.
  Future<void> signInWithGoogle();
  Future<void> signInWithApple();
  Future<void> signInDev(String uid);

  /// `null` nếu chưa đăng nhập.
  Future<String?> getIdToken({bool forceRefresh = false});
  Future<void> signOut();
  bool get isSignedIn;
}

/// Nơi lưu uid dev giữa các lần mở app (tách ra để test không cần plugin).
abstract class DevUidStore {
  Future<String?> read();

  /// `null` = xóa.
  Future<void> write(String? uid);
}

/// Bản thật dựa trên `shared_preferences`.
class SharedPrefsDevUidStore implements DevUidStore {
  static const String _key = 'cham.dev_uid';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key);
  }

  @override
  Future<void> write(String? uid) async {
    final prefs = await SharedPreferences.getInstance();
    if (uid == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, uid);
    }
  }
}

/// Đăng nhập giả cho backend dev: token là `dev:<uid>` (API.md §0.1).
/// uid được lưu (shared_preferences) để mở lại app vẫn ở trạng thái đã đăng nhập,
/// giống Firebase giữ phiên. Đăng xuất thì xóa.
class DevAuthService implements AuthService {
  DevAuthService({DevUidStore? store}) : _store = store ?? SharedPrefsDevUidStore();

  static final RegExp _uidPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  final DevUidStore _store;
  String? _uid;

  static bool isValidUid(String uid) => _uidPattern.hasMatch(uid);

  @override
  Future<void> init() async {
    try {
      final saved = await _store.read();
      // Giá trị lưu hỏng/bị sửa tay thì bỏ qua (coi như chưa đăng nhập).
      if (saved != null && isValidUid(saved)) _uid = saved;
    } on Object catch (e) {
      debugPrint('DevAuthService.init: cannot read saved uid: $e');
    }
  }

  @override
  bool get isSignedIn => _uid != null;

  @override
  Future<void> signInDev(String uid) async {
    if (!isValidUid(uid)) {
      throw const ApiException(code: 'BAD_REQUEST');
    }
    _uid = uid;
    try {
      await _store.write(uid);
    } on Object catch (e) {
      debugPrint('DevAuthService: cannot save uid: $e'); // vẫn đăng nhập được trong phiên này
    }
  }

  @override
  Future<void> signInWithGoogle() async =>
      throw UnsupportedError('Google sign-in is not available in dev auth mode');

  @override
  Future<void> signInWithApple() async =>
      throw UnsupportedError('Apple sign-in is not available in dev auth mode');

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final uid = _uid;
    return uid == null ? null : 'dev:$uid';
  }

  @override
  Future<void> signOut() async {
    _uid = null;
    try {
      await _store.write(null);
    } on Object catch (e) {
      debugPrint('DevAuthService: cannot clear uid: $e');
    }
  }
}

/// Firebase Auth. `Firebase.initializeApp` phải đã chạy (xem main.dart).
///
/// - Google: gói `google_sign_in` **6.x** (`GoogleSignIn().signIn()`); bản 7.x đổi
///   hẳn API – cần kiểm tra theo phiên bản nếu nâng cấp.
/// - Apple: `AppleAuthProvider` của `firebase_auth` (`signInWithProvider`) – không
///   cần tự sinh nonce/băm SHA-256 và không thêm gói `sign_in_with_apple`/`crypto`.
///   Vẫn cần bật capability "Sign in with Apple" trong Xcode (xem APP-CHAY-THU.md).
class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? googleSignIn})
      : _auth = auth ?? FirebaseAuth.instance,
        _google = googleSignIn ?? GoogleSignIn();

  final FirebaseAuth _auth;
  final GoogleSignIn _google;

  @override
  Future<void> init() async {
    // Phiên được khôi phục bất đồng bộ: sự kiện đầu tiên của authStateChanges
    // phản ánh người dùng đã lưu (hoặc null).
    await _auth.authStateChanges().first;
  }

  @override
  bool get isSignedIn => _auth.currentUser != null;

  @override
  Future<void> signInWithGoogle() async {
    try {
      final account = await _google.signIn();
      if (account == null) return; // người dùng hủy
      final tokens = await account.authentication;
      final credential = GoogleAuthProvider.credential(
        idToken: tokens.idToken,
        accessToken: tokens.accessToken,
      );
      await _auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      if (_isCancel(e.code)) return;
      throw _mapFirebaseError(e);
    } on PlatformException catch (e) {
      if (_isCancel(e.code)) return;
      debugPrint('Google sign-in failed: ${e.code}');
      throw ApiException(code: e.code == 'network_error' ? 'NETWORK' : 'AUTH_FAILED');
    }
  }

  @override
  Future<void> signInWithApple() async {
    try {
      final provider = AppleAuthProvider()
        ..addScope('email')
        ..addScope('name');
      await _auth.signInWithProvider(provider);
    } on FirebaseAuthException catch (e) {
      if (_isCancel(e.code)) return;
      throw _mapFirebaseError(e);
    }
  }

  @override
  Future<void> signInDev(String uid) async =>
      throw UnsupportedError('Dev sign-in is not available in firebase auth mode');

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return user.getIdToken(forceRefresh);
  }

  @override
  Future<void> signOut() async {
    try {
      await _google.signOut();
    } on Exception catch (e) {
      debugPrint('Google signOut ignored: $e');
    }
    await _auth.signOut();
  }

  /// Mã lỗi nghĩa là người dùng tự đóng hộp thoại (không báo lỗi). Tên mã khác
  /// nhau theo nền tảng/phiên bản – cần kiểm tra theo phiên bản đã cài.
  static bool _isCancel(String code) {
    final c = code.toLowerCase();
    return c.contains('cancel') || c == 'popup-closed-by-user';
  }

  ApiException _mapFirebaseError(FirebaseAuthException e) {
    debugPrint('FirebaseAuthException: ${e.code}');
    if (e.code == 'network-request-failed') {
      return const ApiException(code: 'NETWORK');
    }
    return const ApiException(code: 'AUTH_FAILED');
  }
}
