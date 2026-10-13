import 'dart:async';

import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/call_quality.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

String _room(int i) => 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c1$i';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeWsClient ws;
  late FakeCallService call;
  late FakePermissionGateway perms;
  late FakeTimers timers;
  late DateTime clock;
  late SwipeController c;
  late List<String> notices;
  late StreamSubscription<String> sub;

  setUp(() {
    ws = FakeWsClient();
    call = FakeCallService();
    perms = FakePermissionGateway();
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 5, 9);
    c = SwipeController(
      ws: ws,
      call: call,
      permissions: perms,
      refreshSession: () async {},
      timerFactory: timers.create,
      now: () => clock,
    );
    notices = <String>[];
    sub = c.notices.listen(notices.add);
  });

  tearDown(() async {
    await sub.cancel();
    c.dispose();
  });

  Future<void> matchAt(int i) async {
    ws.emit(MatchFoundEvent(makeMatch(room: _room(i))));
    await _settle();
  }

  Future<void> weakCall(int i) async {
    await matchAt(i);
    clock = clock.add(const Duration(seconds: 2)); // vượt swipeDebounce
    call.emit(const NetworkPoor());
    await _settle();
  }

  test('1-2 lần mạng yếu: báo và chuyển người khác; lần thứ 3: dừng hẳn, yêu cầu đổi mạng', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();

    await weakCall(1);
    expect(c.status, SwipeStatus.searching);
    expect(notices, ['SWIPE_RELAY_SKIPPED']);
    expect(ws.sentTypes.where((t) => t == 'call.next'), hasLength(1));

    await weakCall(2);
    expect(c.status, SwipeStatus.searching);
    expect(notices, ['SWIPE_RELAY_SKIPPED', 'SWIPE_RELAY_SKIPPED']);

    ws.sent.clear();
    await weakCall(3);
    expect(c.status, SwipeStatus.weakNetwork);
    expect(notices.last, 'SWIPE_WEAK_STOPPED');
    expect(c.weakStreak, SwipeController.maxWeakMatches);
    expect(ws.sentTypes, contains('call.end'));
    expect(ws.sentTypes, isNot(contains('call.next')));
    expect(ws.sentTypes, isNot(contains('queue.join')));

    // Trong lúc dừng, server gửi match mới: bỏ qua và dọn phòng.
    ws.sent.clear();
    await matchAt(4);
    expect(ws.sent.single.type, 'call.end');
    expect(c.status, SwipeStatus.weakNetwork);
  });

  test('thử lại sau khi đổi mạng: activate() xóa chuỗi và tìm người lại', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    await weakCall(1);
    await weakCall(2);
    await weakCall(3);
    expect(c.status, SwipeStatus.weakNetwork);

    ws.sent.clear();
    await c.activate();
    expect(c.weakStreak, 0);
    expect(c.status, SwipeStatus.searching);
    ws.emit(const SessionReady('u1'));
    await _settle();
    expect(ws.sentTypes, contains('queue.join'));
  });

  test('P2P ổn định ở giữa chừng xóa chuỗi: yếu, yếu, P2P tốt, yếu → vẫn chưa dừng', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    await weakCall(1);
    await weakCall(2);

    await matchAt(3);
    call.emit(const CallQualityChanged(level: CallQualityLevel.full, path: CallPath.p2p));
    await _settle();
    expect(c.weakStreak, 0);
    clock = clock.add(const Duration(seconds: 2));
    call.emit(const NetworkPoor());
    await _settle();
    expect(c.weakStreak, 1);
    expect(c.status, SwipeStatus.searching);
  });

  test('relay thông báo trạng thái chất lượng nhưng KHÔNG xóa chuỗi', () async {
    await c.activate();
    ws.emit(const SessionReady('u1'));
    await _settle();
    await weakCall(1);
    await matchAt(2);
    call.emit(const CallQualityChanged(level: CallQualityLevel.low, path: CallPath.relay));
    await _settle();
    expect(c.weakStreak, 1);
    expect(c.callQuality, CallQualityLevel.low);
  });
}
