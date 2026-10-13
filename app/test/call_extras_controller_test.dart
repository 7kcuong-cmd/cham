import 'dart:async';

import 'package:cham/models/call_extras.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/call_extras_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _oneSecond = Duration(seconds: 1);

void main() {
  late FakeWsClient ws;
  late FakeRoom room;
  late FakeTimers timers;
  late DateTime clock;
  late CallExtrasController c;

  CallComment comment(String id, {String text = 'Xin chào', String roomName = kRoom}) => CallComment(
        roomName: roomName,
        commentId: id,
        text: text,
        sentAt: DateTime.utc(2026, 10, 6, 9, 30, 5),
      );

  GiftOffer gift(String id, {int points = 12, int seconds = 20, String roomName = kRoom}) => GiftOffer(
        giftId: id,
        roomName: roomName,
        points: points,
        expiresAt: clock.add(Duration(seconds: seconds)),
      );

  List<SentMessage> hearts() => ws.sent.where((m) => m.type == 'heart.send').toList();

  setUp(() {
    ws = FakeWsClient();
    room = FakeRoom(room: kRoom);
    timers = FakeTimers();
    clock = DateTime.utc(2026, 10, 6, 9, 30);
    c = CallExtrasController(ws: ws, room: room, timerFactory: timers.create, now: () => clock);
  });

  tearDown(() => c.dispose());

  group('gộp chạm tim', () {
    test('25 lần chạm trong 1 giây → đúng 3 thông điệp: count 10, 10, 5 ở mốc 1 s, 2 s, 3 s', () {
      for (var i = 0; i < 25; i++) {
        c.tapHeart();
      }
      expect(hearts(), isEmpty); // chưa tới mốc 1 s
      expect(c.pendingHearts, 25);
      expect(timers.activeCount(_oneSecond), 1); // chỉ MỘT hẹn giờ cho cả 25 lần chạm

      timers.fire(_oneSecond); // mốc 1 s
      expect(hearts().map((m) => m.data['count']), [10]);
      expect(c.pendingHearts, 15);

      timers.fire(_oneSecond); // mốc 2 s
      expect(hearts().map((m) => m.data['count']), [10, 10]);

      timers.fire(_oneSecond); // mốc 3 s
      expect(hearts().map((m) => m.data['count']), [10, 10, 5]);
      expect(c.pendingHearts, 0);

      timers.fire(_oneSecond); // hết dồn: không gửi thêm
      expect(hearts(), hasLength(3));
      expect(timers.activeCount(_oneSecond), 0);
    });

    test('mỗi thông điệp mang đúng roomName và count 1..10', () {
      c.tapHeart();
      c.tapHeart();
      c.tapHeart();
      timers.fire(_oneSecond);
      final m = hearts().single;
      expect(m.data, {'roomName': kRoom, 'count': 3});
    });

    test('một lần chạm duy nhất → count 1', () {
      c.tapHeart();
      timers.fire(_oneSecond);
      expect(hearts().single.data['count'], 1);
    });

    test('ngoài cuộc gọi: không gửi, không hẹn giờ', () {
      room.leave();
      c.tapHeart();
      expect(timers.timers, isEmpty);
      expect(ws.sent, isEmpty);
    });

    test('rời phòng giữa chừng → bỏ số chạm đang chờ, không gửi sang phòng khác', () {
      c.tapHeart();
      c.tapHeart();
      room.enter('r_moi');
      timers.fire(_oneSecond);
      expect(hearts(), isEmpty);
      expect(c.pendingHearts, 0);
    });

    test('chạm sau khi đã gửi một lượt thì mở cửa sổ mới', () {
      c.tapHeart();
      timers.fire(_oneSecond);
      c.tapHeart();
      c.tapHeart();
      expect(timers.activeCount(_oneSecond), 1);
      timers.fire(_oneSecond);
      expect(hearts().map((m) => m.data['count']), [1, 2]);
    });
  });

  group('bình luận', () {
    test('sendComment gửi comment.send sau trim; rỗng/điều khiển/quá dài thì không', () {
      expect(c.sendComment('   '), isFalse);
      expect(c.sendComment('dòng 1\ndòng 2'), isFalse);
      expect(c.sendComment('a' * (CallExtrasController.maxCommentCodePoints + 1)), isFalse);
      expect(ws.sent, isEmpty);

      expect(c.sendComment('  Xin chào  '), isTrue);
      expect(ws.sent.single.type, 'comment.send');
      expect(ws.sent.single.data, {'roomName': kRoom, 'text': 'Xin chào'});
    });

    test('ngoài cuộc gọi: không gửi', () {
      room.leave();
      expect(c.sendComment('hi'), isFalse);
      expect(ws.sent, isEmpty);
    });

    test('comment.sent của mình hiện căn phải; comment.received của người kia', () async {
      ws.emit(CommentSent(comment('c1', text: 'của mình')));
      ws.emit(CommentReceived(comment('c2', text: 'của bạn')));
      await _settle();
      expect(c.comments.map((s) => (s.comment.text, s.mine)), [('của mình', true), ('của bạn', false)]);
    });

    test('bình luận của phòng khác bị bỏ qua', () async {
      ws.emit(CommentReceived(comment('c1', roomName: 'r_cu')));
      await _settle();
      expect(c.comments, isEmpty);
    });

    test('trùng commentId chỉ hiện một lần', () async {
      ws.emit(CommentReceived(comment('c1')));
      ws.emit(CommentReceived(comment('c1')));
      await _settle();
      expect(c.comments, hasLength(1));
    });

    test('tự ẩn sau 6 s', () async {
      ws.emit(CommentReceived(comment('c1')));
      await _settle();
      expect(c.comments, hasLength(1));
      timers.fire(CallExtrasController.commentLifetime);
      expect(c.comments, isEmpty);
    });

    test('tối đa 6 bình luận: cái cũ nhất bị đẩy ra', () async {
      for (var i = 1; i <= 8; i++) {
        ws.emit(CommentReceived(comment('c$i', text: 'n$i')));
      }
      await _settle();
      expect(c.comments, hasLength(CallExtrasController.maxVisibleComments));
      expect(c.comments.first.comment.text, 'n3');
      expect(c.comments.last.comment.text, 'n8');
    });

    test('đổi phòng hoặc hết cuộc gọi → xóa sạch', () async {
      ws.emit(CommentReceived(comment('c1')));
      await _settle();
      room.leave();
      expect(c.comments, isEmpty);

      room.enter(kRoom);
      ws.emit(CommentReceived(comment('c2')));
      await _settle();
      room.enter('r_moi');
      expect(c.comments, isEmpty);
    });

    test('call.ended của phòng hiện tại dọn sớm', () async {
      ws.emit(CommentReceived(comment('c1')));
      await _settle();
      ws.emit(const CallEnded(kRoom, CallEnded.peerLeft));
      await _settle();
      expect(c.comments, isEmpty);
    });
  });

  group('tim nhận', () {
    test('heart.received của phòng hiện tại phát count; phòng khác bỏ qua', () async {
      final got = <int>[];
      final sub = c.incomingHearts.listen(got.add);
      ws.emit(const HeartReceived(kRoom, 3));
      ws.emit(const HeartReceived('r_khac', 5));
      await _settle();
      expect(got, [3]);
      await sub.cancel();
    });
  });

  group('quà rơi', () {
    test('gift.drop hiện; hết hạn thì tự ẩn', () async {
      ws.emit(GiftDrop(gift('g1', seconds: 20)));
      await _settle();
      expect(c.currentGift?.giftId, 'g1');
      expect(c.currentGift?.points, 12);
      timers.fire(const Duration(seconds: 20));
      expect(c.currentGift, isNull);
    });

    test('claimGift gửi gift.claim; gift.claimed → ẩn thẻ, hiện +điểm 1,5 s', () async {
      ws.emit(GiftDrop(gift('g1')));
      await _settle();
      c.claimGift('g1');
      expect(ws.sent.single.type, 'gift.claim');
      expect(ws.sent.single.data, {'giftId': 'g1'});
      expect(c.claimingGiftId, 'g1');
      c.claimGift('g1'); // bấm lại khi đang chờ: không gửi lần hai
      expect(ws.sent, hasLength(1));

      ws.emit(const GiftClaimed('g1', 12, 152));
      await _settle();
      expect(c.currentGift, isNull);
      expect(c.claimingGiftId, isNull);
      expect(c.claimedGift?.points, 12);

      timers.fire(CallExtrasController.claimedDisplay);
      expect(c.claimedGift, isNull);
    });

    test('claimGift quà không tồn tại → không gửi', () {
      c.claimGift('khong-co');
      expect(ws.sent, isEmpty);
    });

    test('GIFT_NOT_FOUND khi đang nhận → gỡ quà + thông báo', () async {
      final notices = <String>[];
      final sub = c.notices.listen(notices.add);
      ws.emit(GiftDrop(gift('g1')));
      await _settle();
      c.claimGift('g1');
      ws.emit(const ServerError('GIFT_NOT_FOUND', 'x'));
      await _settle();
      expect(c.currentGift, isNull);
      expect(notices, ['GIFT_NOT_FOUND']);
      await sub.cancel();
    });

    test('quà của phòng khác bị bỏ qua; quà đã quá hạn không hiện', () async {
      ws.emit(GiftDrop(gift('g1', roomName: 'r_khac')));
      ws.emit(GiftDrop(gift('g2', seconds: -10)));
      await _settle();
      expect(c.gifts, isEmpty);
    });

    test('đồng hồ máy lệch nhiều → vẫn hiện, ẩn bằng hẹn giờ dự phòng', () async {
      ws.emit(GiftDrop(gift('g1', seconds: 3600)));
      await _settle();
      expect(c.currentGift, isNotNull);
      timers.fire(CallExtrasController.giftFallbackLifetime);
      expect(c.currentGift, isNull);
    });

    test('hết cuộc gọi → xóa quà đang chờ', () async {
      ws.emit(GiftDrop(gift('g1')));
      await _settle();
      room.leave();
      expect(c.gifts, isEmpty);
    });
  });

  group('số dư không do client tính', () {
    test('wallet.updated delta > 0 hiện chip 1,5 s; delta <= 0 thì không', () async {
      ws.emit(const WalletUpdated(152, -5, 'unlock'));
      await _settle();
      expect(c.recentDelta, isNull);

      ws.emit(const WalletUpdated(164, 12, 'gift'));
      await _settle();
      expect(c.recentDelta, 12);
      timers.fire(CallExtrasController.deltaDisplay);
      expect(c.recentDelta, isNull);
    });
  });

  test('dispose hủy mọi hẹn giờ (không gửi tim sau khi hủy)', () {
    c.tapHeart();
    c.dispose();
    // tearDown gọi dispose lần hai: ChangeNotifier chấp nhận qua cờ _disposed của controller.
    timers.fire(_oneSecond);
    expect(hearts(), isEmpty);
    c = CallExtrasController(ws: ws, room: room, timerFactory: timers.create, now: () => clock);
  });
}
