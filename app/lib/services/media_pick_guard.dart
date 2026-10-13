import 'package:flutter/foundation.dart';

/// Cờ "đang mở bộ chọn tệp/ảnh của hệ thống". Khi bộ chọn mở, Android đưa app sang `paused/hidden`; nếu không có cờ
/// này màn Home sẽ tưởng người dùng rời app và cắt cuộc gọi. Mọi chỗ mở bộ chọn đều phải đi qua [MediaPickGuard.run].
class MediaPickGuard {
  MediaPickGuard._();

  static int _depth = 0;
  static DateTime? _lastEnd;

  /// Quay lại app xong vẫn còn "ân hạn" ngắn: sự kiện `resumed` có thể đến sau khi Future của bộ chọn hoàn tất.
  static const tail = Duration(seconds: 2);

  static bool get active {
    if (_depth > 0) return true;
    final e = _lastEnd;
    return e != null && DateTime.now().difference(e) < tail;
  }

  static Future<T> run<T>(Future<T> Function() action) async {
    _depth++;
    try {
      return await action();
    } finally {
      _depth--;
      _lastEnd = DateTime.now();
    }
  }

  @visibleForTesting
  static void reset() {
    _depth = 0;
    _lastEnd = null;
  }
}
