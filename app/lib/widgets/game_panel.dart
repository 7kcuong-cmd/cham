import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/game_state.dart';
import '../state/game_controller.dart';
import '../theme/tokens.dart';
import 'tictactoe_board.dart';

/// Phần dưới màn hình cuộc gọi khi đang có ván của mình (đã mời hoặc đang chơi) – T-306.
/// Không che vùng giữa trên (mặt đối phương).
class GamePanel extends StatelessWidget {
  const GamePanel({super.key, required this.opponentName, this.now});

  final String opponentName;

  /// Đồng hồ cho thanh đếm lượt (test).
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final game = context.watch<GameController>();
    final state = game.state;
    if (state == null) return const SizedBox.shrink();

    if (state.status == GameStatus.invited) {
      return _Frame(
        children: [
          Text(
            game.iAmInviter ? l10n.gameInviteSent : l10n.gameInviteFrom(opponentName),
            textAlign: TextAlign.center,
            style: AppText.label,
          ),
          if (game.iAmInviter)
            TextButton(onPressed: game.resign, child: Text(l10n.cancel)),
        ],
      );
    }

    final board = state.board;
    if (board == null) return const SizedBox.shrink();
    final myTurn = game.myTurn;
    final started = game.turnStartedAt;
    return _Frame(
      children: [
        Text(
          myTurn ? l10n.gameYourTurn : l10n.gameTheirTurn(opponentName),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.label.copyWith(
            color: myTurn ? AppColors.primary : AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        // Thanh đếm lượt chỉ khi tới lượt mình; tính từ lúc app nhận `game.state`.
        if (myTurn && started != null)
          TurnBar(
            key: ValueKey<DateTime>(started),
            startedAt: started,
            seconds: game.turnSeconds,
            now: now ?? DateTime.now,
          )
        else
          const SizedBox(height: 3),
        const SizedBox(height: AppSpace.sm),
        Opacity(
          opacity: myTurn ? 1 : 0.6,
          child: TicTacToeBoard(
            board: board,
            enabled: myTurn && !game.moveLocked,
            onCellTap: game.play,
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: game.resign,
          child: Text(l10n.gameResign),
        ),
      ],
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSize.boardSize,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Thanh đếm ngược dài [seconds] giây kể từ [startedAt] (giờ của app, không phải `turnDeadline`).
class TurnBar extends StatefulWidget {
  const TurnBar({super.key, required this.startedAt, required this.seconds, required this.now});

  final DateTime startedAt;
  final int seconds;
  final DateTime Function() now;

  @override
  State<TurnBar> createState() => _TurnBarState();
}

class _TurnBarState extends State<TurnBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    final total = Duration(seconds: widget.seconds < 1 ? 1 : widget.seconds);
    final elapsed = widget.now().difference(widget.startedAt);
    final progress = (elapsed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    _ctrl = AnimationController(vsync: this, duration: total, value: progress)..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: LinearProgressIndicator(
          value: 1 - _ctrl.value,
          minHeight: 3,
          color: AppColors.primary,
          backgroundColor: AppColors.outline,
        ),
      ),
    );
  }
}
