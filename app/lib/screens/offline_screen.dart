import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../state/session_controller.dart';
import '../theme/tokens.dart';

/// Đã đăng nhập nhưng chưa tải được hồ sơ (mất mạng lúc mở app): báo lỗi + nút "Thử lại"
/// (gọi lại `POST /v1/auth/session`). Có thể đăng xuất.
class OfflineScreen extends StatelessWidget {
  const OfflineScreen({super.key});

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
              const Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.textSecondary),
              const SizedBox(height: AppSpace.lg),
              Text(l10n.errorNetwork, textAlign: TextAlign.center, style: AppText.title),
              const SizedBox(height: AppSpace.xl),
              FilledButton(onPressed: session.refresh, child: Text(l10n.retry)),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton(onPressed: session.signOut, child: Text(l10n.signOut)),
            ],
          ),
        ),
      ),
    );
  }
}
