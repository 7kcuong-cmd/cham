import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'notification_channels.dart' show kMessageChannelId;

import 'incoming_call_notifier.dart';
import 'push_service.dart';

/// Thông báo tin nhắn mới không cần Firebase: khi app ở nền mà tiến trình còn sống (WebSocket còn nối) thì tự hiện
/// thông báo. Nội dung tin được mã hóa nên chỉ hiện tên người gửi, không hiện nội dung.
/// Cũng xin quyền thông báo (Android 13+) ngay lần đầu mở app.
class MessageNotifier {
  MessageNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Xin quyền thông báo (bỏ qua nếu đã cấp) và đăng ký xử lý bấm thông báo.
  static Future<void> init() async {
    if (!supported || _ready) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          final p = r.payload;
          if (p == null || p.isEmpty) return;
          try {
            final j = jsonDecode(p);
            if (j is! Map) return;
            final kind = j['kind'];
            if (kind == 'dm' && j['peerId'] is String) PushTaps.chat.add(j['peerId'] as String);
            if (kind == 'call_invite' && j['inviteId'] is String) {
              IncomingCallNotifier.taps.add(j['inviteId'] as String);
            }
          } on Object {
            // payload lạ: bỏ qua
          }
        },
      );
      _ready = true;
      final status = await Permission.notification.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    } on Object catch (e) {
      debugPrint('message notifier init: $e');
    }
  }

  /// Hiện "{name} đã gửi tin nhắn" (không kèm nội dung).
  static Future<void> showMessage({required String peerId, required String name}) async {
    if (!supported) return;
    if (!_ready) await init();
    try {
      await _plugin.show(
        peerId.hashCode & 0x7fffffff,
        name.isEmpty ? 'Tin nhắn mới' : name,
        'Có tin nhắn mới (đã mã hóa)',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            kMessageChannelId,
            'Tin nhắn',
            channelDescription: 'Tin nhắn mới và cuộc gọi nhỡ',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: RawResourceAndroidNotificationSound('msg_ding'),
            category: AndroidNotificationCategory.message,
            autoCancel: true,
          ),
        ),
        payload: jsonEncode(<String, String>{'kind': 'dm', 'peerId': peerId}),
      );
    } on Object catch (e) {
      debugPrint('message notification: $e');
    }
  }

  static final Map<String, int> _missedCount = <String, int>{};

  /// Hiện "Cuộc gọi nhỡ" (một thông báo cho mỗi người gọi, gộp số lần). Trả true nếu đã hiện (để xác nhận với server).
  static Future<bool> showMissedCall({required String peerId, required String name, required DateTime at, int extra = 0}) async {
    if (!supported) return false;
    if (!_ready) await init();
    try {
      final n = (_missedCount[peerId] ?? 0) + 1 + extra;
      _missedCount[peerId] = n;
      final who = name.isEmpty ? 'Một người bạn' : name;
      final hh = at.toLocal().hour.toString().padLeft(2, '0');
      final mm = at.toLocal().minute.toString().padLeft(2, '0');
      await _plugin.show(
        ('missed:$peerId').hashCode & 0x7fffffff,
        n > 1 ? '$n cuộc gọi nhỡ' : 'Cuộc gọi nhỡ',
        n > 1 ? '$who đã gọi bạn $n lần (gần nhất $hh:$mm)' : '$who đã gọi bạn lúc $hh:$mm',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            kMessageChannelId,
            'Tin nhắn',
            channelDescription: 'Tin nhắn mới và cuộc gọi nhỡ',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            sound: RawResourceAndroidNotificationSound('msg_ding'),
            category: AndroidNotificationCategory.message,
            autoCancel: true,
          ),
        ),
        payload: jsonEncode(<String, String>{'kind': 'dm', 'peerId': peerId}), // bấm → mở chat với người gọi để gọi lại
      );
      return true;
    } on Object catch (e) {
      debugPrint('missed call notification: $e');
      return false;
    }
  }

  /// Xóa số đếm khi người dùng đã mở chat/danh bạ với người đó.
  static void clearMissed(String peerId) => _missedCount.remove(peerId);
}
