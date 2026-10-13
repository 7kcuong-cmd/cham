import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Id kênh v2 (có âm thanh riêng trong res/raw; kênh Android không đổi được âm sau khi tạo nên phải đổi id).
/// Phải khớp `CHANNELS` ở backend.
const String kCallChannelId = 'cham_calls_v2';
const String kMessageChannelId = 'cham_messages_v2';

/// Tạo kênh thông báo Android (8.0+). Tên kênh phải khớp `CHANNELS` ở backend (FcmPushProvider.js).
/// Cuộc gọi: độ ưu tiên cao nhất để hiện popup + chuông; tin nhắn: mức cao vừa.
Future<void> createNotificationChannels() async {
  if (kIsWeb || !Platform.isAndroid) return;
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      kCallChannelId,
      'Cuộc gọi',
      description: 'Có người gọi cho bạn',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('ring_chuong'),
      enableVibration: true,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      kMessageChannelId,
      'Tin nhắn',
      description: 'Tin nhắn mới và cuộc gọi nhỡ',
      importance: Importance.high,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('msg_ding'),
    ));
  } on Object catch (e) {
    debugPrint('notification channels: $e');
  }
}
