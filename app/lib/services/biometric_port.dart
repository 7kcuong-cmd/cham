import 'package:local_auth/local_auth.dart';

/// Mở khóa bằng vân tay / khuôn mặt của hệ điều hành. Không thay thế PIN: PIN vẫn là đường dự phòng,
/// và sinh trắc học KHÔNG tính vào số lần nhập sai.
abstract class BiometricPort {
  Future<bool> get available;
  Future<bool> authenticate(String reason);
}

class NoBiometrics implements BiometricPort {
  const NoBiometrics();

  @override
  Future<bool> get available async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// CẦN KIỂM TRA theo phiên bản `local_auth` (viết theo 2.x: `canCheckBiometrics`, `getAvailableBiometrics`,
/// `authenticate(localizedReason:, options: AuthenticationOptions(biometricOnly:))`). Android cần
/// `FlutterFragmentActivity` (tool/patch-platforms.mjs đã vá) và quyền USE_BIOMETRIC.
class LocalAuthBiometrics implements BiometricPort {
  LocalAuthBiometrics([LocalAuthentication? a]) : _a = a ?? LocalAuthentication();

  final LocalAuthentication _a;

  @override
  Future<bool> get available async {
    try {
      return await _a.canCheckBiometrics && (await _a.getAvailableBiometrics()).isNotEmpty;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _a.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } on Object {
      return false;
    }
  }
}
