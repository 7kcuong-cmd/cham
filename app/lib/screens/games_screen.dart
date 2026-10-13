import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/game_state.dart';
import '../state/games_list_controller.dart';
import '../theme/tokens.dart';

/// Chuỗi dịch của `GameHistoryItem.outcome`; mã lạ → `gameOutcomeNone`.
String gameOutcomeLabel(AppLocalizations l10n, String outcome) {
  switch (outcome) {
    case GameHistoryItem.outcomeWin:
      return l10n.gameOutcomeWin;
    case GameHistoryItem.outcomeLoss:
      return l10n.gameOutcomeLoss;
    case GameHistoryItem.outcomeDraw:
      return l10n.gameOutcomeDraw;
    default:
      return l10n.gameOutcomeNone;
  }
}

/// Tab Trò chơi: danh sách game, ghi chú cách chơi và lịch sử (T-306).
class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key, this.autoLoad = true});

  /// Tải khi dựng màn hình (khung chính còn tải lại mỗi lần vào tab).
  final bool autoLoad;

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  static const double _loadMoreThreshold = 300;

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(context.read<GamesListController>().load());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final games = context.watch<GamesListController>();
    final materialL10n = MaterialLocalizations.of(context);
    final history = games.history;
    final catalog = games.games.where((g) => g.type == 'tictactoe').toList();

    return SafeArea(
      bottom: false,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < _loadMoreThreshold && games.historyHasMore) {
            unawaited(games.loadMoreHistory());
          }
          return false;
        },
        child: RefreshIndicator(
          color: AppColors.primary,
          backgroundColor: AppColors.surfaceHigh,
          onRefresh: games.load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.xl),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.md),
                child: Text(l10n.tabGames, style: AppText.title),
              ),
              for (final game in catalog) _GameCard(item: game),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppSpace.lg,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.sports_esports_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        l10n.gamePlayInCallHint,
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.md,
                  AppSpace.lg,
                  AppSpace.sm,
                ),
                child: Text(
                  l10n.gameHistory,
                  style: AppText.label.copyWith(color: AppColors.textSecondary),
                ),
              ),
              if (history.isEmpty && games.historyLoaded)
                Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Text(
                    l10n.gameHistoryEmpty,
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: AppColors.textSecondary),
                  ),
                ),
              if (history.isEmpty && !games.historyLoaded && games.historyError != null)
                Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Column(
                    children: [
                      Text(
                        errorText(l10n, games.historyError!),
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(color: AppColors.textSecondary),
                      ),
                      TextButton(
                        onPressed: () => unawaited(games.load()),
                        child: Text(l10n.retry),
                      ),
                    ],
                  ),
                ),
              for (final item in history)
                _HistoryRow(
                  item: item,
                  outcome: gameOutcomeLabel(l10n, item.outcome),
                  date: materialL10n.formatShortDate(item.endedAt.toLocal()),
                ),
              if (games.historyLoading)
                const Padding(
                  padding: EdgeInsets.all(AppSpace.lg),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.item});

  final GameCatalogItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          const Icon(Icons.grid_3x3_rounded, size: 32, color: AppColors.primary),
          const SizedBox(width: AppSpace.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.gameTicTacToe, style: AppText.label),
                const SizedBox(height: AppSpace.xs),
                Text(
                  l10n.gameReward('${item.winPoints}'),
                  style: AppText.caption.copyWith(color: AppColors.primary),
                ),
                if (item.entryFee > 0)
                  Text(
                    l10n.gameEntryFee('${item.entryFee}'),
                    style: AppText.caption.copyWith(color: AppColors.textSecondary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.item, required this.outcome, required this.date});

  final GameHistoryItem item;
  final String outcome;
  final String date;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final won = item.outcome == GameHistoryItem.outcomeWin;
    return Container(
      height: AppSize.contactRow,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.opponentName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label,
                ),
                Text(
                  date,
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                outcome,
                style: AppText.label.copyWith(
                  color: won ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
              if (item.reward > 0)
                Text(
                  l10n.gameReward('${item.reward}'),
                  style: AppText.caption.copyWith(color: AppColors.primary),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
