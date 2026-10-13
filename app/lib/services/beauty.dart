
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:shared_preferences/shared_preferences.dart';

/// Làm đẹp (0..100, mặc định 0 = tắt): làm mịn + sáng da nhẹ, vẽ bằng bộ lọc Flutter (xem `BeautyFilter`).
/// Mức của mình được gửi cho đối phương qua DataChannel (`BeautySync`) để máy họ vẽ hiệu ứng lên hình của mình;
/// vì thế nó KHÔNG sửa khung hình gửi đi (flutter_webrtc 1.x không có API bộ xử lý khung hình).
class BeautySettings extends ChangeNotifier {
  BeautySettings._();
  static final BeautySettings instance = BeautySettings._();

  static const _key = 'beauty_level';
  static const _channel = MethodChannel('cham/beauty');
  static const effect = 'cham_beauty';

  int _level = 0;
  int get level => _level;

  static const _chinKey = 'beauty_chin';
  static const _eyesKey = 'beauty_eyes';
  int _chin = 0;
  int _eyes = 0;

  /// Nhọn cằm / mắt to (0..100, mặc định 0 = tắt). Cần theo dõi mặt nên chỉ chạy khi thiết bị hỗ trợ.
  int get chin => _chin;
  int get eyes => _eyes;
  bool get reshapeActive => _chin > 0 || _eyes > 0;

  Future<void> setChin(int v) async {
    _chin = v.clamp(0, 100);
    notifyListeners();
    await _saveInt(_chinKey, _chin);
  }

  Future<void> setEyes(int v) async {
    _eyes = v.clamp(0, 100);
    notifyListeners();
    await _saveInt(_eyesKey, _eyes);
  }

  Future<void> _saveInt(String k, int v) async {
    try {
      await (await SharedPreferences.getInstance()).setInt(k, v);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên này
    }
  }

  bool get supported => true;

  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _level = (sp.getInt(_key) ?? 0).clamp(0, 100);
      _chin = (sp.getInt(_chinKey) ?? 0).clamp(0, 100);
      _eyes = (sp.getInt(_eyesKey) ?? 0).clamp(0, 100);
      await _push();
      notifyListeners();
    } on Object {
      // giữ mặc định
    }
  }

  Future<void> setLevel(int v) async {
    _level = v.clamp(0, 100);
    await _push();
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setInt(_key, _level);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên này
    }
  }

  Future<void> _push() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('setLevel', <String, dynamic>{'level': _level});
    } on Object catch (e) {
      debugPrint('beauty setLevel ignored: $e');
    }
  }

  /// Giữ lại cho tương thích: không còn gắn bộ xử lý lên track (hiệu ứng được vẽ ở phía hiển thị).
  Future<void> applyTo(rtc.MediaStream? stream) async {}
}
