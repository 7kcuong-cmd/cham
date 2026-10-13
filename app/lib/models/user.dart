/// Đối tượng `User` – API.md §0.2 (chỉ trả cho chính chủ).
class AppUser {
  const AppUser({
    required this.id,
    required this.displayName,
    required this.birthYear,
    required this.language,
    required this.status,
    required this.profileComplete,
    required this.createdAt,
    this.interests = const <String>[],
  });

  final String id;
  final String displayName;
  final int? birthYear;

  /// `vi` | `en`
  final String language;

  /// `active` | `underage_blocked` | `banned`
  final String status;
  final bool profileComplete;
  final DateTime? createdAt;

  /// Mã sở thích/nhóm (xem models/interests.dart). Server giới hạn 12.
  final List<String> interests;

  /// Phân tích JSON của server. Trường lạ bị bỏ qua (API.md §0). Thiếu/sai kiểu
  /// trường bắt buộc → [FormatException] (ApiClient đổi thành `INTERNAL`).
  factory AppUser.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final displayName = json['displayName'];
    final language = json['language'];
    final profileComplete = json['profileComplete'];
    if (id is! String || displayName is! String || language is! String) {
      throw const FormatException('Invalid User payload');
    }
    if (profileComplete is! bool) {
      throw const FormatException('Invalid User.profileComplete');
    }
    final birthYear = json['birthYear'];
    final createdAt = json['createdAt'];
    return AppUser(
      id: id,
      displayName: displayName,
      birthYear: birthYear is int ? birthYear : null,
      language: language,
      status: json['status'] is String ? json['status'] as String : 'active',
      profileComplete: profileComplete,
      createdAt: createdAt is String ? DateTime.tryParse(createdAt) : null,
      interests: json['interests'] is List
          ? (json['interests'] as List).whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  AppUser copyWith({String? displayName, String? language, int? birthYear, List<String>? interests}) {
    return AppUser(
      id: id,
      displayName: displayName ?? this.displayName,
      birthYear: birthYear ?? this.birthYear,
      language: language ?? this.language,
      status: status,
      profileComplete: profileComplete,
      createdAt: createdAt,
      interests: interests ?? this.interests,
    );
  }
}
