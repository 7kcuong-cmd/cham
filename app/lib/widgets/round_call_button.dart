import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Nút tròn 64 dp có nhãn bên dưới (màn cuộc gọi đến/đi).
class RoundCallButton extends StatelessWidget {
  const RoundCallButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.background = AppColors.primary,
    this.foreground = AppColors.onPrimary,
  });

  final IconData icon;

  /// Chuỗi dịch: dùng làm nhãn hiển thị và nhãn trợ năng.
  final String label;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: label,
          excludeSemantics: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: onPressed == null
                  ? null
                  : [
                      BoxShadow(
                        color: background.withValues(alpha: 0.45),
                        blurRadius: 18,
                        spreadRadius: 1,
                      ),
                    ],
            ),
            child: Material(
            color: onPressed == null ? AppColors.surfaceHigh : background,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: SizedBox(
                width: AppSize.roundButton,
                height: AppSize.roundButton,
                child: Icon(icon, size: 28, color: foreground),
              ),
            ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          label,
          textAlign: TextAlign.center,
          style: AppText.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
