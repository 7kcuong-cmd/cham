/// `BlockedUser` – API-GD2-4 §1.1. `displayName` rỗng nếu người đó không còn tồn tại.
class BlockedUser {
  const BlockedUser({
    required this.userId,
    required this.displayName,
    required this.createdAt,
  });

  final String userId;
  final String displayName;
  final DateTime createdAt;

  /// Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static BlockedUser? tryParse(Object? json) {
    if (json is! Map) return null;
    final userId = json['userId'];
    final name = json['displayName'];
    final created = json['createdAt'];
    if (userId is! String || name is! String || created is! String) return null;
    final createdAt = DateTime.tryParse(created);
    if (createdAt == null) return null;
    return BlockedUser(userId: userId, displayName: name, createdAt: createdAt);
  }

  @override
  bool operator ==(Object other) =>
      other is BlockedUser &&
      other.userId == userId &&
      other.displayName == displayName &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(userId, displayName, createdAt);
}
