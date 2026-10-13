import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/call_extras.dart';
import '../models/ws_messages.dart';
import '../services/call_service.dart';
import '../services/ws_client.dart';
import '../utils/countdown.dart';
import 'call_context.dart';
import 'swipe_controller.dart' show TimerFactory;

/// Bình luận đang hiện trên màn hình. [mine] = do mình gửi (căn phải).
class ShownComment {
  const ShownComment(this.comment, {required this.mine});

  final CallComment comment;
  final bool mine;
}

/// Phần "thêm" của cuộc gọi: bình luận, tim, quà rơi – T-209 (API-GD2-4 §3.3).
///
/// Mọi thứ gắn với `roomName` hiện tại: đổi phòng hoặc hết cuộc gọi thì xóa sạch; thông điệp của
/// phòng khác bị bỏ qua. Controller này KHÔNG giữ số dư: điểm chỉ hiển thị qua `WalletController`.
class CallExtrasController extends ChangeNotifier {
  CallExtrasController({
    required WsClient ws,
    required RoomSource room,
    TimerFactory? timerFactory,
    DateTime Function()? now,
    CallService? call,
  })  : _ws = ws,
        _call = call,
        _room = room,
        _timerFactory = timerFactory ?? Timer.new,
        _now = now ?? DateTime.now {
    _msgSub = _ws.messages.listen(_onMessage);
    _dataSub = _call?.dataMessages.listen(_onData);
    _room.addListener(_onRoomChanged);
    _lastRoom = _room.roomName;
  }

  /// Gộp chạm tim: mỗi cửa sổ 1 giây gửi tối đa một `heart.send`.
  static const heartWindow = Duration(seconds: 1);

  /// `count` tối đa của một thông điệp (API-GD2-4 §3.1).
  static const maxHeartsPerMessage = 10;

  /// Số chạm chờ gửi tối đa (chặn tăng vô hạn khi bấm liên tục).
  static const maxPendingHearts = 100;

  static const commentLifetime = Duration(seconds: 6);
  static const maxVisibleComments = 6;

  /// Độ dài tối đa (code point) của bình luận gửi đi: ngưỡng 4 x 200 của server. Giới hạn 200
  /// grapheme do ô nhập (`maxLength`) và server cùng kiểm.
  static const maxCommentCodePoints = 800;

  static const claimedDisplay = Duration(milliseconds: 1500);
  static const deltaDisplay = Duration(milliseconds: 1500);

  /// Quà không có `expiresAt` hợp lý (đồng hồ máy lệch): ẩn sau chừng này.
  static const giftFallbackLifetime = Duration(seconds: 30);

  final WsClient _ws;
  final RoomSource _room;
  final TimerFactory _timerFactory;
  final DateTime Function() _now;

  final CallService? _call;
  StreamSubscription<Map<String, dynamic>>? _dataSub;
  final List<DateTime> _incomingStamps = <DateTime>[];
  int _directSeq = 0;
  late final StreamSubscription<ServerMessage> _msgSub;
  final StreamController<int> _incomingHearts = StreamController<int>.broadcast();
  final StreamController<String> _notices = StreamController<String>.broadcast();

  final List<ShownComment> _comments = <ShownComment>[];
  final Map<String, Timer> _commentTimers = <String, Timer>{};

  int _pendingHearts = 0;
  Timer? _heartTimer;

  final List<GiftOffer> _gifts = <GiftOffer>[];
  final Map<String, Timer> _giftTimers = <String, Timer>{};
  String? _claimingGiftId;
  ({String giftId, int points})? _claimed;
  Timer? _claimedTimer;

  int? _recentDelta;
  Timer? _deltaTimer;

  String? _lastRoom;
  bool _disposed = false;

  List<ShownComment> get comments => List<ShownComment>.unmodifiable(_comments);

  /// Mỗi lần nhận `heart.received` phát `count` (UI cho `count` trái tim bay).
  Stream<int> get incomingHearts => _incomingHearts.stream;

  /// Mã lỗi đáng báo người dùng (`GIFT_NOT_FOUND`).
  Stream<String> get notices => _notices.stream;

  /// Số lần chạm tim đang chờ gửi (chỉ để test/gỡ lỗi).
  int get pendingHearts => _pendingHearts;

  /// Quà đang chờ nhận (cũ nhất trước).
  List<GiftOffer> get gifts => List<GiftOffer>.unmodifiable(_gifts);
  GiftOffer? get currentGift => _gifts.isEmpty ? null : _gifts.first;

  /// `giftId` đã gửi `gift.claim` và chờ `gift.claimed`.
  String? get claimingGiftId => _claimingGiftId;

  /// Quà vừa nhận xong (hiện [claimedDisplay]); `null` nếu không có.
  ({String giftId, int points})? get claimedGift => _claimed;

  /// `delta` dương của `wallet.updated` vừa tới (hiện [deltaDisplay]).
  int? get recentDelta => _recentDelta;

  // --- hành động -------------------------------------------------------------------

  /// Gửi bình luận. Trả `false` (không gửi) nếu rỗng sau `trim()`, quá dài, có ký tự điều khiển
  /// hoặc không ở trong cuộc gọi. Bình luận chỉ hiện khi server trả `comment.sent`.
  bool sendComment(String raw) {
    final room = _room.roomName;
    if (room == null) return false;
    final text = raw.trim();
    if (text.isEmpty || text.runes.length > maxCommentCodePoints) return false;
    if (_controlChars.hasMatch(text)) return false;
    // Ưu tiên kênh trực tiếp giữa hai máy (DTLS): server không thấy nội dung. Chưa mở thì đi đường server.
    final id = 'd${_now().microsecondsSinceEpoch}-${++_directSeq}';
    if (_call?.sendData(<String, dynamic>{'t': 'comment', 'id': id, 'text': text}) ?? false) {
      _addComment(CallComment(roomName: room, commentId: id, text: text, sentAt: _now()), mine: true);
      return true;
    }
    _ws.send('comment.send', <String, dynamic>{'roomName': room, 'text': text});
    return true;
  }

  static final RegExp _controlChars = RegExp(r'[\u0000-\u001F\u007F]');

  /// Một lần chạm tim. Gộp trong [heartWindow]; thừa hơn [maxHeartsPerMessage] dồn sang lượt sau
  /// (mỗi lượt cách nhau [heartWindow]) nên không bao giờ quá 1 thông điệp/giây.
  void tapHeart() {
    if (_room.roomName == null) return;
    if (_pendingHearts < maxPendingHearts) _pendingHearts++;
    _heartTimer ??= _timerFactory(heartWindow, _flushHearts);
  }

  void _flushHearts() {
    _heartTimer = null;
    final room = _room.roomName;
    if (room == null || _pendingHearts == 0) {
      _pendingHearts = 0;
      return;
    }
    final count = _pendingHearts < maxHeartsPerMessage ? _pendingHearts : maxHeartsPerMessage;
    _pendingHearts -= count;
    _ws.send('heart.send', <String, dynamic>{'roomName': room, 'count': count});
    if (_pendingHearts > 0) _heartTimer = _timerFactory(heartWindow, _flushHearts);
  }

  /// Nhận quà. Số dư chỉ đổi khi `gift.claimed` / `wallet.updated` tới.
  void claimGift(String giftId) {
    if (_claimingGiftId != null) return;
    if (!_gifts.any((g) => g.giftId == giftId)) return;
    _claimingGiftId = giftId;
    _ws.send('gift.claim', <String, dynamic>{'giftId': giftId});
    _notify();
  }

  // --- kênh trực tiếp ----------------------------------------------------------------

  /// Bình luận từ đối phương qua DataChannel. Dữ liệu từ máy lạ nên kiểm tra chặt và giới hạn tốc độ.
  void _onData(Map<String, dynamic> m) {
    if (m['t'] != 'comment') return;
    final room = _room.roomName;
    final id = m['id'];
    final text = m['text'];
    if (room == null || id is! String || id.isEmpty || id.length > 64 || text is! String) return;
    final t = text.trim();
    if (t.isEmpty || t.runes.length > maxCommentCodePoints || _controlChars.hasMatch(t)) return;
    final now = _now();
    _incomingStamps.removeWhere((x) => now.difference(x) > const Duration(seconds: 10));
    if (_incomingStamps.length >= 5) return;
    _incomingStamps.add(now);
    _addComment(CallComment(roomName: room, commentId: 'p$id', text: t, sentAt: now), mine: false);
  }

  // --- WebSocket -------------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case final CommentSent e:
        _addComment(e.comment, mine: true);
      case final CommentReceived e:
        _addComment(e.comment, mine: false);
      case final HeartReceived e:
        if (e.roomName != _room.roomName) return;
        if (!_incomingHearts.isClosed) _incomingHearts.add(e.count);
      case final GiftDrop e:
        _addGift(e.gift);
      case final GiftClaimed e:
        _onClaimed(e);
      case final WalletUpdated e:
        _onWalletUpdated(e);
      case final ServerError e:
        if (e.code == 'GIFT_NOT_FOUND') _onGiftGone();
      case final CallEnded e:
        // Chỉ phòng hiện tại; `SwipeController` đã đưa `roomName` về `null` khi đó (xem
        // [_onRoomChanged]); ở đây dọn sớm để không phụ thuộc thứ tự subscriber.
        if (e.roomName == _room.roomName) _clearCallState();
      default:
        break;
    }
  }

  void _addComment(CallComment c, {required bool mine}) {
    if (c.roomName != _room.roomName) return;
    if (_comments.any((x) => x.comment.commentId == c.commentId)) return;
    _comments.add(ShownComment(c, mine: mine));
    _commentTimers[c.commentId] = _timerFactory(commentLifetime, () => _expireComment(c.commentId));
    while (_comments.length > maxVisibleComments) {
      final dropped = _comments.removeAt(0);
      _commentTimers.remove(dropped.comment.commentId)?.cancel();
    }
    _notify();
  }

  void _expireComment(String commentId) {
    _commentTimers.remove(commentId);
    final before = _comments.length;
    _comments.removeWhere((x) => x.comment.commentId == commentId);
    if (_comments.length != before) _notify();
  }

  void _addGift(GiftOffer g) {
    if (g.roomName != _room.roomName) return;
    if (_gifts.any((x) => x.giftId == g.giftId)) return;
    final remaining = countdownRemaining(g.expiresAt, _now());
    // Quà đã quá hạn theo đồng hồ máy hợp lý: không hiện. (Đồng hồ lệch nhiều → `null` → vẫn hiện
    // và để server quyết định; server trả `GIFT_NOT_FOUND` nếu hết hạn.)
    if (g.expiresAt.isBefore(_now()) && _now().difference(g.expiresAt) < maxCountdown) return;
    _gifts.add(g);
    _giftTimers[g.giftId] =
        _timerFactory(remaining ?? giftFallbackLifetime, () => _expireGift(g.giftId));
    _notify();
  }

  void _expireGift(String giftId) {
    _giftTimers.remove(giftId);
    final before = _gifts.length;
    _gifts.removeWhere((x) => x.giftId == giftId);
    if (_claimingGiftId == giftId) _claimingGiftId = null;
    if (_gifts.length != before) _notify();
  }

  void _onClaimed(GiftClaimed e) {
    _removeGift(e.giftId);
    if (_claimingGiftId == e.giftId) _claimingGiftId = null;
    _claimed = (giftId: e.giftId, points: e.points);
    _claimedTimer?.cancel();
    _claimedTimer = _timerFactory(claimedDisplay, () {
      _claimedTimer = null;
      _claimed = null;
      _notify();
    });
    _notify();
  }

  void _onGiftGone() {
    final id = _claimingGiftId;
    if (id == null) return; // lỗi của lần claim cũ: bỏ qua
    _removeGift(id);
    _claimingGiftId = null;
    if (!_notices.isClosed) _notices.add('GIFT_NOT_FOUND');
    _notify();
  }

  void _onWalletUpdated(WalletUpdated e) {
    if (e.delta <= 0) return;
    _recentDelta = e.delta;
    _deltaTimer?.cancel();
    _deltaTimer = _timerFactory(deltaDisplay, () {
      _deltaTimer = null;
      _recentDelta = null;
      _notify();
    });
    _notify();
  }

  void _removeGift(String giftId) {
    _gifts.removeWhere((x) => x.giftId == giftId);
    _giftTimers.remove(giftId)?.cancel();
  }

  // --- vòng đời phòng ----------------------------------------------------------------

  void _onRoomChanged() {
    final room = _room.roomName;
    if (room == _lastRoom) return;
    _lastRoom = room;
    _clearCallState();
  }

  void _clearCallState() {
    for (final t in _commentTimers.values) {
      t.cancel();
    }
    _commentTimers.clear();
    _comments.clear();
    _heartTimer?.cancel();
    _heartTimer = null;
    _pendingHearts = 0;
    for (final t in _giftTimers.values) {
      t.cancel();
    }
    _giftTimers.clear();
    _gifts.clear();
    _claimingGiftId = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _room.removeListener(_onRoomChanged);
    _msgSub.cancel();
    _dataSub?.cancel();
    for (final t in _commentTimers.values) {
      t.cancel();
    }
    for (final t in _giftTimers.values) {
      t.cancel();
    }
    _heartTimer?.cancel();
    _claimedTimer?.cancel();
    _deltaTimer?.cancel();
    _incomingHearts.close();
    _notices.close();
    super.dispose();
  }
}
