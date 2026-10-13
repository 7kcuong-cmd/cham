import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/env.dart';
import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/match_found.dart';
import '../services/call_service.dart';
import '../state/call_extras_controller.dart';
import '../state/recording_controller.dart';
import '../widgets/recording_layer.dart';
import '../widgets/face_mask_overlay.dart';
import '../state/face_mask_controller.dart';
import '../services/face_tracker.dart';
import '../state/contacts_controller.dart';
import '../state/game_controller.dart';
import '../state/swipe_controller.dart';
import '../theme/tokens.dart';
import '../widgets/call_controls.dart';
import '../widgets/comment_input.dart';
import '../widgets/comment_overlay.dart';
import '../widgets/edge_actions.dart';
import '../widgets/flying_hearts.dart';
import '../games/game_picker.dart';
import '../widgets/call_background.dart';
import '../widgets/draggable_self_view.dart';
import '../games/game_session.dart';
import '../games/game_view.dart';
import '../widgets/gift_drop_card.dart';
import '../widgets/safety_sheet.dart';
import '../utils/tr.dart';
import '../state/watch_controller.dart';
import '../widgets/watch_layer.dart';
import '../widgets/beauty_filter.dart';
import '../widgets/face_reshape.dart';
import '../widgets/voice_sheet.dart';
import '../services/voice_changer.dart';
import '../services/beauty.dart';
import '../state/beauty_sync.dart';
import '../widgets/searching_view.dart';

/// Màn hình chính: tìm người, gọi video toàn màn hình, vuốt lên để sang người khác
/// (DESIGN.md S3).
class SwipeScreen extends StatefulWidget {
  const SwipeScreen({super.key, this.showSocial});

  /// Hiện lớp tương tác GĐ2–4 (tim, bình luận, thêm bạn, quà, game). `null` = theo
  /// `Env.featureSocial` (`--dart-define=FEATURE_SOCIAL`); test ép `true`.
  final bool? showSocial;

  @override
  State<SwipeScreen> createState() => _SwipeScreenState();
}

class _SwipeScreenState extends State<SwipeScreen> with SingleTickerProviderStateMixin {
  /// Vuốt chuyển người: 250 ms.
  static const Duration _exitDuration = Duration(milliseconds: 250);
  static const double _minFlingVelocity = 300; // dp/s
  static const double _minDragFraction = 0.25;

  late final AnimationController _exit;
  StreamSubscription<String>? _noticeSub;
  final List<StreamSubscription<Object?>> _socialSubs = <StreamSubscription<Object?>>[];
  final FlyingHeartsController _hearts = FlyingHeartsController();
  static final ChangeNotifier _noMask = ChangeNotifier();
  BeautySync? _beauty;
  FaceMaskController? _mask;
  FaceTracker? _faceTracker;
  String? _beautyRoom;
  double _dragDy = 0;
  bool _exiting = false;

  bool get _social => widget.showSocial ?? Env.featureSocial;

  @override
  void initState() {
    super.initState();
    _exit = AnimationController(vsync: this, duration: _exitDuration);
    _keepScreenOn(true);
    _noticeSub = context.read<SwipeController>().notices.listen(_showNotice);
    if (_social) {
      _beauty = BeautySync(context.read<CallService>());
      _faceTracker = FaceTracker();
      _mask = FaceMaskController(context.read<CallService>(), detect: _faceTracker!.detect)
        ..chinLevel = (() => BeautySettings.instance.chin)
        ..eyesLevel = (() => BeautySettings.instance.eyes);
      BeautySettings.instance.addListener(_syncReshape);
      _syncReshape();
      final extras = context.read<CallExtrasController>();
      _socialSubs
        ..add(extras.notices.listen(_showNotice))
        ..add(extras.incomingHearts.listen((n) => _hearts.burst(n, fromRight: false)))
        ..add(context.read<GameController>().notices.listen(_showNotice))
        ..addAll(<StreamSubscription<String>>[
          if (_watchOrNull(context) case final w?) w.notices.listen(_showWatchNotice),
        ])
        ..add(context.read<ContactsController>().events.listen(_showFriendEvent));
    }
  }

  /// Giữ màn hình sáng khi đang ghép cặp/gọi (tắt màn hình là app bị treo mạng, mất ghép).
  /// Lỗi plugin (ví dụ trong test không có nền tảng) bị bỏ qua: đây chỉ là tiện ích.
  void _keepScreenOn(bool on) {
    unawaited((on ? WakelockPlus.enable() : WakelockPlus.disable()).catchError((Object _) {}));
  }

  @override
  void dispose() {
    // Không tắt wakelock ở đây: app.dart giữ sáng suốt thời gian mở app.
    _noticeSub?.cancel();
    for (final sub in _socialSubs) {
      sub.cancel();
    }
    BeautySettings.instance.removeListener(_syncReshape);
    _beauty?.dispose();
    _mask?.dispose();
    unawaited(_faceTracker?.dispose() ?? Future<void>.value());
    _exit.dispose();
    super.dispose();
  }

  void _showNotice(String code) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (code == 'PEER_ANOMALY') {
      // Cảnh báo bảo mật: hộp thoại rõ ràng thay vì thanh thông báo thoáng qua.
      unawaited(showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.peerAnomalyTitle),
          content: Text(l10n.peerAnomalyBody),
          actions: [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: Text(l10n.peerAnomalyOk))],
        ),
      ));
      return;
    }
    _snack(errorText(l10n, code));
  }

  /// Bộ điều khiển xem chung (không có trong một số bài test dựng màn hình riêng lẻ).
  WatchTogetherController? _watchOrNull(BuildContext context) {
    try {
      return context.read<WatchTogetherController>();
    } on Object {
      return null;
    }
  }

  void _showWatchNotice(String code) {
    if (!mounted) return;
    if (code == 'WATCH_INCOMING') {
      unawaited(HapticFeedback.mediumImpact());
      // Hộp thoại nổi trên cùng: chắc chắn thấy nút đồng ý dù thẻ lời mời trong video bị che.
      final name = context.read<SwipeController>().current?.peer.displayName ?? '';
      unawaited(showWatchInviteDialog(context, name));
      return;
    }
    _snack(watchNoticeText(context, code));
  }

  void _showFriendEvent(FriendEvent e) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final name = e.name ?? '';
    switch (e.kind) {
      case FriendEventKind.pending:
        _snack(l10n.addFriendPending(name));
      case FriendEventKind.requested:
        _snack(l10n.addFriendRequested(name));
      case FriendEventKind.added:
        _snack(l10n.addFriendDone(name));
      case FriendEventKind.error:
        _snack(errorText(l10n, e.errorCode ?? 'INTERNAL'));
      case FriendEventKind.requestReceived:
        _snack(tr(context, '$name muốn kết bạn với bạn.', '$name wants to add you.'));
      case FriendEventKind.contactJoined:
        _snack(tr(context, '$name đã thêm bạn vào danh bạ.', '$name added you to their contacts.'));
    }
  }

  void _snack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// Bật/tắt theo dõi mặt khi có chỉnh nhọn cằm / mắt to.
  void _syncReshape() => _mask?.setReshape(BeautySettings.instance.reshapeActive);

  void _tapHeart() {
    context.read<CallExtrasController>().tapHeart();
    _hearts.burst(1, fromRight: true);
  }

  Future<void> _swipeAway(SwipeController c) async {
    if (_exiting || !c.canSwipe) return;
    _exiting = true;
    try {
      await _exit.forward();
      if (!mounted) return;
      await c.next();
    } finally {
      if (mounted) {
        _exit.value = 0;
      }
      _exiting = false;
    }
  }

  void _onDragEnd(DragEndDetails d, SwipeController c, double height) {
    final velocity = d.primaryVelocity ?? 0;
    final fastUp = velocity < -_minFlingVelocity;
    final farUp = -_dragDy > height * _minDragFraction;
    if (fastUp || farUp) unawaited(_swipeAway(c));
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SwipeController>(
      builder: (context, c, _) {
        switch (c.status) {
          case SwipeStatus.needsPermission:
            return _PermissionView(controller: c);
          case SwipeStatus.inactive:
            // Đã dừng (vd. vừa cúp cuộc gọi danh bạ): không giả vờ "đang tìm", chờ người dùng chủ động bắt đầu lướt.
            if (c.hasStarted) return _IdleView(onStart: () => unawaited(c.activate()));
            return SearchingView(since: c.searchStartedAt);
          case SwipeStatus.searching:
            return SearchingView(since: c.searchStartedAt);
          case SwipeStatus.offline:
            return SearchingView(since: c.searchStartedAt, offline: true);
          case SwipeStatus.blockedPermanently:
            return _BlockedView(code: c.blockedCode);
          case SwipeStatus.weakNetwork:
            return _WeakNetworkView(onRetry: () => unawaited(c.activate()));
          case SwipeStatus.connecting:
          case SwipeStatus.inCall:
            final match = c.current;
            if (match == null) return SearchingView(since: c.searchStartedAt);
            return _buildCall(context, c, match);
        }
      },
    );
  }

  /// Máy này đang ghi hình cuộc gọi (không có [RecordingController] trong cây → false).
  bool _iAmRecording(BuildContext context) {
    try {
      return context.watch<RecordingController>().iAmRecording;
    } on Object {
      return false;
    }
  }

  Widget _buildCall(BuildContext context, SwipeController c, MatchFound match) {
    final l10n = AppLocalizations.of(context);
    final call = context.read<CallService>();
    final padding = MediaQuery.paddingOf(context);
    final height = MediaQuery.sizeOf(context).height;
    final peer = match.peer;
    final inCall = c.status == SwipeStatus.inCall;
    final recording = _social && _iAmRecording(context);
    if (_beautyRoom != match.roomName) {
      _beautyRoom = match.roomName;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _beauty?.reset();
        _mask?.reset();
      });
    }
    final beauty = _beauty;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (d) => _onDragEnd(d, c, height),
      child: ColoredBox(
        color: AppColors.bg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video đối phương (hoặc nền chờ) – trượt lên & mờ dần khi vuốt.
            AnimatedBuilder(
              animation: _exit,
              builder: (context, child) {
                final t = Curves.easeOutCubic.transform(_exit.value);
                return Opacity(
                  opacity: 1 - t,
                  child: Transform.translate(offset: Offset(0, -t * height), child: child),
                );
              },
              child: inCall
                  ? RecordingBlur(
                      child: _social && beauty != null
                          ? WatchStage(
                              remote: () => ValueListenableBuilder<int>(
                                valueListenable: beauty.peerLevel,
                                builder: (_, lvl, __) => Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (_mask != null)
                                      ListenableBuilder(
                                        listenable: _mask!,
                                        builder: (_, __) => BeautyFilter(
                                          level: lvl,
                                          builder: (_) => FaceReshape(
                                            sample: _mask!.peerFace,
                                            chin: _mask!.peerChin,
                                            eyes: _mask!.peerEyes,
                                            child: call.remoteView(),
                                          ),
                                        ),
                                      )
                                    else
                                      BeautyFilter(level: lvl, builder: (_) => call.remoteView()),
                                    if (_mask != null)
                                      ListenableBuilder(
                                        listenable: _mask!,
                                        builder: (_, __) => FaceMaskOverlay(maskId: _mask!.peerMaskId, sample: _mask!.peer),
                                      ),
                                  ],
                                ),
                              ),
                            )
                          : call.remoteView(),
                    )
                  : _ConnectingView(name: peer.displayName, label: l10n.connecting),
            ),
            // Dải scrim phía trên.
            if (!recording)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: AppSize.topScrimHeight + padding.top,
              child: const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.scrim, AppColors.scrimClear],
                    ),
                  ),
                ),
              ),
            ),
            // Hàng trên: tên + chip ngôn ngữ (trái), nút khiên (phải).
            if (!recording)
            Positioned(
              top: padding.top + AppSpace.sm,
              left: AppSpace.lg,
              right: AppSpace.lg,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      peer.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.label,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _LanguageChip(language: peer.language),
                  const Spacer(),
                  CallControls(
                    micOn: c.micOn,
                    camOn: c.camOn,
                    onToggleMic: c.toggleMic,
                    onToggleCamera: c.toggleCamera,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  EdgeButton(
                    icon: Icons.shield_rounded,
                    tooltip: l10n.a11ySafety,
                    onPressed: () => showSafetySheet(
                      context,
                      peer: peer,
                      roomName: match.roomName,
                    ),
                  ),
                ],
              ),
            ),
            // Khung camera của mình 96x128: chạm để đổi camera, kéo để dời trong khung gọi.
            DraggableSelfView(
              initialTop: padding.top + AppSpace.sm + AppSize.minTouch + AppSpace.sm,
              tooltip: l10n.a11ySwitchCamera,
              onTap: c.switchCamera,
              child: ListenableBuilder(
                listenable: BeautySettings.instance,
                builder: (_, __) => Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_mask != null)
                      ListenableBuilder(
                        listenable: _mask!,
                        builder: (_, __) => BeautyFilter(
                          level: BeautySettings.instance.level,
                          builder: (_) => FaceReshape(
                            sample: _mask!.local,
                            chin: BeautySettings.instance.chin,
                            eyes: BeautySettings.instance.eyes,
                            mirror: true,
                            child: call.localView(),
                          ),
                        ),
                      )
                    else
                      BeautyFilter(
                        level: BeautySettings.instance.level,
                        builder: (_) => call.localView(),
                      ),
                    if (_mask != null)
                      ListenableBuilder(
                        listenable: _mask!,
                        builder: (_, __) => FaceMaskOverlay(maskId: _mask!.maskId, sample: _mask!.local, mirror: true),
                      ),
                  ],
                ),
              ),
            ),
            // Lớp tương tác GĐ2–4 (ẩn ở GĐ1): trái tim bay, bình luận, quà, game, nút mép phải.
            // Đang GHI HÌNH (máy người ghi): ẩn mọi nút/thanh để clip chỉ có cửa sổ gọi; chỉ còn logo Chạm.
            if (_social && recording) Positioned.fill(child: RecordingLayer(peerName: peer.displayName)),
            if (_social && !recording) ..._socialLayers(context, match, inCall),
            // Gợi ý vuốt (3 cuộc gọi đầu).
            if (c.showSwipeHint && !recording)
              Positioned(
                left: 0,
                right: 0,
                bottom: AppSpace.xl,
                child: IgnorePointer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.keyboard_arrow_up_rounded,
                        size: 24,
                        color: AppColors.textSecondary,
                      ),
                      Text(
                        c.isContactCall ? l10n.contactSwipeHint : l10n.swipeHint,
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Các lớp tim/bình luận/quà/game xếp trong cùng `Stack` với video. Ván và bình luận chỉ hiện
  /// khi đã thấy hình đối phương ([inCall]); nút mép phải hiện ngay khi vào phòng.
  List<Widget> _socialLayers(BuildContext context, MatchFound match, bool inCall) {
    final padding = MediaQuery.paddingOf(context);
    final hasGame = context.select<GameSessionController, bool>((g) => g.phase == GamePhase.playing);
    final peerName = match.peer.displayName;
    final watch = _watchOrNull(context);
    final canWatch = watch != null; // cả cuộc gọi danh bạ lẫn Lướt
    return [
      Positioned.fill(child: FlyingHearts(controller: _hearts)),
      // Bình luận: cột trái, đáy cách 120 dp (cao hơn bàn cờ khi đang chơi).
      Positioned(
        left: AppSpace.lg,
        bottom: hasGame ? 72 + AppSize.boardSize + 96 : 120,
        child: CommentOverlay(maxHeight: hasGame ? 120 : 240),
      ),
      // Ván cờ: nửa dưới, bên trái (không che mặt đối phương, không đè cột nút bên phải).
      if (hasGame)
        Positioned(
          left: AppSpace.lg,
          bottom: 72,
          child: const SizedBox.shrink(),
        ),
      // Quà rơi: giữa nửa trên.
      const Align(alignment: Alignment(0, -0.35), child: GiftDropCard()),
      // Lời mời chơi: dưới hàng tên, chừa chỗ khung camera của mình.
      Positioned(
        top: padding.top + AppSpace.sm + AppSize.minTouch + AppSpace.xs,
        left: AppSpace.lg,
        right: AppSpace.lg + AppSize.selfViewWidth + AppSpace.sm,
        child: GameStatusBanner(peerName: peerName),
      ),
      if (hasGame)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: MediaQuery.sizeOf(context).height * 0.58,
          child: const GameView(),
        ),
      // Cột nút bên phải: nằm dưới khung camera, cuộn được nếu màn hình thấp.
      Positioned(
        right: AppSpace.lg,
        bottom: 120,
        top: padding.top + AppSpace.sm + AppSize.minTouch + AppSpace.sm + AppSize.selfViewHeight + AppSpace.sm,
        child: Align(
          alignment: Alignment.bottomRight,
          child: SingleChildScrollView(
            reverse: true,
            child: ListenableBuilder(
              listenable: _mask ?? _noMask,
              builder: (_, __) => EdgeActions(
              peer: match.peer,
              onHeart: _tapHeart,
              onComment: () => unawaited(showCommentInput(context)),
              onGame: () => unawaited(showGamePicker(context)),
              onBeauty: () => unawaited(showBeautySheet(context)),
              onVoice: VoiceChanger.instance.supported ? () => unawaited(showVoiceSheet(context)) : null,
              onWatch: canWatch ? () => unawaited(showWatchStartSheet(context)) : null,
              onMask: _mask == null ? null : () => unawaited(showMaskSheet(context, _mask!)),
              maskActive: _mask?.maskId != null,
            ),
            ),
          ),
        ),
      ),
      // Xem/nghe chung (chỉ cuộc gọi danh bạ).
      if (watch != null) WatchLayer(peerName: peerName),
      // Trên cùng: hộp thoại xin ghi hình phải che mọi lớp khác.
      Positioned.fill(child: RecordingLayer(peerName: peerName)),
    ];
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({required this.language});

  final String language;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: AppSpace.xs),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(language.toUpperCase(), style: AppText.caption),
    );
  }
}

class _ConnectingView extends StatelessWidget {
  const _ConnectingView({required this.name, required this.label});

  final String name;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const CallBackdrop(),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, style: AppText.title),
                const SizedBox(height: AppSpace.lg),
                SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, semanticsLabel: label),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.controller});

  final SwipeController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final denied = controller.permanentlyDenied;
    return ColoredBox(
      color: AppColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.videocam_rounded, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpace.lg),
              Text(l10n.permissionTitle, textAlign: TextAlign.center, style: AppText.title),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.permissionBody,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpace.xl),
              FilledButton(
                onPressed: denied ? controller.openSystemSettings : controller.requestPermission,
                child: Text(denied ? l10n.openSettings : l10n.permissionAllow),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dừng tìm người vì mạng yếu liên tiếp: yêu cầu đổi mạng/Wi‑Fi rồi thử lại.
/// Lướt đang tạm dừng (không tìm người): nút "Bắt đầu lướt".
class _IdleView extends StatelessWidget {
  const _IdleView({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.explore_rounded, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpace.md),
              Text(tr(context, 'Lướt đang tạm dừng', 'Swiping is paused'), style: AppText.body),
              const SizedBox(height: AppSpace.sm),
              Text(
                tr(context, 'Chạm để gặp người mới.', 'Tap to meet someone new.'),
                textAlign: TextAlign.center,
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpace.lg),
              FilledButton(onPressed: onStart, child: Text(tr(context, 'Bắt đầu lướt', 'Start swiping'))),
            ],
          ),
        ),
      ),
    );
  }
}

class _WeakNetworkView extends StatelessWidget {
  const _WeakNetworkView({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: AppColors.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpace.lg),
              Text(l10n.swipeWeakTitle, textAlign: TextAlign.center, style: AppText.title),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.swipeWeakBody,
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpace.xl),
              FilledButton(onPressed: onRetry, child: Text(l10n.swipeWeakRetry)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BlockedView extends StatelessWidget {
  const _BlockedView({required this.code});

  final String? code;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ColoredBox(
      color: AppColors.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Text(
            errorText(l10n, code ?? 'SESSION_REPLACED'),
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
