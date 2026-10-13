import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/game_state.dart';
import '../models/ws_messages.dart';
import '../services/api_client.dart';
import '../services/ws_client.dart';
import '../utils/countdown.dart';
import 'call_context.dart';
import 'swipe_controller.dart' show TimerFactory;

/// Kết quả ván để hiện banner. App KHÔNG tự tính thắng/thua: chỉ đọc `reason` và `winnerId`
/// mà server gửi trong `game.end`.
enum GameResultKind { win, lose, draw, timeoutWin, timeoutLose, abandoned, declined }

/// Banner cho [end] theo góc nhìn của [selfId]; `null` nếu không cần banner
/// (`expired`, `cancelled`: lời mời tự biến mất).
GameResultKind? gameResultKind(GameEnd end, String? selfId) {
  final byMe = end.winnerId != null && end.winnerId == selfId;
  switch (end.reason) {
    case GameEnd.reasonWin:
    case GameEnd.reasonResign:
      if (end.winnerId == null) return null;
      return byMe ? GameResultKind.win : GameResultKind.lose;
    case GameEnd.reasonTimeout:
      if (end.winnerId == null) return null;
      return byMe ? GameResultKind.timeoutWin : GameResultKind.timeoutLose;
    case GameEnd.reasonDraw:
      return GameResultKind.draw;
    case GameEnd.reasonAbandoned:
      return GameResultKind.abandoned;
    case GameEnd.reasonDeclined:
      return GameResultKind.declined;
    default:
      return null;
  }
}

/// Mini game trong cuộc gọi – T-306 (API-GD2-4 §3.4). Giữ tối đa một ván theo `roomName` hiện tại.
class GameController extends ChangeNotifier {
  GameController({
    required ApiClient api,
    required WsClient ws,
    required RoomSource room,
    required String? Function() selfId,
    TimerFactory? timerFactory,
    DateTime Function()? now,
  })  : _api = api,
        _ws = ws,
        _room = room,
        _selfId = selfId,
        _timerFactory = timerFactory ?? Timer.new,
        _now = now ?? DateTime.now {
    _msgSub = _ws.messages.listen(_onMessage);
    _room.addListener(_onRoomChanged);
    _lastRoom = _room.roomName;
  }

  static const defaultGameType = 'tictactoe';

  /// Số giây mỗi lượt khi chưa tải được `GET /v1/games`.
  static const defaultTurnSeconds = 15;

  /// Banner kết quả hiện chừng này.
  static const resultDisplay = Duration(milliseconds: 2500);

  /// Nước đi chưa có phản hồi sau chừng này → mở khóa bàn (tránh kẹt khi mất gói tin).
  static const moveTimeout = Duration(seconds: 5);

  /// Dọn lời mời chậm hơn `expiresAt` chừng này nếu server không báo hết hạn.
  static const expiryGrace = Duration(seconds: 3);

  final ApiClient _api;
  final WsClient _ws;
  final RoomSource _room;
  final String? Function() _selfId;
  final TimerFactory _timerFactory;
  final DateTime Function() _now;

  late final StreamSubscription<ServerMessage> _msgSub;
  final StreamController<String> _notices = StreamController<String>.broadcast();

  GameState? _state;
  GameInvite? _incoming;
  GameEnd? _lastEnd;
  GameResultKind? _resultKind;
  int _turnSeconds = defaultTurnSeconds;
  bool _catalogRequested = false;

  /// Đã gửi `game.invite`/`game.accept` và chưa thấy kết quả.
  bool _awaiting = false;
  bool _moveLocked = false;
  DateTime? _turnStartedAt;

  /// Ván đã kết thúc trong phòng này: state/invite muộn của chúng bị bỏ.
  final Set<String> _endedIds = <String>{};

  Timer? _moveTimer;
  Timer? _resultTimer;
  Timer? _inviteTimer;

  String? _lastRoom;
  bool _disposed = false;

  /// Ván hiện tại (đã mời hoặc đang chơi); `null` nếu không có.
  GameState? get state => _state;

  /// Lời mời chơi đến từ đối phương, chưa trả lời.
  GameInvite? get incomingInvite => _incoming;

  /// Kết quả ván vừa xong, hiện [resultDisplay].
  GameEnd? get lastEnd => _lastEnd;
  GameResultKind? get resultKind => _resultKind;

  int get turnSeconds => _turnSeconds;

  /// Lúc app nhận `game.state` đang hiệu lực (gốc của thanh đếm lượt; không dùng `turnDeadline`
  /// vì đồng hồ máy có thể lệch).
  DateTime? get turnStartedAt => _turnStartedAt;

  /// Bàn bị khóa tới khi có phản hồi cho nước vừa đi.
  bool get moveLocked => _moveLocked;

  /// Đang chờ server trả lời `game.invite` / `game.accept`.
  bool get awaiting => _awaiting;

  Stream<String> get notices => _notices.stream;

  /// Trong cuộc gọi, chưa có ván/lời mời nào: được phép mời.
  bool get canInvite =>
      _room.roomName != null && _state == null && _incoming == null && !_awaiting;

  /// Mình là người mời của ván `invited` hiện tại.
  bool get iAmInviter {
    final s = _state;
    final me = _selfId();
    if (s == null || me == null || s.players.isEmpty) return false;
    return s.status == GameStatus.invited && s.players.first.userId == me;
  }

  bool get myTurn {
    final s = _state;
    final me = _selfId();
    return s != null && s.isActive && me != null && s.turn == me;
  }

  /// Ký hiệu của mình (`X`/`O`) trong ván hiện tại.
  String? get mySymbol {
    final me = _selfId();
    return me == null ? null : _state?.symbolOf(me);
  }

  // --- hành động -------------------------------------------------------------------

  /// Mời đối phương chơi.
  void invite([String gameType = defaultGameType]) {
    final room = _room.roomName;
    if (room == null || !canInvite) return;
    _awaiting = true;
    unawaited(_loadCatalogOnce());
    _ws.send('game.invite', <String, dynamic>{'roomName': room, 'gameType': gameType});
    _notify();
  }

  /// Chấp nhận lời mời đang hiện.
  void accept() {
    final inv = _incoming;
    if (inv == null || _awaiting) return;
    _awaiting = true;
    unawaited(_loadCatalogOnce());
    _ws.send('game.accept', <String, dynamic>{'gameId': inv.gameId});
    _notify();
  }

  /// Từ chối lời mời đang hiện.
  void decline() {
    final inv = _incoming;
    if (inv == null) return;
    _ws.send('game.decline', <String, dynamic>{'gameId': inv.gameId});
    _clearIncoming();
    _notify();
  }

  /// Đi nước vào ô [cell] (0..8). Bàn bị khóa tới khi có `game.state` mới hoặc lỗi.
  /// Trả `false` nếu không gửi (không tới lượt, ô đã có quân, đang khóa...). Hợp lệ hay không
  /// vẫn do server quyết định.
  bool play(int cell) {
    final s = _state;
    if (s == null || !s.isActive || !myTurn || _moveLocked) return false;
    final board = s.board;
    if (board == null || cell < 0 || cell >= board.length || board[cell] != null) return false;
    _moveLocked = true;
    _moveTimer?.cancel();
    _moveTimer = _timerFactory(moveTimeout, _onMoveTimeout);
    _ws.send('game.move', <String, dynamic>{
      'gameId': s.gameId,
      'move': <String, dynamic>{'cell': cell},
    });
    _notify();
    return true;
  }

  /// Bỏ cuộc (ván đang chơi) hoặc hủy lời mời (người mời).
  void resign() {
    final s = _state;
    if (s == null) return;
    _ws.send('game.end', <String, dynamic>{'gameId': s.gameId});
  }

  /// Ẩn banner kết quả ngay.
  void dismissResult() {
    if (_lastEnd == null) return;
    _clearResult();
    _notify();
  }

  // --- WebSocket -------------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case final GameInviteReceived e:
        _onInvite(e.invite);
      case final GameStateMessage e:
        _onState(e.state);
      case final GameEndMessage e:
        _onEnd(e.end);
      case final ServerError e:
        _onError(e);
      default:
        break;
    }
  }

  void _onInvite(GameInvite inv) {
    if (inv.roomName != _room.roomName) return;
    if (_endedIds.contains(inv.gameId)) return;
    if (_state != null && _state!.gameId != inv.gameId) return;
    _incoming = inv;
    _inviteTimer?.cancel();
    _inviteTimer = _expiryTimer(inv.expiresAt, () {
      _inviteTimer = null;
      if (_incoming?.gameId == inv.gameId) {
        _incoming = null;
        _awaiting = false;
        _notify();
      }
    });
    _notify();
  }

  void _onState(GameState s) {
    if (s.roomName != _room.roomName) return;
    if (_endedIds.contains(s.gameId)) return;
    final current = _state;
    if (current != null && current.gameId == s.gameId && s.version <= current.version) return;
    _state = s;
    _awaiting = false;
    _moveLocked = false;
    _moveTimer?.cancel();
    _moveTimer = null;
    if (s.isActive) {
      _turnStartedAt = _now();
      _clearIncoming();
    } else {
      _turnStartedAt = null;
      final exp = s.inviteExpiresAt;
      if (exp != null) {
        _inviteTimer?.cancel();
        _inviteTimer = _expiryTimer(exp, () {
          _inviteTimer = null;
          if (_state?.gameId == s.gameId && _state?.status == GameStatus.invited) {
            _state = null;
            _awaiting = false;
            _notify();
          }
        });
      }
    }
    _notify();
  }

  void _onEnd(GameEnd end) {
    if (end.roomName != _room.roomName) return;
    // `game.end` có thể tới trước hoặc sau `call.ended`: ở đây phòng vẫn khớp nên dọn ván;
    // nếu `call.ended` tới trước thì [_onRoomChanged] đã dọn và `roomName` không khớp ở trên.
    _endedIds.add(end.gameId);
    final matchesState = _state?.gameId == end.gameId;
    final matchesInvite = _incoming?.gameId == end.gameId;
    if (matchesState) _state = null;
    if (matchesInvite) _clearIncoming();
    _awaiting = false;
    _moveLocked = false;
    _moveTimer?.cancel();
    _moveTimer = null;
    _turnStartedAt = null;
    _inviteTimer?.cancel();
    _inviteTimer = null;

    final kind = gameResultKind(end, _selfId());
    if (kind != null) {
      _lastEnd = end;
      _resultKind = kind;
      _resultTimer?.cancel();
      _resultTimer = _timerFactory(resultDisplay, () {
        _resultTimer = null;
        _clearResult();
        _notify();
      });
    }
    _notify();
  }

  void _onError(ServerError e) {
    switch (e.code) {
      case 'ILLEGAL_MOVE':
      case 'NOT_YOUR_TURN':
        if (!_moveLocked) return;
        _unlockMove();
        _addNotice(e.code);
      case 'INVALID_STATE':
        // Ở GĐ4 `INVALID_STATE` của game chỉ có khi đi nước lúc ván chưa `active`.
        if (!_moveLocked) return;
        _unlockMove();
      case 'GAME_NOT_FOUND':
        if (_state == null && _incoming == null && !_awaiting) return;
        _state = null;
        _clearIncoming();
        _awaiting = false;
        _unlockMove();
        _turnStartedAt = null;
        _addNotice(e.code);
      case 'GAME_ALREADY_ACTIVE':
      case 'INSUFFICIENT_POINTS':
        if (!_awaiting) return;
        _awaiting = false;
        _addNotice(e.code);
        _notify();
      case 'FEATURE_DISABLED':
        if (!_awaiting) return;
        _awaiting = false;
        _addNotice(e.code);
        _notify();
      default:
        break;
    }
  }

  void _unlockMove() {
    _moveLocked = false;
    _moveTimer?.cancel();
    _moveTimer = null;
    _notify();
  }

  void _onMoveTimeout() {
    _moveTimer = null;
    if (_moveLocked) {
      _moveLocked = false;
      _notify();
    }
  }

  // --- vòng đời phòng ----------------------------------------------------------------

  void _onRoomChanged() {
    final room = _room.roomName;
    if (room == _lastRoom) return;
    _lastRoom = room;
    _clearAll();
  }

  void _clearAll() {
    _state = null;
    _awaiting = false;
    _moveLocked = false;
    _turnStartedAt = null;
    _endedIds.clear();
    _moveTimer?.cancel();
    _moveTimer = null;
    _clearIncoming();
    _clearResult();
    _notify();
  }

  void _clearIncoming() {
    _incoming = null;
    _inviteTimer?.cancel();
    _inviteTimer = null;
  }

  void _clearResult() {
    _lastEnd = null;
    _resultKind = null;
    _resultTimer?.cancel();
    _resultTimer = null;
  }

  Timer? _expiryTimer(DateTime expiresAt, void Function() callback) {
    final remaining = countdownRemaining(expiresAt, _now());
    if (remaining == null) return null;
    return _timerFactory(remaining + expiryGrace, callback);
  }

  /// Tải `turnSeconds` một lần; lỗi thì giữ mặc định 15.
  Future<void> _loadCatalogOnce() async {
    if (_catalogRequested) return;
    _catalogRequested = true;
    try {
      final games = await _api.getGames();
      for (final g in games) {
        if (g.type == defaultGameType && g.turnSeconds > 0) {
          _turnSeconds = g.turnSeconds;
          _notify();
        }
      }
    } on ApiException {
      _catalogRequested = false; // thử lại lần sau
    }
  }

  void _addNotice(String code) {
    if (!_notices.isClosed) _notices.add(code);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _room.removeListener(_onRoomChanged);
    _msgSub.cancel();
    _moveTimer?.cancel();
    _resultTimer?.cancel();
    _inviteTimer?.cancel();
    _notices.close();
    super.dispose();
  }
}
