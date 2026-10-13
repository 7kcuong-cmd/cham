import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Kho bí mật gắn với Keystore (Android) / Keychain (iOS): khóa chat, khóa mã hóa dữ liệu, băm mã khóa app.
abstract class SecureVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
}

class MemorySecureVault implements SecureVault {
  final Map<String, String> _m = <String, String>{};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);

  @override
  Future<void> deleteAll() async => _m.clear();
}

/// Bản thật (`flutter_secure_storage`). Khóa chỉ dùng được khi máy đã mở khóa và KHÔNG chuyển sang máy khác.
class FlutterSecureVault implements SecureVault {
  FlutterSecureVault([FlutterSecureStorage? s])
      : _s = s ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
            );

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _s.delete(key: key);

  @override
  Future<void> deleteAll() => _s.deleteAll();
}
