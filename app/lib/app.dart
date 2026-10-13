import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'services/direct_dm.dart';

import 'config/env.dart';
import 'l10n/app_localizations.dart';
import 'screens/birth_year_screen.dart';
import 'screens/interests_screen.dart';
import 'screens/home_shell.dart';
import 'screens/offline_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/underage_screen.dart';
import 'services/api_client.dart';
import 'services/chat_store.dart';
import 'screens/lock_screen.dart';
import 'services/app_lock_service.dart';
import 'services/biometric_port.dart';
import 'services/app_wiper.dart';
import 'services/screen_recorder.dart';
import 'services/secure_vault.dart';
import 'state/app_lock_controller.dart';
import 'state/privacy_settings.dart';
import 'state/recording_controller.dart';
import 'services/auth_service.dart';
import 'services/call_service.dart';
import 'services/hybrid_call_service.dart';
import 'services/permission_gateway.dart';
import 'services/presence_reporter.dart';
import 'screens/chat_screen.dart';
import 'services/chat_bubbles.dart';
import 'services/push_service.dart';
import 'services/remote_config.dart';
import 'services/ws_client.dart';
import 'state/avatar_cache.dart';
import 'state/call_extras_controller.dart';
import 'services/beauty.dart';
import 'services/recording_privacy.dart';
import 'models/ws_messages.dart';
import 'services/incoming_call_notifier.dart';
import 'services/message_notifier.dart';
import 'services/message_sound.dart';
import 'models/chat_message.dart';
import 'services/screen_awake.dart';
import 'state/watch_controller.dart';
import 'watch/watch_runtime.dart';
import 'state/chat_controller.dart';
import 'state/contacts_controller.dart';
import 'games/game_keys.dart';
import 'state/call_background.dart';
import 'games/game_models.dart';
import 'games/game_session.dart';
import 'games/game_store.dart';
import 'state/game_controller.dart';
import 'state/games_list_controller.dart';
import 'state/invite_controller.dart';
import 'state/safety_controller.dart';
import 'state/session_controller.dart';
import 'state/swipe_controller.dart';
import 'state/wallet_controller.dart';
import 'security/shield_controller.dart';
import 'theme/app_theme.dart';
import 'theme/tokens.dart';

/// Gốc ứng dụng: dựng các controller dùng chung và định tuyến theo
/// [SessionStatus] (T-010).
class ChamApp extends StatefulWidget {
  const ChamApp({
    super.key,
    required this.auth,
    required this.api,
    required this.session,
    this.ws,
    this.call,
    this.permissions,
    this.push,
    this.social,
    this.localeOverride,
    this.initSession = true,
    this.chatStore,
    this.recorder,
    this.vault,
    this.biometrics,
  });

  final AuthService auth;
  final ApiClient api;
  final SessionController session;

  /// Tiêm cho test; mặc định là bản thật.
  final WsClient? ws;
  final CallService? call;
  final PermissionGateway? permissions;

  /// Thông báo đẩy; mặc định không làm gì ([NoopPushService]).
  final PushService? push;

  /// Bật GĐ2–4 (danh bạ, tim, quà, game, thông báo đẩy). `null` = theo `Env.featureSocial`.
  final bool? social;

  /// Ép locale (test). `null` = theo `user.language`, chưa có user thì theo máy.
  final Locale? localeOverride;

  /// `false` để test tự điều khiển [SessionController.init].
  final bool initSession;

  /// Kho tin nhắn trên máy; mặc định là tệp trong thư mục dữ liệu của app. Tiêm bản bộ nhớ cho test.
  final ChatStore? chatStore;

  /// Bộ ghi màn hình của hệ điều hành; mặc định chưa hỗ trợ (ẩn tính năng ghi hình).
  final ScreenRecorder? recorder;

  /// Kho bí mật (Keystore/Keychain). Mặc định bộ nhớ tạm (test); `main.dart` truyền bản thật.
  final SecureVault? vault;

  /// Vân tay/khuôn mặt cho khóa ứng dụng; mặc định không có (test).
  final BiometricPort? biometrics;

  @override
  State<ChamApp> createState() => _ChamAppState();
}

class _ChamAppState extends State<ChamApp> {
  late final WsClient _ws;
  late final CallService _call;
  late final SwipeController _swipe;
  late final SafetyController _safety;
  late final PushService _push;
  late final PresenceReporter _presence;
  late final ContactsController _contacts;
  late final InviteController _invites;
  late final CallExtrasController _extras;
  late final WatchTogetherController _watch;
  late final WalletController _wallet;
  late final GameController _game;
  late final GameSessionController _gameSession;
  late final GamesListController _gamesList;
  late final ChatController _chat;
  late final AvatarCache _avatars;
  late final RecordingController _recording;
  late final SecureVault _vault;
  late final ChatStore _store;
  late final AppWiper _wiper;
  late final AppLockController _lock;
  late final RemoteConfigService _remote;
  late final WaitingMusic _music;
  late final WaitingMusic _ring;
  SwipeStatus? _lastSwipeStatus;
  bool _wasReady = false;

  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  StreamSubscription<String>? _chatTapSub;

  final ScreenAwake _awake = ScreenAwake();
  StreamSubscription<ServerMessage>? _bgSub;
  StreamSubscription<ChatMessage>? _chatSoundSub;
  final MessageSound _msgSound = MessageSound();

  bool get _social => widget.social ?? Env.featureSocial;

  @override
  void initState() {
    super.initState();
    // Giữ màn hình sáng suốt thời gian mở ứng dụng.
    _awake.start();
    final session = widget.session;
    final permissions = widget.permissions ?? const SystemPermissionGateway();
    _ws = widget.ws ?? WsClient(url: Env.wsUrl, auth: widget.auth);
    _call = widget.call ??
        (Env.callMode == 'livekit' ? LiveKitCallService() : HybridCallService(
          _ws,
          relay: Env.relay,
          // Có TURN dự phòng: để bộ điều phối chất lượng (10/20/30 s) quyết định; hết hạn của Hybrid chỉ là lưới an toàn.
          p2pTimeout: Env.turnFallback ? const Duration(seconds: 34) : const Duration(seconds: 6),
        ));
    _swipe = SwipeController(
      ws: _ws,
      call: _call,
      permissions: permissions,
      refreshSession: session.refresh,
      autoBlock: (peer) => widget.api.block(peer.id),
    );
    _safety = SafetyController(api: widget.api, swipe: _swipe);

    // GĐ2–4: các controller nghe cùng một WebSocket với SwipeController (xem call_context.dart).
    _push = widget.push ?? NoopPushService();
    _presence = PresenceReporter(_ws);
    _vault = widget.vault ?? MemorySecureVault();
    _store = widget.chatStore ?? SqliteChatStore(vault: _vault);
    _contacts = ContactsController(api: widget.api, ws: _ws, room: _swipe, cache: _store);
    _invites = InviteController(
      ws: _ws,
      permissions: permissions,
      swipe: _swipe,
      openedInviteIds: _push.openedInviteIds,
    );
    _extras = CallExtrasController(ws: _ws, room: _swipe, call: _call);
    _watch = WatchTogetherController(
      call: _call,
      room: _swipe,
      runtime: const DeviceWatchRuntime(),
      relayOnly: () => PrivacySettings.instance.relayOnly,
    );
    _recording = RecordingController(call: _call, room: _swipe, recorder: widget.recorder ?? const UnsupportedScreenRecorder());
    _wallet = WalletController(api: widget.api, ws: _ws);
    _game = GameController(
      api: widget.api,
      ws: _ws,
      room: _swipe,
      selfId: () => session.user?.id,
    );
    _gamesList = GamesListController(api: widget.api);
    _wiper = AppWiper(
      vault: _vault,
      store: _store,
      extra: () async => _chat.reset(),
      signOut: () => widget.session.signOut(),
    );
    _lock = AppLockController(
      service: AppLockService(vault: _vault, onWipe: _wiper.wipe),
      biometrics: widget.biometrics,
    );
    unawaited(_lock.init());
    unawaited(PrivacySettings.instance.load());
    unawaited(CallBackgroundSettings.instance.load());
    unawaited(ShieldController.instance.load());
    unawaited(BeautySettings.instance.load());
    unawaited(RecordingPrivacy.instance.load());
    _chat = ChatController(
      api: widget.api,
      ws: _ws,
      store: _store,
      // Nhắn tin trực tiếp P2P khi hai bên cùng online; tắt khi bật "chế độ riêng tư" (để không lộ IP cho bạn bè).
      filesDir: kIsWeb ? null : getApplicationDocumentsDirectory,
      directFactory: kIsWeb || !Env.directDm
          ? null
          : (onMessage, onControl) => DirectDm(
                ws: _ws,
                myId: () => widget.session.user?.id,
                enabled: () => !PrivacySettings.instance.relayOnly,
                onMessage: onMessage,
                onControl: onControl,
              ),
    );
    _avatars = AvatarCache(api: widget.api);
    _remote = RemoteConfigService(api: widget.api);
    _gameSession = GameSessionController(
      call: _call,
      store: GameStore(
        rootDir: () async {
          final base = await getApplicationSupportDirectory();
          return Directory('${base.path}/games');
        },
        publicKey: kGamePublicKeyB64.isEmpty ? const <int>[] : base64.decode(kGamePublicKeyB64),
      ),
      catalog: () => GameCatalogEntry.parseAll(_remote.games),
    );
    _music = WaitingMusic(_remote);
    _ring = WaitingMusic(_remote, ringing: true);
    _swipe.addListener(_onSwipeChanged);
    _invites.addListener(_syncSound);
    _bgSub = _ws.messages.listen(_onWsWhileBackground);
    unawaited(MessageNotifier.init()); // xin quyền thông báo ngay lần đầu mở app
    // Tin mới khi đang mở app mà không ở màn trò chuyện đó: phát âm báo (nền thì thông báo hệ thống lo).
    _chatSoundSub = _chat.changes.listen((m) {
      if (m.mine || m.status != ChatStatus.received || _chat.isOpen(m.peerId)) return;
      final life = WidgetsBinding.instance.lifecycleState;
      if (life == null || life == AppLifecycleState.resumed) unawaited(_msgSound.play());
    });

    // WS đóng 4404 (chưa có hồ sơ) → tạo phiên rồi kết nối lại.
    _ws.onNeedsSessionRefresh = session.refresh;
    // Đăng xuất từ bất kỳ màn nào: rời hàng chờ/cuộc gọi, đóng WS.
    session.beforeSignOut = () async {
      // Xóa push token khỏi server TRƯỚC khi đăng xuất Firebase (ADR-004 §9).
      if (_social) await _push.unregister();
      await _swipe.deactivate();
      _swipe.reset();
      await _ws.close();
      _wallet.reset();
      _contacts.reset();
      _gamesList.reset();
      try {
        await _chat.reset(); // xóa lịch sử và khóa chat trên máy khi đăng xuất
      } on Object {
        // kho chưa sẵn sàng
      }
    };
    session.addListener(_onSessionChanged);
    if (widget.initSession) unawaited(session.init());
    _onSessionChanged();
  }

  /// Dự phòng không cần FCM: app ở nền nhưng tiến trình còn sống (WS còn nối) thì tự hiện cuộc gọi đến toàn màn hình
  /// (đánh thức màn hình) và bong bóng tin nhắn. Khi app bị hệ thống tắt hẳn thì CHỈ có FCM mới đánh thức được.
  void _onWsWhileBackground(ServerMessage m) {
    // Cuộc gọi nhỡ (mọi trạng thái app): hiện thông báo rồi xác nhận để server xóa khỏi hộp thư. Nếu chưa hiện được thì
    // không xác nhận → server gửi lại lần đăng nhập sau (giống hộp thư tin nhắn).
    if (m is CallMissed) {
      final hit = _contacts.contacts.where((c) => c.id == m.fromUserId);
      final name = m.name.isNotEmpty ? m.name : (hit.isEmpty ? '' : hit.first.displayName);
      unawaited(MessageNotifier.showMissedCall(peerId: m.fromUserId, name: name, at: m.at).then((ok) {
        if (ok) _ws.send('call.missed.ack', <String, dynamic>{'inviteIds': <String>[m.inviteId]});
      }));
      return;
    }
    final life = WidgetsBinding.instance.lifecycleState;
    if (life == null || life == AppLifecycleState.resumed) return;
    if (m is DmReceived) {
      // Tin nhắn mới khi app ở nền: luôn hiện thông báo (kể cả bản dev, không cần Firebase).
      final hit = _contacts.contacts.where((c) => c.id == m.fromUserId);
      final name = hit.isEmpty ? '' : hit.first.displayName;
      if (Env.chatBubbles && !Env.isDev) {
        unawaited(ChatBubbles.show(peerId: m.fromUserId, name: name, text: ''));
      } else {
        unawaited(MessageNotifier.showMessage(peerId: m.fromUserId, name: name));
      }
      return;
    }
    switch (m) {
      case CallInviteIncoming(:final invite):
        if (Env.fullscreenCall) {
          unawaited(IncomingCallNotifier.showLocal(inviteId: invite.inviteId, name: invite.from.displayName));
        }
      default:
        break;
    }
  }

  /// Âm thanh: chuông khi có cuộc gọi đến; nhạc chờ khi đang tìm người hoặc đang chờ bạn nghe máy; còn lại im.
  void _onSwipeChanged() {
    final st = _swipe.status;
    if (st == _lastSwipeStatus) return;
    _lastSwipeStatus = st;
    _syncSound();
  }

  void _syncSound() {
    final inv = _invites.status;
    final wantRing = inv == InviteStatus.incoming;
    final wantWait = !wantRing && (inv == InviteStatus.outgoing || _swipe.status == SwipeStatus.searching);
    if (wantRing) {
      unawaited(_ring.start());
    } else {
      unawaited(_ring.stop());
    }
    if (wantWait) {
      unawaited(_music.start());
    } else {
      unawaited(_music.stop());
    }
  }

  /// Vừa vào trạng thái `ready` (đã có hồ sơ): kết nối WS ngay để nhận lời mời gọi dù không ở
  /// tab Lướt, xin quyền thông báo, tải số dư và danh bạ.
  void _onSessionChanged() {
    final ready = widget.session.status == SessionStatus.ready;
    if (!ready) {
      _wasReady = false;
      return;
    }
    if (_wasReady) return;
    _wasReady = true;
    if (!_social) return;
    unawaited(_ws.connect());
    unawaited(_push.start());
    unawaited(_wallet.refresh());
    unawaited(_contacts.load());
    unawaited(_remote.refresh());
    _chatTapSub ??= PushTaps.chat.stream.listen(_openChatFromPush);
    if (Env.chatBubbles) unawaited(ChatBubbles.start()); // sau khi đã có người nghe PushTaps.chat
  }

  /// Bấm thông báo tin nhắn: mở màn chat với người gửi (tên lấy từ danh bạ nếu đã tải).
  void _openChatFromPush(String userId) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    var name = '';
    for (final c in _contacts.contacts) {
      if (c.id == userId) name = c.displayName;
    }
    unawaited(nav.push(MaterialPageRoute<void>(
      builder: (_) => ChangeNotifierProvider<ChatController>.value(
        value: _chat,
        child: ChatScreen(peerId: userId, peerName: name),
      ),
    )));
  }

  @override
  void dispose() {
    unawaited(_awake.stop());
    widget.session.removeListener(_onSessionChanged);
    widget.session.beforeSignOut = null;
    _game.dispose();
    _gameSession.dispose();
    _swipe.removeListener(_onSwipeChanged);
    unawaited(_bgSub?.cancel());
    unawaited(_chatSoundSub?.cancel());
    unawaited(_msgSound.dispose());
    unawaited(_music.dispose());
    unawaited(_ring.dispose());
    _remote.dispose();
    _chat.dispose();
    _recording.dispose();
    _lock.dispose();
    _avatars.dispose();
    _gamesList.dispose();
    _wallet.dispose();
    _extras.dispose();
    _watch.dispose();
    _invites.dispose();
    _contacts.dispose();
    unawaited(_presence.dispose());
    unawaited(_chatTapSub?.cancel());
    unawaited(_push.dispose());
    _swipe.dispose();
    unawaited(_ws.dispose());
    unawaited(_call.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: widget.session),
        ChangeNotifierProvider<SwipeController>.value(value: _swipe),
        Provider<SafetyController>.value(value: _safety),
        Provider<ApiClient>.value(value: widget.api),
        Provider<CallService>.value(value: _call),
        ChangeNotifierProvider<ContactsController>.value(value: _contacts),
        ChangeNotifierProvider<RecordingController>.value(value: _recording),
        Provider<ChatStore>.value(value: _store),
        ChangeNotifierProvider<AppLockController>.value(value: _lock),
        ChangeNotifierProvider<PrivacySettings>.value(value: PrivacySettings.instance),
        ChangeNotifierProvider<InviteController>.value(value: _invites),
        ChangeNotifierProvider<CallExtrasController>.value(value: _extras),
        ChangeNotifierProvider<WatchTogetherController>.value(value: _watch),
        ChangeNotifierProvider<WalletController>.value(value: _wallet),
        ChangeNotifierProvider<GameController>.value(value: _game),
        ChangeNotifierProvider<GameSessionController>.value(value: _gameSession),
        ChangeNotifierProvider<GamesListController>.value(value: _gamesList),
        ChangeNotifierProvider<ChatController>.value(value: _chat),
        ChangeNotifierProvider<AvatarCache>.value(value: _avatars),
        ChangeNotifierProvider<RemoteConfigService>.value(value: _remote),
        Provider<PresenceReporter>.value(value: _presence),
        Provider<PushService>.value(value: _push),
      ],
      child: Consumer<SessionController>(
        builder: (context, session, _) {
          return MaterialApp(
            navigatorKey: _navKey,
            builder: (context, child) => Stack(children: [
              child ?? const SizedBox.shrink(),
              Consumer<AppLockController>(
                builder: (_, lock, __) => lock.locked ? const Positioned.fill(child: LockScreen()) : const SizedBox.shrink(),
              ),
            ]),
            debugShowCheckedModeBanner: false,
            onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
            theme: buildTheme(),
            darkTheme: buildTheme(),
            themeMode: ThemeMode.dark,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            locale: widget.localeOverride ?? session.locale,
            // Ngôn ngữ máy không phải vi/en → en (T-009).
            localeResolutionCallback: (locale, supported) {
              if (locale != null) {
                for (final s in supported) {
                  if (s.languageCode == locale.languageCode) return s;
                }
              }
              return const Locale('en');
            },
            home: _routeFor(session),
          );
        },
      ),
    );
  }

  Widget _routeFor(SessionController session) {
    switch (session.status) {
      case SessionStatus.loading:
        return const _LoadingScreen();
      case SessionStatus.signedOut:
        return const SignInScreen();
      case SessionStatus.offline:
        return const OfflineScreen();
      case SessionStatus.needsBirthYear:
        return const BirthYearScreen();
      case SessionStatus.underage:
        return const UnderageScreen();
      case SessionStatus.banned:
        return const UnderageScreen(banned: true);
      case SessionStatus.ready:
        if (session.askInterests) return const InterestsScreen();
        return HomeShell(showSocial: _social);
    }
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
