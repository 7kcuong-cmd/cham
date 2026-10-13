import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/match_found.dart';
import '../state/contacts_controller.dart';
import '../theme/tokens.dart';
import 'edge_actions.dart';

/// Nút "Thêm bạn" cạnh phải màn hình cuộc gọi (T-109, API-GD2-4 §3.2).
///
/// - Đã là bạn từ trước: ẩn.
/// - Chưa bấm: `person_add_rounded`.
/// - Mình đã bấm: `hourglass_top_rounded`, vô hiệu.
/// - Đối phương bấm trước: viền `primary` nhấp nháy 2 lần, bấm để đồng ý.
/// - Đã thành bạn trong cuộc gọi này: `how_to_reg_rounded`, vô hiệu.
class AddFriendButton extends StatefulWidget {
  const AddFriendButton({super.key, required this.peer});

  final Peer peer;

  @override
  State<AddFriendButton> createState() => _AddFriendButtonState();
}

class _AddFriendButtonState extends State<AddFriendButton>
    with SingleTickerProviderStateMixin {
  /// Một nhịp sáng-tắt; `repeat(count: 4, reverse: true)` = 2 lần nhấp nháy.
  static const Duration _blinkPeriod = Duration(milliseconds: 400);

  late final AnimationController _blink;
  AddFriendState? _lastState;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(vsync: this, duration: _blinkPeriod);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  void _onState(AddFriendState state) {
    if (state == _lastState) return;
    final previous = _lastState;
    _lastState = state;
    if (state == AddFriendState.requested && previous != AddFriendState.requested) {
      _blink.repeat(reverse: true, period: _blinkPeriod, count: 4);
    } else {
      _blink.stop();
      _blink.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contacts = context.watch<ContactsController>();
    final state = contacts.addFriendState;
    _onState(state);

    if (state != AddFriendState.added && contacts.isContact(widget.peer.id)) {
      return const SizedBox.shrink();
    }

    final IconData icon;
    final VoidCallback? onPressed;
    switch (state) {
      case AddFriendState.idle:
      case AddFriendState.requested:
        icon = Icons.person_add_rounded;
        onPressed = contacts.requestAdd;
      case AddFriendState.pending:
        icon = Icons.hourglass_top_rounded;
        onPressed = null;
      case AddFriendState.added:
        icon = Icons.how_to_reg_rounded;
        onPressed = null;
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        EdgeButton(icon: icon, tooltip: l10n.addFriend, onPressed: onPressed),
        // Viền nhấp nháy khi đối phương đã bấm trước (không nhận chạm).
        IgnorePointer(
          child: FadeTransition(
            opacity: _blink,
            child: Container(
              width: AppSize.minTouch,
              height: AppSize.minTouch,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.primary, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
