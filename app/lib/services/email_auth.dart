import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/api_error.dart';
import 'auth_service.dart';
import 'secure_vault.dart';

/// Đăng ký / đăng nhập bằng email (mã 6 số gửi qua email). Bật bằng `--dart-define=EMAIL_AUTH=true`
/// và server phải cấu hình EMAIL_PROVIDER (xem DANG-NHAP-EMAIL.md). CHƯA THỬ TRÊN MÁY THẬT.
abstract class EmailAuthPort {
  /// Gửi mã tới email. Không báo email có tồn tại hay không.
  Future<void> requestEmailCode(String email, {required String language});

  /// Đổi mã lấy phiên đăng nhập. Ném [ApiException] nếu sai/hết hạn.
  Future<void> verifyEmailCode(String email, String code);
}

/// Bọc một [AuthService] có sẵn (Firebase hoặc dev) và thêm đăng nhập bằng email.
/// Token email do server ký (hạn mặc định 30 ngày), lưu trong kho bí mật; hết hạn thì phải xin mã mới.
class EmailAuthService implements AuthService, EmailAuthPort {
  EmailAuthService({required AuthService inner, required String baseUrl, required SecureVault vault, http.Client? client})
      : _inner = inner,
        _base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _vault = vault,
        _http = client ?? http.Client();

  static const _key = 'email_token';
  final AuthService _inner;
  final String _base;
  final SecureVault _vault;
  final http.Client _http;
  String? _token;

  /// Hạn (giây epoch) trong token `em1.<payload>.<chữ ký>`; `null` nếu hỏng.
  static int? tokenExpiry(String token) {
    final parts = token.split('.');
    if (parts.length != 3 || parts[0] != 'em1') return null;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final e = j is Map ? j['e'] : null;
      return e is int ? e : null;
    } on Object {
      return null;
    }
  }

  bool _valid(String? t) {
    if (t == null) return false;
    final e = tokenExpiry(t);
    return e != null && e * 1000 > DateTime.now().millisecondsSinceEpoch;
  }

  @override
  Future<void> init() async {
    await _inner.init();
    try {
      final saved = await _vault.read(_key);
      _token = _valid(saved) ? saved : null;
      if (saved != null && _token == null) await _vault.delete(_key);
    } on Object catch (e) {
      debugPrint('email token read failed: $e');
    }
  }

  @override
  bool get isSignedIn => _token != null || _inner.isSignedIn;

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    if (_token != null) {
      if (_valid(_token)) return _token;
      _token = null;
      await _vault.delete(_key);
    }
    return _inner.getIdToken(forceRefresh: forceRefresh);
  }

  @override
  Future<void> signInWithGoogle() => _inner.signInWithGoogle();
  @override
  Future<void> signInWithApple() => _inner.signInWithApple();
  @override
  Future<void> signInDev(String uid) => _inner.signInDev(uid);

  @override
  Future<void> signOut() async {
    _token = null;
    try {
      await _vault.delete(_key);
    } on Object {
      // không xóa được: token vẫn hết hạn theo thời gian
    }
    await _inner.signOut();
  }

  @override
  Future<void> requestEmailCode(String email, {required String language}) async {
    await _post('/v1/auth/email/start', <String, dynamic>{'email': email.trim(), 'language': language});
  }

  @override
  Future<void> verifyEmailCode(String email, String code) async {
    final json = await _post('/v1/auth/email/verify', <String, dynamic>{'email': email.trim(), 'code': code.trim()});
    final t = json?['idToken'];
    if (t is! String || !_valid(t)) throw const ApiException(code: 'AUTH_FAILED');
    _token = t;
    try {
      await _vault.write(_key, t);
    } on Object catch (e) {
      debugPrint('email token save failed: $e'); // vẫn đăng nhập được trong phiên này
    }
  }

  Future<Map<String, dynamic>?> _post(String path, Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('$_base$path'), headers: <String, String>{'content-type': 'application/json'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
    } on Object {
      throw const ApiException(code: 'NETWORK');
    }
    if (res.statusCode >= 200 && res.statusCode < 300) {
      if (res.body.isEmpty) return null;
      final d = jsonDecode(res.body);
      return d is Map<String, dynamic> ? d : null;
    }
    var code = 'AUTH_FAILED';
    try {
      final d = jsonDecode(res.body);
      final c = d is Map ? (d['error'] is Map ? (d['error'] as Map)['code'] : null) : null;
      if (c is String) code = c;
    } on Object {
      // giữ mã mặc định
    }
    throw ApiException(code: code, httpStatus: res.statusCode);
  }
}
