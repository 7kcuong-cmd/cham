import 'package:cham/widgets/tictactoe_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/harness.dart';

const _empty = <String?>[null, null, null, null, null, null, null, null, null];

/// Vị trí tâm ô [index] (0..8) so với góc trên-trái của bàn cờ.
Offset _cellCenter(WidgetTester tester, int index) {
  final origin = tester.getTopLeft(find.byType(TicTacToeBoard));
  final row = index ~/ 3;
  final col = index % 3;
  return origin + Offset(72.0 * col + 36, 72.0 * row + 36);
}

void main() {
  testWidgets('kích thước 216x216, vẽ đúng quân X/O theo board của server', (tester) async {
    await tester.pumpWidget(harness(
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(
            board: const ['X', null, null, null, 'O', null, null, null, 'X'],
            enabled: true,
            onCellTap: (_) {},
          ),
        ),
      ),
    ));
    expect(tester.getSize(find.byType(TicTacToeBoard)), const Size(216, 216));
    expect(find.text('X'), findsNWidgets(2));
    expect(find.text('O'), findsOneWidget);
  });

  testWidgets('chạm ô trống khi enabled → onCellTap(index); ô có quân thì không', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(harness(
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(
            board: const ['X', null, null, null, 'O', null, null, null, null],
            enabled: true,
            onCellTap: taps.add,
          ),
        ),
      ),
    ));
    await tester.tapAt(_cellCenter(tester, 8));
    await tester.tapAt(_cellCenter(tester, 2));
    await tester.tapAt(_cellCenter(tester, 0)); // đã có X
    await tester.tapAt(_cellCenter(tester, 4)); // đã có O
    expect(taps, [8, 2]);
  });

  testWidgets('enabled=false (chưa tới lượt / đang khóa): không nhận chạm', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(harness(
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(board: _empty, enabled: false, onCellTap: taps.add),
        ),
      ),
    ));
    for (var i = 0; i < 9; i++) {
      await tester.tapAt(_cellCenter(tester, i));
    }
    expect(taps, isEmpty);
  });

  testWidgets('9 ô, mỗi ô nhận đúng chỉ số theo hàng (0 1 2 / 3 4 5 / 6 7 8)', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(harness(
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(board: _empty, enabled: true, onCellTap: taps.add),
        ),
      ),
    ));
    for (var i = 0; i < 9; i++) {
      await tester.tapAt(_cellCenter(tester, i));
    }
    expect(taps, [0, 1, 2, 3, 4, 5, 6, 7, 8]);
  });

  testWidgets('màn 320 dp, bản en, chữ 1,3: không tràn', (tester) async {
    useNarrowSurface(tester);
    await tester.pumpWidget(harness(
      locale: const Locale('en'),
      textScale: 1.3,
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(
            board: const ['X', 'O', 'X', null, 'O', null, null, null, 'X'],
            enabled: true,
            onCellTap: (_) {},
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TicTacToeBoard)).width, lessThanOrEqualTo(320));
  });

  testWidgets('board ngắn hơn 9 phần tử không làm hỏng giao diện (chịu dữ liệu lạ)', (tester) async {
    await tester.pumpWidget(harness(
      home: Scaffold(
        body: Center(
          child: TicTacToeBoard(board: const ['X'], enabled: true, onCellTap: (_) {}),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('X'), findsOneWidget);
  });
}
