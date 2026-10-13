import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/wallet.dart';
import '../state/wallet_controller.dart';
import '../theme/tokens.dart';

/// Chuỗi dịch của `LedgerEntry.reason`; mã lạ (bản app cũ, server mới) → `pointsReasonOther`.
String ledgerReasonLabel(AppLocalizations l10n, String reason) {
  switch (reason) {
    case 'gift':
      return l10n.pointsReasonGift;
    case 'heart_rx':
      return l10n.pointsReasonHeartRx;
    case 'heart_tx':
      return l10n.pointsReasonHeartTx;
    case 'unlock':
      return l10n.pointsReasonUnlock;
    case 'game_fee':
      return l10n.pointsReasonGameFee;
    case 'game_refund':
      return l10n.pointsReasonGameRefund;
    case 'game_win':
      return l10n.pointsReasonGameWin;
    case 'game_draw':
      return l10n.pointsReasonGameDraw;
    case 'admin_adjust':
      return l10n.pointsReasonAdjust;
    default:
      return l10n.pointsReasonOther;
  }
}

/// Điểm của tôi: số dư, lịch sử (cuộn vô hạn) và mở khóa (T-209). Mở từ Cài đặt.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, this.now});

  /// Đồng hồ để biết mở khóa còn hạn hay không (test).
  final DateTime Function()? now;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  /// Còn chừng này dp nữa tới đáy thì tải trang kế.
  static const double _loadMoreThreshold = 300;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final wallet = context.read<WalletController>();
      unawaited(wallet.refresh());
      unawaited(wallet.loadLedger());
      unawaited(wallet.loadUnlocks());
    });
  }

  Future<void> _buy(String feature) async {
    final l10n = AppLocalizations.of(context);
    final wallet = context.read<WalletController>();
    final messenger = ScaffoldMessenger.of(context);
    final error = await wallet.purchase(feature);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(error == null ? l10n.unlockDone : errorText(l10n, error))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final wallet = context.watch<WalletController>();
    final materialL10n = MaterialLocalizations.of(context);
    final now = (widget.now ?? DateTime.now)();
    final balance = wallet.balance;
    final unlocks = wallet.unlocks;
    final items = <UnlockCatalogItem>[
      if (unlocks != null) ...unlocks.catalog.where((c) => c.feature == _strictLanguage),
    ];
    final ledger = wallet.ledger;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.myPoints, style: AppText.title)),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n.metrics.extentAfter < _loadMoreThreshold && wallet.ledgerHasMore) {
            unawaited(wallet.loadMoreLedger());
          }
          return false;
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpace.xl),
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.xl),
              child: Center(
                child: balance == null
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        l10n.pointsBalance('$balance'),
                        textAlign: TextAlign.center,
                        style: AppText.display.copyWith(color: AppColors.primary),
                      ),
              ),
            ),
            if (items.isNotEmpty) ...[
              _SectionTitle(l10n.unlocksTitle),
              for (final item in items)
                _UnlockCard(
                  item: item,
                  activeUntil: unlocks?.activeUntil(item.feature, now),
                  purchasing: wallet.purchasing == item.feature,
                  onBuy: wallet.purchasing == null ? () => unawaited(_buy(item.feature)) : null,
                  formatDate: (d) => materialL10n.formatShortDate(d.toLocal()),
                ),
            ],
            _SectionTitle(l10n.pointsHistory),
            if (ledger.isEmpty && wallet.ledgerLoaded)
              Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Text(
                  l10n.pointsHistoryEmpty,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ),
            if (ledger.isEmpty && !wallet.ledgerLoaded && wallet.ledgerError != null)
              Padding(
                padding: const EdgeInsets.all(AppSpace.xl),
                child: Column(
                  children: [
                    Text(
                      errorText(l10n, wallet.ledgerError!),
                      textAlign: TextAlign.center,
                      style: AppText.body.copyWith(color: AppColors.textSecondary),
                    ),
                    TextButton(
                      onPressed: () => unawaited(wallet.loadLedger()),
                      child: Text(l10n.retry),
                    ),
                  ],
                ),
              ),
            for (final entry in ledger)
              _LedgerRow(
                label: ledgerReasonLabel(l10n, entry.reason),
                date: materialL10n.formatShortDate(entry.createdAt.toLocal()),
                delta: entry.delta,
              ),
            if (wallet.ledgerLoading)
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
    );
  }

  static const String _strictLanguage = 'strict_language';
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.md, AppSpace.lg, AppSpace.sm),
      child: Text(text, style: AppText.label.copyWith(color: AppColors.textSecondary)),
    );
  }
}

class _UnlockCard extends StatelessWidget {
  const _UnlockCard({
    required this.item,
    required this.activeUntil,
    required this.purchasing,
    required this.onBuy,
    required this.formatDate,
  });

  final UnlockCatalogItem item;
  final DateTime? activeUntil;
  final bool purchasing;
  final VoidCallback? onBuy;
  final String Function(DateTime) formatDate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final until = activeUntil;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.xs),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.unlockStrictLanguage, style: AppText.label),
          const SizedBox(height: AppSpace.xs),
          Text(
            l10n.unlockStrictLanguageBody('${item.durationDays}'),
            style: AppText.caption.copyWith(color: AppColors.textSecondary),
          ),
          if (until != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              l10n.unlockActiveUntil(formatDate(until)),
              style: AppText.caption.copyWith(color: AppColors.primary),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          FilledButton(
            onPressed: onBuy,
            child: purchasing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.unlockBuy('${item.cost}')),
          ),
        ],
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.label, required this.date, required this.delta});

  final String label;
  final String date;
  final int delta;

  @override
  Widget build(BuildContext context) {
    final positive = delta > 0;
    return Container(
      height: AppSize.settingsRow,
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
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
                Text(
                  date,
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            positive ? '+$delta' : '$delta',
            style: AppText.label.copyWith(
              color: positive ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
