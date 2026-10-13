import 'match_found.dart';

/// Lời mời gọi đến – `call.invite` (server → client), API-GD2-4 §3.5.
class IncomingInvite {
  const IncomingInvite({
    required this.inviteId,
    required this.from,
    required this.expiresAt,
  });

  final String inviteId;
  final Peer from;
  final DateTime expiresAt;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static IncomingInvite? tryParse(Map<String, dynamic> data) {
    final inviteId = data['inviteId'];
    final from = Peer.tryParse(data['from']);
    final expires = data['expiresAt'];
    if (inviteId is! String || from == null || expires is! String) return null;
    final expiresAt = DateTime.tryParse(expires);
    if (expiresAt == null) return null;
    return IncomingInvite(inviteId: inviteId, from: from, expiresAt: expiresAt);
  }
}

/// Lời mời gọi đi đã được server nhận – `call.inviting`.
class OutgoingInvite {
  const OutgoingInvite({
    required this.inviteId,
    required this.contactId,
    required this.expiresAt,
    required this.calleeOnline,
  });

  final String inviteId;
  final String contactId;
  final DateTime expiresAt;
  final bool calleeOnline;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static OutgoingInvite? tryParse(Map<String, dynamic> data) {
    final inviteId = data['inviteId'];
    final contactId = data['contactId'];
    final expires = data['expiresAt'];
    final calleeOnline = data['calleeOnline'];
    if (inviteId is! String || contactId is! String) return null;
    if (expires is! String || calleeOnline is! bool) return null;
    final expiresAt = DateTime.tryParse(expires);
    if (expiresAt == null) return null;
    return OutgoingInvite(
      inviteId: inviteId,
      contactId: contactId,
      expiresAt: expiresAt,
      calleeOnline: calleeOnline,
    );
  }
}
