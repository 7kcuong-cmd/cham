import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import 'brand_mark.dart';

/// Trạng thái `searching` / `offline` (DESIGN.md S3): vòng tròn nhịp đập + chữ.
class SearchingView extends StatefulWidget {
  const SearchingView({
    super.key,
    required this.since,
    this.offline = false,
    this.now,
  });

  /// Lúc bắt đầu tìm; quá 10 giây thì hiện thêm dòng `searchingLong`.
  final DateTime? since;

  /// `true`: dải "đang kết nối lại" ở trên, vòng tròn màu `textSecondary`.
  final bool offline;

  /// Đồng hồ (test).
  final DateTime Function()? now;

  static const Duration longWait = Duration(seconds: 10);

  @override
  State<SearchingView> createState() => _SearchingViewState();
}

class _SearchingViewState extends State<SearchingView> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.15)
        .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  bool get _isLong {
    final since = widget.since;
    if (since == null) return false;
    final now = (widget.now ?? DateTime.now)();
    return now.difference(since) > SearchingView.longWait;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ringColor = widget.offline ? AppColors.textSecondary : AppColors.primary;
    return ColoredBox(
      color: AppColors.bg,
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: AppSize.searchRing * 2,
                  height: AppSize.searchRing * 2,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // Quầng sáng nhịp đập phía sau.
                      ScaleTransition(
                        scale: _scale,
                        child: Container(
                          width: AppSize.searchRing * 2,
                          height: AppSize.searchRing * 2,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: widget.offline
                                ? null
                                : const RadialGradient(
                                    colors: [AppColors.primaryGlow, AppColors.scrimClear],
                                  ),
                          ),
                        ),
                      ),
                      ScaleTransition(
                        scale: _scale,
                        child: Container(
                          width: AppSize.searchRing,
                          height: AppSize.searchRing,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.offline ? null : AppColors.primarySoft,
                            border: Border.all(color: ringColor, width: 2),
                          ),
                        ),
                      ),
                      Opacity(
                        opacity: widget.offline ? 0.5 : 1,
                        child: const BrandMark(size: 48),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.xl),
                Text(
                  l10n.searching,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
                if (_isLong) ...[
                  const SizedBox(height: AppSpace.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
                    child: Text(
                      l10n.searchingLong,
                      textAlign: TextAlign.center,
                      style: AppText.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.offline)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: AppColors.surfaceHigh,
                padding: EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  MediaQuery.paddingOf(context).top + AppSpace.md,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Text(
                  l10n.reconnecting,
                  textAlign: TextAlign.center,
                  style: AppText.label,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
