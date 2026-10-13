import 'package:cham/models/match_found.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/security/ice_guard.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/security/shield_controller.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

const _room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakeTimers timers;
  late DateTime clock;
  late ShieldController shield;
  late List<Peer> blocked;
  late SwipeController c;
  late List<String> notices;

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 10, 9);
    shield = ShieldController(now: () => clock);
    blocked = <Peer>[];
    c = SwipeController(
      ws: ws,
      call: call,
      permissions: FakePermissionGateway(),
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => clock,
      autoBlock: (p) async => blocked.add(p),
      shield: shield,
    );
    notices = <String>[];
    c.notices.listen(notices.add);
  });

  tearDown(() => c.dispose());

  Future<void> reachInCall() async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.emit(MatchFoundEvent(makeMatch(room: _room)));
    await _settle();
    call.emit(const RemoteVideoReady());
    await _settle();
  }

  test('Khi video đối phương lên, app báo rtc.state=connected cho server', () async {
    await reachInCall();
    final st = ws.sent.firstWhere((m) => m.type == 'rtc.state');
    expect(st.data['state'], 'connected');
    expect(st.data['roomName'], _room);
  });

  test('PeerAnomaly: báo server (không IP), cảnh báo, chặn, rồi sang người khác', () async {
    await reachInCall();
    ws.sent.clear();

    call.emit(const PeerAnomaly([AbuseSignal('cand_private', 1)]));
    await _settle();

    final abuse = ws.sent.firstWhere((m) => m.type == 'rtc.abuse');
    expect(abuse.data['roomName'], _room);
    expect(abuse.data['signals'], [
      {'code': 'cand_private', 'count': 1}
    ]);
    expect(ws.sentTypes, contains('call.next'));
    expect(notices, contains('PEER_ANOMALY'));
    expect(blocked.single.id, 'Q9pLm2vX0aB7cWn3RtY1kZ');
    expect(call.leaveCalls, greaterThan(0));
  });

  test('PeerAnomaly không bị swipeDebounce chặn', () async {
    await reachInCall();
    await c.next(); // vừa vuốt xong
    ws.emit(MatchFoundEvent(makeMatch(room: 'r_aaaaaaaa-5b7d-4c2a-9a51-0f6f0b8f7c11')));
    await _settle();
    ws.sent.clear();
    call.emit(const PeerAnomaly([AbuseSignal('cand_flood', 1)]));
    await _settle();
    expect(ws.sentTypes, containsAll(['rtc.abuse', 'call.next']));
  });

  test('lần thứ hai trong 15 phút: tạm dừng ghép rồi tự vào hàng chờ lại', () async {
    await reachInCall();
    call.emit(const PeerAnomaly([AbuseSignal('cand_private', 1)]));
    await _settle();

    ws.emit(MatchFoundEvent(makeMatch(room: 'r_bbbbbbbb-5b7d-4c2a-9a51-0f6f0b8f7c11')));
    await _settle();
    ws.sent.clear();
    call.emit(const PeerAnomaly([AbuseSignal('cand_private', 1)]));
    await _settle();

    expect(ws.sentTypes, contains('rtc.abuse'));
    expect(ws.sentTypes, contains('call.end'));
    expect(ws.sentTypes, isNot(contains('call.next')));
    expect(notices, contains('SHIELD_PAUSE'));
    expect(c.status, SwipeStatus.searching);
    expect(timers.activeCount(ShieldController.pauseDuration), 1);

    ws.sent.clear();
    clock = clock.add(const Duration(seconds: 61));
    timers.fire(ShieldController.pauseDuration);
    await _settle();
    expect(ws.sentTypes, ['queue.join']);
  });

  test('không có cuộc gọi hiện tại thì bỏ qua', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    ws.sent.clear();
    call.emit(const PeerAnomaly([AbuseSignal('cand_private', 1)]));
    await _settle();
    expect(ws.sent, isEmpty);
    expect(blocked, isEmpty);
  });
}
