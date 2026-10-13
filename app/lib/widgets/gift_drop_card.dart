import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/call_extras.dart';
import '../state/call_extras_controller.dart';
import '../theme/tokens.dart';
import '../utils/countdown.dart';

/// Thẻ quà rơi 160x96 ở giữa nửa trên màn hình cuộc gọi (T-209). Hiện quà cũ nhất đang chờ;
/// sau khi nhận hiện `+{points} điểm` 1,5 s. Hết hạn thì tự ẩn (controller gỡ quà khỏi danh sách).
class GiftDropCard extends StatelessWidget {
  const GiftDropCard({super.key, this.now});

  /// Đồng hồ (test).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final extras = context.watch<CallExtrasController>();
    final claimed = extras.claimedGift;
    if (claimed != null) {
      return _CardFrame(
        child: Center(
          child: Text(
            l10n.giftClaimed('${claimed.points}'),
            textAlign: TextAlign.center,
            style: AppText.title.copyWith(color: AppColors.primary),
          ),
        ),
      );
    }
    final gift = extras.currentGift;
    if (gift == null) return const SizedBox.shrink();
    return _GiftCard(
      key: ValueKey<String>(gift.giftId),
      gift: gift,
      claiming: extras.claimingGiftId == gift.giftId,
      onClaim: () => extras.claimGift(gift.giftId),
      now: now ?? DateTime.now,
    );
  }
}

class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: AppSize.giftCardWidth,
      height: AppSize.giftCardHeight,
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.primary),
      ),
      child: child,
    );
  }
}

class _GiftCard extends StatefulWidget {
  const _GiftCard({
    super.key,
    required this.gift,
    required this.claiming,
    required this.onClaim,
    required this.now,
  });

  final GiftOffer gift;
  final bool claiming;
  final VoidCallback onClaim;
  final DateTime Function() now;

  @override
  State<_GiftCard> createState() => _GiftCardState();
}

class _GiftCardState extends State<_GiftCard> with SingleTickerProviderStateMixin {
  AnimationController? _bar;

  @override
  void initState() {
    super.initState();
    // Thanh đếm ngược chạy theo thời gian còn lại lúc quà xuất hiện; đồng hồ máy lệch thì không có.
    final remaining = countdownRemaining(widget.gift.expiresAt, widget.now());
    if (remaining != null && remaining > Duration.zero) {
      _bar = AnimationController(vsync: this, duration: remaining)..forward();
    }
  }

  @override
  void dispose() {
    _bar?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final bar = _bar;
    return _CardFrame(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.card_giftcard_rounded, size: 24, color: AppColors.primary),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  l10n.giftDropTitle('${widget.gift.points}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.label,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 32,
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: EdgeInsets.zero,
                textStyle: AppText.caption,
              ),
              onPressed: widget.claiming ? null : widget.onClaim,
              child: Text(l10n.giftClaim),
            ),
          ),
          if (bar != null)
            AnimatedBuilder(
              animation: bar,
              builder: (context, _) => LinearProgressIndicator(
                value: 1 - bar.value,
                minHeight: 2,
                color: AppColors.primary,
                backgroundColor: AppColors.outline,
              ),
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }
}
