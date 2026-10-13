import 'package:permission_handler/permission_handler.dart';

enum PermissionOutcome { granted, denied, permanentlyDenied }

/// Quyền camera + micro. Tách khỏi `permission_handler` để test được.
abstract class PermissionGateway {
  Future<bool> hasCameraAndMic();
  Future<PermissionOutcome> request();
  Future<void> openSettings();
}

class SystemPermissionGateway implements PermissionGateway {
  const SystemPermissionGateway();

  @override
  Future<bool> hasCameraAndMic() async {
    final camera = await Permission.camera.status;
    final mic = await Permission.microphone.status;
    return camera.isGranted && mic.isGranted;
  }

  @override
  Future<PermissionOutcome> request() async {
    final result = await <Permission>[Permission.camera, Permission.microphone].request();
    final statuses = result.values;
    if (statuses.every((s) => s.isGranted)) return PermissionOutcome.granted;
    if (statuses.any((s) => s.isPermanentlyDenied)) return PermissionOutcome.permanentlyDenied;
    return PermissionOutcome.denied;
  }

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
