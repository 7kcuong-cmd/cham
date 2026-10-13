import 'json_utils.dart';

/// Trạng thái ván mà server gửi ra ngoài (`starting` không gửi) – API-GD2-4 §3.4.
enum GameStatus { invited, active }

class GamePlayer {
  const GamePlayer({required this.userId, required this.symbol});

  final String userId;

  /// `X` | `O`; `null` khi ván mới ở trạng thái `invited`.
  final String? symbol;

  static GamePlayer? tryParse(Object? json) {
    if (json is! Map) return null;
    final userId = json['userId'];
    final symbol = json['symbol'];
    if (userId is! String) return null;
    if (symbol != null && symbol is! String) return null;
    return GamePlayer(userId: userId, symbol: symbol as String?);
  }
}

/// `GameState` (`game.state.data`) – API-GD2-4 §3.4. App chỉ vẽ, không tự suy luận luật.
class GameState {
  const GameState({
    required this.gameId,
    required this.gameType,
    required this.roomName,
    required this.status,
    required this.version,
    required this.players,
    required this.turn,
    required this.turnDeadline,
    required this.inviteExpiresAt,
    required this.entryFee,
    required this.board,
  });

  final String gameId;
  final String gameType;
  final String roomName;
  final GameStatus status;

  /// Tăng 1 mỗi lần server gửi `game.state` mới cho ván này; state cũ hơn bị bỏ.
  final int version;
  final List<GamePlayer> players;

  /// userId của người đang tới lượt; `null` khi `invited`.
  final String? turn;
  final DateTime? turnDeadline;
  final DateTime? inviteExpiresAt;
  final int entryFee;

  /// Với cờ caro: 9 ô theo hàng (0 1 2 / 3 4 5 / 6 7 8), mỗi ô `X` | `O` | `null`.
  /// `null` khi ván chưa `active`.
  final List<String?>? board;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static GameState? tryParse(Map<String, dynamic> data) {
    final gameId = data['gameId'];
    final gameType = data['gameType'];
    final roomName = data['roomName'];
    final statusRaw = data['status'];
    final version = jsonInt(data['version']);
    final playersRaw = data['players'];
    final entryFee = jsonInt(data['entryFee']);
    if (gameId is! String || gameType is! String || roomName is! String) return null;
    if (statusRaw is! String || version == null || entryFee == null) return null;
    if (playersRaw is! List) return null;

    final GameStatus status;
    switch (statusRaw) {
      case 'invited':
        status = GameStatus.invited;
      case 'active':
        status = GameStatus.active;
      default:
        return null;
    }

    final players = <GamePlayer>[];
    for (final p in playersRaw) {
      final parsed = GamePlayer.tryParse(p);
      if (parsed == null) return null;
      players.add(parsed);
    }

    final turn = data['turn'];
    if (turn != null && turn is! String) return null;

    final parsedBoard = parseBoard(data['board']);
    if (!parsedBoard.ok) return null;

    return GameState(
      gameId: gameId,
      gameType: gameType,
      roomName: roomName,
      status: status,
      version: version,
      players: List<GamePlayer>.unmodifiable(players),
      turn: turn as String?,
      turnDeadline: jsonDate(data['turnDeadline']),
      inviteExpiresAt: jsonDate(data['inviteExpiresAt']),
      entryFee: entryFee,
      board: parsedBoard.board,
    );
  }

  /// Ký hiệu của [userId] (`X`/`O`), `null` nếu không phải người chơi hoặc chưa có.
  String? symbolOf(String userId) {
    for (final p in players) {
      if (p.userId == userId) return p.symbol;
    }
    return null;
  }

  /// userId của đối thủ của [userId]; `null` nếu không xác định.
  String? opponentOf(String userId) {
    for (final p in players) {
      if (p.userId != userId) return p.userId;
    }
    return null;
  }

  bool get isActive => status == GameStatus.active;
}

/// Đọc trường `board`: `null` hoặc danh sách phần tử `String`/`null`.
/// `ok == false` nếu sai dạng.
({bool ok, List<String?>? board}) parseBoard(Object? raw) {
  if (raw == null) return (ok: true, board: null);
  if (raw is! List) return (ok: false, board: null);
  final cells = <String?>[];
  for (final c in raw) {
    if (c != null && c is! String) return (ok: false, board: null);
    cells.add(c as String?);
  }
  return (ok: true, board: List<String?>.unmodifiable(cells));
}

/// `game.invite` (server → người được mời) – API-GD2-4 §3.4.
class GameInvite {
  const GameInvite({
    required this.gameId,
    required this.gameType,
    required this.roomName,
    required this.fromUserId,
    required this.entryFee,
    required this.expiresAt,
  });

  final String gameId;
  final String gameType;
  final String roomName;
  final String fromUserId;
  final int entryFee;
  final DateTime expiresAt;

  static GameInvite? tryParse(Map<String, dynamic> data) {
    final gameId = data['gameId'];
    final gameType = data['gameType'];
    final roomName = data['roomName'];
    final fromUserId = data['fromUserId'];
    final entryFee = jsonInt(data['entryFee']);
    final expiresAt = jsonDate(data['expiresAt']);
    if (gameId is! String || gameType is! String || roomName is! String) return null;
    if (fromUserId is! String || entryFee == null || expiresAt == null) return null;
    return GameInvite(
      gameId: gameId,
      gameType: gameType,
      roomName: roomName,
      fromUserId: fromUserId,
      entryFee: entryFee,
      expiresAt: expiresAt,
    );
  }
}

/// `game.end` (server → cả hai) – API-GD2-4 §3.4.
class GameEnd {
  const GameEnd({
    required this.gameId,
    required this.gameType,
    required this.roomName,
    required this.reason,
    required this.winnerId,
    required this.reward,
    required this.board,
  });

  final String gameId;
  final String gameType;
  final String roomName;

  /// `win` | `draw` | `timeout` | `resign` | `declined` | `expired` | `cancelled` | `abandoned`
  /// (giữ nguyên chuỗi để chịu giá trị mới).
  final String reason;

  /// userId của người thắng khi `win`/`timeout`/`resign`, ngược lại `null`.
  final String? winnerId;

  /// Điểm người nhận thông điệp này thật sự được cộng (0 nếu chạm hạn mức hoặc không có thưởng).
  final int reward;
  final List<String?>? board;

  static const reasonWin = 'win';
  static const reasonDraw = 'draw';
  static const reasonTimeout = 'timeout';
  static const reasonResign = 'resign';
  static const reasonDeclined = 'declined';
  static const reasonExpired = 'expired';
  static const reasonCancelled = 'cancelled';
  static const reasonAbandoned = 'abandoned';

  static GameEnd? tryParse(Map<String, dynamic> data) {
    final gameId = data['gameId'];
    final gameType = data['gameType'];
    final roomName = data['roomName'];
    final reason = data['reason'];
    final winnerId = data['winnerId'];
    final reward = jsonInt(data['reward']);
    if (gameId is! String || gameType is! String || roomName is! String) return null;
    if (reason is! String || reward == null) return null;
    if (winnerId != null && winnerId is! String) return null;
    final parsedBoard = parseBoard(data['board']);
    if (!parsedBoard.ok) return null;
    return GameEnd(
      gameId: gameId,
      gameType: gameType,
      roomName: roomName,
      reason: reason,
      winnerId: winnerId as String?,
      reward: reward,
      board: parsedBoard.board,
    );
  }
}

/// Một mục của `GET /v1/games`.
class GameCatalogItem {
  const GameCatalogItem({
    required this.type,
    required this.entryFee,
    required this.winPoints,
    required this.drawPoints,
    required this.turnSeconds,
  });

  final String type;
  final int entryFee;
  final int winPoints;
  final int drawPoints;
  final int turnSeconds;

  static GameCatalogItem? tryParse(Object? json) {
    if (json is! Map) return null;
    final type = json['type'];
    final entryFee = jsonInt(json['entryFee']);
    final winPoints = jsonInt(json['winPoints']);
    final drawPoints = jsonInt(json['drawPoints']);
    final turnSeconds = jsonInt(json['turnSeconds']);
    if (type is! String || entryFee == null || winPoints == null) return null;
    if (drawPoints == null || turnSeconds == null) return null;
    return GameCatalogItem(
      type: type,
      entryFee: entryFee,
      winPoints: winPoints,
      drawPoints: drawPoints,
      turnSeconds: turnSeconds,
    );
  }
}

/// Một mục của `GET /v1/games/history`.
class GameHistoryItem {
  const GameHistoryItem({
    required this.gameId,
    required this.gameType,
    required this.outcome,
    required this.reason,
    required this.reward,
    required this.opponentId,
    required this.opponentName,
    required this.endedAt,
  });

  final String gameId;
  final String gameType;

  /// `win` | `loss` | `draw` | `none`
  final String outcome;
  final String reason;
  final int reward;
  final String opponentId;

  /// Bản chụp tên lúc ván kết thúc.
  final String opponentName;
  final DateTime endedAt;

  static const outcomeWin = 'win';
  static const outcomeLoss = 'loss';
  static const outcomeDraw = 'draw';
  static const outcomeNone = 'none';

  static GameHistoryItem? tryParse(Object? json) {
    if (json is! Map) return null;
    final gameId = json['gameId'];
    final gameType = json['gameType'];
    final outcome = json['outcome'];
    final reason = json['reason'];
    final reward = jsonInt(json['reward']);
    final opponent = json['opponent'];
    final endedAt = jsonDate(json['endedAt']);
    if (gameId is! String || gameType is! String) return null;
    if (outcome is! String || reason is! String || reward == null) return null;
    if (opponent is! Map || endedAt == null) return null;
    final opponentId = opponent['id'];
    final opponentName = opponent['displayName'];
    if (opponentId is! String || opponentName is! String) return null;
    return GameHistoryItem(
      gameId: gameId,
      gameType: gameType,
      outcome: outcome,
      reason: reason,
      reward: reward,
      opponentId: opponentId,
      opponentName: opponentName,
      endedAt: endedAt,
    );
  }
}

/// Một trang của `GET /v1/games/history`.
class GameHistoryPage {
  const GameHistoryPage({required this.results, required this.nextBefore});

  final List<GameHistoryItem> results;

  /// ISO `endedAt` của phần tử cuối nếu trang đầy; `null` = hết.
  final DateTime? nextBefore;
}
