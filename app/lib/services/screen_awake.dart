import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Giữ màn hình sáng khi app đang mở. Cờ giữ sáng của Android có thể mất khi Activity bị dựng lại
/// (sau hộp thoại quyền, chọn tệp, quét QR, khóa sinh trắc...) và một lần `enable()` lỗi sớm bị nuốt im lặng,
/// nên ở đây BẬT LẠI khi app quay lại và cứ 15 giây một lần trong lúc đang mở (gọi lại rất rẻ).
class ScreenAwake with WidgetsBindingObserver {
  ScreenAwake({this.interval = const Duration(seconds: 15)});

  final Duration interval;
  Timer? _timer;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_hold());
    _timer = Timer.periodic(interval, (_) => unawaited(_hold()));
  }

  /// Đường dự phòng: tự đặt FLAG_KEEP_SCREEN_ON lên cửa sổ Activity (plugin `cham_notify`, Android).
  /// Chạy độc lập với wakelock_plus để một trong hai lỗi thì màn hình vẫn sáng.
  static const MethodChannel _native = MethodChannel('cham/notify');

  Future<void> _hold() async {
    try {
      await WakelockPlus.enable();
    } on Object catch (e) {
      debugPrint('wakelock enable failed (sẽ thử lại): $e');
    }
    await _nativeKeepOn(true);
  }

  Future<void> _nativeKeepOn(bool on) async {
    try {
      await _native.invokeMethod<void>('keepScreenOn', <String, dynamic>{'on': on});
    } on Object {
      // Không phải Android / không có plugin (test): bỏ qua.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_hold());
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    try {
      await WakelockPlus.disable();
    } on Object {
      // bỏ qua
    }
    await _nativeKeepOn(false);
  }
}
