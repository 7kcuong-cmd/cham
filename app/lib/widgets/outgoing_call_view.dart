import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/invite_controller.dart';
import '../theme/tokens.dart';
import 'round_call_button.dart';

/// Đang gọi một người trong danh bạ: toàn màn hình trên tab hiện tại (T-109).
class OutgoingCallView extends StatefulWidget {
  const OutgoingCallView({super.key});

  @override
  State<OutgoingCallView> createState() => _OutgoingCallViewState();
}

class _OutgoingCallViewState extends State<OutgoingCallView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Vòng nhịp giống màn `searching`.
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.15)
        .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invites = context.watch<InviteController>();
    final contact = invites.outgoingContact;
    if (contact == null) return const SizedBox.shrink();

    return ColoredBox(
      color: AppColors.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Text(
                contact.displayName,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.title,
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                l10n.outgoingCalling(contact.displayName),
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpace.xxl),
              ScaleTransition(
                scale: _scale,
                child: Container(
                  width: AppSize.searchRing,
                  height: AppSize.searchRing,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.primary, width: 2),
                  ),
                ),
              ),
              const Spacer(flex: 3),
              RoundCallButton(
                icon: Icons.call_end_rounded,
                label: l10n.outgoingCancel,
                background: AppColors.danger,
                foreground: AppColors.textPrimary,
                onPressed: invites.cancel,
              ),
              const SizedBox(height: AppSpace.xxl),
            ],
          ),
        ),
      ),
    );
  }
}
