import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';

/// S2b – Chưa đủ tuổi (DESIGN.md S2b). Không có cách khai lại năm sinh.
/// `banned: true` dùng cho tài khoản bị khóa: tiêu đề `errorBanned`, chỉ nút Đăng xuất.
class UnderageScreen extends StatelessWidget {
  const UnderageScreen({super.key, this.banned = false});

  final bool banned;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final session = context.read<SessionController>();
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_rounded, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpace.lg),
              Text(
                banned ? l10n.errorBanned : l10n.underageTitle,
                textAlign: TextAlign.center,
                style: AppText.title,
              ),
              if (!banned) ...[
                const SizedBox(height: AppSpace.sm),
                Text(
                  l10n.underageBody,
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppColors.textSecondary),
                ),
              ],
              const SizedBox(height: AppSpace.xl),
              OutlinedButton(onPressed: session.signOut, child: Text(l10n.signOut)),
            ],
          ),
        ),
      ),
    );
  }
}
