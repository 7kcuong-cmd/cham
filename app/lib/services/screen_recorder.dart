/// Cổng tới bộ ghi màn hình của hệ điều hành (Android MediaProjection, iOS ReplayKit).
/// Chưa có bản cài thật: cần mã native và thử trên máy thật. Khi [supported] = false, UI ẩn nút ghi
/// và [RecordingController] không bao giờ xin phép người kia.
abstract class ScreenRecorder {
  bool get supported;

  /// Bắt đầu ghi. `false` nếu bị từ chối quyền / lỗi.
  Future<bool> start();

  /// Dừng ghi; trả đường dẫn tệp (hoặc `null` nếu lỗi).
  Future<String?> stop();
}

/// Bộ ghi có thể bị dừng từ bên ngoài app (nút "Dừng" trong thông báo, hệ thống dừng chia sẻ màn hình).
/// Mỗi phần tử là đường dẫn clip (null nếu lỗi). Tách riêng để các bản giả trong test không phải cài.
abstract interface class ExternalStopSource {
  Stream<String?> get externalStops;
}

class UnsupportedScreenRecorder implements ScreenRecorder {
  const UnsupportedScreenRecorder();

  @override
  bool get supported => false;

  @override
  Future<bool> start() async => false;

  @override
  Future<String?> stop() async => null;
}
