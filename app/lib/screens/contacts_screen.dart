import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/contact.dart';
import '../services/push_service.dart';
import '../state/contacts_controller.dart';
import '../state/invite_controller.dart';
import '../state/chat_controller.dart';
import '../theme/tokens.dart';
import '../widgets/user_avatar.dart';
import '../utils/tr.dart';
import 'add_contact_screen.dart';
import 'chat_screen.dart';

/// Tab Danh bạ (DESIGN.md "Danh bạ", T-109): danh sách bạn, gọi lại, nhấn giữ để xóa/chặn.
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.autoLoad = true});

  /// Tải danh bạ khi dựng màn hình. Khung chính còn tải lại mỗi lần vào tab.
  final bool autoLoad;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cc = context.read<ContactsController>();
        unawaited(cc.load());
        unawaited(cc.loadRequests());
      });
    }
  }

  Future<void> _refresh() => context.read<ContactsController>().load();

  void _showError(String code) {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(errorText(l10n, code))));
  }

  /// Số tin chưa đọc theo người; không có ChatController (test dựng riêng) thì 0.
  int _unreadOf(BuildContext context, String peerId) {
    try {
      return context.watch<ChatController>().unread(peerId);
    } on Object {
      return 0;
    }
  }

  void _openChat(Contact contact) {
    // Màn chat cần ChatController; thiếu (ví dụ test không dựng) thì bỏ qua.
    try {
      context.read<ChatController>();
    } on Object {
      return;
    }
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ChatScreen(peerId: contact.id, peerName: contact.displayName),
    )));
  }

  Future<void> _call(Contact contact) async {
    await context.read<InviteController>().invite(contact);
  }

  Future<void> _openActions(Contact contact) async {
    final l10n = AppLocalizations.of(context);
    final action = await showModalBottomSheet<_ContactAction>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SheetRow(
              label: l10n.contactRemove,
              color: AppColors.danger,
              onTap: () => Navigator.of(sheetContext).pop(_ContactAction.remove),
            ),
            _SheetRow(
              label: l10n.blockUser(contact.displayName),
              color: AppColors.danger,
              onTap: () => Navigator.of(sheetContext).pop(_ContactAction.block),
            ),
            _SheetRow(
              label: l10n.cancel,
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _ContactAction.remove:
        await _confirmRemove(contact);
      case _ContactAction.block:
        await _confirmBlock(contact);
    }
  }

  Future<void> _confirmRemove(Contact contact) async {
    final l10n = AppLocalizations.of(context);
    final controller = context.read<ContactsController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.contactRemoveConfirmTitle(contact.displayName)),
        content: Text(l10n.contactRemoveConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.remove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.remove(contact.id);
    if (error != null && mounted) _showError(error);
  }

  Future<void> _confirmBlock(Contact contact) async {
    final l10n = AppLocalizations.of(context);
    final controller = context.read<ContactsController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.blockConfirmTitle(contact.displayName)),
        content: Text(l10n.blockConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.block),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.block(contact.id);
    if (!mounted) return;
    if (error != null) {
      _showError(error);
    } else {
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(l10n.blockDone)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contacts = context.watch<ContactsController>();
    final push = context.read<PushService>();
    final busy = context.select<InviteController, bool>((c) => c.status != InviteStatus.none);

    final Widget body;
    if (contacts.loading && !contacts.loaded) {
      body = const Center(child: CircularProgressIndicator());
    } else if (contacts.contacts.isEmpty) {
      body = _EmptyView(
        errorCode: contacts.loadError,
        onRetry: _refresh,
      );
    } else {
      body = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: contacts.contacts.length,
        itemBuilder: (context, i) {
          final contact = contacts.contacts[i];
          return _ContactRow(
            contact: contact,
            callEnabled: !busy,
            onCall: () => unawaited(_call(contact)),
            onLongPress: () => unawaited(_openActions(contact)),
            onOpenChat: () => _openChat(contact),
            unread: _unreadOf(context, contact.id),
          );
        },
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.lg,
              AppSpace.lg,
              AppSpace.md,
            ),
            child: Row(
              children: [
                Expanded(child: Text(l10n.tabContacts, style: AppText.title)),
                IconButton.filledTonal(
                  tooltip: tr(context, 'Thêm liên hệ', 'Add contact'),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  onPressed: () => unawaited(Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const AddContactScreen()),
                  )),
                ),
              ],
            ),
          ),
          for (final r in contacts.requests)
            ListTile(
              dense: true,
              leading: const Icon(Icons.mail_rounded, color: AppColors.primary),
              title: Text(
                tr(context, '${r.displayName} muốn kết bạn', '${r.displayName} wants to add you'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: tr(context, 'Từ chối', 'Decline'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => unawaited(contacts.declineRequest(r.userId)),
                  ),
                  IconButton(
                    tooltip: tr(context, 'Chấp nhận', 'Accept'),
                    icon: const Icon(Icons.check_rounded, color: AppColors.primary),
                    onPressed: () async {
                      final err = await contacts.acceptRequest(r.userId);
                      if (err != null && mounted) _showError(err);
                    },
                  ),
                ],
              ),
            ),
          ValueListenableBuilder<bool>(
            valueListenable: push.notificationsEnabled,
            builder: (context, enabled, _) {
              if (enabled) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  0,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.notifications_off_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        l10n.notificationsRationale,
                        style: AppText.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primary,
              backgroundColor: AppColors.surfaceHigh,
              onRefresh: _refresh,
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}

enum _ContactAction { remove, block }

class _ContactRow extends StatelessWidget {
  const _ContactRow({
    required this.contact,
    required this.callEnabled,
    required this.onCall,
    required this.onLongPress,
    required this.onOpenChat,
    this.unread = 0,
  });

  final Contact contact;
  final bool callEnabled;
  final VoidCallback onCall;
  final VoidCallback onLongPress;
  final VoidCallback onOpenChat;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return InkWell(
      onTap: onOpenChat,
      onLongPress: onLongPress,
      child: Container(
        height: AppSize.contactRow,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.outline)),
        ),
        child: Row(
          children: [
            Semantics(
              label: contact.online ? l10n.contactOnline : null,
              child: Container(
                width: AppSize.statusDot,
                height: AppSize.statusDot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: contact.online ? AppColors.primary : AppColors.outline,
                ),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            MaybeUserAvatar(userId: contact.id, name: contact.displayName, size: 40),
            const SizedBox(width: AppSpace.md),
            Flexible(
              child: Text(
                contact.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.label,
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: AppSpace.xs,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(contact.language.toUpperCase(), style: AppText.caption),
            ),
            const Spacer(),
            Tooltip(
              message: tr(context, 'Nhắn tin', 'Message'),
              child: SizedBox(
                width: AppSize.minTouch,
                height: AppSize.minTouch,
                child: InkResponse(
                  key: const ValueKey('contact-chat'),
                  onTap: onOpenChat,
                  radius: AppSize.minTouch / 2,
                  child: Center(
                    child: Badge(
                      isLabelVisible: unread > 0,
                      label: Text(unread > 99 ? '99+' : '$unread'),
                      child: Container(
                        width: AppSize.edgeButton,
                        height: AppSize.edgeButton,
                        decoration: const BoxDecoration(
                          color: AppColors.surfaceHigh,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.chat_bubble_rounded, size: 22, color: AppColors.primary),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Tooltip(
              message: l10n.contactCall,
              child: SizedBox(
                width: AppSize.minTouch,
                height: AppSize.minTouch,
                child: InkResponse(
                  onTap: callEnabled ? onCall : null,
                  radius: AppSize.minTouch / 2,
                  child: Center(
                    child: Container(
                      width: AppSize.edgeButton,
                      height: AppSize.edgeButton,
                      decoration: const BoxDecoration(
                        color: AppColors.surfaceHigh,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.videocam_rounded,
                        size: 24,
                        color: callEnabled ? AppColors.primary : AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.errorCode, required this.onRetry});

  final String? errorCode;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final error = errorCode;
    // Cuộn được để kéo-xuống-tải-lại hoạt động cả khi danh sách rỗng.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(AppSpace.xl),
      children: [
        const SizedBox(height: AppSpace.xxl),
        Icon(
          error == null ? Icons.people_outline_rounded : Icons.cloud_off_rounded,
          size: 48,
          color: AppColors.textSecondary,
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          error == null ? l10n.contactsEmpty : errorText(l10n, error),
          textAlign: TextAlign.center,
          style: AppText.body.copyWith(color: AppColors.textSecondary),
        ),
        if (error != null) ...[
          const SizedBox(height: AppSpace.lg),
          Center(
            child: TextButton(
              onPressed: () => unawaited(onRetry()),
              child: Text(l10n.retry),
            ),
          ),
        ],
      ],
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.label, required this.onTap, this.color = AppColors.textPrimary});

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: AppSize.reasonRow,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        child: Text(label, style: AppText.body.copyWith(color: color)),
      ),
    );
  }
}
