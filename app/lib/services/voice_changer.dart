import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Kiểu giọng (khớp `VoiceChanger` ở Android: 0 tắt, 1 trầm, 2 cao, 3 robot, 4 quái vật).
enum VoicePreset { off, deep, high, robot, monster }

/// Đổi giọng của mình trước khi gửi đi (người kia nghe giọng đã đổi, mình vẫn nghe giọng thật).
/// Chỉ Android (bộ xử lý âm thanh gắn vào flutter_webrtc qua plugin `cham_beauty`). Không lưu: mỗi lần mở app là tắt.
class VoiceChanger extends ChangeNotifier {
  VoiceChanger._();
  static final VoiceChanger instance = VoiceChanger._();

  static const _channel = MethodChannel('cham/voice');

  VoicePreset _preset = VoicePreset.off;
  VoicePreset get preset => _preset;

  /// Mô tả trạng thái bộ xử lý (để hiện khi không nghe thấy hiệu ứng).
  String status = '';

  bool get supported => !kIsWeb && Platform.isAndroid;

  /// Đặt kiểu giọng. Trả `true` nếu bật được; `false` nếu thư viện gọi không cho gắn bộ xử lý (đã tắt hiệu ứng).
  Future<bool> setPreset(VoicePreset p) async {
    if (!supported) return p == VoicePreset.off;
    try {
      final r = await _channel.invokeMapMethod<String, dynamic>('setPreset', <String, dynamic>{'preset': p.index});
      final ok = r?['ok'] == true;
      status = (r?['status'] as String?) ?? '';
      _preset = ok ? p : VoicePreset.off;
      notifyListeners();
      return ok;
    } on Object catch (e) {
      status = 'lỗi kênh: $e';
      _preset = VoicePreset.off;
      notifyListeners();
      return false;
    }
  }

  Future<void> refreshStatus() async {
    if (!supported) return;
    try {
      status = (await _channel.invokeMethod<String>('status')) ?? status;
      notifyListeners();
    } on Object {
      // giữ trạng thái cũ
    }
  }
}
