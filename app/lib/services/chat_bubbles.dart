import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'push_service.dart';

/// Bong bóng tin nhắn (Android 11+) qua plugin `cham_notify`. Build với `--dart-define=CHAT_BUBBLES=true` và backend
/// `PUSH_CHAT_BUBBLES=true` (tin `dm_new` gửi dạng data-only để app tự dựng thông báo có bong bóng).
/// Bong bóng chỉ là lối tắt: bấm vào sẽ mở màn chat trong app (không có ô trả lời ngay trong bong bóng).
/// CHƯA THỬ TRÊN MÁY THẬT.
class ChatBubbles {
  ChatBubbles._();

  static const MethodChannel _ch = MethodChannel('cham/notify');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Gọi được cả trong isolate nền của FCM. Trả `false` nếu không hiện được.
  static Future<bool> show({required String peerId, required String name, required String text}) async {
    if (!supported) return false;
    try {
      return (await _ch.invokeMethod<bool>('bubble', <String, dynamic>{'peerId': peerId, 'name': name, 'text': text})) ?? false;
    } on Object catch (e) {
      debugPrint('chat bubble: $e');
      return false;
    }
  }

  /// Nghe bấm bong bóng khi app đang chạy và lấy cuộc trò chuyện đã mở app từ trạng thái tắt. Gọi một lần sau khi
  /// `PushTaps.chat` đã có người nghe.
  static Future<void> start() async {
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'openChat') {
        final id = (call.arguments as Map?)?['peerId'];
        if (id is String && id.isNotEmpty) PushTaps.chat.add(id);
      }
      return null;
    });
    try {
      final id = await _ch.invokeMethod<String>('takeLaunchPeer');
      if (id != null && id.isNotEmpty) PushTaps.chat.add(id);
    } on Object catch (e) {
      debugPrint('chat bubble launch: $e');
    }
  }
}
