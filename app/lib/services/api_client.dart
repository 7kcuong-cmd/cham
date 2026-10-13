import 'dart:convert';
import '../models/discovery.dart';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/api_error.dart';
import '../models/avatar.dart';
import '../models/blocked_user.dart';
import '../models/contact.dart';
import '../models/game_state.dart';
import '../models/user.dart';
import '../models/wallet.dart';
import 'auth_service.dart';

/// Client REST – API.md §1 (GĐ1) và API-GD2-4.md §2 (GĐ2–4). Mọi đường dẫn/JSON theo hợp đồng.
class ApiClient {
  ApiClient({
    required String baseUrl,
    required AuthService auth,
    http.Client? client,
    Duration timeout = const Duration(seconds: 15),
  })  : _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _auth = auth,
        _client = client ?? http.Client(),
        _timeout = timeout;

  final String _baseUrl;
  final AuthService _auth;
  final http.Client _client;
  final Duration _timeout;

  /// `POST /v1/auth/session` – token nằm trong body, không có header Authorization.
  Future<({AppUser user, bool isNew})> createSession({required String language}) {
    return _withAuthRetry((token) async {
      final json = await _send(
        'POST',
        '/v1/auth/session',
        body: <String, dynamic>{'idToken': token, 'language': language},
      );
      return (user: _userFrom(json), isNew: json['isNew'] == true);
    });
  }

  /// `GET /v1/me`
  Future<AppUser> getMe() {
    return _withAuthRetry((token) async {
      return _userFrom(await _send('GET', '/v1/me', bearer: token));
    });
  }

  /// `PUT /v1/me` – cần ít nhất một trường.
  Future<AppUser> updateMe({int? birthYear, String? language, String? displayName, List<String>? interests, String? avatarPreset}) {
    final body = <String, dynamic>{
      if (birthYear != null) 'birthYear': birthYear,
      if (language != null) 'language': language,
      if (displayName != null) 'displayName': displayName,
      if (interests != null) 'interests': interests,
      if (avatarPreset != null) 'avatarPreset': avatarPreset,
    };
    if (body.isEmpty) {
      throw ArgumentError('updateMe needs at least one field');
    }
    return _withAuthRetry((token) async {
      return _userFrom(await _send('PUT', '/v1/me', bearer: token, body: body));
    });
  }

  /// `GET /v1/users/:id/avatar` → ảnh đại diện (null nếu chưa đặt).
  Future<Avatar?> getAvatar(String userId) {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/users/${Uri.encodeComponent(userId)}/avatar', bearer: token);
      return Avatar.tryParse(json['avatar']);
    });
  }

  /// `PUT /v1/me/avatar` – JPEG thô ≤ 24 KB, ≤ 512 px.
  Future<Avatar?> uploadAvatar(Uint8List jpeg) {
    return _withAuthRetry((token) async {
      final http.Response res;
      try {
        res = await _client
            .put(
              Uri.parse('$_baseUrl/v1/me/avatar'),
              headers: <String, String>{'authorization': 'Bearer $token', 'content-type': 'image/jpeg'},
              body: jpeg,
            )
            .timeout(_timeout);
      } on Exception {
        throw const ApiException(code: 'NETWORK');
      }
      if (res.statusCode != 200) throw _errorFrom(res);
      final decoded = _decode(res);
      return decoded is Map ? Avatar.tryParse(decoded['avatar']) : null;
    });
  }

  /// `DELETE /v1/me/avatar`
  Future<void> deleteAvatar() {
    return _withAuthRetry((token) async {
      await _send('DELETE', '/v1/me/avatar', bearer: token);
    });
  }

  /// `PUT /v1/me/key` – đăng ký khóa công khai (base64, 32 byte) cho tin nhắn mã hóa đầu cuối.
  Future<void> putChatKey(String publicKeyB64) {
    return _withAuthRetry((token) async {
      await _send('PUT', '/v1/me/key', bearer: token, body: <String, dynamic>{'publicKey': publicKeyB64});
    });
  }

  /// `GET /v1/users/:id/key` – khóa công khai của người khác (null nếu họ chưa đăng ký).
  Future<String?> getChatKey(String userId) {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/users/${Uri.encodeComponent(userId)}/key', bearer: token);
      final k = json['publicKey'];
      return k is String ? k : null;
    });
  }

  /// `GET /v1/me/phone` – { enabled, verified }. Máy chủ chưa cấu hình thì enabled=false.
  Future<({bool enabled, bool verified})> getPhoneStatus() {
    return _withAuthRetry((token) async {
      final j = await _send('GET', '/v1/me/phone', bearer: token);
      return (enabled: j['enabled'] == true, verified: j['verified'] == true);
    });
  }

  /// `POST /v1/me/phone/challenge` – xin mã; người dùng nhắn `text` tới `destNumber`.
  Future<({String destNumber, String text, DateTime expiresAt})> startPhoneChallenge() {
    return _withAuthRetry((token) async {
      final j = await _send('POST', '/v1/me/phone/challenge', bearer: token, body: <String, dynamic>{});
      return (
        destNumber: '${j['destNumber']}',
        text: '${j['text']}',
        expiresAt: DateTime.tryParse('${j['expiresAt']}') ?? DateTime.now().add(const Duration(minutes: 10)),
      );
    });
  }

  /// `GET /v1/config` – cấu hình từ xa (nhạc chờ, chuông, chủ đề, kho game). Công khai, không cần token.
  Future<Map<String, dynamic>> getRemoteConfig() => _send('GET', '/v1/config');

  /// `POST /v1/blocks` (201 hoặc 200 đều là thành công).
  Future<void> block(String userId) {
    return _withAuthRetry((token) async {
      await _send(
        'POST',
        '/v1/blocks',
        bearer: token,
        body: <String, dynamic>{'userId': userId},
      );
    });
  }

  /// `POST /v1/reports` (201). `note` rỗng sau trim thì bỏ qua.
  Future<void> report({
    required String userId,
    required String reason,
    String? roomName,
    String? note,
  }) {
    final trimmedNote = note?.trim();
    final body = <String, dynamic>{
      'userId': userId,
      'reason': reason,
      if (roomName != null) 'roomName': roomName,
      if (trimmedNote != null && trimmedNote.isNotEmpty) 'note': trimmedNote,
    };
    return _withAuthRetry((token) async {
      await _send('POST', '/v1/reports', bearer: token, body: body);
    });
  }

  // --- GĐ2: danh bạ, danh sách chặn, push token (API-GD2-4 §2.1) ------------------

  /// `GET /v1/contacts` – sắp `addedAt` giảm dần. Phần tử sai dạng bị bỏ qua.
  Future<List<Contact>> getContacts() {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/contacts', bearer: token);
      return _listOf(json, 'contacts', Contact.tryParse);
    });
  }

  /// `DELETE /v1/contacts/:userId` – xóa hai chiều, luôn 204.
  Future<void> removeContact(String userId) {
    return _withAuthRetry((token) async {
      await _send('DELETE', '/v1/contacts/${Uri.encodeComponent(userId)}', bearer: token);
    });
  }

  // --- Thêm liên hệ: QR, tìm kiếm, lời mời ---------------------------------------

  /// `GET /v1/me/contact-code` – mã (đưa vào QR) để người khác quét.
  Future<({String code, String link})> getContactCode() {
    return _withAuthRetry((token) async {
      final j = await _send('GET', '/v1/me/contact-code', bearer: token);
      final code = j['code'];
      final link = j['link'];
      if (code is! String) throw const ApiException(code: 'INTERNAL');
      return (code: code, link: link is String ? link : 'cham://add/$code');
    });
  }

  /// `POST /v1/contacts/by-code` – quét QR: thành bạn hai chiều ngay.
  Future<Contact> addContactByCode(String code) {
    return _withAuthRetry((token) async {
      final j = await _send('POST', '/v1/contacts/by-code', bearer: token, body: <String, dynamic>{'code': code});
      final c = Contact.tryParse(j['contact']);
      if (c == null) throw const ApiException(code: 'INTERNAL');
      return c;
    });
  }

  /// `GET /v1/users/search?q=` – email, số điện thoại (khớp đúng) hoặc đầu tên.
  Future<List<UserHit>> searchUsers(String q) {
    return _withAuthRetry((token) async {
      final j = await _send('GET', '/v1/users/search?q=${Uri.encodeQueryComponent(q)}', bearer: token);
      return _listOf(j, 'users', UserHit.tryParse);
    });
  }

  /// `POST /v1/contacts/requests` → `sent` | `accepted` | `contact`.
  Future<String> sendContactRequest(String userId) {
    return _withAuthRetry((token) async {
      final j = await _send('POST', '/v1/contacts/requests', bearer: token, body: <String, dynamic>{'userId': userId});
      final st = j['status'];
      return st is String ? st : 'sent';
    });
  }

  /// `GET /v1/contacts/requests` – lời mời đang chờ mình.
  Future<List<ContactRequest>> getContactRequests() {
    return _withAuthRetry((token) async {
      final j = await _send('GET', '/v1/contacts/requests', bearer: token);
      return _listOf(j, 'requests', ContactRequest.tryParse);
    });
  }

  /// `POST /v1/contacts/requests/:userId/accept`.
  Future<Contact> acceptContactRequest(String userId) {
    return _withAuthRetry((token) async {
      final j = await _send('POST', '/v1/contacts/requests/${Uri.encodeComponent(userId)}/accept', bearer: token, body: <String, dynamic>{});
      final c = Contact.tryParse(j['contact']);
      if (c == null) throw const ApiException(code: 'INTERNAL');
      return c;
    });
  }

  /// `DELETE /v1/contacts/requests/:userId` – từ chối lời mời đến hoặc hủy lời mời đã gửi.
  Future<void> declineContactRequest(String userId) {
    return _withAuthRetry((token) async {
      await _send('DELETE', '/v1/contacts/requests/${Uri.encodeComponent(userId)}', bearer: token);
    });
  }

  Future<DiscoveryPrefs> getDiscovery() {
    return _withAuthRetry((token) async => DiscoveryPrefs.fromJson(await _send('GET', '/v1/me/discovery', bearer: token)));
  }

  Future<DiscoveryPrefs> setDiscovery({bool? byEmail, bool? byPhone, bool? byName}) {
    return _withAuthRetry((token) async {
      final body = <String, dynamic>{
        if (byEmail != null) 'byEmail': byEmail,
        if (byPhone != null) 'byPhone': byPhone,
        if (byName != null) 'byName': byName,
      };
      return DiscoveryPrefs.fromJson(await _send('PUT', '/v1/me/discovery', bearer: token, body: body));
    });
  }

  /// `GET /v1/blocks` – người mình đã chặn.
  Future<List<BlockedUser>> getBlocks() {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/blocks', bearer: token);
      return _listOf(json, 'blocks', BlockedUser.tryParse);
    });
  }

  /// `DELETE /v1/blocks/:userId` – bỏ chặn, luôn 204 (không khôi phục danh bạ).
  Future<void> unblock(String userId) {
    return _withAuthRetry((token) async {
      await _send('DELETE', '/v1/blocks/${Uri.encodeComponent(userId)}', bearer: token);
    });
  }

  /// `PUT /v1/me/push-token` (204). [platform] là `android` hoặc `ios`.
  Future<void> setPushToken(String token, String platform) {
    return _withAuthRetry((bearer) async {
      await _send(
        'PUT',
        '/v1/me/push-token',
        bearer: bearer,
        body: <String, dynamic>{'token': token, 'platform': platform},
      );
    });
  }

  /// `DELETE /v1/me/push-token` với body `{token}` (204). Chỉ xóa nếu token khớp.
  Future<void> deletePushToken(String token) {
    return _withAuthRetry((bearer) async {
      await _send(
        'DELETE',
        '/v1/me/push-token',
        bearer: bearer,
        body: <String, dynamic>{'token': token},
      );
    });
  }

  // --- GĐ3: ví, sổ cái, mở khóa (API-GD2-4 §2.2) ------------------------------------

  /// `GET /v1/wallet`
  Future<Wallet> getWallet() {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/wallet', bearer: token);
      final wallet = Wallet.tryParse(json['wallet']);
      if (wallet == null) throw const ApiException(code: 'INTERNAL');
      return wallet;
    });
  }

  /// `GET /v1/wallet/ledger?limit=&before=` – `limit` 1–100, `before` = `seq` (chỉ lấy `seq < before`).
  Future<LedgerPage> getLedger({int limit = 20, int? before}) {
    return _withAuthRetry((token) async {
      final json = await _send(
        'GET',
        '/v1/wallet/ledger',
        bearer: token,
        query: <String, String>{
          'limit': '$limit',
          if (before != null) 'before': '$before',
        },
      );
      final entries = _listOf(json, 'entries', LedgerEntry.tryParse);
      final next = json['nextBefore'];
      return LedgerPage(entries: entries, nextBefore: next is int ? next : null);
    });
  }

  /// `GET /v1/unlocks`
  Future<UnlockStatus> getUnlocks() {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/unlocks', bearer: token);
      return UnlockStatus(
        catalog: _listOf(json, 'catalog', UnlockCatalogItem.tryParse),
        active: _listOf(json, 'active', ActiveUnlock.tryParse),
      );
    });
  }

  /// `POST /v1/unlocks` – [idempotencyKey] PHẢI được tạo một lần cho một ý định và dùng lại
  /// khi thử lại (`^[A-Za-z0-9_-]{8,64}$`). 201 = vừa trừ điểm, 200 = lần lặp.
  Future<UnlockPurchase> purchaseUnlock(String feature, String idempotencyKey) {
    return _withAuthRetry((token) async {
      final result = await _request(
        'POST',
        '/v1/unlocks',
        bearer: token,
        body: <String, dynamic>{'feature': feature, 'idempotencyKey': idempotencyKey},
      );
      final unlock = ActiveUnlock.tryParse(result.body['unlock']);
      final balance = result.body['balance'];
      if (unlock == null || balance is! int) {
        throw ApiException(code: 'INTERNAL', httpStatus: result.status);
      }
      return UnlockPurchase(unlock: unlock, balance: balance, created: result.status == 201);
    });
  }

  // --- GĐ4: trò chơi (API-GD2-4 §2.3) -------------------------------------------------

  /// `GET /v1/games`
  Future<List<GameCatalogItem>> getGames() {
    return _withAuthRetry((token) async {
      final json = await _send('GET', '/v1/games', bearer: token);
      return _listOf(json, 'games', GameCatalogItem.tryParse);
    });
  }

  /// `GET /v1/games/history?limit=&before=` – `before` là ISO `endedAt`.
  Future<GameHistoryPage> getGameHistory({int limit = 20, DateTime? before}) {
    return _withAuthRetry((token) async {
      final json = await _send(
        'GET',
        '/v1/games/history',
        bearer: token,
        query: <String, String>{
          'limit': '$limit',
          if (before != null) 'before': before.toUtc().toIso8601String(),
        },
      );
      final results = _listOf(json, 'results', GameHistoryItem.tryParse);
      final next = json['nextBefore'];
      return GameHistoryPage(
        results: results,
        nextBefore: next is String ? DateTime.tryParse(next) : null,
      );
    });
  }

  void close() => _client.close();

  // --- nội bộ ---------------------------------------------------------------

  /// Đọc mảng [key] của phản hồi, bỏ phần tử sai dạng. Thiếu/không phải mảng → `INTERNAL`.
  List<T> _listOf<T>(Map<String, dynamic> json, String key, T? Function(Object? raw) parse) {
    final raw = json[key];
    if (raw is! List) throw const ApiException(code: 'INTERNAL');
    final out = <T>[];
    for (final item in raw) {
      final parsed = parse(item);
      if (parsed != null) out.add(parsed);
    }
    return out;
  }

  /// Lấy token, chạy [action]; 401 → làm mới token và thử lại đúng một lần.
  Future<T> _withAuthRetry<T>(Future<T> Function(String token) action) async {
    final token = await _auth.getIdToken();
    if (token == null) {
      throw const ApiException(code: 'UNAUTHENTICATED', httpStatus: 401);
    }
    try {
      return await action(token);
    } on ApiException catch (e) {
      if (e.httpStatus != 401) rethrow;
      final fresh = await _auth.getIdToken(forceRefresh: true);
      if (fresh == null) rethrow;
      return action(fresh);
    }
  }

  AppUser _userFrom(Map<String, dynamic> json) {
    final user = json['user'];
    if (user is! Map) {
      throw const ApiException(code: 'INTERNAL');
    }
    try {
      return AppUser.fromJson(Map<String, dynamic>.from(user));
    } on FormatException {
      throw const ApiException(code: 'INTERNAL');
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    String? bearer,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    final result = await _request(method, path, bearer: bearer, body: body, query: query);
    return result.body;
  }

  /// Như [_send] nhưng trả thêm mã trạng thái. `204` (không body) → body rỗng `{}`.
  Future<({int status, Map<String, dynamic> body})> _request(
    String method,
    String path, {
    String? bearer,
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    var uri = Uri.parse('$_baseUrl$path');
    if (query != null && query.isNotEmpty) {
      uri = uri.replace(queryParameters: query);
    }
    final request = http.Request(method, uri);
    request.headers['accept'] = 'application/json';
    if (bearer != null) request.headers['authorization'] = 'Bearer $bearer';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      final streamed = await _client.send(request).timeout(_timeout);
      response = await http.Response.fromStream(streamed).timeout(_timeout);
    } on Exception {
      // TimeoutException, SocketException, ClientException, ...
      throw const ApiException(code: 'NETWORK');
    }

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      // API-GD2-4 §2.1: DELETE/PUT push-token trả 204 không body.
      if (status == 204) return (status: status, body: const <String, dynamic>{});
      final decoded = _decode(response);
      if (decoded is Map<String, dynamic>) return (status: status, body: decoded);
      throw ApiException(code: 'INTERNAL', httpStatus: status);
    }
    throw _errorFrom(response);
  }

  Object? _decode(http.Response response) {
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  ApiException _errorFrom(http.Response response) {
    final status = response.statusCode;
    final decoded = _decode(response);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map && error['code'] is String) {
        int? retryAfter;
        final details = error['details'];
        if (details is Map && details['retryAfterSec'] is num) {
          retryAfter = (details['retryAfterSec'] as num).toInt();
        }
        retryAfter ??= int.tryParse(response.headers['retry-after'] ?? '');
        return ApiException(
          code: error['code'] as String,
          httpStatus: status,
          retryAfterSec: retryAfter,
        );
      }
    }
    return ApiException(code: 'INTERNAL', httpStatus: status);
  }
}
