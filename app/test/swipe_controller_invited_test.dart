import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';
const _other = 'r_aaaaaaaa-5b7d-4c2a-9a51-0f6f0b8f7c11';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

/// Cuộc gọi lại bạn bè (T-108): `match.found` được nhận như cuộc gọi GĐ1 khi đã `expectInvitedCall`,
/// kể cả lúc người dùng ở tab khác (controller chưa `activate`).
void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakeTimers timers;
  late SwipeController c;

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    timers = FakeTimers();
    c = SwipeController(
      ws: ws,
      call: call,
      permissions: FakePermissionGateway(),
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => DateTime.utc(2026, 10, 6, 9),
    );
  });

  tearDown(() => c.dispose());

  test('đang inactive + expectInvitedCall + match.found → vào cuộc gọi, không gửi call.end', () async {
    expect(c.status, SwipeStatus.inactive);
    c.expectInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _room, peerName: 'Anna')));
    await _settle();

    expect(c.status, SwipeStatus.connecting);
    expect(c.roomName, _room);
    expect(c.peer?.displayName, 'Anna');
    expect(call.joins, hasLength(1));
    expect(ws.sentTypes, isNot(contains('call.end')));
  });

  test('không expect + inactive + match.found → báo server dọn phòng (call.end)', () async {
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();

    expect(c.status, SwipeStatus.inactive);
    expect(c.roomName, isNull);
    expect(call.joins, isEmpty);
    expect(ws.sent.single.type, 'call.end');
    expect(ws.sent.single.data['roomName'], _room);
  });

  test('clearInvitedCall trước match.found → như không expect', () async {
    c.expectInvitedCall();
    c.clearInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();

    expect(c.roomName, isNull);
    expect(ws.sentTypes, ['call.end']);
  });

  test('đang needsPermission (quyền cấp qua hộp thoại lời mời) + expect + match.found → vào cuộc gọi', () async {
    final perms = FakePermissionGateway(granted: false);
    final c2 = SwipeController(
      ws: ws,
      call: call,
      permissions: perms,
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => DateTime.utc(2026, 10, 6, 9),
    );
    addTearDown(c2.dispose);
    await c2.activate();
    expect(c2.status, SwipeStatus.needsPermission);

    c2.expectInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();

    expect(c2.status, SwipeStatus.connecting);
    expect(c2.isContactCall, isTrue);
  });

  test('clearInvitedCall khi đang ở hàng chờ → gửi lại queue.join (server đã rút mình khỏi hàng chờ lúc accept)', () async {
    ws.emitState(WsConnState.connected);
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();
    c.expectInvitedCall();
    c.clearInvitedCall();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('expect chỉ dùng một lần: match.found thứ hai bị từ chối', () async {
    c.expectInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _other)));
    await _settle();

    expect(c.roomName, _room);
    expect(ws.sent.where((m) => m.type == 'call.end').map((m) => m.data['roomName']), [_other]);
  });

  test('đang trong cuộc gọi: expect không chiếm phòng mới', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    call.emit(const RemoteVideoReady());
    await _settle();
    expect(c.status, SwipeStatus.inCall);

    c.expectInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _other)));
    await _settle();

    expect(c.roomName, _room);
    expect(ws.sent.where((m) => m.type == 'call.end').map((m) => m.data['roomName']), [_other]);
  });

  test('session.ready (kết nối lại) hủy kỳ vọng cuộc gọi mời', () async {
    c.expectInvitedCall();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();

    expect(c.roomName, isNull);
    expect(ws.sentTypes, ['call.end']);
  });

  test('roomName của cuộc gọi mời được RoomSource báo và listener được gọi', () async {
    var notified = 0;
    c.addListener(() => notified++);
    c.expectInvitedCall();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    expect(notified, greaterThan(0));
    expect(c.inCallOrConnecting, isTrue);
  });

  group('cuộc gọi danh bạ: vuốt = cúp máy', () {
    Future<void> inContactCall() async {
      c.expectInvitedCall();
      ws.emit(MatchFoundEvent(makeMatch(room: _room, peerName: 'Anna')));
      await _settle();
      call.emit(const RemoteVideoReady());
      await _settle();
    }

    test('next() gửi call.end, không call.next, không vào hàng chờ, phát sự kiện', () async {
      await inContactCall();
      expect(c.isContactCall, isTrue);
      expect(c.showSwipeHint, isTrue);
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);

      await c.next();
      await _settle();

      expect(c.status, SwipeStatus.inactive);
      expect(c.isContactCall, isFalse);
      expect(ws.sentTypes, contains('call.end'));
      expect(ws.sentTypes, isNot(contains('call.next')));
      expect(ws.sentTypes, isNot(contains('queue.join')));
      expect(ends.single.byPeer, isFalse);
    });

    test('peer_left → báo đối phương cúp máy, không tìm người mới', () async {
      await inContactCall();
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);

      ws.emit(const CallEnded(_room, CallEnded.peerLeft));
      await _settle();

      expect(c.status, SwipeStatus.inactive);
      expect(ends.single.byPeer, isTrue);
      expect(ends.single.peer.displayName, 'Anna');
      expect(ws.sentTypes, isNot(contains('queue.join')));
    });

    test('mất kết nối WS giữa cuộc gọi danh bạ → kết thúc, session.ready sau đó KHÔNG vào hàng chờ lướt', () async {
      await inContactCall();
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);
      final notices = <String>[];
      c.notices.listen(notices.add);
      ws.sent.clear();

      ws.emitState(WsConnState.connected);
      ws.emitState(WsConnState.disconnected);
      await _settle();
      // Rớt WS ngắn: vẫn giữ cuộc gọi, chờ nối lại.
      expect(c.status, SwipeStatus.inCall);
      expect(ends, isEmpty);
      timers.fire(SwipeController.contactResumeWindow); // hết thời gian chờ
      await _settle();
      expect(c.status, SwipeStatus.inactive);
      expect(c.isContactCall, isFalse);
      expect(ends.single.network, isTrue);
      expect(ends.single.byPeer, isFalse);
      expect(notices, contains('NETWORK'));

      ws.emitState(WsConnState.connected);
      ws.emit(const SessionReady('u1'));
      await _settle();
      expect(c.status, SwipeStatus.inactive);
      expect(ws.sentTypes, isNot(contains('queue.join')));
    });

    test('rớt WS ngắn rồi nối lại: gửi call.resume, giữ cuộc gọi, không vào hàng chờ', () async {
      await inContactCall();
      ws.sent.clear();
      ws.emitState(WsConnState.connected);
      ws.emitState(WsConnState.disconnected);
      await _settle();
      ws.emitState(WsConnState.connected);
      ws.emit(const SessionReady('u1'));
      await _settle();
      expect(ws.sentTypes, contains('call.resume'));
      expect(ws.sentTypes, isNot(contains('queue.join')));
      ws.emit(const CallResumed(_room));
      await _settle();
      timers.fire(SwipeController.contactResumeWindow); // đã hủy: không còn hiệu lực
      await _settle();
      expect(c.status, SwipeStatus.inCall);
      expect(c.isContactCall, isTrue);
    });

    test('call.resume bị từ chối (NOT_IN_CALL) → kết thúc do mất kết nối', () async {
      await inContactCall();
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);
      ws.emitState(WsConnState.connected);
      ws.emitState(WsConnState.disconnected);
      await _settle();
      ws.emitState(WsConnState.connected);
      ws.emit(const SessionReady('u1'));
      await _settle();
      ws.emit(const ServerError('NOT_IN_CALL', 'x'));
      await _settle();
      expect(c.status, SwipeStatus.inactive);
      expect(ends.single.network, isTrue);
    });

    test('call.ended lý do khác (không phải peer_left/you_left) vẫn báo kết thúc, không tìm người mới', () async {
      await inContactCall();
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);
      ws.emit(const CallEnded(_room, 'timeout'));
      await _settle();
      expect(ends, hasLength(1));
      expect(c.status, SwipeStatus.inactive);
      expect(ws.sentTypes, isNot(contains('queue.join')));
    });

    test('deactivate() (ra nền / rời tab) khi đang gọi danh bạ → phát sự kiện kết thúc', () async {
      await inContactCall();
      final ends = <ContactCallEnd>[];
      c.contactCallEnds.listen(ends.add);
      await c.deactivate();
      await _settle();
      expect(ends, hasLength(1));
      expect(ends.single.byPeer, isFalse);
      expect(ws.sentTypes, contains('call.end'));
    });

    test('cuộc gọi lướt thường vẫn đổi người khi vuốt', () async {
      await c.activate();
      ws.emit(const SessionReady('u1'));
      await _settle();
      ws.emit(MatchFoundEvent(makeMatch(room: _room)));
      await _settle();
      call.emit(const RemoteVideoReady());
      await _settle();
      expect(c.isContactCall, isFalse);
      await c.next();
      expect(ws.sentTypes, contains('call.next'));
      expect(c.status, SwipeStatus.searching);
    });
  });
}
