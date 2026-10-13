import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';

/// Bàn cờ caro 3x3, 216 dp (3 x 72): chỉ VẼ `board` mà server gửi và báo ô được chạm. Không có
/// luật chơi hay xét thắng thua trong app (server là trọng tài, ADR-006).
///
/// [board]: 9 ô theo hàng (0 1 2 / 3 4 5 / 6 7 8), mỗi ô `X` | `O` | `null`. Ô chỉ nhận chạm khi
/// [enabled] và ô còn trống. Không phải lượt mình: bên ngoài bọc [Opacity] 0,6.
class TicTacToeBoard extends StatelessWidget {
  const TicTacToeBoard({
    super.key,
    required this.board,
    required this.enabled,
    required this.onCellTap,
  });

  static const int cells = 9;
  static const int side = 3;

  final List<String?> board;
  final bool enabled;
  final ValueChanged<int> onCellTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Container(
      width: AppSize.boardSize,
      height: AppSize.boardSize,
      decoration: BoxDecoration(
        color: AppColors.scrim,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var row = 0; row < side; row++)
            Row(
              children: [
                for (var col = 0; col < side; col++)
                  _Cell(
                    index: row * side + col,
                    row: row,
                    col: col,
                    value: row * side + col < board.length ? board[row * side + col] : null,
                    enabled: enabled,
                    cellLabel: l10n.gameCellLabel('${row + 1}', '${col + 1}'),
                    xLabel: l10n.gameCellX,
                    oLabel: l10n.gameCellO,
                    onTap: onCellTap,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.index,
    required this.row,
    required this.col,
    required this.value,
    required this.enabled,
    required this.cellLabel,
    required this.xLabel,
    required this.oLabel,
    required this.onTap,
  });

  final int index;
  final int row;
  final int col;
  final String? value;
  final bool enabled;
  final String cellLabel;
  final String xLabel;
  final String oLabel;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    const line = BorderSide(color: AppColors.outline, width: 2);
    final empty = value == null;
    final tappable = enabled && empty;
    final mark = value;
    final spoken = mark == null ? cellLabel : '$cellLabel, ${mark == 'X' ? xLabel : oLabel}';
    return Semantics(
      button: tappable,
      label: spoken,
      excludeSemantics: true,
      child: InkWell(
        onTap: tappable ? () => onTap(index) : null,
        child: Container(
          width: AppSize.boardCell,
          height: AppSize.boardCell,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              right: col < TicTacToeBoard.side - 1 ? line : BorderSide.none,
              bottom: row < TicTacToeBoard.side - 1 ? line : BorderSide.none,
            ),
          ),
          child: mark == null
              ? null
              : Text(
                  mark,
                  style: AppText.title.copyWith(
                    color: mark == 'X' ? AppColors.primary : AppColors.textPrimary,
                  ),
                ),
        ),
      ),
    );
  }
}
