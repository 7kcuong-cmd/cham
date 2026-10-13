import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/api_error.dart';
import '../models/match_found.dart';
import '../state/safety_controller.dart';
import '../state/swipe_controller.dart';
import '../theme/tokens.dart';

/// Mở sheet An toàn (DESIGN.md S4). Cuộc gọi vẫn tiếp tục phía sau; mic của mình
/// tự tắt khi sheet mở và bật lại khi đóng (trừ khi người dùng đã tự tắt trước đó).
///
/// Giữ `peer` và `roomName` tại thời điểm mở: nếu cuộc gọi kết thúc trong lúc
/// sheet mở thì vẫn báo cáo được người cũ.
Future<void> showSafetySheet(
  BuildContext context, {
  required Peer peer,
  required String? roomName,
}) async {
  final swipe = context.read<SwipeController>();
  final micWasOn = swipe.micOn;
  // Việc đổi mic làm ở đây (không trong dispose của widget) vì notifyListeners
  // trong lúc cây đang khóa gây lỗi.
  unawaited(swipe.setMic(false));
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SafetySheet(peer: peer, roomName: roomName),
    );
  } finally {
    unawaited(swipe.setMic(micWasOn));
  }
}

enum _Step { choose, report }

class SafetySheet extends StatefulWidget {
  const SafetySheet({super.key, required this.peer, required this.roomName});

  final Peer peer;
  final String? roomName;

  @override
  State<SafetySheet> createState() => _SafetySheetState();
}

class _SafetySheetState extends State<SafetySheet> {
  static const int _noteMaxLength = 500;

  _Step _step = _Step.choose;
  String? _reason;
  bool _alsoBlock = true;
  bool _sending = false;
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _reasonLabel(AppLocalizations l10n, String reason) {
    switch (reason) {
      case 'nudity':
        return l10n.reasonNudity;
      case 'harassment':
        return l10n.reasonHarassment;
      case 'underage':
        return l10n.reasonUnderage;
      case 'spam':
        return l10n.reasonSpam;
      case 'violence':
        return l10n.reasonViolence;
      default:
        return l10n.reasonOther;
    }
  }

  Future<void> _submitReport() async {
    final reason = _reason;
    if (reason == null || _sending) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final safety = context.read<SafetyController>();
    setState(() => _sending = true);
    try {
      final outcome = await safety.report(
        peer: widget.peer,
        reason: reason,
        note: _note.text,
        alsoBlock: _alsoBlock,
        roomName: widget.roomName,
      );
      messenger.showSnackBar(SnackBar(content: Text(l10n.reportThanks)));
      if (outcome == ReportOutcome.doneBlockFailed) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
      if (mounted) navigator.pop();
    } on ApiException catch (e) {
      // RATE_LIMITED → errorRateLimited; mã khác theo bảng DESIGN.md §5.
      messenger.showSnackBar(SnackBar(content: Text(errorText(l10n, e.code))));
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _confirmBlock() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final safety = context.read<SafetyController>();
    final name = widget.peer.displayName;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.blockConfirmTitle(name)),
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
    if (confirmed != true || !mounted) return;
    setState(() => _sending = true);
    try {
      await safety.block(widget.peer);
      messenger.showSnackBar(SnackBar(content: Text(l10n.blockDone)));
      if (mounted) navigator.pop();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(l10n, e.code))));
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, AppSpace.lg),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOutCubic,
          child: _step == _Step.choose
              ? _buildChoose(context)
              : _buildReport(context),
        ),
      ),
    );
  }

  Widget _buildChoose(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = widget.peer.displayName;
    return Column(
      key: const ValueKey<String>('safety-choose'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.safetyTitle, style: AppText.title),
        const SizedBox(height: AppSpace.lg),
        _ActionRow(
          icon: Icons.flag_rounded,
          label: l10n.reportUser(name),
          onTap: _sending ? null : () => setState(() => _step = _Step.report),
        ),
        const SizedBox(height: AppSpace.sm),
        _ActionRow(
          icon: Icons.block_rounded,
          label: l10n.blockUser(name),
          color: AppColors.danger,
          onTap: _sending ? null : _confirmBlock,
        ),
        const SizedBox(height: AppSpace.sm),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }

  Widget _buildReport(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      key: const ValueKey<String>('safety-report'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.reportTitle, style: AppText.title),
        const SizedBox(height: AppSpace.sm),
        for (final reason in kReportReasons)
          _ReasonRow(
            label: _reasonLabel(l10n, reason),
            selected: _reason == reason,
            onTap: _sending ? null : () => setState(() => _reason = reason),
          ),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: _note,
          enabled: !_sending,
          maxLength: _noteMaxLength,
          minLines: 2,
          maxLines: 4,
          style: AppText.body,
          decoration: InputDecoration(hintText: l10n.reportNoteHint),
        ),
        InkWell(
          onTap: _sending ? null : () => setState(() => _alsoBlock = !_alsoBlock),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: AppSize.minTouch),
            child: Row(
              children: [
                Checkbox(
                  value: _alsoBlock,
                  onChanged: _sending
                      ? null
                      : (v) => setState(() => _alsoBlock = v ?? false),
                ),
                Expanded(child: Text(l10n.alsoBlock, style: AppText.body)),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        FilledButton(
          onPressed: (_reason == null || _sending) ? null : _submitReport,
          child: _sending
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.onPrimary,
                  ),
                )
              : Text(l10n.submitReport),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = AppColors.textPrimary,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: SizedBox(
          height: AppSize.settingsRow,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            child: Row(
              children: [
                Icon(icon, size: 24, color: color),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Text(label, style: AppText.label.copyWith(color: color)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Hàng chọn lý do (radio tự vẽ để tránh API `Radio` đang đổi giữa các bản Flutter).
class _ReasonRow extends StatelessWidget {
  const _ReasonRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: AppSize.reasonRow,
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 24,
                color: selected ? AppColors.primary : AppColors.textSecondary,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(label, style: AppText.body)),
            ],
          ),
        ),
      ),
    );
  }
}
