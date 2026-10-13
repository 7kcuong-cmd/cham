import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n_errors.dart';
import '../models/ws_messages.dart';
import '../state/invite_controller.dart';
import '../theme/tokens.dart';
import 'incoming_call_sheet.dart';
import 'outgoing_call_view.dart';

/// Chuỗi dịch cho một [InviteNotice].
String inviteNoticeText(AppLocalizations l10n, InviteNotice notice) {
  switch (notice) {
    case InviteErrorNotice(:final code):
      return errorText(l10n, code);
    case InviteEndedNotice(:final reason, :final outgoing):
      switch (reason) {
        case CallInviteEnded.declined:
          return l10n.inviteEndedDeclined;
        case CallInviteEnded.busy:
          return l10n.inviteEndedBusy;
        case CallInviteEnded.failed:
          return l10n.inviteEndedFailed;
        case CallInviteEnded.timeout:
          // Người gọi: "không ai trả lời". Người nghe: cuộc gọi nhỡ → "đã kết thúc".
          return outgoing ? l10n.inviteEndedTimeout : l10n.inviteEndedCancelled;
        default:
          return l10n.inviteEndedCancelled;
      }
  }
}

/// Phủ màn hình cuộc gọi đến / đang gọi lên trên mọi tab và hiện SnackBar khi lời mời kết thúc
/// (T-109). Đặt bên ngoài `Scaffold` của khung chính để che luôn thanh điều hướng.
class CallOverlays extends StatefulWidget {
  const CallOverlays({super.key, required this.child, this.now});

  final Widget child;

  /// Đồng hồ cho đếm ngược (test).
  final DateTime Function()? now;

  @override
  State<CallOverlays> createState() => _CallOverlaysState();
}

class _CallOverlaysState extends State<CallOverlays> {
  StreamSubscription<InviteNotice>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = context.read<InviteController>().notices.listen(_onNotice);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onNotice(InviteNotice notice) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(inviteNoticeText(l10n, notice))));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final invites = context.watch<InviteController>();
    final status = invites.status;
    final waitingPush = invites.awaitedPushInviteId != null && status == InviteStatus.none;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (waitingPush)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: AppColors.surfaceHigh,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  MediaQuery.paddingOf(context).top + AppSpace.md,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Text(
                  l10n.connecting,
                  textAlign: TextAlign.center,
                  style: AppText.label,
                ),
              ),
            ),
          ),
        if (status == InviteStatus.incoming)
          Positioned.fill(
            child: Material(
              color: AppColors.bg,
              child: IncomingCallSheet(now: widget.now),
            ),
          )
        else if (status == InviteStatus.outgoing)
          const Positioned.fill(
            child: Material(
              color: AppColors.bg,
              child: OutgoingCallView(),
            ),
          ),
      ],
    );
  }
}
