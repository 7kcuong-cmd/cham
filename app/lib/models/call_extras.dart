import 'json_utils.dart';

/// Một bình luận trong cuộc gọi – `comment.sent` / `comment.received` (API-GD2-4 §3.3).
/// `text` là bản server đã lọc từ cấm.
class CallComment {
  const CallComment({
    required this.roomName,
    required this.commentId,
    required this.text,
    required this.sentAt,
  });

  final String roomName;
  final String commentId;
  final String text;
  final DateTime sentAt;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static CallComment? tryParse(Map<String, dynamic> data) {
    final roomName = data['roomName'];
    final commentId = data['commentId'];
    final text = data['text'];
    final sentAt = jsonDate(data['sentAt']);
    if (roomName is! String || commentId is! String || text is! String) return null;
    if (sentAt == null) return null;
    return CallComment(roomName: roomName, commentId: commentId, text: text, sentAt: sentAt);
  }
}

/// Quà rơi – `gift.drop` (API-GD2-4 §3.3). Chỉ người nhận thấy.
class GiftOffer {
  const GiftOffer({
    required this.giftId,
    required this.roomName,
    required this.points,
    required this.expiresAt,
  });

  final String giftId;
  final String roomName;
  final int points;
  final DateTime expiresAt;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static GiftOffer? tryParse(Map<String, dynamic> data) {
    final giftId = data['giftId'];
    final roomName = data['roomName'];
    final points = jsonInt(data['points']);
    final expiresAt = jsonDate(data['expiresAt']);
    if (giftId is! String || roomName is! String) return null;
    if (points == null || expiresAt == null) return null;
    return GiftOffer(giftId: giftId, roomName: roomName, points: points, expiresAt: expiresAt);
  }
}
