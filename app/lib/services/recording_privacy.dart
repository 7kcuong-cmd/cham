import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tùy chọn riêng tư khi MÌNH ghi hình: làm mờ (ô vuông pixel) khuôn mặt người đối diện trong clip.
/// Mặc định BẬT: tắt thì mặt người kia lộ rõ trong clip của bạn.
class RecordingPrivacy extends ChangeNotifier {
  RecordingPrivacy._();
  static final RecordingPrivacy instance = RecordingPrivacy._();

  static const _key = 'rec_pixel_peer_face';
  bool _blur = true;
  bool get blurPeerFace => _blur;

  Future<void> load() async {
    try {
      _blur = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
      notifyListeners();
    } on Object {
      // giữ mặc định (bật)
    }
  }

  Future<void> set(bool v) async {
    _blur = v;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, v);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên này
    }
  }

  @visibleForTesting
  void debugSet(bool v) {
    _blur = v;
    notifyListeners();
  }
}
