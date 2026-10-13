import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/match_found.dart';
import '../state/call_extras_controller.dart';
import '../services/beauty.dart';
import '../services/voice_changer.dart';
import '../games/game_session.dart';
import '../utils/tr.dart';
import '../theme/tokens.dart';
import 'add_friend_button.dart';
import 'heart_button.dart';
import '../state/recording_controller.dart';
import 'recording_layer.dart' show RecordingLayer;

/// Nút tròn ở mép màn hình: vòng tròn 44 nền `scrim`, biểu tượng 24, vùng chạm 48
/// (DESIGN.md §2.3).
class EdgeButton extends StatelessWidget {
  const EdgeButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.iconColor = AppColors.textPrimary,
    this.active = false,
  });

  /// Đang bật (làm đẹp, mặt lạ...): viền màu nhấn.
  final bool active;
  final IconData icon;
  final VoidCallback? onPressed;

  /// Chuỗi dịch (khóa `a11y*`) – dùng cho tooltip và trình đọc màn hình.
  final String? tooltip;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: AppSize.minTouch,
      height: AppSize.minTouch,
      child: InkResponse(
        onTap: onPressed,
        radius: AppSize.minTouch / 2,
        child: Center(
          child: Container(
            width: AppSize.edgeButton,
            height: AppSize.edgeButton,
            decoration: BoxDecoration(
              color: AppColors.scrim,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? AppColors.primary : Colors.white.withValues(alpha: 0.18),
                width: active ? 1.5 : 1,
              ),
            ),
            child: Icon(icon, size: 24, color: active ? AppColors.primary : iconColor),
          ),
        ),
      ),
    );
    final label = tooltip;
    if (label == null) return button;
    return Tooltip(message: label, child: button);
  }
}

/// Cột nút ở mép phải màn hình cuộc gọi: tim, bình luận, thêm bạn, trò chơi
/// (DESIGN.md §2.3). Chỉ dựng khi bản build bật `FEATURE_SOCIAL`.
class EdgeActions extends StatelessWidget {
  const EdgeActions({
    super.key,
    required this.peer,
    required this.onHeart,
    required this.onComment,
    required this.onGame,
    this.onBeauty,
    this.onVoice,
    this.onWatch,
    this.onMask,
    this.maskActive = false,
  });

  /// Đối phương trong cuộc gọi (cho nút Thêm bạn).
  final Peer peer;

  /// Mỗi lần chạm tim (UI chạy hiệu ứng bay; gộp chạm do `CallExtrasController`).
  final VoidCallback onHeart;
  final VoidCallback onComment;

  /// Mời chơi game.
  final VoidCallback onGame;

  /// Mở bảng làm đẹp (null = ẩn nút).
  final VoidCallback? onBeauty;

  /// Mở bảng đổi giọng (null = ẩn nút; chỉ Android).
  final VoidCallback? onVoice;

  /// Mở xem video / nghe nhạc chung (null = ẩn nút; chỉ truyền khi gọi danh bạ và chưa có phiên).
  final VoidCallback? onWatch;

  /// Mở bảng mặt lạ (null = ẩn nút).
  final VoidCallback? onMask;

  /// Đang bật một mặt nạ (nút sáng viền).
  final bool maskActive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final canInvite = context.select<GameSessionController, bool>((g) => !g.busy);
    final delta = context.select<CallExtrasController, int?>((c) => c.recentDelta);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (delta != null)
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.xs),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.sm,
                    vertical: AppSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.scrim,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    l10n.pointsDeltaChip('$delta'),
                    style: AppText.caption.copyWith(color: AppColors.primary),
                  ),
                ),
              ),
            HeartButton(tooltip: l10n.a11yHeart, onPressed: onHeart),
          ],
        ),
        // Ghi hình và bình luận đã chuyển vào nút "...".
        if (onMask != null) ...[
          const SizedBox(height: AppSpace.sm),
          EdgeButton(
            icon: Icons.face_retouching_natural_rounded,
            tooltip: tr(context, 'Mặt lạ', 'Face masks'),
            active: maskActive,
            onPressed: onMask,
          ),
        ],
        const SizedBox(height: AppSpace.sm),
        AddFriendButton(peer: peer),
        const SizedBox(height: AppSpace.sm),
        EdgeButton(
          icon: Icons.sports_esports_rounded,
          tooltip: l10n.a11yGame,
          onPressed: canInvite ? onGame : null,
        ),
        ...[
          const SizedBox(height: AppSpace.sm),
          ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[BeautySettings.instance, VoiceChanger.instance]),
            builder: (context, _) => EdgeButton(
              icon: Icons.more_horiz_rounded,
              tooltip: tr(context, 'Thêm', 'More'),
              active: BeautySettings.instance.level > 0 || VoiceChanger.instance.preset != VoicePreset.off,
              onPressed: () => _openMore(context),
            ),
          ),
        ],
      ],
    );
  }

  /// Gom các nút ít dùng (làm đẹp, đổi giọng, xem/nghe chung) vào một bảng.
  Future<void> _openMore(BuildContext context) async {
    RecordingController? rec;
    try {
      rec = context.read<RecordingController>();
    } on Object {
      rec = null;
    }
    final canRecord = rec != null && rec.canRequest;
    final pick = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surfaceHigh,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canRecord)
              ListTile(
                leading: const Icon(Icons.fiber_manual_record_rounded, color: AppColors.danger),
                title: Text(tr(ctx, 'Ghi hình', 'Record')),
                onTap: () => Navigator.of(ctx).pop('record'),
              ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_rounded),
              title: Text(tr(ctx, 'Bình luận', 'Comment')),
              onTap: () => Navigator.of(ctx).pop('comment'),
            ),
            if (onBeauty != null)
              ListTile(
                leading: const Icon(Icons.auto_awesome_rounded),
                title: Text(tr(ctx, 'Làm đẹp', 'Beauty')),
                onTap: () => Navigator.of(ctx).pop('beauty'),
              ),
            if (onVoice != null)
              ListTile(
                leading: const Icon(Icons.record_voice_over_rounded),
                title: Text(tr(ctx, 'Đổi giọng', 'Voice changer')),
                onTap: () => Navigator.of(ctx).pop('voice'),
              ),
            if (onWatch != null)
              ListTile(
                leading: const Icon(Icons.movie_filter_rounded),
                title: Text(tr(ctx, 'Xem video / nghe nhạc cùng nhau', 'Watch or listen together')),
                onTap: () => Navigator.of(ctx).pop('watch'),
              ),
          ],
        ),
      ),
    );
    switch (pick) {
      case 'record':
        if (context.mounted && rec != null) RecordingLayer.choose(context, rec);
      case 'comment':
        onComment();
      case 'beauty':
        onBeauty?.call();
      case 'voice':
        onVoice?.call();
      case 'watch':
        onWatch?.call();
    }
  }
}
