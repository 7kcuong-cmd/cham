import 'package:cham/models/game_state.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:flutter_test/flutter_test.dart';

// Mẫu JSON sao chép nguyên văn từ API-GD2-4.md §3.4/§3.5.
const _stateInvited =
    '{ "type": "game.state", "data": { "gameId": "6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11", "gameType": "tictactoe", "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "status": "invited", "version": 1, "players": [ { "userId": "Xk3vN0aQp1L7cWm2RtY8bA", "symbol": null }, { "userId": "Q9pLm2vX0aB7cWn3RtY1kZ", "symbol": null } ], "turn": null, "turnDeadline": null, "inviteExpiresAt": "2026-10-06T09:31:20.000Z", "entryFee": 0, "board": null } }';
const _stateActive = '''
{
  "type": "game.state",
  "data": {
    "gameId": "6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11",
    "gameType": "tictactoe",
    "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11",
    "status": "active",
    "version": 3,
    "players": [ { "userId": "Xk3vN0aQp1L7cWm2RtY8bA", "symbol": "X" }, { "userId": "Q9pLm2vX0aB7cWn3RtY1kZ", "symbol": "O" } ],
    "turn": "Q9pLm2vX0aB7cWn3RtY1kZ",
    "turnDeadline": "2026-10-06T09:31:15.000Z",
    "inviteExpiresAt": null,
    "entryFee": 0,
    "board": ["X", null, null, null, "O", null, null, null, "X"]
  }
}''';
const _gameEnd =
    '{ "type": "game.end", "data": { "gameId": "6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11", "gameType": "tictactoe", "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "reason": "win", "winnerId": "Xk3vN0aQp1L7cWm2RtY8bA", "reward": 10, "board": ["X", "O", null, null, "X", "O", null, null, "X"] } }';
const _gameInvite =
    '{ "type": "game.invite", "data": { "gameId": "6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11", "gameType": "tictactoe", "roomName": "r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11", "fromUserId": "Xk3vN0aQp1L7cWm2RtY8bA", "entryFee": 0, "expiresAt": "2026-10-06T09:31:20.000Z" } }';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';

void main() {
  test('game.state invited: symbol null, board null, có inviteExpiresAt', () {
    final m = ServerMessage.parse(_stateInvited);
    expect(m, isA<GameStateMessage>());
    final s = (m as GameStateMessage).state;
    expect(s.gameId, '6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11');
    expect(s.gameType, 'tictactoe');
    expect(s.roomName, _room);
    expect(s.status, GameStatus.invited);
    expect(s.isActive, isFalse);
    expect(s.version, 1);
    expect(s.players.map((p) => p.userId), ['Xk3vN0aQp1L7cWm2RtY8bA', 'Q9pLm2vX0aB7cWn3RtY1kZ']);
    expect(s.players.every((p) => p.symbol == null), isTrue);
    expect(s.turn, isNull);
    expect(s.turnDeadline, isNull);
    expect(s.inviteExpiresAt, DateTime.utc(2026, 10, 6, 9, 31, 20));
    expect(s.entryFee, 0);
    expect(s.board, isNull);
  });

  test('game.state active: bàn 9 ô, lượt, ký hiệu từng người', () {
    final m = ServerMessage.parse(_stateActive);
    expect(m, isA<GameStateMessage>());
    final s = (m as GameStateMessage).state;
    expect(s.status, GameStatus.active);
    expect(s.isActive, isTrue);
    expect(s.version, 3);
    expect(s.turn, 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(s.turnDeadline, DateTime.utc(2026, 10, 6, 9, 31, 15));
    expect(s.inviteExpiresAt, isNull);
    expect(s.board, ['X', null, null, null, 'O', null, null, null, 'X']);
    expect(s.symbolOf('Xk3vN0aQp1L7cWm2RtY8bA'), 'X');
    expect(s.symbolOf('Q9pLm2vX0aB7cWn3RtY1kZ'), 'O');
    expect(s.symbolOf('khong-co'), isNull);
    expect(s.opponentOf('Xk3vN0aQp1L7cWm2RtY8bA'), 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(s.opponentOf('Q9pLm2vX0aB7cWn3RtY1kZ'), 'Xk3vN0aQp1L7cWm2RtY8bA');
  });

  test('game.end win: winnerId, reward, board', () {
    final m = ServerMessage.parse(_gameEnd);
    expect(m, isA<GameEndMessage>());
    final e = (m as GameEndMessage).end;
    expect(e.gameId, '6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11');
    expect(e.reason, GameEnd.reasonWin);
    expect(e.winnerId, 'Xk3vN0aQp1L7cWm2RtY8bA');
    expect(e.reward, 10);
    expect(e.board, ['X', 'O', null, null, 'X', 'O', null, null, 'X']);
  });

  test('game.end hòa/hủy: winnerId và board có thể null', () {
    final m = ServerMessage.parse(
      '{"type":"game.end","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","reason":"declined","winnerId":null,"reward":0,"board":null}}',
    );
    expect(m, isA<GameEndMessage>());
    final e = (m as GameEndMessage).end;
    expect(e.winnerId, isNull);
    expect(e.board, isNull);
    expect(e.reason, GameEnd.reasonDeclined);
    expect(
      <String>[
        GameEnd.reasonWin,
        GameEnd.reasonDraw,
        GameEnd.reasonTimeout,
        GameEnd.reasonResign,
        GameEnd.reasonDeclined,
        GameEnd.reasonExpired,
        GameEnd.reasonCancelled,
        GameEnd.reasonAbandoned,
      ],
      ['win', 'draw', 'timeout', 'resign', 'declined', 'expired', 'cancelled', 'abandoned'],
    );
  });

  test('game.invite', () {
    final m = ServerMessage.parse(_gameInvite);
    expect(m, isA<GameInviteReceived>());
    final i = (m as GameInviteReceived).invite;
    expect(i.gameId, '6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11');
    expect(i.gameType, 'tictactoe');
    expect(i.roomName, _room);
    expect(i.fromUserId, 'Xk3vN0aQp1L7cWm2RtY8bA');
    expect(i.entryFee, 0);
    expect(i.expiresAt, DateTime.utc(2026, 10, 6, 9, 31, 20));
  });

  group('sai dạng → UnknownMessage (không ném)', () {
    const cases = <String, String>{
      'game.state status lạ':
          '{"type":"game.state","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","status":"starting","version":1,"players":[],"turn":null,"turnDeadline":null,"inviteExpiresAt":null,"entryFee":0,"board":null}}',
      'game.state thiếu version':
          '{"type":"game.state","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","status":"active","players":[],"turn":null,"turnDeadline":null,"inviteExpiresAt":null,"entryFee":0,"board":null}}',
      'game.state board không phải mảng':
          '{"type":"game.state","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","status":"active","version":1,"players":[],"turn":null,"turnDeadline":null,"inviteExpiresAt":null,"entryFee":0,"board":"XO"}}',
      'game.state ô cờ là số':
          '{"type":"game.state","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","status":"active","version":1,"players":[],"turn":null,"turnDeadline":null,"inviteExpiresAt":null,"entryFee":0,"board":[1,null]}}',
      'game.state player thiếu userId':
          '{"type":"game.state","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","status":"active","version":1,"players":[{"symbol":"X"}],"turn":null,"turnDeadline":null,"inviteExpiresAt":null,"entryFee":0,"board":null}}',
      'game.end thiếu reward':
          '{"type":"game.end","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","reason":"win","winnerId":"u","board":null}}',
      'game.end thiếu reason':
          '{"type":"game.end","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","winnerId":null,"reward":0,"board":null}}',
      'game.invite thiếu expiresAt':
          '{"type":"game.invite","data":{"gameId":"g","gameType":"tictactoe","roomName":"$_room","fromUserId":"u","entryFee":0}}',
    };
    cases.forEach((name, raw) {
      test(name, () {
        expect(ServerMessage.parse(raw), isA<UnknownMessage>());
      });
    });
  });
}
