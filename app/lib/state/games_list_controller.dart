import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/game_state.dart';
import '../services/api_client.dart';

/// Tab Trò chơi: danh sách game (`GET /v1/games`) và lịch sử (`GET /v1/games/history`) – T-306.
class GamesListController extends ChangeNotifier {
  GamesListController({required ApiClient api}) : _api = api;

  static const pageSize = 20;

  final ApiClient _api;

  List<GameCatalogItem> _games = const <GameCatalogItem>[];
  String? _gamesError;
  bool _gamesLoaded = false;

  List<GameHistoryItem> _history = const <GameHistoryItem>[];
  DateTime? _nextBefore;
  bool _historyLoading = false;
  bool _historyLoaded = false;
  String? _historyError;
  bool _disposed = false;

  List<GameCatalogItem> get games => _games;
  String? get gamesError => _gamesError;
  bool get gamesLoaded => _gamesLoaded;

  List<GameHistoryItem> get history => _history;
  bool get historyLoading => _historyLoading;
  bool get historyLoaded => _historyLoaded;
  bool get historyHasMore => _nextBefore != null;
  String? get historyError => _historyError;

  /// Tải lại danh sách game và trang đầu của lịch sử (khi vào tab / kéo xuống).
  Future<void> load() async {
    await Future.wait<void>(<Future<void>>[_loadGames(), loadHistory()]);
  }

  Future<void> _loadGames() async {
    try {
      _games = List<GameCatalogItem>.unmodifiable(await _api.getGames());
      _gamesError = null;
      _gamesLoaded = true;
    } on ApiException catch (e) {
      _gamesError = e.code;
    }
    _notify();
  }

  Future<void> loadHistory() async {
    if (_historyLoading) return;
    _historyLoading = true;
    _historyError = null;
    _notify();
    try {
      final page = await _api.getGameHistory(limit: pageSize);
      _history = List<GameHistoryItem>.unmodifiable(page.results);
      _nextBefore = page.nextBefore;
      _historyLoaded = true;
    } on ApiException catch (e) {
      _historyError = e.code;
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// Cuộn vô hạn: trang kế theo `nextBefore`.
  Future<void> loadMoreHistory() async {
    final before = _nextBefore;
    if (before == null || _historyLoading) return;
    _historyLoading = true;
    _historyError = null;
    _notify();
    try {
      final page = await _api.getGameHistory(limit: pageSize, before: before);
      final known = _history.map((h) => h.gameId).toSet();
      _history = List<GameHistoryItem>.unmodifiable(
        <GameHistoryItem>[..._history, ...page.results.where((h) => !known.contains(h.gameId))],
      );
      _nextBefore = page.nextBefore;
    } on ApiException catch (e) {
      _historyError = e.code;
    } finally {
      _historyLoading = false;
      _notify();
    }
  }

  /// Đăng xuất.
  void reset() {
    _games = const <GameCatalogItem>[];
    _gamesError = null;
    _gamesLoaded = false;
    _history = const <GameHistoryItem>[];
    _nextBefore = null;
    _historyLoaded = false;
    _historyError = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
