/// Cấu hình lúc build, đọc từ `--dart-define`. Không có bí mật nào ở đây.
class Env {
  const Env._();

  static const apiBaseUrl =
      String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8080');
  static const wsUrl =
      String.fromEnvironment('WS_URL', defaultValue: 'ws://10.0.2.2:8080/v1/ws');

  /// `firebase` | `dev`
  static const authMode = String.fromEnvironment('AUTH_MODE', defaultValue: 'dev');
  static const termsUrl = String.fromEnvironment('TERMS_URL');
  static const privacyUrl = String.fromEnvironment('PRIVACY_URL');
  static const featureSocial = bool.fromEnvironment('FEATURE_SOCIAL');

  /// `p2p` (WebRTC trực tiếp, mặc định) | `livekit` (qua LiveKit Cloud). Phải khớp CALL_PROVIDER của server.
  static const callMode = String.fromEnvironment('CALL_MODE', defaultValue: 'p2p');

  /// `true`: cho phép relay (LiveKit) khi P2P không nối được. Mặc định TẮT để không tốn băng thông relay.
  static const relay = bool.fromEnvironment('RELAY');

  /// `true` (mặc định): server cấp TURN làm DỰ PHÒNG cho mọi cuộc gọi; ICE thử P2P song song, app giới hạn chất lượng khi phải đi
  /// qua relay và dừng cuộc gọi theo mốc thời gian (xem call_quality.dart, PHAN-TICH-GOI-DIEN-TURN.md). Không có TURN ở server thì không có tác dụng.
  static const turnFallback = bool.fromEnvironment('TURN_FALLBACK', defaultValue: true);

  /// `true`: dùng bộ ghi màn hình thật (plugin cham_recorder). Mặc định tắt vì chưa thử trên máy thật.
  static const nativeRecorder = bool.fromEnvironment('NATIVE_RECORDER');

  /// `false`: không dùng kênh nhắn tin trực tiếp P2P (mọi tin qua hộp thư server).
  static const directDm = bool.fromEnvironment('DIRECT_DM', defaultValue: true);

  /// `true`: hiện đăng nhập bằng email (server phải có EMAIL_PROVIDER).
  /// Mã hóa tin nhắn bằng Double Ratchet (ratchet.dart). Mặc định TẮT cho tới khi thử trên máy thật; luôn GIẢI MÃ được "dr2:".
  static const doubleRatchet = bool.fromEnvironment('DOUBLE_RATCHET');
  /// Cuộc gọi đến toàn màn hình trên Android (xem services/incoming_call_notifier.dart). Cần backend PUSH_CALL_FULLSCREEN=true.
  static const fullscreenCall = bool.fromEnvironment('FULLSCREEN_CALL');
  /// Bong bóng tin nhắn Android (services/chat_bubbles.dart). Cần backend PUSH_CHAT_BUBBLES=true.
  static const chatBubbles = bool.fromEnvironment('CHAT_BUBBLES');
  static const emailAuth = bool.fromEnvironment('EMAIL_AUTH');

  /// Mã commit của bản build (workflow GitHub truyền vào) – hiện ở Cài đặt để biết đang chạy bản nào.
  static const buildId = String.fromEnvironment('BUILD_ID', defaultValue: 'local');

  /// Bộ lọc/phát hiện dò IP trong cuộc gọi P2P (CHONG-QUET-IP-P2P.md). Mặc định bật.
  static const iceGuard = bool.fromEnvironment('ICE_GUARD', defaultValue: true);

  /// Không gửi ứng viên host IPv6 toàn cục (an toàn hơn, có thể làm rớt vài cặp mạng). Mặc định tắt.
  static const iceGuardStrictIpv6 = bool.fromEnvironment('ICE_GUARD_STRICT_IPV6');

  static bool get isDev => authMode == 'dev';
}
