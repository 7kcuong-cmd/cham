import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/game_controller.dart';
import '../theme/tokens.dart';

/// Chuỗi dịch của một kết quả ván.
String gameResultText(AppLocalizations l10n, GameResultKind kind) {
  switch (kind) {
    case GameResultKind.win:
      return l10n.gameWin;
    case GameResultKind.lose:
      return l10n.gameLose;
    case GameResultKind.draw:
      return l10n.gameDraw;
    case GameResultKind.timeoutWin:
      return l10n.gameTimeoutWin;
    case GameResultKind.timeoutLose:
      return l10n.gameTimeoutLose;
    case GameResultKind.abandoned:
      return l10n.gameAbandoned;
    case GameResultKind.declined:
      return l10n.gameDeclined;
  }
}

/// Banner kết quả giữa màn hình, 2,5 s (controller tự ẩn); chạm để đóng sớm (T-306).
class GameResultBanner extends StatelessWidget {
  const GameResultBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final game = context.watch<GameController>();
    final kind = game.resultKind;
    final end = game.lastEnd;
    if (kind == null || end == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: game.dismissResult,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl, vertical: AppSpace.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.primary),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(gameResultText(l10n, kind), textAlign: TextAlign.center, style: AppText.title),
            if (end.reward > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.xs),
                child: Text(
                  l10n.gameReward('${end.reward}'),
                  style: AppText.label.copyWith(color: AppColors.primary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
