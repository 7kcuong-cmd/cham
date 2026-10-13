import 'package:cham/models/api_error.dart';
import 'package:cham/models/game_state.dart';
import 'package:cham/screens/games_screen.dart';
import 'package:cham/state/games_list_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

const _tictactoe =
    GameCatalogItem(type: 'tictactoe', entryFee: 10, winPoints: 20, drawPoints: 10, turnSeconds: 15);

GameHistoryItem _item(String id, String outcome, {int reward = 20, String name = 'Anna'}) =>
    GameHistoryItem(
      gameId: id,
      gameType: 'tictactoe',
      outcome: outcome,
      reason: 'line',
      reward: reward,
      opponentId: 'u2',
      opponentName: name,
      endedAt: DateTime.utc(2026, 10, 6, 9),
    );

void main() {
  late FakeApiClient api;
  late GamesListController list;

  Widget app({Locale locale = const Locale('vi'), double textScale = 1.0}) => harness(
        gamesList: list,
        locale: locale,
        textScale: textScale,
        home: const Scaffold(body: GamesScreen()),
      );

  setUp(() {
    api = FakeApiClient();
    list = GamesListController(api: api);
  });

  tearDown(() => list.dispose());

  testWidgets('hiện game, thưởng, phí vào, gợi ý chơi trong cuộc gọi', (tester) async {
    api.onGetGames = () async => const <GameCatalogItem>[_tictactoe];
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Trò chơi'), findsOneWidget);
    expect(find.text('Cờ caro 3×3'), findsOneWidget);
    expect(find.text('+20 điểm'), findsOneWidget);
    expect(find.text('Phí vào: 10 điểm'), findsOneWidget);
    expect(find.textContaining('Chơi trong lúc gọi video'), findsOneWidget);
  });

  testWidgets('lịch sử: tên đối thủ, kết quả, thưởng chỉ khi > 0', (tester) async {
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async => GameHistoryPage(
          results: [_item('g1', 'win'), _item('g2', 'loss', reward: 0, name: 'Bình')],
          nextBefore: null,
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('Thắng'), findsOneWidget);
    expect(find.text('Bình'), findsOneWidget);
    expect(find.text('Thua'), findsOneWidget);
    expect(find.text('+20 điểm'), findsOneWidget); // chỉ ván thắng có thưởng > 0
  });

  testWidgets('lịch sử rỗng: hiện "Chưa có ván nào."', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Chưa có ván nào.'), findsOneWidget);
  });

  testWidgets('lỗi tải lịch sử: hiện lỗi, bấm Thử lại tải lại', (tester) async {
    var fail = true;
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async {
      if (fail) throw const ApiException(code: 'NETWORK');
      return GameHistoryPage(results: [_item('g1', 'draw', reward: 0)], nextBefore: null);
    };
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Không có kết nối mạng.'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(find.text('Hòa'), findsOneWidget);
  });

  testWidgets('outcome lạ không làm vỡ màn hình', (tester) async {
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async =>
        GameHistoryPage(results: [_item('g1', 'weird', reward: 0)], nextBefore: null);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Dừng'), findsOneWidget);
  });

  testWidgets('en, 320dp, chữ 1,3: không tràn', (tester) async {
    useNarrowSurface(tester);
    api.onGetGames = () async => const <GameCatalogItem>[_tictactoe];
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async => GameHistoryPage(
          results: [_item('g1', 'win', name: 'A very long opponent display name')],
          nextBefore: null,
        );
    await tester.pumpWidget(app(locale: const Locale('en'), textScale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('Games'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
