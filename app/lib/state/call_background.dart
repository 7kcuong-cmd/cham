import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ảnh nền cuộc gọi người dùng chọn (id trong `backgrounds` của remote-config). Rỗng = không dùng.
class CallBackgroundSettings extends ChangeNotifier {
  CallBackgroundSettings._();
  static final CallBackgroundSettings instance = CallBackgroundSettings._();

  static const _key = 'call_background_id';
  String _id = '';
  String get selectedId => _id;

  Future<void> load() async {
    try {
      _id = (await SharedPreferences.getInstance()).getString(_key) ?? '';
      notifyListeners();
    } on Object {
      // giữ mặc định
    }
  }

  Future<void> select(String id) async {
    _id = id;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_key, id);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên hiện tại
    }
  }
}
