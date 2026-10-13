/// Kết quả tìm người dùng (`GET /v1/users/search`).
class UserHit {
  const UserHit({required this.id, required this.displayName, required this.relation});

  final String id;
  final String displayName;

  /// `none` | `contact` | `requested` (mình đã mời) | `incoming` (họ đã mời mình)
  final String relation;

  static UserHit? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['displayName'];
    final rel = json['relation'];
    if (id is! String || name is! String) return null;
    return UserHit(id: id, displayName: name, relation: rel is String ? rel : 'none');
  }

  UserHit withRelation(String r) => UserHit(id: id, displayName: displayName, relation: r);
}

/// Lời mời kết bạn đang chờ mình trả lời.
class ContactRequest {
  const ContactRequest({required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  static ContactRequest? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['userId'];
    final name = json['displayName'];
    if (id is! String || name is! String) return null;
    return ContactRequest(userId: id, displayName: name);
  }
}

/// Mình cho phép người khác tìm bằng gì (`/v1/me/discovery`).
class DiscoveryPrefs {
  const DiscoveryPrefs({required this.byEmail, required this.byPhone, required this.byName});

  final bool byEmail;
  final bool byPhone;
  final bool byName;

  static DiscoveryPrefs fromJson(Map<String, dynamic> j) => DiscoveryPrefs(
        byEmail: j['byEmail'] != false,
        byPhone: j['byPhone'] != false,
        byName: j['byName'] == true,
      );
}

/// Cách nhận mã trong QR: `c1.<id>.<tag>` hoặc `cham://add/<mã>`.
String? parseContactCodeFromScan(String raw) {
  final s = raw.trim().replaceFirst(RegExp(r'^cham://add/', caseSensitive: false), '');
  return RegExp(r'^c1\.[A-Za-z0-9_-]{4,64}\.[A-Za-z0-9_-]{12}$').hasMatch(s) ? s : null;
}
