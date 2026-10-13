import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/blocked_user.dart';
import '../state/contacts_controller.dart';
import '../theme/tokens.dart';

/// Người đã chặn, mở từ Cài đặt (T-109). Bỏ chặn không khôi phục danh bạ.
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(context.read<ContactsController>().loadBlocked());
    });
  }

  Future<void> _unblock(BlockedUser user) async {
    final l10n = AppLocalizations.of(context);
    final controller = context.read<ContactsController>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.unblockConfirmTitle(user.displayName)),
        content: Text(l10n.unblockConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.unblock),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.unblock(user.userId);
    if (error != null) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(errorText(l10n, error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contacts = context.watch<ContactsController>();
    final materialL10n = MaterialLocalizations.of(context);
    final blocked = contacts.blocked;

    final Widget body;
    if (contacts.blockedLoading && blocked.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (blocked.isEmpty) {
      final error = contacts.blockedError;
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error == null ? l10n.blockedUsersEmpty : errorText(l10n, error),
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: AppColors.textSecondary),
              ),
              if (error != null)
                TextButton(
                  onPressed: () => unawaited(contacts.loadBlocked()),
                  child: Text(l10n.retry),
                ),
            ],
          ),
        ),
      );
    } else {
      body = ListView.builder(
        itemCount: blocked.length,
        itemBuilder: (context, i) {
          final user = blocked[i];
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
                        user.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.label,
                      ),
                      Text(
                        materialL10n.formatShortDate(user.createdAt.toLocal()),
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: AppColors.primary),
                  onPressed: () => unawaited(_unblock(user)),
                  child: Text(l10n.unblock),
                ),
              ],
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.blockedUsers, style: AppText.title)),
      body: body,
    );
  }
}
