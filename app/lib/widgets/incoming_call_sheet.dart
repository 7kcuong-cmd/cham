import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/invite_controller.dart';
import '../theme/tokens.dart';
import '../utils/countdown.dart';
import 'round_call_button.dart';

/// Màn hình cuộc gọi đến, phủ toàn màn hình, nền `bg` (DESIGN.md "Cuộc gọi đến", T-109).
///
/// Đồng hồ đếm ngược chỉ hiện khi `expiresAt` nằm trong [0, 120 s] so với đồng hồ máy; ngược lại
/// ẩn (đồng hồ máy có thể lệch) và để server báo hết hạn.
class IncomingCallSheet extends StatefulWidget {
  const IncomingCallSheet({super.key, this.now});

  /// Đồng hồ (test).
  final DateTime Function()? now;

  @override
  State<IncomingCallSheet> createState() => _IncomingCallSheetState();
}

class _IncomingCallSheetState extends State<IncomingCallSheet> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invites = context.watch<InviteController>();
    final inv = invites.incoming;
    if (inv == null) return const SizedBox.shrink();

    final now = (widget.now ?? DateTime.now)();
    final remaining = countdownRemaining(inv.expiresAt, now);
    final accepting = invites.accepting;

    return ColoredBox(
      color: AppColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Text(
                l10n.incomingCallTitle(inv.from.displayName),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: AppText.title,
              ),
              const SizedBox(height: AppSpace.sm),
              SizedBox(
                height: 18,
                child: remaining == null
                    ? null
                    : Text(
                        formatCountdown(remaining),
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
              ),
              const Spacer(flex: 3),
              if (accepting)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        semanticsLabel: l10n.connecting,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      l10n.connecting,
                      style: AppText.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                )
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    RoundCallButton(
                      icon: Icons.call_end_rounded,
                      label: l10n.incomingDecline,
                      background: AppColors.danger,
                      foreground: AppColors.textPrimary,
                      onPressed: invites.decline,
                    ),
                    RoundCallButton(
                      icon: Icons.videocam_rounded,
                      label: l10n.incomingAccept,
                      onPressed: () => unawaited(invites.accept()),
                    ),
                  ],
                ),
              const SizedBox(height: AppSpace.xxl),
            ],
          ),
        ),
      ),
    );
  }
}
