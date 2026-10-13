import 'package:cham/models/api_error.dart';
import 'package:cham/models/game_state.dart';
import 'package:cham/state/games_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

GameHistoryItem _item(String id, DateTime endedAt, {String outcome = 'win'}) => GameHistoryItem(
      gameId: id,
      gameType: 'tictactoe',
      outcome: outcome,
      reason: 'line',
      reward: 20,
      opponentId: 'u2',
      opponentName: 'Anna',
      endedAt: endedAt,
    );

void main() {
  late FakeApiClient api;
  late GamesListController c;

  setUp(() {
    api = FakeApiClient();
    c = GamesListController(api: api);
  });

  tearDown(() => c.dispose());

  test('load: tải danh sách game và trang đầu lịch sử', () async {
    api.onGetGames = () async => const <GameCatalogItem>[
          GameCatalogItem(type: 'tictactoe', entryFee: 10, winPoints: 20, drawPoints: 10, turnSeconds: 15),
        ];
    final t = DateTime.utc(2026, 10, 6, 9);
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async =>
        GameHistoryPage(results: <GameHistoryItem>[_item('g1', t)], nextBefore: null);
    await c.load();
    expect(c.gamesLoaded, isTrue);
    expect(c.games.single.type, 'tictactoe');
    expect(c.history.single.gameId, 'g1');
    expect(c.historyHasMore, isFalse);
    expect(api.log, contains('getGameHistory(limit: 20, before: null)'));
  });

  test('lỗi tải game: ghi mã lỗi, lịch sử vẫn tải', () async {
    api.onGetGames = () async => throw const ApiException(code: 'FEATURE_DISABLED');
    await c.load();
    expect(c.gamesError, 'FEATURE_DISABLED');
    expect(c.gamesLoaded, isFalse);
    expect(c.historyLoaded, isTrue);
  });

  test('loadMoreHistory: nối trang theo nextBefore, bỏ trùng', () async {
    final t1 = DateTime.utc(2026, 10, 6, 9);
    final t0 = DateTime.utc(2026, 10, 6, 8);
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async {
      if (before == null) {
        return GameHistoryPage(results: <GameHistoryItem>[_item('g1', t1)], nextBefore: t1);
      }
      return GameHistoryPage(
        results: <GameHistoryItem>[_item('g1', t1), _item('g0', t0, outcome: 'loss')],
        nextBefore: null,
      );
    };
    await c.loadHistory();
    expect(c.historyHasMore, isTrue);
    await c.loadMoreHistory();
    expect(c.history.map((h) => h.gameId), <String>['g1', 'g0']);
    expect(c.historyHasMore, isFalse);
    expect(api.log.last, 'getGameHistory(limit: 20, before: $t1)');
  });

  test('loadMoreHistory khi hết trang: không gọi API', () async {
    await c.loadHistory();
    final calls = api.log.length;
    await c.loadMoreHistory();
    expect(api.log.length, calls);
  });

  test('lỗi lịch sử: ghi mã lỗi, giữ dữ liệu cũ', () async {
    final t = DateTime.utc(2026, 10, 6, 9);
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async =>
        GameHistoryPage(results: <GameHistoryItem>[_item('g1', t)], nextBefore: t);
    await c.loadHistory();
    api.onGetGameHistory = ({int limit = 20, DateTime? before}) async =>
        throw const ApiException(code: 'NETWORK');
    await c.loadMoreHistory();
    expect(c.historyError, 'NETWORK');
    expect(c.history, hasLength(1));
    expect(c.historyHasMore, isTrue);
  });

  test('reset xóa sạch', () async {
    await c.load();
    c.reset();
    expect(c.gamesLoaded, isFalse);
    expect(c.history, isEmpty);
    expect(c.historyLoaded, isFalse);
  });
}
