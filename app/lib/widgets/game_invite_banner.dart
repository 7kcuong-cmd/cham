import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/game_controller.dart';
import '../theme/tokens.dart';

/// Banner mời chơi ở trên cùng màn hình cuộc gọi (T-306): nền `surface`, nút Chơi / Không.
/// Tự ẩn khi hết hạn (controller gỡ lời mời) hoặc khi ván bắt đầu.
class GameInviteBanner extends StatelessWidget {
  const GameInviteBanner({super.key, required this.opponentName});

  /// Tên đối phương trong cuộc gọi.
  final String opponentName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final game = context.watch<GameController>();
    final invite = game.incomingInvite;
    if (invite == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.gameInviteFrom(opponentName), style: AppText.label),
          if (invite.entryFee > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(
                l10n.gameEntryFee('${invite.entryFee}'),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: AppSpace.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: game.awaiting ? null : game.decline,
                child: Text(l10n.gameDecline),
              ),
              const SizedBox(width: AppSpace.sm),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                ),
                onPressed: game.awaiting ? null : game.accept,
                child: Text(l10n.gameAccept),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
