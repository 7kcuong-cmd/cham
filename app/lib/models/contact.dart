/// `Contact` – API-GD2-4 §1.1 (chỉ trả cho chủ danh bạ).
///
/// Không có `birthYear`, `firebaseUid`, `status`.
class Contact {
  const Contact({
    required this.id,
    required this.displayName,
    required this.language,
    required this.online,
    required this.addedAt,
  });

  final String id;
  final String displayName;

  /// `vi` | `en`
  final String language;

  /// Có phiên WS và ứng dụng đang ở foreground (API-GD2-4 §3.2 `presence.update`).
  final bool online;
  final DateTime addedAt;

  /// Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static Contact? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['displayName'];
    final lang = json['language'];
    final online = json['online'];
    final added = json['addedAt'];
    if (id is! String || name is! String || lang is! String) return null;
    if (online is! bool || added is! String) return null;
    final addedAt = DateTime.tryParse(added);
    if (addedAt == null) return null;
    return Contact(
      id: id,
      displayName: name,
      language: lang,
      online: online,
      addedAt: addedAt,
    );
  }

  Contact copyWith({bool? online}) {
    return Contact(
      id: id,
      displayName: displayName,
      language: language,
      online: online ?? this.online,
      addedAt: addedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Contact &&
      other.id == id &&
      other.displayName == displayName &&
      other.language == language &&
      other.online == online &&
      other.addedAt == addedAt;

  @override
  int get hashCode => Object.hash(id, displayName, language, online, addedAt);
}
