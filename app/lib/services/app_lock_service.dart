import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'secure_vault.dart';

enum UnlockStatus { ok, wrong, wiped, notEnabled }

class UnlockResult {
  const UnlockResult(this.status, {this.remaining = 0});
  final UnlockStatus status;

  /// Số lần thử còn lại trước khi xóa sạch (khi [status] = wrong).
  final int remaining;
}

/// Khóa ứng dụng bằng mã PIN 6 số. CHỈ hoạt động khi người dùng bật.
///  - PIN không lưu; chỉ lưu băm PBKDF2-HMAC-SHA256 + muối trong [SecureVault].
///  - Số lần sai được GHI TRƯỚC khi kiểm tra: tắt app giữa chừng cũng không được thử lại miễn phí.
///  - Sai đủ [maxAttempts] lần liên tiếp → gọi [onWipe] (xóa toàn bộ dữ liệu trên máy).
class AppLockService {
  AppLockService({required SecureVault vault, required this.onWipe, this.iterations = 150000}) : _v = vault;

  final SecureVault _v;
  final Future<void> Function() onWipe;
  final int iterations;

  static const _kEnabled = 'lock_enabled';
  static const _kSalt = 'lock_salt';
  static const _kHash = 'lock_hash';
  static const _kMax = 'lock_max';
  static const _kFails = 'lock_fails';
  static const _kAfter = 'lock_after';
  static const _kBio = 'lock_bio';

  static final RegExp pinFormat = RegExp(r'^\d{6}$');
  static const allowedAttempts = <int>[3, 5, 10];

  Future<bool> get isEnabled async => await _v.read(_kEnabled) == '1';
  Future<int> get maxAttempts async => int.tryParse(await _v.read(_kMax) ?? '') ?? 3;
  Future<bool> get biometricEnabled async => await _v.read(_kBio) == '1';
  Future<void> setBiometric(bool on) => on ? _v.write(_kBio, '1') : _v.delete(_kBio);

  Future<int> get lockAfterSeconds async => int.tryParse(await _v.read(_kAfter) ?? '') ?? 30;

  Future<List<int>> _hash(String pin, List<int> salt) async {
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
        .deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }

  Future<void> enable(String pin, {int maxAttempts = 3, int lockAfterSeconds = 30}) async {
    if (!pinFormat.hasMatch(pin)) throw ArgumentError('PIN phải gồm 6 chữ số');
    if (!allowedAttempts.contains(maxAttempts)) throw ArgumentError('Số lần thử không hợp lệ');
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    await _v.write(_kSalt, base64.encode(salt));
    await _v.write(_kHash, base64.encode(await _hash(pin, salt)));
    await _v.write(_kMax, '$maxAttempts');
    await _v.write(_kAfter, '$lockAfterSeconds');
    await _v.write(_kFails, '0');
    await _v.write(_kEnabled, '1');
  }

  Future<UnlockResult> verify(String pin) async {
    if (!await isEnabled) return const UnlockResult(UnlockStatus.notEnabled);
    final max = await maxAttempts;
    final fails = (int.tryParse(await _v.read(_kFails) ?? '') ?? 0) + 1;
    await _v.write(_kFails, '$fails'); // ghi TRƯỚC khi kiểm tra
    final saltB64 = await _v.read(_kSalt);
    final hashB64 = await _v.read(_kHash);
    var ok = false;
    if (saltB64 != null && hashB64 != null && pinFormat.hasMatch(pin)) {
      final got = await _hash(pin, base64.decode(saltB64));
      final want = base64.decode(hashB64);
      var diff = got.length ^ want.length;
      for (var i = 0; i < got.length && i < want.length; i++) {
        diff |= got[i] ^ want[i];
      }
      ok = diff == 0;
    }
    if (ok) {
      await _v.write(_kFails, '0');
      return const UnlockResult(UnlockStatus.ok);
    }
    if (fails >= max) {
      await onWipe();
      return const UnlockResult(UnlockStatus.wiped);
    }
    return UnlockResult(UnlockStatus.wrong, remaining: max - fails);
  }

  /// Tắt khóa (phải nhập đúng PIN; nhập sai vẫn tính lần).
  Future<UnlockResult> disable(String pin) async {
    final r = await verify(pin);
    if (r.status == UnlockStatus.ok) {
      for (final k in [_kEnabled, _kSalt, _kHash, _kMax, _kFails, _kAfter, _kBio]) {
        await _v.delete(k);
      }
    }
    return r;
  }
}
