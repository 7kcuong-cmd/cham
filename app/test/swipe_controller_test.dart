import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/permission_gateway.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakePermissionGateway perms;
  late FakeTimers timers;
  late DateTime clock;
  late int refreshCalls;
  late SwipeController c;

  SwipeController build() => SwipeController(
        ws: ws,
        call: call,
        permissions: perms,
        refreshSession: () async => refreshCalls++,
        timerFactory: timers.create,
        now: () => clock,
      );

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    perms = FakePermissionGateway();
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 5, 9);
    refreshCalls = 0;
    c = build();
  });

  tearDown(() => c.dispose());

  /// activate + session.ready + match.found + RemoteVideoReady → inCall.
  Future<void> reachInCall() async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    call.emit(const RemoteVideoReady());
    await _settle();
  }

  test('1. activate có quyền + session.ready → gửi queue.join, trạng thái searching', () async {
    await c.activate();
    expect(c.status, SwipeStatus.searching);
    expect(ws.connectCalls, 1);
    expect(ws.sent, isEmpty); // chưa connected: chờ session.ready

    ws.emit(const SessionReady('u1'));
    await _settle();

    expect(ws.sentTypes, ['queue.join']);
    expect(c.status, SwipeStatus.searching);
  });

  test('activate khi WS đã connected → gửi queue.join ngay', () async {
    ws.emitState(WsConnState.connected);
    await c.activate();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('activate chưa có quyền → needsPermission, không kết nối WS', () async {
    perms.granted = false;
    await c.activate();
    expect(c.status, SwipeStatus.needsPermission);
    expect(ws.connectCalls, 0);

    await c.requestPermission();
    expect(perms.requestCalls, 1);
    expect(c.status, SwipeStatus.searching);
    expect(ws.connectCalls, 1);
  });

  test('từ chối vĩnh viễn → vẫn needsPermission với cờ permanentlyDenied', () async {
    perms
      ..granted = false
      ..requestOutcome = PermissionOutcome.permanentlyDenied;
    await c.activate();
    await c.requestPermission();
    expect(c.status, SwipeStatus.needsPermission);
    expect(c.permanentlyDenied, isTrue);
  });

  test('2. MatchFound → CallService.join đúng url/token, connecting; RemoteVideoReady → inCall', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();

    final match = makeMatch(room: _room);
    ws.emit(MatchFoundEvent(match));
    await _settle();

    expect(call.joins, ['${match.livekitUrl}|${match.token}']);
    expect(c.status, SwipeStatus.connecting);
    expect(c.current?.roomName, _room);

    call.emit(const RemoteVideoReady());
    await _settle();
    expect(c.status, SwipeStatus.inCall);
    expect(c.showSwipeHint, isTrue);
  });

  test('MatchFound khi không ở searching → bỏ qua và gửi call.end để server dọn', () async {
    await c.activate();
    await c.deactivate();
    ws.sent.clear();

    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();

    expect(call.joins, isEmpty);
    expect(ws.sent.single.type, 'call.end');
    expect(ws.sent.single.data, {'roomName': _room});
  });

  test('3. không có RemoteVideoReady trong 15 s → gửi call.next {roomName}', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    ws.sent.clear();

    expect(timers.activeCount(SwipeController.matchTimeout), 1);
    timers.fire(SwipeController.matchTimeout);
    await _settle();

    expect(ws.sent.single.type, 'call.next');
    expect(ws.sent.single.data, {'roomName': _room});
    expect(c.status, SwipeStatus.searching);
    expect(call.leaveCalls, 1);
  });

  test('RemoteVideoReady hủy hẹn giờ 15 s', () async {
    await reachInCall();
    expect(timers.activeCount(SwipeController.matchTimeout), 0);
  });

  test('4. next() khi inCall → leave() TRƯỚC khi gửi call.next; hai lần cách 100 ms chỉ gửi 1', () async {
    final order = <String>[];
    call = FakeCallService(order: order);
    c.dispose();
    c = build();
    await reachInCall();
    ws.sent.clear();
    order.clear();

    // Ghi thứ tự: dịch vụ gọi ghi vào `order`; gửi WS được chèn bằng cách quan sát `sent`.
    final nextFuture = c.next();
    clock = clock.add(const Duration(milliseconds: 100));
    final second = c.next();
    await Future.wait([nextFuture, second]);

    expect(order, ['call.leave']);
    expect(call.leaveCalls, 1);
    expect(ws.sent.where((m) => m.type == 'call.next').length, 1);
    expect(ws.sent.single.data, {'roomName': _room});
    expect(c.status, SwipeStatus.searching);
    expect(c.current, isNull);
  });

  test('next() ngắt LiveKit trước rồi mới gửi call.next (thứ tự thật)', () async {
    final events = <String>[];
    final gatedCall = _OrderedCall(events);
    final gatedWs = _OrderedWs(events);
    final ctrl = SwipeController(
      ws: gatedWs,
      call: gatedCall,
      permissions: perms,
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => clock,
    );
    addTearDown(ctrl.dispose);

    await ctrl.activate();
    gatedWs.emit(const SessionReady('u1'));
    await _settle();
    gatedWs.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    gatedCall.emit(const RemoteVideoReady());
    await _settle();
    events.clear();

    await ctrl.next();

    expect(events, ['call.leave', 'ws:call.next']);
  });

  test('next() sau 800 ms thì được phép lại', () async {
    await reachInCall();
    await c.next();
    ws.emit(MatchFoundEvent(makeMatch(room: 'r_second')));
    await _settle();
    call.emit(const RemoteVideoReady());
    await _settle();
    ws.sent.clear();

    clock = clock.add(const Duration(milliseconds: 800));
    await c.next();
    expect(ws.sent.single.type, 'call.next');
    expect(ws.sent.single.data, {'roomName': 'r_second'});
  });

  test('5. CallEnded peer_left đúng phòng → leave(), gửi queue.join', () async {
    await reachInCall();
    ws.sent.clear();
    final leaves = call.leaveCalls;

    ws.emit(const CallEnded(_room, CallEnded.peerLeft));
    await _settle();

    expect(call.leaveCalls, leaves + 1);
    expect(ws.sentTypes, ['queue.join']);
    expect(c.status, SwipeStatus.searching);
    expect(c.current, isNull);
  });

  test('CallEnded blocked → cũng queue.join', () async {
    await reachInCall();
    ws.sent.clear();
    ws.emit(const CallEnded(_room, CallEnded.blocked));
    await _settle();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('CallEnded của phòng khác → bỏ qua', () async {
    await reachInCall();
    ws.sent.clear();
    final leaves = call.leaveCalls;

    ws.emit(const CallEnded('r_other', CallEnded.peerLeft));
    await _settle();

    expect(call.leaveCalls, leaves);
    expect(ws.sent, isEmpty);
    expect(c.status, SwipeStatus.inCall);
    expect(c.current?.roomName, _room);
  });

  test('CallEnded server_shutdown → offline', () async {
    await reachInCall();
    ws.emit(const CallEnded(_room, CallEnded.serverShutdown));
    await _settle();
    expect(c.status, SwipeStatus.offline);
  });

  test('6. deactivate() khi inCall → call.end {roomName}; khi searching → queue.leave', () async {
    await reachInCall();
    ws.sent.clear();
    await c.deactivate();
    expect(ws.sent.single.type, 'call.end');
    expect(ws.sent.single.data, {'roomName': _room});
    expect(c.status, SwipeStatus.inactive);
    expect(call.leaveCalls, greaterThanOrEqualTo(1));

    // lần khác: đang searching
    final ws2 = FakeWsClient();
    final c2 = SwipeController(
      ws: ws2,
      call: FakeCallService(),
      permissions: perms,
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => clock,
    );
    addTearDown(c2.dispose);
    await c2.activate();
    ws2.emit(const SessionReady('u1'));
    await _settle();
    ws2.sent.clear();
    await c2.deactivate();
    expect(ws2.sentTypes, ['queue.leave']);
    expect(c2.status, SwipeStatus.inactive);
  });

  test('7. SESSION_REPLACED → blockedPermanently, không gửi gì thêm', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();

    final notices = <String>[];
    c.notices.listen(notices.add);
    ws.emit(const ServerError('SESSION_REPLACED', 'replaced'));
    await _settle();
    ws.emitState(WsConnState.closedPermanently);
    await _settle();

    expect(c.status, SwipeStatus.blockedPermanently);
    expect(c.blockedCode, 'SESSION_REPLACED');
    expect(ws.sent, isEmpty);
    expect(notices, ['SESSION_REPLACED']);

    // activate() không làm gì khi đã bị chặn vĩnh viễn
    await c.activate();
    expect(c.status, SwipeStatus.blockedPermanently);
    expect(ws.connectCalls, 1);
  });

  test('RemoteLeft: chờ call.ended; sau 3 s chưa có → next()', () async {
    await reachInCall();
    ws.sent.clear();

    call.emit(const RemoteLeft());
    await _settle();
    expect(ws.sent, isEmpty);
    expect(timers.activeCount(SwipeController.remoteLeftGrace), 1);

    timers.fire(SwipeController.remoteLeftGrace);
    await _settle();
    expect(ws.sent.single.type, 'call.next');
  });

  test('CallReconnecting: hủy hẹn kết thúc, không next(); nối lại xong vẫn đang gọi', () async {
    await reachInCall();
    ws.sent.clear();
    call.emit(const RemoteLeft());
    await _settle();
    expect(timers.activeCount(SwipeController.remoteLeftGrace), 1);

    call.emit(const CallReconnecting());
    await _settle();
    expect(timers.activeCount(SwipeController.remoteLeftGrace), 0);
    expect(ws.sent, isEmpty);

    call.emit(const CallReconnected());
    await _settle();
    expect(c.status, SwipeStatus.inCall);
    expect(ws.sent, isEmpty);
  });

  test('RemoteLeft rồi CallEnded đến trước 3 s → không next() thừa', () async {
    await reachInCall();
    call.emit(const RemoteLeft());
    await _settle();
    ws.sent.clear();

    ws.emit(const CallEnded(_room, CallEnded.peerLeft));
    await _settle();
    expect(timers.activeCount(SwipeController.remoteLeftGrace), 0);
    expect(ws.sentTypes, ['queue.join']);
  });

  test('mất kết nối WS → offline; kết nối lại + session.ready → queue.join, searching', () async {
    await reachInCall();
    ws.emitState(WsConnState.connected);
    ws.sent.clear();

    ws.emitState(WsConnState.disconnected);
    await _settle();
    expect(c.status, SwipeStatus.offline);
    expect(c.current, isNull);
    expect(call.leaveCalls, greaterThanOrEqualTo(1));

    ws.emitState(WsConnState.connecting);
    ws.emitState(WsConnState.connected);
    ws.emit(const SessionReady('u1'));
    await _settle();

    expect(c.status, SwipeStatus.searching);
    expect(ws.sentTypes, ['queue.join']);
  });

  test('RATE_LIMITED → thông báo, rồi gửi lại queue.join sau retryAfterSec', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();
    final notices = <String>[];
    c.notices.listen(notices.add);

    ws.emit(const ServerError('RATE_LIMITED', 'slow', retryAfterSec: 4));
    await _settle();
    expect(notices, ['RATE_LIMITED']);
    expect(ws.sent, isEmpty);

    timers.fire(const Duration(seconds: 4));
    await _settle();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('CALL_PROVIDER_ERROR → thông báo, giữ searching, queue.join lại sau 5 s', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();
    final notices = <String>[];
    c.notices.listen(notices.add);

    ws.emit(const ServerError('CALL_PROVIDER_ERROR', 'x'));
    await _settle();
    expect(c.status, SwipeStatus.searching);
    expect(notices, ['CALL_PROVIDER_ERROR']);

    timers.fire(SwipeController.providerRetry);
    await _settle();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('PROFILE_INCOMPLETE / UNDERAGE → gọi refreshSession', () async {
    await c.activate();
    ws.emit(const ServerError('PROFILE_INCOMPLETE', 'x'));
    ws.emit(const ServerError('UNDERAGE', 'x'));
    await _settle();
    expect(refreshCalls, 2);
  });

  test('join thất bại → tự next()', () async {
    call.joinShouldFail = true;
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();

    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    await _settle();

    expect(ws.sent.single.type, 'call.next');
    expect(c.status, SwipeStatus.searching);
  });

  test('toggleMic / setMic gọi CallService và đổi micOn', () async {
    await reachInCall();
    await c.setMic(false);
    expect(c.micOn, isFalse);
    expect(call.micCalls, [false]);
    await c.setMic(false); // không đổi → không gọi lại
    expect(call.micCalls, [false]);
    await c.setMic(true);
    expect(call.micCalls, [false, true]);
  });

  test('gợi ý vuốt chỉ hiện ở 3 cuộc gọi đầu', () async {
    var shown = 0;
    for (var i = 0; i < 4; i++) {
      await c.activate();
      if (i == 0) {
        ws.emit(const SessionReady('u1'));
        await _settle();
      }
      ws.emit(MatchFoundEvent(makeMatch(room: 'r_$i')));
      await _settle();
      call.emit(const RemoteVideoReady());
      await _settle();
      if (c.showSwipeHint) shown++;
      clock = clock.add(const Duration(seconds: 1));
      await c.next();
    }
    expect(shown, 3);
    expect(c.swipeHintsShown, 3);
  });
}

/// Ghi thứ tự call.leave và ws:call.next vào cùng một danh sách.
class _OrderedCall extends FakeCallService {
  _OrderedCall(this.log);
  final List<String> log;

  @override
  Future<void> leave() async {
    log.add('call.leave');
    // nhường vòng lặp sự kiện để lộ lỗi nếu controller không `await`
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _OrderedWs extends FakeWsClient {
  _OrderedWs(this.events);
  final List<String> events;

  @override
  void send(String type, [Map<String, dynamic> data = const <String, dynamic>{}]) {
    events.add('ws:$type');
    super.send(type, data);
  }
}
