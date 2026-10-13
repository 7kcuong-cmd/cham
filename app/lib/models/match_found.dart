/// `Peer` – API.md §0.3: đúng 3 trường.
class Peer {
  const Peer({required this.id, required this.displayName, required this.language});

  final String id;
  final String displayName;
  final String language;

  /// Trả `null` nếu thiếu/sai kiểu trường bắt buộc.
  static Peer? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['displayName'];
    final lang = json['language'];
    if (id is! String || name is! String || lang is! String) return null;
    return Peer(id: id, displayName: name, language: lang);
  }

  @override
  bool operator ==(Object other) =>
      other is Peer &&
      other.id == id &&
      other.displayName == displayName &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, displayName, language);
}

/// Cấu hình P2P kèm `match.found` khi server chạy CALL_PROVIDER=p2p.
class RtcInfo {
  const RtcInfo({required this.initiator, required this.iceServers});

  /// Bên này tạo offer (đúng một trong hai bên).
  final bool initiator;

  /// Danh sách STUN/TURN theo dạng `RTCConfiguration.iceServers`.
  final List<Map<String, dynamic>> iceServers;

  static RtcInfo? tryParse(Object? json) {
    if (json is! Map) return null;
    final initiator = json['initiator'];
    final servers = json['iceServers'];
    if (initiator is! bool || servers is! List) return null;
    return RtcInfo(
      initiator: initiator,
      iceServers: servers.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList(growable: false),
    );
  }
}

/// Dữ liệu của `match.found` – API.md §2.4.
class MatchFound {
  const MatchFound({
    required this.roomName,
    required this.livekitUrl,
    required this.token,
    required this.tokenExpiresAt,
    required this.peer,
    this.rtc,
    this.commonInterests = const <String>[],
  });

  /// null khi server dùng LiveKit.
  final RtcInfo? rtc;

  /// Sở thích chung với người kia (mã).
  final List<String> commonInterests;

  final String roomName;
  final String livekitUrl;
  final String token;
  final DateTime tokenExpiresAt;
  final Peer peer;

  /// `data` của thông điệp. Trả `null` nếu thiếu/sai kiểu bất kỳ trường bắt buộc nào.
  static MatchFound? tryParse(Map<String, dynamic> data) {
    final roomName = data['roomName'];
    final url = data['livekitUrl'];
    final token = data['token'];
    final expires = data['tokenExpiresAt'];
    final peer = Peer.tryParse(data['peer']);
    if (roomName is! String || url is! String || token is! String) return null;
    if (expires is! String || peer == null) return null;
    final expiresAt = DateTime.tryParse(expires);
    if (expiresAt == null) return null;
    return MatchFound(
      roomName: roomName,
      livekitUrl: url,
      token: token,
      tokenExpiresAt: expiresAt,
      peer: peer,
      rtc: RtcInfo.tryParse(data['rtc']),
      commonInterests: data['commonInterests'] is List
          ? (data['commonInterests'] as List).whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }
}
