import 'dart:async';

import 'package:cham/models/invite.dart';
import 'package:cham/models/match_found.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/permission_gateway.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/invite_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _inviteId = '0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b';

void main() {
  late FakeWsClient ws;
  late FakePermissionGateway perms;
  late FakeRoom room;
  late FakeTimers timers;
  late DateTime clock;
  late StreamController<String> opened;
  late InviteController c;
  late List<InviteNotice> notices;
  late StreamSubscription<InviteNotice> noticeSub;

  OutgoingInvite outgoing({String inviteId = _inviteId, String contactId = kPeerId}) => OutgoingInvite(
        inviteId: inviteId,
        contactId: contactId,
        expiresAt: clock.add(const Duration(seconds: 30)),
        calleeOnline: true,
      );

  IncomingInvite incoming({String inviteId = _inviteId, int seconds = 30}) => IncomingInvite(
        inviteId: inviteId,
        from: const Peer(id: kSelfId, displayName: 'Minh', language: 'vi'),
        expiresAt: clock.add(Duration(seconds: seconds)),
      );

  setUp(() {
    ws = FakeWsClient()..emitState(WsConnState.connected);
    perms = FakePermissionGateway();
    room = FakeRoom();
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 6, 9, 30);
    opened = StreamController<String>.broadcast();
    c = InviteController(
      ws: ws,
      permissions: perms,
      swipe: room,
      openedInviteIds: opened.stream,
      timerFactory: timers.create,
      now: () => clock,
    );
    notices = <InviteNotice>[];
    noticeSub = c.notices.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
    c.dispose();
    await opened.close();
  });

  group('gọi đi', () {
    test('invite gửi call.invite {contactId}, trạng thái outgoing, rồi nhận call.inviting', () async {
      expect(await c.invite(makeContact()), isTrue);
      expect(ws.sent.single.type, 'call.invite');
      expect(ws.sent.single.data, {'contactId': kPeerId});
      expect(c.status, InviteStatus.outgoing);
      expect(c.outgoingContact?.displayName, 'Anna');
      expect(c.outgoingInvite, isNull);

      ws.emit(CallInviting(outgoing()));
      await _settle();
      expect(c.outgoingInvite?.inviteId, _inviteId);
      expect(room.expecting, isTrue); // match.found sắp tới là cuộc gọi lại bạn
    });

    test('call.invite.ended(timeout) → none + thông báo + thôi chờ cuộc gọi', () async {
      await c.invite(makeContact());
      ws.emit(CallInviting(outgoing()));
      await _settle();

      ws.emit(const CallInviteEnded(_inviteId, CallInviteEnded.timeout));
      await _settle();

      expect(c.status, InviteStatus.none);
      expect(room.expecting, isFalse);
      final n = notices.single as InviteEndedNotice;
      expect(n.reason, 'timeout');
      expect(n.outgoing, isTrue);
    });

    test('đang bận (busy) trả ngay thay cho call.inviting', () async {
      await c.invite(makeContact());
      ws.emit(const CallInviteEnded('uuid-moi', CallInviteEnded.busy));
      await _settle();
      expect(c.status, InviteStatus.none);
      expect((notices.single as InviteEndedNotice).reason, 'busy');
    });

    test('WS chưa kết nối → false + NETWORK, không gửi gì', () async {
      ws.emitState(WsConnState.disconnected);
      expect(await c.invite(makeContact()), isFalse);
      expect(ws.sent, isEmpty);
      expect((notices.single as InviteErrorNotice).code, 'NETWORK');
    });

    test('bị từ chối quyền camera/micro → false + PERMISSION_DENIED', () async {
      perms.granted = false;
      perms.requestOutcome = PermissionOutcome.denied;
      expect(await c.invite(makeContact()), isFalse);
      expect(ws.sent, isEmpty);
      await _settle();
      expect((notices.single as InviteErrorNotice).code, 'PERMISSION_DENIED');
    });

    test('đang có lời mời hoặc đang trong cuộc gọi → không gọi thêm', () async {
      await c.invite(makeContact());
      expect(await c.invite(makeContact(id: 'khac')), isFalse);
      expect(ws.sent, hasLength(1));

      c.cancel();
      room.busy = true;
      expect(await c.invite(makeContact()), isFalse);
    });

    test('cancel sau call.inviting gửi call.invite.cancel đúng inviteId', () async {
      await c.invite(makeContact());
      ws.emit(CallInviting(outgoing()));
      await _settle();
      c.cancel();
      expect(ws.sent.last.type, 'call.invite.cancel');
      expect(ws.sent.last.data, {'inviteId': _inviteId});
      expect(c.status, InviteStatus.none);
      expect(room.expecting, isFalse);
    });

    test('cancel trước khi server xác nhận → hủy ngay khi call.inviting tới', () async {
      await c.invite(makeContact());
      c.cancel();
      expect(ws.sent.map((m) => m.type), ['call.invite']); // chưa có inviteId để hủy
      ws.emit(CallInviting(outgoing()));
      await _settle();
      expect(ws.sent.last.type, 'call.invite.cancel');
      expect(ws.sent.last.data, {'inviteId': _inviteId});
      expect(c.status, InviteStatus.none);
    });

    test('server không trả lời call.inviting trong 8 s → NETWORK, none', () async {
      await c.invite(makeContact());
      timers.fire(InviteController.confirmTimeout);
      await _settle();
      expect(c.status, InviteStatus.none);
      expect((notices.single as InviteErrorNotice).code, 'NETWORK');
    });

    test('CONTACT_NOT_FOUND khi đang chờ xác nhận → thông báo + none', () async {
      await c.invite(makeContact());
      ws.emit(const ServerError('CONTACT_NOT_FOUND', 'x'));
      await _settle();
      expect(c.status, InviteStatus.none);
      expect((notices.single as InviteErrorNotice).code, 'CONTACT_NOT_FOUND');
    });

    test('mất kết nối WS khi đang gọi → none', () async {
      await c.invite(makeContact());
      ws.emit(CallInviting(outgoing()));
      await _settle();
      ws.emitState(WsConnState.disconnected);
      await _settle();
      expect(c.status, InviteStatus.none);
      expect(room.expecting, isFalse);
    });

    test('match.found khi đang gọi → xong lời mời (cuộc gọi do SwipeController lo)', () async {
      await c.invite(makeContact());
      ws.emit(CallInviting(outgoing()));
      await _settle();
      ws.emit(MatchFoundEvent(makeMatch()));
      await _settle();
      expect(c.status, InviteStatus.none);
      expect(notices, isEmpty);
    });

    test('lời mời đi hết hạn (quá expiresAt + 5 s) → timeout', () async {
      await c.invite(makeContact());
      ws.emit(CallInviting(outgoing()));
      await _settle();
      timers.fire(const Duration(seconds: 30) + InviteController.expiryGrace);
      await _settle();
      expect(c.status, InviteStatus.none);
      expect((notices.single as InviteEndedNotice).reason, 'timeout');
    });
  });

  group('gọi đến', () {
    test('call.invite → incoming; accept gửi call.accept đúng inviteId', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      expect(c.status, InviteStatus.incoming);
      expect(c.incoming?.from.displayName, 'Minh');

      await c.accept();
      expect(ws.sent.single.type, 'call.accept');
      expect(ws.sent.single.data, {'inviteId': _inviteId});
      expect(c.accepting, isTrue);
      expect(room.expecting, isTrue);

      ws.emit(MatchFoundEvent(makeMatch()));
      await _settle();
      expect(c.status, InviteStatus.none);
      expect(c.accepting, isFalse);
    });

    test('decline gửi call.decline và về none', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      c.decline();
      expect(ws.sent.single.type, 'call.decline');
      expect(ws.sent.single.data, {'inviteId': _inviteId});
      expect(c.status, InviteStatus.none);
    });

    test('accept khi bị từ chối quyền → gửi call.decline + PERMISSION_DENIED', () async {
      perms.granted = false;
      perms.requestOutcome = PermissionOutcome.denied;
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      await c.accept();
      expect(ws.sent.map((m) => m.type), ['call.decline']);
      expect(c.status, InviteStatus.none);
      await _settle();
      expect((notices.single as InviteErrorNotice).code, 'PERMISSION_DENIED');
    });

    test('người gọi hủy (cancelled) → none + thông báo', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      ws.emit(const CallInviteEnded(_inviteId, CallInviteEnded.cancelled));
      await _settle();
      expect(c.status, InviteStatus.none);
      final n = notices.single as InviteEndedNotice;
      expect(n.reason, 'cancelled');
      expect(n.outgoing, isFalse);
    });

    test('đang trong cuộc gọi → call.invite bị bỏ qua', () async {
      room.busy = true;
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      expect(c.status, InviteStatus.none);
    });

    test('nghe máy nhưng INVITE_NOT_FOUND → lời mời đã hết, thôi chờ match.found', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      await c.accept();
      ws.emit(const ServerError('INVITE_NOT_FOUND', 'x'));
      await _settle();
      expect(c.status, InviteStatus.none);
      expect(c.accepting, isFalse);
      expect(room.expecting, isFalse);
      expect(notices.single, isA<InviteEndedNotice>());
    });

    test('nghe máy mà 10 s không có match.found → bỏ', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      await c.accept();
      timers.fire(InviteController.acceptTimeout);
      expect(c.accepting, isFalse);
      expect(c.status, InviteStatus.none);
      expect(room.expecting, isFalse);
    });

    test('lời mời đến tự dọn sau expiresAt + 5 s', () async {
      ws.emit(CallInviteIncoming(incoming(seconds: 30)));
      await _settle();
      timers.fire(const Duration(seconds: 35));
      expect(c.status, InviteStatus.none);
    });

    test('đồng hồ máy lệch (expiresAt xa quá 120 s) → không hẹn dọn, chờ server báo', () async {
      ws.emit(CallInviteIncoming(incoming(seconds: 3600)));
      await _settle();
      expect(timers.timers, isEmpty);
      expect(c.status, InviteStatus.incoming);
    });

    test('hai lời mời: hiện cái mới nhất, trả lời xong thì còn cái cũ', () async {
      ws.emit(CallInviteIncoming(incoming(inviteId: 'cu')));
      ws.emit(CallInviteIncoming(incoming(inviteId: 'moi')));
      await _settle();
      expect(c.incoming?.inviteId, 'moi');
      c.decline();
      expect(c.incoming?.inviteId, 'cu');
    });
  });

  group('thông báo đẩy', () {
    test('bấm thông báo rồi server phát lại call.invite cùng id → incoming từ push', () async {
      opened.add(_inviteId);
      await _settle();
      expect(c.awaitedPushInviteId, _inviteId);

      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      expect(c.status, InviteStatus.incoming);
      expect(c.incomingFromPush, isTrue);
      expect(c.awaitedPushInviteId, isNull);
    });

    test('10 s không thấy lời mời phát lại → thôi chờ', () async {
      opened.add(_inviteId);
      await _settle();
      timers.fire(InviteController.pushWait);
      expect(c.awaitedPushInviteId, isNull);
      expect(c.status, InviteStatus.none);
    });

    test('lời mời đã tới trước khi bấm thông báo → đánh dấu từ push ngay', () async {
      ws.emit(CallInviteIncoming(incoming()));
      await _settle();
      expect(c.incomingFromPush, isFalse);
      opened.add(_inviteId);
      await _settle();
      expect(c.incomingFromPush, isTrue);
    });
  });
}
