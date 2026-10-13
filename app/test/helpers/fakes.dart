import 'dart:async';
import 'package:cham/models/discovery.dart';
import 'dart:typed_data';

import 'package:cham/models/api_error.dart';
import 'package:cham/models/avatar.dart';
import 'package:cham/models/blocked_user.dart';
import 'package:cham/models/contact.dart';
import 'package:cham/models/game_state.dart';
import 'package:cham/models/match_found.dart';
import 'package:cham/models/user.dart';
import 'package:cham/models/wallet.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/services/api_client.dart';
import 'package:cham/services/auth_service.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/permission_gateway.dart';
import 'package:cham/services/ws_client.dart';
import 'package:cham/state/call_context.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

AppUser makeUser({
  String id = 'Xk3vN0aQp1L7cWm2RtY8bA',
  String name = 'Minh',
  int? birthYear,
  String language = 'vi',
  bool? profileComplete,
}) {
  return AppUser(
    id: id,
    displayName: name,
    birthYear: birthYear,
    language: language,
    status: 'active',
    profileComplete: profileComplete ?? birthYear != null,
    createdAt: DateTime.utc(2026, 10, 5),
  );
}

MatchFound makeMatch({String room = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11', String peerName = 'Anna'}) {
  return MatchFound(
    roomName: room,
    livekitUrl: 'wss://cham-xxxx.livekit.cloud',
    token: 'tok-$room',
    tokenExpiresAt: DateTime.utc(2026, 10, 5, 9, 40),
    peer: Peer(id: 'Q9pLm2vX0aB7cWn3RtY1kZ', displayName: peerName, language: 'en'),
  );
}

class FakeAuthService implements AuthService {
  FakeAuthService({this.signedIn = false, this.tokens = const ['dev:alice']});

  bool signedIn;

  /// Token trả lần lượt cho mỗi lần gọi getIdToken (lần cuối lặp lại).
  List<String> tokens;
  final List<bool> tokenCalls = <bool>[]; // forceRefresh của từng lần gọi
  int signOutCalls = 0;
  bool signInShouldSucceed = true;
  String? lastDevUid;

  @override
  Future<void> init() async {}

  @override
  bool get isSignedIn => signedIn;

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async {
    if (!signedIn) return null;
    tokenCalls.add(forceRefresh);
    final i = tokenCalls.length - 1;
    return tokens[i < tokens.length ? i : tokens.length - 1];
  }

  @override
  Future<void> signInDev(String uid) async {
    lastDevUid = uid;
    signedIn = signInShouldSucceed;
  }

  @override
  Future<void> signInWithApple() async => signedIn = signInShouldSucceed;

  @override
  Future<void> signInWithGoogle() async => signedIn = signInShouldSucceed;

  @override
  Future<void> signOut() async {
    signOutCalls++;
    signedIn = false;
  }
}

/// ApiClient giả: mỗi phương thức gọi một closure có thể thay trong test.
class FakeApiClient implements ApiClient {
  // Phương thức ApiClient mới mà test không dùng: không cần khai báo từng cái (gọi nhầm sẽ ném NoSuchMethodError).
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  // Ảnh đại diện / khóa chat / cấu hình từ xa: mặc định rỗng.
  @override
  Future<List<ContactRequest>> getContactRequests() async => const <ContactRequest>[];

  @override
  Future<Avatar?> getAvatar(String userId) async => null;

  @override
  Future<Avatar?> uploadAvatar(Uint8List jpeg) async => const Avatar.upload(1);

  @override
  Future<void> deleteAvatar() async {}

  @override
  Future<void> putChatKey(String publicKeyB64) async {}

  @override
  Future<String?> getChatKey(String userId) async => null;

  @override
  Future<Map<String, dynamic>> getRemoteConfig() async => <String, dynamic>{};

  Future<({AppUser user, bool isNew})> Function(String language)? onCreateSession;
  Future<AppUser> Function({int? birthYear, String? language, String? displayName})? onUpdateMe;
  Future<void> Function(String userId)? onBlock;
  Future<void> Function(String userId, String reason, String? roomName, String? note)? onReport;

  // GĐ2
  Future<List<Contact>> Function()? onGetContacts;
  Future<void> Function(String userId)? onRemoveContact;
  Future<List<BlockedUser>> Function()? onGetBlocks;
  Future<void> Function(String userId)? onUnblock;
  Future<void> Function(String token, String platform)? onSetPushToken;
  Future<void> Function(String token)? onDeletePushToken;

  // GĐ3
  Future<Wallet> Function()? onGetWallet;
  Future<LedgerPage> Function({int limit, int? before})? onGetLedger;
  Future<UnlockStatus> Function()? onGetUnlocks;
  Future<UnlockPurchase> Function(String feature, String key)? onPurchaseUnlock;

  // GĐ4
  Future<List<GameCatalogItem>> Function()? onGetGames;
  Future<GameHistoryPage> Function({int limit, DateTime? before})? onGetGameHistory;

  final List<String> log = <String>[];

  @override
  Future<({AppUser user, bool isNew})> createSession({required String language}) {
    log.add('createSession($language)');
    final f = onCreateSession;
    if (f == null) {
      return Future.value((user: makeUser(birthYear: 1995), isNew: false));
    }
    return f(language);
  }

  @override
  Future<AppUser> getMe() async => makeUser(birthYear: 1995);

  @override
  Future<AppUser> updateMe({int? birthYear, String? language, String? displayName, List<String>? interests, String? avatarPreset}) {
    log.add('updateMe(birthYear: $birthYear, language: $language, displayName: $displayName)');
    final f = onUpdateMe;
    if (f == null) {
      return Future.value(makeUser(
        birthYear: birthYear ?? 1995,
        language: language ?? 'vi',
        name: displayName ?? 'Minh',
      ));
    }
    return f(birthYear: birthYear, language: language, displayName: displayName);
  }

  @override
  Future<void> block(String userId) async {
    log.add('block($userId)');
    await onBlock?.call(userId);
  }

  @override
  Future<void> report({
    required String userId,
    required String reason,
    String? roomName,
    String? note,
  }) async {
    log.add('report($userId, $reason)');
    await onReport?.call(userId, reason, roomName, note);
  }

  @override
  Future<List<Contact>> getContacts() async {
    log.add('getContacts');
    return await onGetContacts?.call() ?? <Contact>[];
  }

  @override
  Future<void> removeContact(String userId) async {
    log.add('removeContact($userId)');
    await onRemoveContact?.call(userId);
  }

  @override
  Future<List<BlockedUser>> getBlocks() async {
    log.add('getBlocks');
    return await onGetBlocks?.call() ?? <BlockedUser>[];
  }

  @override
  Future<void> unblock(String userId) async {
    log.add('unblock($userId)');
    await onUnblock?.call(userId);
  }

  @override
  Future<void> setPushToken(String token, String platform) async {
    log.add('setPushToken($token, $platform)');
    await onSetPushToken?.call(token, platform);
  }

  @override
  Future<void> deletePushToken(String token) async {
    log.add('deletePushToken($token)');
    await onDeletePushToken?.call(token);
  }

  @override
  Future<Wallet> getWallet() async {
    log.add('getWallet');
    final f = onGetWallet;
    return f == null ? Wallet(balance: 0, updatedAt: null) : f();
  }

  @override
  Future<LedgerPage> getLedger({int limit = 20, int? before}) async {
    log.add('getLedger(limit: $limit, before: $before)');
    final f = onGetLedger;
    return f == null
        ? const LedgerPage(entries: <LedgerEntry>[], nextBefore: null)
        : f(limit: limit, before: before);
  }

  @override
  Future<UnlockStatus> getUnlocks() async {
    log.add('getUnlocks');
    final f = onGetUnlocks;
    return f == null
        ? const UnlockStatus(catalog: <UnlockCatalogItem>[], active: <ActiveUnlock>[])
        : f();
  }

  @override
  Future<UnlockPurchase> purchaseUnlock(String feature, String idempotencyKey) async {
    log.add('purchaseUnlock($feature, $idempotencyKey)');
    final f = onPurchaseUnlock;
    if (f == null) throw StateError('onPurchaseUnlock chưa được đặt');
    return f(feature, idempotencyKey);
  }

  @override
  Future<List<GameCatalogItem>> getGames() async {
    log.add('getGames');
    return await onGetGames?.call() ?? <GameCatalogItem>[];
  }

  @override
  Future<GameHistoryPage> getGameHistory({int limit = 20, DateTime? before}) async {
    log.add('getGameHistory(limit: $limit, before: $before)');
    final f = onGetGameHistory;
    return f == null
        ? const GameHistoryPage(results: <GameHistoryItem>[], nextBefore: null)
        : f(limit: limit, before: before);
  }

  @override
  void close() {}
}

class SentMessage {
  const SentMessage(this.type, this.data);
  final String type;
  final Map<String, dynamic> data;

  @override
  String toString() => '$type $data';
}

/// WsClient giả: ghi lại thông điệp gửi đi, cho phép test phát thông điệp/trạng thái.
class FakeWsClient implements WsClient {
  final StreamController<ServerMessage> _messages = StreamController<ServerMessage>.broadcast();
  final StreamController<WsConnState> _states = StreamController<WsConnState>.broadcast();
  final List<SentMessage> sent = <SentMessage>[];
  int connectCalls = 0;
  int closeCalls = 0;
  WsConnState _current = WsConnState.disconnected;

  @override
  Future<void> Function()? onNeedsSessionRefresh;

  @override
  String get url => 'ws://fake';

  @override
  AuthService get auth => FakeAuthService();

  @override
  Stream<ServerMessage> get messages => _messages.stream;

  @override
  Stream<WsConnState> get state => _states.stream;

  @override
  WsConnState get currentState => _current;

  @override
  bool get isConnected => _current == WsConnState.connected;

  @override
  Future<void> connect() async => connectCalls++;

  @override
  void send(String type, [Map<String, dynamic> data = const <String, dynamic>{}]) {
    sent.add(SentMessage(type, data));
  }

  @override
  Future<void> close() async => closeCalls++;

  @override
  Future<void> dispose() async {}

  // --- điều khiển từ test ---
  void emit(ServerMessage m) => _messages.add(m);

  void emitState(WsConnState s) {
    _current = s;
    _states.add(s);
  }

  List<String> get sentTypes => sent.map((m) => m.type).toList();
}

class FakeCallService implements CallService {
  final StreamController<CallEvent> _events = StreamController<CallEvent>.broadcast();

  /// Thứ tự các sự kiện của dịch vụ gọi VÀ của FakeWsClient nếu dùng chung `order`.
  final List<String> order;
  FakeCallService({List<String>? order}) : order = order ?? <String>[];

  final List<String> joins = <String>[];
  int leaveCalls = 0;
  final List<bool> micCalls = <bool>[];
  final List<bool> cameraCalls = <bool>[];
  bool joinShouldFail = false;

  @override
  Future<void> join(String url, String token) async {
    order.add('call.join');
    joins.add('$url|$token');
    if (joinShouldFail) throw StateError('join failed');
  }

  @override
  Future<void> joinMatch(MatchFound match) => join(match.livekitUrl, match.token);

  @override
  Stream<Map<String, dynamic>> get dataMessages => const Stream<Map<String, dynamic>>.empty();

  @override
  bool sendData(Map<String, dynamic> message) => false;

  @override
  Future<void> leave() async {
    order.add('call.leave');
    leaveCalls++;
  }

  @override
  Stream<CallEvent> get events => _events.stream;

  @override
  Widget remoteView() => const SizedBox.shrink();

  @override
  Widget localView() => const SizedBox.shrink();

  @override
  Future<void> setMicEnabled(bool on) async => micCalls.add(on);

  @override
  Future<void> setCameraEnabled(bool on) async => cameraCalls.add(on);

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> dispose() async {}

  void emit(CallEvent e) => _events.add(e);
}

class FakePermissionGateway implements PermissionGateway {
  FakePermissionGateway({this.granted = true, this.requestOutcome = PermissionOutcome.granted});

  bool granted;
  PermissionOutcome requestOutcome;
  int requestCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<bool> hasCameraAndMic() async => granted;

  @override
  Future<PermissionOutcome> request() async {
    requestCalls++;
    if (requestOutcome == PermissionOutcome.granted) granted = true;
    return requestOutcome;
  }

  @override
  Future<void> openSettings() async => openSettingsCalls++;
}

/// Hẹn giờ giả: test tự `fire`/`advance` mà không chờ thời gian thật.
class FakeTimers {
  final List<FakeTimer> timers = <FakeTimer>[];

  Timer create(Duration d, void Function() cb) {
    final t = FakeTimer(d, cb);
    timers.add(t);
    return t;
  }

  /// Chạy mọi hẹn giờ còn hiệu lực có thời lượng đúng [d].
  void fire(Duration d) {
    for (final t in List<FakeTimer>.of(timers)) {
      if (t.isActive && t.duration == d) t.fire();
    }
  }

  int activeCount(Duration d) => timers.where((t) => t.isActive && t.duration == d).length;
}

class FakeTimer implements Timer {
  FakeTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// Tạo ApiException nhanh.
ApiException apiError(String code, {int status = 400, int? retryAfterSec}) =>
    ApiException(code: code, httpStatus: status, retryAfterSec: retryAfterSec);


/// `RoomSource` + `InvitedCallHost` giả: test tự đặt phòng/đối phương và xem lời gọi.
class FakeRoom extends ChangeNotifier implements RoomSource, InvitedCallHost {
  FakeRoom({String? room, Peer? peer})
      : _room = room,
        _peer = peer;

  String? _room;
  Peer? _peer;
  bool busy = false;
  bool expecting = false;
  int expectCalls = 0;
  int clearCalls = 0;

  @override
  String? get roomName => _room;

  @override
  Peer? get peer => _peer;

  @override
  bool get inCallOrConnecting => busy;

  @override
  void expectInvitedCall() {
    expecting = true;
    expectCalls++;
  }

  @override
  void clearInvitedCall() {
    expecting = false;
    clearCalls++;
  }

  /// Vào phòng [room] với [peer] (mặc định Anna).
  void enter(String room, {Peer? peer}) {
    _room = room;
    _peer = peer ?? makeMatch(room: room).peer;
    notifyListeners();
  }

  void leave() {
    _room = null;
    _peer = null;
    notifyListeners();
  }
}

const String kRoom = 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11';
const String kSelfId = 'Xk3vN0aQp1L7cWm2RtY8bA';
const String kPeerId = 'Q9pLm2vX0aB7cWn3RtY1kZ';

Contact makeContact({
  String id = kPeerId,
  String name = 'Anna',
  String language = 'en',
  bool online = false,
}) {
  return Contact(
    id: id,
    displayName: name,
    language: language,
    online: online,
    addedAt: DateTime.utc(2026, 10, 6, 9, 30),
  );
}
