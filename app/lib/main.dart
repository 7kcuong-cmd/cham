import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'config/env.dart';
import 'config/firebase_options.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/email_auth.dart';
import 'services/incoming_call_notifier.dart';
import 'services/notification_channels.dart';
import 'services/push_service.dart';
import 'services/native_screen_recorder.dart';
import 'services/biometric_port.dart';
import 'services/secure_vault.dart';
import 'state/session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  AuthService auth;
  if (Env.isDev) {
    // AUTH_MODE=dev: không đụng tới Firebase.
    auth = DevAuthService();
  } else {
    // Thiếu FIREBASE_* → StateError ngay lúc khởi động (lỗi cấu hình của người build).
    await Firebase.initializeApp(options: firebaseOptionsFromEnv());
    auth = FirebaseAuthService();
  }

  final vault = FlutterSecureVault();
  EmailAuthService? emailAuth;
  if (Env.emailAuth) {
    emailAuth = EmailAuthService(inner: auth, baseUrl: Env.apiBaseUrl, vault: vault);
    auth = emailAuth;
  }
  await createNotificationChannels();
  if ((Env.fullscreenCall || Env.chatBubbles) && !Env.isDev) {
    FirebaseMessaging.onBackgroundMessage(chamBackgroundMessage); // phải đăng ký trước runApp
  }
  if (Env.fullscreenCall) await IncomingCallNotifier.init(); // cả bản dev: thông báo cuộc gọi cục bộ không cần Firebase
  final api = ApiClient(baseUrl: Env.apiBaseUrl, auth: auth);
  final session = SessionController(auth: auth, api: api, emailAuth: emailAuth);
  // Thông báo đẩy chỉ khi bản build bật GĐ2+ và dùng Firebase thật (AUTH_MODE=dev: không có FCM).
  final PushService push = (Env.featureSocial && !Env.isDev)
      ? FirebasePushService(api: api)
      : NoopPushService();
  runApp(ChamApp(auth: auth, api: api, session: session, push: push, vault: vault, biometrics: LocalAuthBiometrics(), recorder: Env.nativeRecorder ? NativeScreenRecorder() : null));
}
