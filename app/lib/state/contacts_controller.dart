import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/blocked_user.dart';
import '../models/contact.dart';
import '../models/discovery.dart';
import '../models/ws_messages.dart';
import '../services/api_client.dart';
import '../services/chat_store.dart';
import '../services/ws_client.dart';
import 'call_context.dart';

/// Trạng thái nút "Thêm bạn" trong cuộc gọi hiện tại (API-GD2-4 §3.2 `contact.add`).
enum AddFriendState {
  /// Chưa ai bấm.
  idle,

  /// Mình đã bấm, chờ đối phương bấm.
  pending,

  /// Đối phương bấm trước, đang chờ mình.
  requested,

  /// Đã là bạn.
  added,
}

enum FriendEventKind { pending, requested, added, error, requestReceived, contactJoined }

/// Điều cần báo cho người dùng (toast). [name] là tên đối phương, [errorCode] chỉ có khi
/// [kind] là [FriendEventKind.error].
class FriendEvent {
  const FriendEvent(this.kind, {this.name, this.errorCode});

  final FriendEventKind kind;
  final String? name;
  final String? errorCode;
}

/// Danh bạ, danh sách chặn và nút Thêm bạn – T-108/T-109.
///
/// Danh sách chỉ đổi theo REST (`load`, `remove`, `unblock`) hoặc `contact.added`. `online` của
/// từng bạn chỉ chính xác tại lúc tải: UI tải lại mỗi khi vào tab Danh bạ.
class ContactsController extends ChangeNotifier {
  ContactsController({
    required ApiClient api,
    required WsClient ws,
    required RoomSource room,
    ChatStore? cache,
  })  : _api = api,
        _cache = cache,
        _ws = ws,
        _room = room {
    _msgSub = _ws.messages.listen(_onMessage);
    _room.addListener(_onRoomChanged);
    _lastRoom = _room.roomName;
  }

  final ApiClient _api;
  final WsClient _ws;
  final RoomSource _room;

  /// Bản sao danh bạ trên máy (SQLite, cùng kho với lịch sử chat). Server vẫn là nguồn gốc: `load` luôn ghi đè bản sao.
  final ChatStore? _cache;
  static const String _cacheKey = 'contacts_cache_v1';

  late final StreamSubscription<ServerMessage> _msgSub;
  final StreamController<FriendEvent> _events = StreamController<FriendEvent>.broadcast();

  List<Contact> _contacts = const <Contact>[];
  List<BlockedUser> _blocked = const <BlockedUser>[];
  bool _loading = false;
  bool _loaded = false;
  String? _loadError;
  bool _blockedLoading = false;
  String? _blockedError;

  List<ContactRequest> _requests = const <ContactRequest>[];

  AddFriendState _addState = AddFriendState.idle;
  String? _lastRoom;
  bool _disposed = false;

  List<Contact> get contacts => _contacts;
  List<BlockedUser> get blocked => _blocked;
  bool get loading => _loading;

  /// Đã tải xong ít nhất một lần thành công.
  bool get loaded => _loaded;

  /// Mã lỗi của lần tải gần nhất; `null` nếu thành công.
  String? get loadError => _loadError;
  bool get blockedLoading => _blockedLoading;
  String? get blockedError => _blockedError;

  /// Trạng thái nút Thêm bạn của cuộc gọi hiện tại.
  AddFriendState get addFriendState => _addState;

  Stream<FriendEvent> get events => _events.stream;

  /// Lời mời kết bạn đang chờ mình trả lời.
  List<ContactRequest> get requests => _requests;

  bool isContact(String userId) => _contacts.any((c) => c.id == userId);

  // --- REST ------------------------------------------------------------------------

  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    _loadError = null;
    if (!_loaded) await _restoreCache();
    _notify();
    try {
      final list = await _api.getContacts();
      _contacts = List<Contact>.unmodifiable(list);
      _loaded = true;
      _persist();
    } on ApiException catch (e) {
      _loadError = e.code;
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Xóa bạn (hai chiều). Trả mã lỗi, hoặc `null` nếu thành công.
  Future<String?> remove(String userId) async {
    try {
      await _api.removeContact(userId);
    } on ApiException catch (e) {
      return e.code;
    }
    _contacts = List<Contact>.unmodifiable(_contacts.where((c) => c.id != userId));
    _persist();
    // Xóa bạn của người đang gọi: nút Thêm bạn quay về trạng thái ban đầu.
    if (_room.peer?.id == userId) _addState = AddFriendState.idle;
    _notify();
    return null;
  }

  /// Chặn một người trong danh bạ (`POST /v1/blocks`; server tự xóa bạn hai chiều).
  /// Trả mã lỗi, hoặc `null` nếu thành công.
  Future<String?> block(String userId) async {
    try {
      await _api.block(userId);
    } on ApiException catch (e) {
      return e.code;
    }
    _contacts = List<Contact>.unmodifiable(_contacts.where((c) => c.id != userId));
    _persist();
    _blocked = const <BlockedUser>[]; // danh sách chặn đã cũ: tải lại khi mở màn hình
    _notify();
    return null;
  }

  Future<void> loadBlocked() async {
    if (_blockedLoading) return;
    _blockedLoading = true;
    _blockedError = null;
    _notify();
    try {
      final list = await _api.getBlocks();
      _blocked = List<BlockedUser>.unmodifiable(list);
    } on ApiException catch (e) {
      _blockedError = e.code;
    } finally {
      _blockedLoading = false;
      _notify();
    }
  }

  /// Bỏ chặn. Trả mã lỗi, hoặc `null` nếu thành công. Danh bạ không được khôi phục.
  Future<String?> unblock(String userId) async {
    try {
      await _api.unblock(userId);
    } on ApiException catch (e) {
      return e.code;
    }
    _blocked = List<BlockedUser>.unmodifiable(_blocked.where((b) => b.userId != userId));
    _notify();
    return null;
  }

  // --- Thêm liên hệ ngoài cuộc gọi: QR, tìm kiếm, lời mời ---------------------------

  Future<void> loadRequests() async {
    try {
      _requests = List<ContactRequest>.unmodifiable(await _api.getContactRequests());
      _notify();
    } on ApiException {
      // Giữ danh sách cũ; lần vào tab sau sẽ thử lại.
    }
  }

  /// Quét QR của người khác. Trả `null` nếu thành công, ngược lại là mã lỗi.
  Future<String?> addByCode(String code) async {
    try {
      final c = await _api.addContactByCode(code);
      _upsert(c);
      _notify();
      return null;
    } on ApiException catch (e) {
      return e.code;
    }
  }

  /// Gửi lời mời. Trả `sent` | `accepted` | `contact`, hoặc `error:<mã>`.
  Future<String> sendRequest(String userId) async {
    try {
      final st = await _api.sendContactRequest(userId);
      if (st == 'accepted') unawaited(load());
      return st;
    } on ApiException catch (e) {
      return 'error:${e.code}';
    }
  }

  Future<String?> acceptRequest(String userId) async {
    try {
      final c = await _api.acceptContactRequest(userId);
      _upsert(c);
      _requests = List<ContactRequest>.unmodifiable(_requests.where((r) => r.userId != userId));
      _notify();
      return null;
    } on ApiException catch (e) {
      return e.code;
    }
  }

  Future<void> declineRequest(String userId) async {
    _requests = List<ContactRequest>.unmodifiable(_requests.where((r) => r.userId != userId));
    _notify();
    try {
      await _api.declineContactRequest(userId);
    } on ApiException {
      // Đã gỡ khỏi màn hình; lần tải sau sẽ đồng bộ lại.
    }
  }

  // --- Thêm bạn trong cuộc gọi -------------------------------------------------------

  /// Bấm "Thêm bạn". Gửi `contact.add`; kết quả tới qua `contact.pending` / `contact.added`.
  /// Không làm gì khi không ở trong cuộc gọi hoặc đã là bạn.
  void requestAdd() {
    final room = _room.roomName;
    if (room == null) return;
    if (_addState == AddFriendState.added) return;
    _ws.send('contact.add', <String, dynamic>{'roomName': room});
  }

  // --- WebSocket ---------------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case final ContactPending e:
        if (e.roomName != _room.roomName) return;
        // Đối phương đã bấm trước thì server trả `contact.added`, không phải `pending`.
        if (_addState != AddFriendState.added) _addState = AddFriendState.pending;
        _emit(FriendEvent(FriendEventKind.pending, name: _room.peer?.displayName));
        _notify();
      case final ContactRequested e:
        if (e.roomName != _room.roomName) return;
        if (_addState == AddFriendState.idle) _addState = AddFriendState.requested;
        _emit(FriendEvent(FriendEventKind.requested, name: _room.peer?.displayName));
        _notify();
      case final ContactAdded e:
        _upsert(e.contact);
        if (e.roomName == _room.roomName) {
          _addState = AddFriendState.added;
          _emit(FriendEvent(FriendEventKind.added, name: e.contact.displayName));
        }
        _notify();
      case final ContactRequestIncoming e:
        if (!_requests.any((r) => r.userId == e.userId)) {
          _requests = List<ContactRequest>.unmodifiable(
            <ContactRequest>[ContactRequest(userId: e.userId, displayName: e.displayName), ..._requests],
          );
        }
        _emit(FriendEvent(FriendEventKind.requestReceived, name: e.displayName));
        _notify();
      case final ContactNew e:
        _requests = List<ContactRequest>.unmodifiable(_requests.where((r) => r.userId != e.userId));
        _emit(FriendEvent(FriendEventKind.contactJoined, name: e.displayName));
        unawaited(load());
      case final ServerError e:
        _onError(e);
      default:
        break;
    }
  }

  void _onError(ServerError e) {
    // Chỉ các mã mà `contact.add` có thể trả. `NOT_IN_CALL` (chặn nhau/cuộc gọi vừa hết) bỏ qua:
    // `call.ended` sẽ tới ngay sau.
    if (e.code == 'CONTACT_LIMIT') {
      _emit(const FriendEvent(FriendEventKind.error, errorCode: 'CONTACT_LIMIT'));
    }
  }

  /// Đăng xuất: quên danh bạ của người trước.
  void reset() {
    _contacts = const <Contact>[];
    _persist();
    _requests = const <ContactRequest>[];
    _blocked = const <BlockedUser>[];
    _loaded = false;
    _loadError = null;
    _blockedError = null;
    _addState = AddFriendState.idle;
    _notify();
  }

  void _upsert(Contact c) {
    final next = <Contact>[c, ..._contacts.where((x) => x.id != c.id)];
    _contacts = List<Contact>.unmodifiable(next);
    _persist();
  }

  /// Đọc bản sao trên máy để hiện ngay (online=false vì chưa hỏi server). Hỏng/không có thì bỏ qua.
  Future<void> _restoreCache() async {
    final cache = _cache;
    if (cache == null || _contacts.isNotEmpty) return;
    try {
      final raw = await cache.readKv(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is! List) return;
      final out = <Contact>[];
      for (final e in j) {
        final c = Contact.tryParse(e);
        if (c != null) out.add(c.copyWith(online: false));
      }
      if (out.isEmpty) return;
      _contacts = List<Contact>.unmodifiable(out);
      _loaded = true;
    } on Object {
      // bản sao hỏng: coi như chưa có
    }
  }

  /// Ghi bản sao (không chờ, lỗi bỏ qua). Không lưu `online` thật: lúc đọc lại luôn là false.
  void _persist() {
    final cache = _cache;
    if (cache == null) return;
    final data = jsonEncode(<Map<String, Object>>[
      for (final c in _contacts)
        <String, Object>{
          'id': c.id,
          'displayName': c.displayName,
          'language': c.language,
          'online': false,
          'addedAt': c.addedAt.toUtc().toIso8601String(),
        },
    ]);
    unawaited(cache.writeKv(_cacheKey, data).catchError((Object _) {}));
  }

  void _onRoomChanged() {
    final room = _room.roomName;
    if (room == _lastRoom) return;
    _lastRoom = room;
    // Cuộc gọi mới (hoặc hết cuộc gọi): "Thêm bạn" làm lại từ đầu.
    if (_addState != AddFriendState.idle) {
      _addState = AddFriendState.idle;
      _notify();
    }
  }

  void _emit(FriendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _room.removeListener(_onRoomChanged);
    _msgSub.cancel();
    _events.close();
    super.dispose();
  }
}
