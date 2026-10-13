import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Mở URL bằng trình duyệt ngoài. Lỗi chỉ ghi log (liên kết không quan trọng
/// tới mức chặn người dùng).
Future<void> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || url.isEmpty) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (e) {
    debugPrint('openExternalUrl failed: $e');
  }
}
