import 'dart:async';

import 'package:cham/models/game_state.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/game_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _gameId = '6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11';
const _empty = <String?>[null, null, null, null, null, null, null, null, null];

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late FakeRoom room;
  late FakeTimers timers;
  late DateTime clock;
  late GameController c;
  late List<String> notices;
  late StreamSubscription<String> noticeSub;

  /// Mình (kSelfId) là X, đối thủ (kPeerId) là O.
  GameState active({
    int version = 2,
    String turn = kSelfId,
    List<String?> board = _empty,
    String roomName = kRoom,
    String gameId = _gameId,
  }) =>
      GameState(
        gameId: gameId,
        gameType: 'tictactoe',
        roomName: roomName,
        status: GameStatus.active,
        version: version,
        players: const [
          GamePlayer(userId: kSelfId, symbol: 'X'),
          GamePlayer(userId: kPeerId, symbol: 'O'),
        ],
        turn: turn,
        turnDeadline: DateTime.utc(2026, 10, 6, 9, 31, 15),
        inviteExpiresAt: null,
        entryFee: 0,
        board: board,
      );

  GameState invited({int version = 1, String inviter = kSelfId}) => GameState(
        gameId: _gameId,
        gameType: 'tictactoe',
        roomName: kRoom,
        status: GameStatus.invited,
        version: version,
        players: [
          GamePlayer(userId: inviter, symbol: null),
          GamePlayer(userId: inviter == kSelfId ? kPeerId : kSelfId, symbol: null),
        ],
        turn: null,
        turnDeadline: null,
        inviteExpiresAt: clock.add(const Duration(seconds: 20)),
        entryFee: 0,
        board: null,
      );

  GameEnd end(
    String reason, {
    String? winnerId,
    int reward = 0,
    String roomName = kRoom,
  }) =>
      GameEnd(
        gameId: _gameId,
        gameType: 'tictactoe',
        roomName: roomName,
        reason: reason,
        winnerId: winnerId,
        reward: reward,
        board: null,
      );

  GameInvite inviteMsg({int seconds = 20}) => GameInvite(
        gameId: _gameId,
        gameType: 'tictactoe',
        roomName: kRoom,
        fromUserId: kPeerId,
        entryFee: 0,
        expiresAt: clock.add(Duration(seconds: seconds)),
      );

  List<SentMessage> sentOf(String type) => ws.sent.where((m) => m.type == type).toList();

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    room = FakeRoom(room: kRoom);
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 6, 9, 31);
    c = GameController(
      api: api,
      ws: ws,
      room: room,
      selfId: () => kSelfId,
      timerFactory: timers.create,
      now: () => clock,
    );
    notices = <String>[];
    noticeSub = c.notices.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
    c.dispose();
  });

  Future<void> deliver(ServerMessage m) async {
    ws.emit(m);
    await _settle();
  }

  group('gameResultKind (chỉ đọc reason/winnerId của server)', () {
    test('thắng/thua theo winnerId, hòa, hết giờ, bỏ cuộc, dừng, từ chối', () {
      GameResultKind? k(String reason, {String? winnerId}) =>
          gameResultKind(end(reason, winnerId: winnerId), kSelfId);
      expect(k('win', winnerId: kSelfId), GameResultKind.win);
      expect(k('win', winnerId: kPeerId), GameResultKind.lose);
      expect(k('resign', winnerId: kSelfId), GameResultKind.win); // đối phương bỏ cuộc
      expect(k('resign', winnerId: kPeerId), GameResultKind.lose);
      expect(k('timeout', winnerId: kSelfId), GameResultKind.timeoutWin);
      expect(k('timeout', winnerId: kPeerId), GameResultKind.timeoutLose);
      expect(k('draw'), GameResultKind.draw);
      expect(k('abandoned'), GameResultKind.abandoned);
      expect(k('declined'), GameResultKind.declined);
      expect(k('expired'), isNull);
      expect(k('cancelled'), isNull);
      expect(k('gi-do-moi'), isNull);
      expect(k('win'), isNull); // thiếu winnerId: không đoán
    });
  });

  group('mời và nhận lời mời', () {
    test('invite gửi game.invite {roomName, gameType}; chờ phản hồi thì không mời lại', () async {
      expect(c.canInvite, isTrue);
      c.invite();
      expect(ws.sent.single.type, 'game.invite');
      expect(ws.sent.single.data, {'roomName': kRoom, 'gameType': 'tictactoe'});
      expect(c.awaiting, isTrue);
      expect(c.canInvite, isFalse);
      c.invite();
      expect(sentOf('game.invite'), hasLength(1));
    });

    test('ngoài cuộc gọi: không mời', () {
      room.leave();
      expect(c.canInvite, isFalse);
      c.invite();
      expect(ws.sent, isEmpty);
    });

    test('game.state invited → mình là người mời, bàn chưa có', () async {
      c.invite();
      await deliver(GameStateMessage(invited()));
      expect(c.state?.status, GameStatus.invited);
      expect(c.iAmInviter, isTrue);
      expect(c.awaiting, isFalse);
      expect(c.canInvite, isFalse);
    });

    test('INSUFFICIENT_POINTS khi vừa mời → thôi chờ + thông báo', () async {
      c.invite();
      await deliver(const ServerError('INSUFFICIENT_POINTS', 'x'));
      expect(c.awaiting, isFalse);
      expect(notices, ['INSUFFICIENT_POINTS']);
      expect(c.canInvite, isTrue);
    });

    test('GAME_ALREADY_ACTIVE khi vừa mời → thông báo', () async {
      c.invite();
      await deliver(const ServerError('GAME_ALREADY_ACTIVE', 'x'));
      expect(notices, ['GAME_ALREADY_ACTIVE']);
    });

    test('lỗi tới khi không chờ gì thì bỏ qua', () async {
      await deliver(const ServerError('INSUFFICIENT_POINTS', 'x'));
      await deliver(const ServerError('GAME_ALREADY_ACTIVE', 'x'));
      expect(notices, isEmpty);
    });

    test('game.invite đến → incomingInvite; accept gửi game.accept; game.state active dọn lời mời', () async {
      await deliver(GameInviteReceived(inviteMsg()));
      expect(c.incomingInvite?.gameId, _gameId);
      c.accept();
      expect(ws.sent.single.type, 'game.accept');
      expect(ws.sent.single.data, {'gameId': _gameId});
      expect(c.awaiting, isTrue);

      await deliver(GameStateMessage(active(version: 2, turn: kPeerId)));
      expect(c.incomingInvite, isNull);
      expect(c.state?.isActive, isTrue);
      expect(c.awaiting, isFalse);
    });

    test('decline gửi game.decline và xóa lời mời', () async {
      await deliver(GameInviteReceived(inviteMsg()));
      c.decline();
      expect(ws.sent.single.type, 'game.decline');
      expect(ws.sent.single.data, {'gameId': _gameId});
      expect(c.incomingInvite, isNull);
    });

    test('lời mời đến tự ẩn sau expiresAt + 3 s', () async {
      await deliver(GameInviteReceived(inviteMsg(seconds: 20)));
      timers.fire(const Duration(seconds: 23));
      expect(c.incomingInvite, isNull);
    });

    test('lời mời của phòng khác bị bỏ qua', () async {
      await deliver(GameInviteReceived(GameInvite(
        gameId: 'g2',
        gameType: 'tictactoe',
        roomName: 'r_khac',
        fromUserId: kPeerId,
        entryFee: 0,
        expiresAt: clock.add(const Duration(seconds: 20)),
      )));
      expect(c.incomingInvite, isNull);
    });

    test('mời kèm phí: giữ nguyên entryFee để banner hiện', () async {
      await deliver(GameInviteReceived(GameInvite(
        gameId: _gameId,
        gameType: 'tictactoe',
        roomName: kRoom,
        fromUserId: kPeerId,
        entryFee: 5,
        expiresAt: clock.add(const Duration(seconds: 20)),
      )));
      expect(c.incomingInvite?.entryFee, 5);
    });
  });

  group('version và chơi', () {
    test('state có version ≤ bản đang giữ bị bỏ', () async {
      await deliver(GameStateMessage(active(version: 3, board: ['X', ...List<String?>.filled(8, null)])));
      expect(c.state?.version, 3);

      await deliver(GameStateMessage(active(version: 2))); // cũ hơn
      expect(c.state?.version, 3);
      expect(c.state?.board?.first, 'X');

      await deliver(GameStateMessage(active(version: 3))); // trùng
      expect(c.state?.board?.first, 'X');

      await deliver(GameStateMessage(active(version: 4, board: ['X', 'O', ...List<String?>.filled(7, null)])));
      expect(c.state?.version, 4);
      expect(c.state?.board?[1], 'O');
    });

    test('play gửi game.move {gameId, move:{cell}} và KHÓA bàn tới khi có state mới', () async {
      await deliver(GameStateMessage(active(version: 2)));
      expect(c.myTurn, isTrue);
      expect(c.play(4), isTrue);
      expect(ws.sent.single.type, 'game.move');
      expect(ws.sent.single.data, {'gameId': _gameId, 'move': {'cell': 4}});
      expect(c.moveLocked, isTrue);

      expect(c.play(0), isFalse); // đang khóa
      expect(sentOf('game.move'), hasLength(1));

      await deliver(GameStateMessage(active(version: 3, turn: kPeerId, board: [null, null, null, null, 'X', null, null, null, null])));
      expect(c.moveLocked, isFalse);
      expect(c.myTurn, isFalse);
      expect(c.play(0), isFalse); // chưa tới lượt
    });

    test('ILLEGAL_MOVE / NOT_YOUR_TURN mở khóa và báo lỗi', () async {
      await deliver(GameStateMessage(active()));
      c.play(0);
      await deliver(const ServerError('ILLEGAL_MOVE', 'x'));
      expect(c.moveLocked, isFalse);
      expect(notices, ['ILLEGAL_MOVE']);

      c.play(1);
      await deliver(const ServerError('NOT_YOUR_TURN', 'x'));
      expect(c.moveLocked, isFalse);
      expect(notices, ['ILLEGAL_MOVE', 'NOT_YOUR_TURN']);
    });

    test('không có phản hồi sau 5 s → tự mở khóa', () async {
      await deliver(GameStateMessage(active()));
      c.play(0);
      expect(c.moveLocked, isTrue);
      timers.fire(GameController.moveTimeout);
      expect(c.moveLocked, isFalse);
    });

    test('ô đã có quân hoặc ngoài 0..8: không gửi', () async {
      await deliver(GameStateMessage(active(board: ['X', ...List<String?>.filled(8, null)])));
      expect(c.play(0), isFalse);
      expect(c.play(-1), isFalse);
      expect(c.play(9), isFalse);
      expect(ws.sent, isEmpty);
    });

    test('mySymbol và turnStartedAt (giờ nhận state, không phải turnDeadline)', () async {
      await deliver(GameStateMessage(active()));
      expect(c.mySymbol, 'X');
      expect(c.turnStartedAt, clock);
      clock = clock.add(const Duration(seconds: 3));
      await deliver(GameStateMessage(active(version: 3, turn: kPeerId)));
      expect(c.turnStartedAt, clock);
    });

    test('resign gửi game.end {gameId}', () async {
      await deliver(GameStateMessage(active()));
      c.resign();
      expect(ws.sent.single.type, 'game.end');
      expect(ws.sent.single.data, {'gameId': _gameId});
    });

    test('turnSeconds lấy từ GET /v1/games khi mời lần đầu (mặc định 15)', () async {
      expect(c.turnSeconds, GameController.defaultTurnSeconds);
      api.onGetGames = () async => const [
            GameCatalogItem(type: 'tictactoe', entryFee: 0, winPoints: 10, drawPoints: 3, turnSeconds: 20),
          ];
      c.invite();
      await _settle();
      expect(c.turnSeconds, 20);
    });
  });

  group('kết thúc ván và cuộc gọi', () {
    test('game.end tới TRƯỚC call.ended: banner rồi dọn sạch', () async {
      await deliver(GameStateMessage(active()));
      await deliver(GameEndMessage(end('win', winnerId: kSelfId, reward: 10)));
      expect(c.state, isNull);
      expect(c.resultKind, GameResultKind.win);
      expect(c.lastEnd?.reward, 10);

      room.leave(); // call.ended làm SwipeController đưa roomName về null
      expect(c.state, isNull);
      expect(c.resultKind, isNull);
      expect(c.lastEnd, isNull);
      expect(c.incomingInvite, isNull);
    });

    test('game.end tới SAU call.ended: bị bỏ qua, không dựng lại gì', () async {
      await deliver(GameStateMessage(active()));
      room.leave();
      expect(c.state, isNull);
      await deliver(GameEndMessage(end('abandoned')));
      expect(c.state, isNull);
      expect(c.resultKind, isNull);
    });

    test('game.end của cuộc gọi cũ không dính sang phòng mới', () async {
      await deliver(GameStateMessage(active()));
      room.enter('r_moi');
      await deliver(GameEndMessage(end('abandoned')));
      expect(c.resultKind, isNull);
      await deliver(GameStateMessage(active(roomName: kRoom, version: 9)));
      expect(c.state, isNull);
    });

    test('banner kết quả tự ẩn sau 2,5 s và chạm để đóng sớm', () async {
      await deliver(GameStateMessage(active()));
      await deliver(GameEndMessage(end('draw')));
      expect(c.resultKind, GameResultKind.draw);
      timers.fire(GameController.resultDisplay);
      expect(c.resultKind, isNull);

      await deliver(GameStateMessage(active(version: 5, gameId: 'g-khac')));
      await deliver(GameEndMessage(GameEnd(
        gameId: 'g-khac',
        gameType: 'tictactoe',
        roomName: kRoom,
        reason: 'declined',
        winnerId: null,
        reward: 0,
        board: null,
      )));
      expect(c.resultKind, GameResultKind.declined);
      c.dismissResult();
      expect(c.resultKind, isNull);
    });

    test('expired/cancelled: dọn lời mời, không banner', () async {
      await deliver(GameStateMessage(invited()));
      await deliver(GameEndMessage(end('expired')));
      expect(c.state, isNull);
      expect(c.resultKind, isNull);
    });

    test('state muộn của ván đã kết thúc bị bỏ', () async {
      await deliver(GameStateMessage(active(version: 2)));
      await deliver(GameEndMessage(end('win', winnerId: kPeerId)));
      expect(c.resultKind, GameResultKind.lose);
      await deliver(GameStateMessage(active(version: 3)));
      expect(c.state, isNull);
    });

    test('game.end khi đang chờ nước đi: mở khóa bàn', () async {
      await deliver(GameStateMessage(active()));
      c.play(0);
      await deliver(GameEndMessage(end('timeout', winnerId: kPeerId)));
      expect(c.moveLocked, isFalse);
      expect(c.resultKind, GameResultKind.timeoutLose);
    });

    test('game.end dọn cả lời mời đang hiện', () async {
      await deliver(GameInviteReceived(inviteMsg()));
      await deliver(GameEndMessage(end('cancelled')));
      expect(c.incomingInvite, isNull);
    });

    test('GAME_NOT_FOUND: bỏ ván + thông báo', () async {
      await deliver(GameStateMessage(active()));
      await deliver(const ServerError('GAME_NOT_FOUND', 'x'));
      expect(c.state, isNull);
      expect(notices, ['GAME_NOT_FOUND']);
    });

    test('đổi phòng xóa ván, lời mời, banner', () async {
      await deliver(GameInviteReceived(inviteMsg()));
      room.enter('r_moi');
      expect(c.incomingInvite, isNull);
      expect(c.state, isNull);
    });
  });
}
