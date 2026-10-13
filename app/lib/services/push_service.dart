import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import 'api_client.dart';
import 'incoming_call_notifier.dart';

/// Thông báo đẩy (ADR-004 §7–9, T-108). Server gửi `call_invite` / `call_missed`; app chỉ cần:
/// 1. xin quyền thông báo, lấy FCM token và đăng ký lên server (`PUT /v1/me/push-token`);
/// 2. khi người dùng bấm thông báo `call_invite` → phát `inviteId` để [InviteController] chờ
///    server phát lại lời mời sau `session.ready`;
/// 3. khi đăng xuất → xóa token khỏi server TRƯỚC khi đăng xuất Firebase.
abstract class PushService {
  /// Xin quyền, đăng ký token, bắt đầu nghe thông báo đã bấm. Idempotent.
  Future<void> start();

  /// `inviteId` của thông báo `call_invite` mà người dùng đã bấm để mở app.
  /// Luồng broadcast: người nghe PHẢI đăng ký trước khi gọi [start].
  Stream<String> get openedInviteIds;

  /// `false` khi người dùng từ chối quyền thông báo (UI hiện `notificationsRationale`).
  ValueListenable<bool> get notificationsEnabled;

  /// `DELETE /v1/me/push-token` với token hiện tại. Không ném. Gọi lại [start] sau đó vẫn được.
  Future<void> unregister();

  Future<void> dispose();
}

/// Bấm thông báo tin nhắn (`dm_new`) → phát `userId` người gửi để app mở màn chat.
/// Tách khỏi [PushService] để không phải sửa các lớp giả trong test.
class PushTaps {
  PushTaps._();
  static final StreamController<String> chat = StreamController<String>.broadcast();
}

/// Dùng khi `AUTH_MODE=dev` hoặc chưa cấu hình Firebase: không làm gì.
class NoopPushService implements PushService {
  final ValueNotifier<bool> _enabled = ValueNotifier<bool>(true);

  @override
  Future<void> start() async {}

  @override
  Stream<String> get openedInviteIds => Stream<String>.empty(broadcast: true);

  @override
  ValueListenable<bool> get notificationsEnabled => _enabled;

  @override
  Future<void> unregister() async {}

  @override
  Future<void> dispose() async => _enabled.dispose();
}

/// Lớp mỏng quanh `firebase_messaging` để [FirebasePushService] test được; mọi lời gọi SDK có
/// rủi ro theo phiên bản nằm gọn ở [FirebaseMessagingPort].
abstract class PushMessagingPort {
  /// `true` nếu được phép hiện thông báo (kể cả "tạm thời" trên iOS).
  Future<bool> requestPermission();

  Future<String?> getToken();

  Stream<String> get onTokenRefresh;

  /// `data` của thông báo mà người dùng bấm khi app đang ở nền.
  Stream<Map<String, String>> get onOpened;

  /// `data` của thông báo đã mở app từ trạng thái tắt hẳn (nếu có).
  Future<Map<String, String>?> getInitialOpened();
}

/// Bản thật.
///
/// CẦN KIỂM TRA THEO PHIÊN BẢN `firebase_messaging` (chưa biên dịch với SDK thật khi viết; theo
/// hiểu biết về 15.x): `FirebaseMessaging.instance`, `requestPermission()` →
/// `NotificationSettings.authorizationStatus` (`AuthorizationStatus.authorized|provisional`),
/// `getToken()`, `onTokenRefresh`, `FirebaseMessaging.onMessageOpenedApp`,
/// `getInitialMessage()`, `RemoteMessage.data`. Tài liệu: https://firebase.flutter.dev/docs/messaging/overview
/// Trên iOS `getToken()` có thể ném lỗi khi chưa có APNs token – đã bọc try/catch, token sẽ đến qua
/// `onTokenRefresh`.
class FirebaseMessagingPort implements PushMessagingPort {
  FirebaseMessagingPort([FirebaseMessaging? messaging])
      : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission();
    final status = settings.authorizationStatus;
    return status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => _messaging.getToken();

  @override
  Stream<String> get onTokenRefresh => _messaging.onTokenRefresh;

  @override
  Stream<Map<String, String>> get onOpened =>
      FirebaseMessaging.onMessageOpenedApp.map((m) => _stringify(m.data));

  @override
  Future<Map<String, String>?> getInitialOpened() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _stringify(message.data);
  }

  static Map<String, String> _stringify(Map<String, dynamic> data) {
    return <String, String>{for (final e in data.entries) e.key: '${e.value}'};
  }
}

class FirebasePushService implements PushService {
  FirebasePushService({
    required ApiClient api,
    PushMessagingPort? port,
    String Function()? platform,
  })  : _api = api,
        _port = port ?? FirebaseMessagingPort(),
        _platform = platform ?? _defaultPlatform;

  final ApiClient _api;
  final PushMessagingPort _port;
  final String Function() _platform;

  final StreamController<String> _opened = StreamController<String>.broadcast();
  final ValueNotifier<bool> _enabled = ValueNotifier<bool>(true);
  final List<StreamSubscription<Object?>> _subs = <StreamSubscription<Object?>>[];

  String? _token;
  bool _started = false;
  bool _disposed = false;

  static String _defaultPlatform() => Platform.isIOS ? 'ios' : 'android';

  @override
  Stream<String> get openedInviteIds => _opened.stream;

  @override
  ValueListenable<bool> get notificationsEnabled => _enabled;

  @override
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;

    try {
      _enabled.value = await _port.requestPermission();
    } on Object catch (e) {
      debugPrint('push: requestPermission failed: $e');
    }

    _subs.add(_port.onTokenRefresh.listen((t) => unawaited(_register(t))));
    _subs.add(_port.onOpened.listen(_onOpenedData));
    // Bấm thông báo toàn màn hình (FULLSCREEN_CALL): cùng đường với thông báo call_invite thường.
    _subs.add(IncomingCallNotifier.taps.stream.listen((id) {
      if (!_opened.isClosed) _opened.add(id);
    }));
    final launched = IncomingCallNotifier.takeLaunchInvite();
    if (launched != null) _opened.add(launched);

    try {
      final initial = await _port.getInitialOpened();
      if (initial != null) _onOpenedData(initial);
    } on Object catch (e) {
      debugPrint('push: getInitialMessage failed: $e');
    }

    final token = await _safeGetToken();
    if (token != null) await _register(token);
  }

  @override
  Future<void> unregister() async {
    final token = _token ?? await _safeGetToken();
    _token = null;
    _started = false;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    if (token == null) return;
    try {
      await _api.deletePushToken(token);
    } on ApiException catch (e) {
      debugPrint('push: deletePushToken failed: ${e.code}');
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    await _opened.close();
    _enabled.dispose();
  }

  Future<String?> _safeGetToken() async {
    try {
      return await _port.getToken();
    } on Object catch (e) {
      debugPrint('push: getToken failed: $e');
      return null;
    }
  }

  Future<void> _register(String token) async {
    if (_disposed) return;
    _token = token;
    try {
      await _api.setPushToken(token, _platform());
    } on ApiException catch (e) {
      // Lần mở app sau (hoặc onTokenRefresh) sẽ đăng ký lại.
      debugPrint('push: setPushToken failed: ${e.code}');
    }
  }

  void _onOpenedData(Map<String, String> data) {
    if (data['kind'] == 'dm_new') {
      final from = data['fromUserId'];
      if (from != null && from.isNotEmpty) PushTaps.chat.add(from);
      return;
    }
    if (data['kind'] != 'call_invite') return;
    final inviteId = data['inviteId'];
    if (inviteId == null || inviteId.isEmpty || _opened.isClosed) return;
    _opened.add(inviteId);
  }
}
