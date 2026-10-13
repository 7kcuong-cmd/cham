import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'chat_bubbles.dart';
import 'notification_channels.dart' show kCallChannelId;

/// Cuộc gọi đến TOÀN MÀN HÌNH trên Android khi app ở nền / bị tắt / màn hình khóa (build với FULLSCREEN_CALL=true,
/// backend đặt PUSH_CALL_FULLSCREEN=true). Server gửi `call_invite` dạng data-only; hàm [chamBackgroundMessage] chạy ở
/// isolate nền và hiện thông báo `fullScreenIntent` (category call). Bấm / mở từ thông báo → phát `inviteId` để
/// [InviteController] nhận lời mời, rồi `IncomingCallSheet` hiện như bình thường.
/// iOS không làm được nếu không có CallKit + PushKit (cần tài khoản Apple trả phí); iOS vẫn nhận thông báo thường.
/// CHƯA THỬ TRÊN MÁY THẬT. Android 14+: người dùng có thể phải cấp "Thông báo toàn màn hình" trong Cài đặt.
const int _callNotificationId = 7001;
const String _callChannelId = kCallChannelId;

@pragma('vm:entry-point')
Future<void> chamBackgroundMessage(RemoteMessage message) async {
  final d = message.data;
  if (d['kind'] == 'dm_new' && (d['fromUserId'] ?? '').isNotEmpty) {
    // Tin nhắn mới khi app ở nền: thông báo hội thoại có bong bóng (nội dung được mã hóa nên chỉ hiện tên người gửi).
    await ChatBubbles.show(peerId: d['fromUserId']!, name: d['name'] ?? '', text: d['body'] ?? '');
    return;
  }
  if (d['kind'] != 'call_invite' || (d['inviteId'] ?? '').isEmpty) return;
  await IncomingCallNotifier._show(
    inviteId: d['inviteId']!,
    title: d['title'] ?? 'Cuộc gọi đến',
    body: d['body'] ?? '',
  );
}

/// Phát `inviteId` khi người dùng bấm thông báo cuộc gọi (đăng ký trước khi `FirebasePushService.start`).
class IncomingCallNotifier {
  IncomingCallNotifier._();

  static final StreamController<String> taps = StreamController<String>.broadcast();
  static String? _launchInvite;

  /// `inviteId` của thông báo đã mở app từ trạng thái tắt (dùng một lần).
  static String? takeLaunchInvite() {
    final v = _launchInvite;
    _launchInvite = null;
    return v;
  }

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static String? _inviteOf(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final j = jsonDecode(payload);
      final id = j is Map ? j['inviteId'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } on Object {
      return null;
    }
  }

  /// Gọi một lần khi khởi động app (isolate chính).
  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) {
          final id = _inviteOf(r.payload);
          if (id != null) taps.add(id);
        },
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        _launchInvite = _inviteOf(launch?.notificationResponse?.payload);
      }
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.requestFullScreenIntentPermission();
    } on Object catch (e) {
      debugPrint('incoming call init: $e');
    }
  }

  /// Gỡ thông báo cuộc gọi (đã trả lời / hết hạn).
  static Future<void> cancel() async {
    try {
      await _plugin.cancel(_callNotificationId);
    } on Object {
      // bỏ qua
    }
  }

  /// Hiện thông báo cuộc gọi đến toàn màn hình từ chính app (khi app ở nền nhưng WS còn sống, không cần FCM).
  static Future<void> showLocal({required String inviteId, required String name}) =>
      _show(inviteId: inviteId, title: '$name đang gọi', body: 'Chạm để trả lời');

  static Future<void> _show({required String inviteId, required String title, required String body}) async {
    try {
      await _plugin.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _callChannelId,
        'Cuộc gọi',
        description: 'Có người gọi cho bạn',
        importance: Importance.max,
        playSound: true,
        sound: RawResourceAndroidNotificationSound('ring_chuong'),
        enableVibration: true,
      ));
      await _plugin.show(
        _callNotificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _callChannelId,
            'Cuộc gọi',
            channelDescription: 'Có người gọi cho bạn',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.call,
            fullScreenIntent: true,
            visibility: NotificationVisibility.public,
            playSound: true,
            sound: const RawResourceAndroidNotificationSound('ring_chuong'),
            audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
            additionalFlags: Int32List.fromList(<int>[4]), // FLAG_INSISTENT: lặp chuông tới khi trả lời / hết hạn
            ongoing: true,
            autoCancel: true,
            timeoutAfter: 30000, // khớp thời hạn lời mời trên server (xem INVITE_TTL)
            ticker: title,
          ),
        ),
        payload: jsonEncode(<String, String>{'kind': 'call_invite', 'inviteId': inviteId}),
      );
    } on Object catch (e) {
      debugPrint('incoming call show: $e');
    }
  }
}
