import 'dart:async';
import 'dart:convert';

import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/services/ws_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

/// Kết nối giả: test điều khiển việc "server" mở, gửi và đóng với mã tùy ý.
class FakeTransport implements WsTransport {
  FakeTransport(this.uri, this.headers);

  final Uri uri;
  final Map<String, String> headers;
  final StreamController<String> _in = StreamController<String>();
  final Completer<void> _ready = Completer<void>();
  final List<String> sent = <String>[];
  int? _closeCode;
  bool closed = false;

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<String> get incoming => _in.stream;

  @override
  void send(String text) => sent.add(text);

  @override
  int? get closeCode => _closeCode;

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed) await _in.close();
  }

  // --- phía "server" ---
  void open() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void serverSends(String json) => _in.add(json);

  void serverCloses(int? code) {
    _closeCode = code;
    _in.close();
  }
}

const _sessionReady =
    '{"type":"session.ready","data":{"userId":"u1","serverTime":"2026-10-05T09:30:00.000Z"}}';

String _error(String code) =>
    jsonEncode({'type': 'error', 'data': {'code': code, 'message': 'x'}});

Future<void> _until(bool Function() cond, {int ms = 2000}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: ms));
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met within ${ms}ms');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeAuthService auth;
  late List<FakeTransport> transports;
  late List<int> attempts;
  late WsClient ws;
  late List<WsConnState> states;
  late List<ServerMessage> messages;

  WsClient build({Duration rateLimited = const Duration(milliseconds: 60)}) {
    final client = WsClient(
      url: 'ws://localhost:8080/v1/ws',
      auth: auth,
      connector: (uri, headers) {
        final t = FakeTransport(uri, headers);
        transports.add(t);
        return t;
      },
      backoff: (attempt) {
        attempts.add(attempt);
        return const Duration(milliseconds: 5);
      },
      rateLimitedDelay: rateLimited,
    );
    states = <WsConnState>[];
    messages = <ServerMessage>[];
    client.state.listen(states.add);
    client.messages.listen(messages.add);
    return client;
  }

  /// Bắt đầu connect, mở transport thứ [index], chưa gửi session.ready.
  Future<FakeTransport> openTransport(int index, Future<void> connectFuture) async {
    await _until(() => transports.length > index);
    final t = transports[index];
    t.open();
    await connectFuture;
    return t;
  }

  setUp(() {
    auth = FakeAuthService(signedIn: true, tokens: ['t1', 't2', 't3']);
    transports = <FakeTransport>[];
    attempts = <int>[];
    ws = build();
  });

  tearDown(() => ws.dispose());

  test('defaultBackoff: 1, 2, 4, 8, 16, 30, 30… giây', () {
    expect(
      [for (var i = 0; i < 8; i++) WsClient.defaultBackoff(i).inSeconds],
      [1, 2, 4, 8, 16, 30, 30, 30],
    );
  });

  test('token qua header Authorization (không qua query); connected chỉ sau session.ready', () async {
    final t = await openTransport(0, ws.connect());
    expect(t.headers, {'Authorization': 'Bearer t1'});
    expect(t.uri.toString(), 'ws://localhost:8080/v1/ws');
    expect(t.uri.hasQuery, isFalse);
    expect(ws.currentState, WsConnState.connecting);
    expect(ws.isConnected, isFalse);

    t.serverSends(_sessionReady);
    await _until(() => ws.isConnected);
    expect(states, [WsConnState.connecting, WsConnState.connected]);
    await _until(() => messages.isNotEmpty);
    expect(messages.single, isA<SessionReady>());
  });

  test('send: bỏ khi chưa connected; khi connected gửi {type, reqId c-n, data}', () async {
    ws.send('queue.join'); // chưa connect: bỏ
    final t = await openTransport(0, ws.connect());
    ws.send('queue.join'); // đang connecting: bỏ
    expect(t.sent, isEmpty);

    t.serverSends(_sessionReady);
    await _until(() => ws.isConnected);
    ws.send('queue.join');
    ws.send('call.next', {'roomName': 'r_x'});

    expect(jsonDecode(t.sent[0]), {'type': 'queue.join', 'reqId': 'c-1', 'data': {}});
    expect(jsonDecode(t.sent[1]), {
      'type': 'call.next',
      'reqId': 'c-2',
      'data': {'roomName': 'r_x'},
    });
  });

  test('4401: làm mới token (forceRefresh) và thử lại MỘT lần; lại 4401 → closedPermanently + UNAUTHENTICATED',
      () async {
    final first = await openTransport(0, ws.connect());
    first.serverSends(_error('UNAUTHENTICATED'));
    first.serverCloses(4401);

    await _until(() => transports.length == 2);
    expect(transports[1].headers, {'Authorization': 'Bearer t2'});
    expect(auth.tokenCalls, [false, true]);
    // Lỗi đi kèm lần 4401 đầu không được chuyển tiếp.
    expect(messages.whereType<ServerError>(), isEmpty);

    transports[1].open();
    transports[1].serverSends(_error('UNAUTHENTICATED'));
    transports[1].serverCloses(4401);

    await _until(() => ws.currentState == WsConnState.closedPermanently);
    await _until(() => messages.whereType<ServerError>().isNotEmpty);
    expect(messages.whereType<ServerError>().single.code, 'UNAUTHENTICATED');
    await _wait(60);
    expect(transports.length, 2, reason: 'không kết nối lại lần thứ ba');
  });

  test('4401 rồi thành công: lần sau 4401 lại được thử lại (cờ được reset bởi session.ready)', () async {
    final first = await openTransport(0, ws.connect());
    first.serverCloses(4401);
    await _until(() => transports.length == 2);
    transports[1].open();
    transports[1].serverSends(_sessionReady);
    await _until(() => ws.isConnected);

    transports[1].serverCloses(4401);
    await _until(() => transports.length == 3);
    expect(auth.tokenCalls.last, isTrue);
  });

  for (final code in [4403, 4409]) {
    test('$code: closedPermanently, không kết nối lại', () async {
      final t = await openTransport(0, ws.connect());
      t.serverSends(_sessionReady);
      await _until(() => ws.isConnected);

      t.serverCloses(code);
      await _until(() => ws.currentState == WsConnState.closedPermanently);
      await _wait(60);
      expect(transports.length, 1);
      expect(attempts, isEmpty);
    });
  }

  test('4403 vẫn chuyển tiếp lỗi UNDERAGE do server gửi trước khi đóng', () async {
    final t = await openTransport(0, ws.connect());
    t.serverSends(_error('UNDERAGE'));
    t.serverCloses(4403);
    await _until(() => ws.currentState == WsConnState.closedPermanently);
    await _until(() => messages.isNotEmpty);
    expect((messages.single as ServerError).code, 'UNDERAGE');
  });

  test('4404: gọi onNeedsSessionRefresh rồi kết nối lại', () async {
    var refreshed = 0;
    ws.onNeedsSessionRefresh = () async => refreshed++;
    final t = await openTransport(0, ws.connect());
    t.serverSends(_error('USER_NOT_FOUND'));
    t.serverCloses(4404);

    await _until(() => transports.length == 2);
    expect(refreshed, 1);
  });

  test('4429: chờ rateLimitedDelay rồi mới kết nối lại', () async {
    await ws.dispose();
    ws = build(rateLimited: const Duration(milliseconds: 150));
    final t = await openTransport(0, ws.connect());
    t.serverSends(_sessionReady);
    await _until(() => ws.isConnected);

    t.serverCloses(4429);
    await _wait(60);
    expect(transports.length, 1, reason: 'chưa tới hạn chờ');
    await _until(() => transports.length == 2, ms: 1500);
    expect(attempts, isEmpty, reason: '4429 không dùng backoff');
  });

  test('mã khác (1006/1001/null): backoff tăng dần, reset sau session.ready', () async {
    final t0 = await openTransport(0, ws.connect());
    t0.serverCloses(1006);
    await _until(() => transports.length == 2);
    transports[1].open();
    transports[1].serverCloses(1001);
    await _until(() => transports.length == 3);
    expect(attempts, [0, 1]);

    transports[2].open();
    transports[2].serverSends(_sessionReady);
    await _until(() => ws.isConnected);
    transports[2].serverCloses(null);
    await _until(() => transports.length == 4);
    expect(attempts, [0, 1, 0]);
    expect(states, contains(WsConnState.disconnected));
  });

  test('handshake thất bại (ready lỗi) → backoff rồi thử lại', () async {
    final f = ws.connect();
    await _until(() => transports.isNotEmpty);
    transports[0]._ready.completeError(StateError('refused'));
    transports[0].serverCloses(null);
    await f;
    await _until(() => transports.length == 2);
    expect(attempts, [0]);
  });

  test('close(): không tự kết nối lại nữa', () async {
    final t = await openTransport(0, ws.connect());
    t.serverSends(_sessionReady);
    await _until(() => ws.isConnected);

    await ws.close();
    expect(ws.currentState, WsConnState.disconnected);
    expect(t.closed, isTrue);
    await _wait(60);
    expect(transports.length, 1);

    // connect() lại sau close() hoạt động bình thường
    final f = ws.connect();
    await _until(() => transports.length == 2);
    transports[1].open();
    await f;
  });

  test('chưa đăng nhập (token null) → closedPermanently + UNAUTHENTICATED', () async {
    auth.signedIn = false;
    await ws.connect();
    expect(ws.currentState, WsConnState.closedPermanently);
    await _until(() => messages.isNotEmpty);
    expect((messages.single as ServerError).code, 'UNAUTHENTICATED');
    expect(transports, isEmpty);
  });
}
