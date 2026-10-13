import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Chế độ riêng tư": cuộc gọi đi qua máy chủ chuyển tiếp (TURN) nên đối phương KHÔNG thấy IP của bạn.
/// Đổi lại: độ trễ cao hơn và tốn băng thông máy chủ. Mặc định tắt (P2P thuần, hai bên thấy IP nhau).
class PrivacySettings extends ChangeNotifier {
  PrivacySettings._();
  static final PrivacySettings instance = PrivacySettings._();

  static const _key = 'privacy_relay_only';
  bool _on = false;
  bool get relayOnly => _on;

  Future<void> load() async {
    try {
      _on = (await SharedPreferences.getInstance()).getBool(_key) ?? false;
      notifyListeners();
    } on Object {
      // giữ mặc định
    }
  }

  Future<void> set(bool on) async {
    _on = on;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên hiện tại
    }
  }

  /// Tạo cấu hình ICE theo chế độ. Trả `null` nếu bật riêng tư mà server không cấp TURN (không thể ẩn IP).
  static Map<String, dynamic>? iceConfig(List<Map<String, dynamic>> servers, {required bool relayOnly}) {
    bool isTurn(Map<String, dynamic> s) {
      final u = s['urls'];
      final list = u is List ? u : <Object?>[u];
      return list.any((x) => x is String && (x.startsWith('turn:') || x.startsWith('turns:')));
    }

    if (relayOnly) {
      final turn = servers.where(isTurn).toList(growable: false);
      if (turn.isEmpty) return null;
      return <String, dynamic>{'iceServers': turn, 'iceTransportPolicy': 'relay'};
    }
    // Không riêng tư: bỏ TURN để không tốn relay; chỉ STUN.
    return <String, dynamic>{'iceServers': servers.where((s) => !isTurn(s)).toList(growable: false)};
  }
}
