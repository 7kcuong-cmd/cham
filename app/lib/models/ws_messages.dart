import 'dart:convert';

import 'call_extras.dart';
import 'contact.dart';
import 'game_state.dart';
import 'invite.dart';
import 'json_utils.dart';
import 'match_found.dart';

/// Thông điệp server → client – API.md §2.4 (GĐ1) và API-GD2-4.md §3.5 (GĐ2–4).
///
/// [ServerMessage.parse] không bao giờ ném: JSON sai, thiếu `type`/`data`, hoặc
/// thiếu trường bắt buộc đều cho [UnknownMessage].
sealed class ServerMessage {
  const ServerMessage({this.reqId});

  /// `reqId` server chép lại từ yêu cầu của client (nếu có).
  final String? reqId;

  static ServerMessage parse(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const UnknownMessage('');
    }
    if (decoded is! Map) return const UnknownMessage('');
    final type = decoded['type'];
    if (type is! String) return const UnknownMessage('');
    final dataRaw = decoded['data'];
    if (dataRaw is! Map) return UnknownMessage(type);
    final data = Map<String, dynamic>.from(dataRaw);
    final reqIdRaw = decoded['reqId'];
    final reqId = reqIdRaw is String ? reqIdRaw : null;

    switch (type) {
      case 'call.missed':
        final mId = data['inviteId'];
        final mFrom = data['fromUserId'];
        final mAt = _date(data['at']);
        if (mId is! String || mFrom is! String || mAt == null) return UnknownMessage(type);
        final mName = data['name'];
        return CallMissed(mId, mFrom, mName is String ? mName : '', mAt, reqId: reqId);
      case 'dm.received':
        final dmId = data['msgId'];
        final dmFrom = data['fromUserId'];
        final dmBody = data['body'];
        final dmAt = _date(data['sentAt']);
        if (dmId is! String || dmFrom is! String || dmBody is! String || dmAt == null) return UnknownMessage(type);
        return DmReceived(dmId, dmFrom, dmBody, dmAt, reqId: reqId);
      case 'dm.sent':
        final sentId = data['msgId'];
        if (sentId is! String) return UnknownMessage(type);
        return DmSent(sentId, data['delivered'] == true, reqId: reqId);
      case 'dm.read':
        final readBy = data['byUserId'];
        final readIds = data['msgIds'];
        if (readBy is! String || readIds is! List) return UnknownMessage(type);
        return DmRead(readBy, <String>[for (final x in readIds) if (x is String) x], reqId: reqId);
      case 'dm.typing':
        final typingFrom = data['fromUserId'];
        if (typingFrom is! String) return UnknownMessage(type);
        return DmTyping(typingFrom, reqId: reqId);
      case 'rtc.fallback':
        final fbRoom = data['roomName'];
        final fbUrl = data['livekitUrl'];
        final fbToken = data['token'];
        if (fbRoom is! String || fbUrl is! String || fbToken is! String) return UnknownMessage(type);
        return RtcFallback(fbRoom, fbUrl, fbToken, reqId: reqId);
      case 'dm.rtc':
        final rtcFrom = data['fromUserId'];
        final rtcKind = data['kind'];
        final rtcPayload = data['payload'];
        if (rtcFrom is! String || rtcKind is! String) return UnknownMessage(type);
        return DmRtcSignal(
          rtcFrom,
          rtcKind,
          rtcPayload is Map ? Map<String, dynamic>.from(rtcPayload) : const <String, dynamic>{},
          reqId: reqId,
        );
      case 'rtc.signal':
        final sigRoom = data['roomName'];
        final sigKind = data['kind'];
        final sigPayload = data['payload'];
        if (sigRoom is! String || sigKind is! String) return UnknownMessage(type);
        return RtcSignal(
          sigRoom,
          sigKind,
          sigPayload is Map ? Map<String, dynamic>.from(sigPayload) : const <String, dynamic>{},
          reqId: reqId,
        );
      case 'session.ready':
        final userId = data['userId'];
        if (userId is! String) return UnknownMessage(type);
        return SessionReady(userId, reqId: reqId);
      case 'queue.joined':
        final queuedAt = _date(data['queuedAt']);
        if (queuedAt == null) return UnknownMessage(type);
        return QueueJoined(queuedAt, reqId: reqId);
      case 'queue.left':
        return QueueLeft(reqId: reqId);
      case 'match.found':
        final match = MatchFound.tryParse(data);
        if (match == null) return UnknownMessage(type);
        return MatchFoundEvent(match, reqId: reqId);
      case 'call.resumed':
        final r = data['roomName'];
        if (r is! String) return UnknownMessage(type);
        return CallResumed(r, reqId: reqId);
      case 'call.ended':
        final roomName = data['roomName'];
        final reason = data['reason'];
        if (roomName is! String || reason is! String) return UnknownMessage(type);
        return CallEnded(roomName, reason, reqId: reqId);
      case 'error':
        final code = data['code'];
        if (code is! String) return UnknownMessage(type);
        final message = data['message'];
        final retry = data['retryAfterSec'];
        return ServerError(
          code,
          message is String ? message : '',
          retryAfterSec: retry is num ? retry.toInt() : null,
          reqId: reqId,
        );
      // --- GĐ2: danh bạ, gọi lại bạn (API-GD2-4 §3.2, §3.5) ---
      // (Tên biến cục bộ khác nhau giữa các case để không phụ thuộc quy tắc phạm vi của switch.)
      case 'contact.pending':
        final pendingRoom = data['roomName'];
        if (pendingRoom is! String) return UnknownMessage(type);
        return ContactPending(pendingRoom, reqId: reqId);
      case 'contact.requested':
        final requestedRoom = data['roomName'];
        if (requestedRoom is! String) return UnknownMessage(type);
        return ContactRequested(requestedRoom, reqId: reqId);
      case 'contact.added':
        final addedRoom = data['roomName'];
        final addedContact = Contact.tryParse(data['contact']);
        if (addedRoom is! String || addedContact == null) return UnknownMessage(type);
        return ContactAdded(addedRoom, addedContact, reqId: reqId);
      case 'contact.request':
        final reqFrom = data['userId'];
        final reqName = data['displayName'];
        if (reqFrom is! String || reqName is! String) return UnknownMessage(type);
        return ContactRequestIncoming(reqFrom, reqName, reqId: reqId);
      case 'contact.new':
        final newFrom = data['userId'];
        final newName = data['displayName'];
        if (newFrom is! String || newName is! String) return UnknownMessage(type);
        return ContactNew(newFrom, newName, reqId: reqId);
      case 'call.invite':
        final incomingInvite = IncomingInvite.tryParse(data);
        if (incomingInvite == null) return UnknownMessage(type);
        return CallInviteIncoming(incomingInvite, reqId: reqId);
      case 'call.inviting':
        final outgoingInvite = OutgoingInvite.tryParse(data);
        if (outgoingInvite == null) return UnknownMessage(type);
        return CallInviting(outgoingInvite, reqId: reqId);
      case 'call.invite.ended':
        final endedInviteId = data['inviteId'];
        final endedReason = data['reason'];
        if (endedInviteId is! String || endedReason is! String) return UnknownMessage(type);
        return CallInviteEnded(endedInviteId, endedReason, reqId: reqId);
      // --- GĐ3: bình luận, tim, quà, ví (API-GD2-4 §3.3, §3.5) ---
      case 'comment.sent':
        final sentComment = CallComment.tryParse(data);
        if (sentComment == null) return UnknownMessage(type);
        return CommentSent(sentComment, reqId: reqId);
      case 'comment.received':
        final receivedComment = CallComment.tryParse(data);
        if (receivedComment == null) return UnknownMessage(type);
        return CommentReceived(receivedComment, reqId: reqId);
      case 'heart.received':
        final heartRoom = data['roomName'];
        final heartCount = jsonInt(data['count']);
        if (heartRoom is! String || heartCount == null) return UnknownMessage(type);
        return HeartReceived(heartRoom, heartCount, reqId: reqId);
      case 'gift.drop':
        final droppedGift = GiftOffer.tryParse(data);
        if (droppedGift == null) return UnknownMessage(type);
        return GiftDrop(droppedGift, reqId: reqId);
      case 'gift.claimed':
        final claimedGiftId = data['giftId'];
        final claimedPoints = jsonInt(data['points']);
        final claimedBalance = jsonInt(data['balance']);
        if (claimedGiftId is! String || claimedPoints == null || claimedBalance == null) {
          return UnknownMessage(type);
        }
        return GiftClaimed(claimedGiftId, claimedPoints, claimedBalance, reqId: reqId);
      case 'wallet.updated':
        final walletBalance = jsonInt(data['balance']);
        final walletDelta = jsonInt(data['delta']);
        final walletReason = data['reason'];
        if (walletBalance == null || walletDelta == null || walletReason is! String) {
          return UnknownMessage(type);
        }
        return WalletUpdated(walletBalance, walletDelta, walletReason, reqId: reqId);
      // --- GĐ4: mini game (API-GD2-4 §3.4, §3.5) ---
      case 'game.invite':
        final gameInvite = GameInvite.tryParse(data);
        if (gameInvite == null) return UnknownMessage(type);
        return GameInviteReceived(gameInvite, reqId: reqId);
      case 'game.state':
        final gameState = GameState.tryParse(data);
        if (gameState == null) return UnknownMessage(type);
        return GameStateMessage(gameState, reqId: reqId);
      case 'game.end':
        final gameEnd = GameEnd.tryParse(data);
        if (gameEnd == null) return UnknownMessage(type);
        return GameEndMessage(gameEnd, reqId: reqId);
      default:
        return UnknownMessage(type);
    }
  }

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
}

final class SessionReady extends ServerMessage {
  const SessionReady(this.userId, {super.reqId});
  final String userId;
}

final class QueueJoined extends ServerMessage {
  const QueueJoined(this.queuedAt, {super.reqId});
  final DateTime queuedAt;
}

final class QueueLeft extends ServerMessage {
  const QueueLeft({super.reqId});
}

/// `rtc.fallback` – server mở phòng LiveKit dự phòng cho cuộc gọi P2P không nối được.
final class RtcFallback extends ServerMessage {
  const RtcFallback(this.roomName, this.livekitUrl, this.token, {super.reqId});
  final String roomName;
  final String livekitUrl;
  final String token;
}

/// `rtc.signal` – tín hiệu WebRTC (offer/answer/candidate/bye) do đối phương gửi, server chỉ chuyển tiếp.
/// `dm.rtc` – tín hiệu WebRTC để nối kênh nhắn tin trực tiếp với một người bạn.
final class DmRtcSignal extends ServerMessage {
  const DmRtcSignal(this.fromUserId, this.kind, this.payload, {super.reqId});
  final String fromUserId;
  final String kind;
  final Map<String, dynamic> payload;
}

final class RtcSignal extends ServerMessage {
  const RtcSignal(this.roomName, this.kind, this.payload, {super.reqId});
  final String roomName;
  final String kind;
  final Map<String, dynamic> payload;
}

/// `match.found`. (Tên `MatchFoundEvent` để không trùng lớp dữ liệu [MatchFound].)
final class MatchFoundEvent extends ServerMessage {
  const MatchFoundEvent(this.match, {super.reqId});
  final MatchFound match;
}

/// Server nhận lại cuộc gọi danh bạ sau khi WebSocket rớt ngắn.
final class CallResumed extends ServerMessage {
  const CallResumed(this.roomName, {super.reqId});
  final String roomName;
}

final class CallEnded extends ServerMessage {
  const CallEnded(this.roomName, this.reason, {super.reqId});
  final String roomName;

  /// `you_left` | `you_next` | `peer_left` | `blocked` | `server_shutdown`
  /// (giữ nguyên chuỗi để chịu được giá trị mới trong tương lai).
  final String reason;

  static const youLeft = 'you_left';
  static const youNext = 'you_next';
  static const peerLeft = 'peer_left';
  static const blocked = 'blocked';
  static const serverShutdown = 'server_shutdown';
}

final class ServerError extends ServerMessage {
  const ServerError(this.code, this.message, {this.retryAfterSec, super.reqId});
  final String code;

  /// Chỉ cho lập trình viên/log; không bao giờ hiển thị.
  final String message;
  final int? retryAfterSec;
}

// --- GĐ2 ---------------------------------------------------------------------

/// `contact.pending` – mình đã bấm Thêm bạn, chờ người kia.
final class ContactPending extends ServerMessage {
  const ContactPending(this.roomName, {super.reqId});
  final String roomName;
}

/// `contact.requested` – người kia đã bấm Thêm bạn trước.
final class ContactRequested extends ServerMessage {
  const ContactRequested(this.roomName, {super.reqId});
  final String roomName;
}

/// `contact.added` – hai người đã thành bạn; [contact] là hồ sơ của người kia.
final class ContactAdded extends ServerMessage {
  const ContactAdded(this.roomName, this.contact, {super.reqId});
  final String roomName;
  final Contact contact;
}

/// `contact.request` – có người gửi lời mời kết bạn (ngoài cuộc gọi).
final class ContactRequestIncoming extends ServerMessage {
  const ContactRequestIncoming(this.userId, this.displayName, {super.reqId});
  final String userId;
  final String displayName;
}

/// `contact.new` – người khác vừa thêm mình (quét QR của họ hoặc chấp nhận lời mời của mình).
final class ContactNew extends ServerMessage {
  const ContactNew(this.userId, this.displayName, {super.reqId});
  final String userId;
  final String displayName;
}

/// `call.invite` (server → người được mời). Tên khác `call.invite` phía client gửi.
final class CallInviteIncoming extends ServerMessage {
  const CallInviteIncoming(this.invite, {super.reqId});
  final IncomingInvite invite;
}

/// `call.inviting` – server đã nhận lời mời gọi đi của mình.
final class CallInviting extends ServerMessage {
  const CallInviting(this.invite, {super.reqId});
  final OutgoingInvite invite;
}

/// `call.invite.ended`.
final class CallInviteEnded extends ServerMessage {
  const CallInviteEnded(this.inviteId, this.reason, {super.reqId});
  final String inviteId;

  /// `declined` | `cancelled` | `timeout` | `busy` | `failed`
  /// (giữ nguyên chuỗi để chịu giá trị mới trong tương lai).
  final String reason;

  static const declined = 'declined';
  static const cancelled = 'cancelled';
  static const timeout = 'timeout';
  static const busy = 'busy';
  static const failed = 'failed';
}

// --- GĐ3 ---------------------------------------------------------------------

/// `comment.sent` – bản của mình, `text` đã lọc từ cấm.
final class CommentSent extends ServerMessage {
  const CommentSent(this.comment, {super.reqId});
  final CallComment comment;
}

/// `comment.received` – bình luận của đối phương.
final class CommentReceived extends ServerMessage {
  const CommentReceived(this.comment, {super.reqId});
  final CallComment comment;
}

/// `heart.received` – đối phương thả [count] tim.
final class HeartReceived extends ServerMessage {
  const HeartReceived(this.roomName, this.count, {super.reqId});
  final String roomName;
  final int count;
}

/// `gift.drop` – server cho một món quà rơi.
final class GiftDrop extends ServerMessage {
  const GiftDrop(this.gift, {super.reqId});
  final GiftOffer gift;
}

/// `gift.claimed` – đã nhận quà; [balance] là số dư mới do server tính.
final class GiftClaimed extends ServerMessage {
  const GiftClaimed(this.giftId, this.points, this.balance, {super.reqId});
  final String giftId;
  final int points;
  final int balance;
}

/// `wallet.updated` – số dư mới; app chỉ ghi nhận, không tự cộng/trừ.
final class WalletUpdated extends ServerMessage {
  const WalletUpdated(this.balance, this.delta, this.reason, {super.reqId});
  final int balance;
  final int delta;
  final String reason;
}

// --- GĐ4 ---------------------------------------------------------------------

/// `game.invite` (server → người được mời).
final class GameInviteReceived extends ServerMessage {
  const GameInviteReceived(this.invite, {super.reqId});
  final GameInvite invite;
}

/// `game.state`.
final class GameStateMessage extends ServerMessage {
  const GameStateMessage(this.state, {super.reqId});
  final GameState state;
}

/// `game.end`.
final class GameEndMessage extends ServerMessage {
  const GameEndMessage(this.end, {super.reqId});
  final GameEnd end;
}

/// `call.missed` – cuộc gọi nhỡ từ bạn (server gửi lại mỗi lần đăng nhập cho tới khi máy gửi `call.missed.ack`).
final class CallMissed extends ServerMessage {
  const CallMissed(this.inviteId, this.fromUserId, this.name, this.at, {super.reqId});
  final String inviteId;
  final String fromUserId;
  final String name;
  final DateTime at;
}

/// `dm.received` – tin nhắn (bản mã) từ bạn; máy nhận giải mã, lưu rồi gửi `dm.ack`.
final class DmReceived extends ServerMessage {
  const DmReceived(this.msgId, this.fromUserId, this.body, this.sentAt, {super.reqId});
  final String msgId;
  final String fromUserId;
  final String body;
  final DateTime sentAt;
}

/// `dm.sent` – server đã nhận tin của mình (`delivered`: người nhận đang online và đã được đẩy ngay).
final class DmSent extends ServerMessage {
  const DmSent(this.msgId, this.delivered, {super.reqId});
  final String msgId;
  final bool delivered;
}

/// `dm.read` – người kia đã đọc các tin `msgIds` của mình.
final class DmRead extends ServerMessage {
  const DmRead(this.byUserId, this.msgIds, {super.reqId});
  final String byUserId;
  final List<String> msgIds;
}

/// `dm.typing` – người kia đang nhập.
final class DmTyping extends ServerMessage {
  const DmTyping(this.fromUserId, {super.reqId});
  final String fromUserId;
}

final class UnknownMessage extends ServerMessage {
  const UnknownMessage(this.type);
  final String type;
}

/// Mã hóa thông điệp client → server: `{type, reqId?, data}` (API.md §2.2).
String encodeClient(String type, Map<String, dynamic> data, [String? reqId]) {
  return jsonEncode(<String, dynamic>{
    'type': type,
    if (reqId != null) 'reqId': reqId,
    'data': data,
  });
}
