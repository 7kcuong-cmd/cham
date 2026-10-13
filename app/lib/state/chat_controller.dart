import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../models/ws_messages.dart';
import '../services/api_client.dart';
import '../config/env.dart';
import '../services/chat_crypto.dart';
import '../services/ratchet.dart';
import '../services/chat_store.dart';
import '../services/direct_dm.dart';
import '../services/file_transfer.dart';
import '../services/ws_client.dart';

/// Tin nhắn giữa bạn bè, mã hóa đầu cuối. Lịch sử CHỈ lưu trên máy ([ChatStore]).
/// Server giữ tạm bản mã tối đa 7 ngày cho người đang offline và xóa khi nhận `dm.ack`.
class ChatController extends ChangeNotifier {
  ChatController({
    required ApiClient api,
    required WsClient ws,
    required ChatStore store,
    ChatCrypto? crypto,
    String Function()? newId,
    DirectDm Function(void Function(String peerId, Map<String, dynamic> msg) onMessage, void Function(String peerId, Map<String, dynamic> msg) onControl)? directFactory,
    Future<Directory> Function()? filesDir,
    bool? useRatchet,
  })  : _useRatchet = useRatchet ?? Env.doubleRatchet,
         _api = api,
        _ws = ws,
        _store = store,
        _crypto = crypto ?? ChatCrypto(),
        _newId = newId ?? _uuidV4 {
    _direct = directFactory?.call(_onDirect, (p, m) => _files?.handle(p, m));
    final d = _direct;
    if (d != null && filesDir != null) {
      _files = FileTransfer(
        direct: d,
        crypto: _crypto,
        peerKey: (p) async {
          await _ensureInit();
          return _peerKey(p);
        },
        baseDir: filesDir,
        onOffer: (o) {
          _offers.add(o);
          _notify();
        },
        onReceived: (peer, id, name, size, path) => unawaited(_fileReceived(peer, id, name, size)),
      );
    }
    _msgSub = _ws.messages.listen(_onMessage);
    _stateSub = _ws.state.listen((s) {
      if (s == WsConnState.connected) unawaited(_onConnected());
    });
    if (_ws.isConnected) unawaited(_onConnected());
  }

  static const int maxChars = 1500;

  final ApiClient _api;
  final WsClient _ws;
  final ChatStore _store;
  final ChatCrypto _crypto;
  final bool _useRatchet;
  final Map<String, RatchetConversation> _convs = <String, RatchetConversation>{};
  final Map<String, Future<void>> _convLocks = <String, Future<void>>{};
  final Map<String, String> _bodyCache = <String, String>{};
  final String Function() _newId;
  DirectDm? _direct;
  FileTransfer? _files;
  final List<FileOffer> _offers = <FileOffer>[];

  final StreamController<ChatMessage> _changes = StreamController<ChatMessage>.broadcast();

  /// Mỗi lần có tin mới hoặc đổi trạng thái (để đẩy sang web đang liên kết).
  Stream<ChatMessage> get changes => _changes.stream;

  StreamSubscription<ServerMessage>? _msgSub;
  StreamSubscription<WsConnState>? _stateSub;
  Future<void>? _init;
  bool _keyPublished = false;
  bool _flushing = false;
  bool _disposed = false;

  final Map<String, String> _peerKeys = <String, String>{};
  final Map<String, List<ChatMessage>> _threads = <String, List<ChatMessage>>{};
  final Map<String, int> _unread = <String, int>{};
  String? _openPeer;

  // --- gửi lại / đang nhập ---
  static const Duration _retryAfter = Duration(seconds: 6);
  static const Duration _failAfter = Duration(seconds: 18);
  static final RegExp _uuidRe = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  final Map<String, Timer> _typingTimers = <String, Timer>{};
  final Set<String> _typing = <String>{};
  final Map<String, DateTime> _typingSentAt = <String, DateTime>{};

  static String _uuidV4() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int x) => x.toRadixString(16).padLeft(2, '0');
    final s = b.map(h).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  Future<void> _ensureInit() => _init ??= () async {
        final saved = await _store.readSecret();
        final seed = await _crypto.init(saved == null ? null : Uint8List.fromList(base64.decode(saved)));
        if (saved == null) await _store.writeSecret(base64.encode(seed));
      }();

  List<ChatMessage> thread(String peerId) => List<ChatMessage>.unmodifiable(_threads[peerId] ?? const <ChatMessage>[]);
  int unread(String peerId) => _unread[peerId] ?? 0;
  int get totalUnread => _unread.values.fold(0, (a, b) => a + b);

  /// Mở một cuộc trò chuyện: nạp lịch sử từ máy và đánh dấu đã đọc.
  Future<void> open(String peerId) async {
    _openPeer = peerId;
    _direct?.warmUp(peerId);
    _threads[peerId] = await _store.load(peerId);
    _unread.remove(peerId);
    _notify();
    unawaited(_sendReadReceipts(peerId));
  }

  /// Đang mở màn trò chuyện với [peerId]?
  bool isOpen(String peerId) => _openPeer == peerId;

  /// Người kia đang nhập?
  bool isTyping(String peerId) => _typing.contains(peerId);

  /// Báo "đang nhập" cho người kia (tối đa 1 lần / 3 giây).
  void notifyTyping(String peerId) {
    if (!_ws.isConnected) return;
    final now = DateTime.now();
    final last = _typingSentAt[peerId];
    if (last != null && now.difference(last) < const Duration(seconds: 3)) return;
    _typingSentAt[peerId] = now;
    _ws.send('dm.typing', <String, dynamic>{'toUserId': peerId});
  }

  void _onTyping(String peerId) {
    _typing.add(peerId);
    _typingTimers[peerId]?.cancel();
    _typingTimers[peerId] = Timer(const Duration(seconds: 5), () {
      _typing.remove(peerId);
      _typingTimers.remove(peerId);
      _notify();
    });
    _notify();
  }

  void _stopTyping(String peerId) {
    _typingTimers.remove(peerId)?.cancel();
    if (_typing.remove(peerId)) _notify();
  }

  /// Báo "đã đọc" cho các tin người kia gửi mà mình chưa báo. Chỉ khi đang online (không thì lần mở sau sẽ báo).
  Future<void> _sendReadReceipts(String peerId) async {
    if (!_ws.isConnected) return;
    final t = _threads[peerId];
    if (t == null) return;
    final ids = <String>[];
    for (var i = 0; i < t.length; i++) {
      final m = t[i];
      if (m.mine || m.status != ChatStatus.received) continue;
      t[i] = m.withStatus(ChatStatus.read);
      await _store.save(t[i]);
      if (_uuidRe.hasMatch(m.id)) ids.add(m.id);
    }
    for (var i = 0; i < ids.length; i += 100) {
      _ws.send('dm.read', <String, dynamic>{'toUserId': peerId, 'msgIds': ids.sublist(i, min(i + 100, ids.length))});
    }
  }

  /// Người kia báo đã đọc các tin của mình.
  Future<void> _onReadReceipt(DmRead r) async {
    final cached = _threads[r.byUserId];
    final t = cached ?? List<ChatMessage>.of(await _store.load(r.byUserId));
    var changed = false;
    for (final id in r.msgIds) {
      final i = t.indexWhere((x) => x.id == id && x.mine);
      if (i < 0 || t[i].status == ChatStatus.read) continue;
      final u = t[i].withStatus(ChatStatus.read);
      t[i] = u;
      await _store.save(u);
      _emit(u);
      changed = true;
    }
    if (changed) _notify();
  }

  /// Gửi lại một tin lỗi.
  Future<void> retry(String id, String peerId) async {
    final t = _threads[peerId];
    if (t == null) return;
    final i = t.indexWhere((x) => x.id == id && x.mine && x.status == ChatStatus.failed);
    if (i < 0) return;
    final m = t[i].withStatus(ChatStatus.sending);
    t[i] = m;
    await _store.save(m);
    _emit(m);
    _notify();
    unawaited(_deliver(m));
  }

  void _armRetry(ChatMessage m) {
    _retryTimers[m.id]?.cancel();
    _retryTimers[m.id] = Timer(_retryAfter, () {
      // Chưa có dm.sent sau vài giây: gửi lại một lần (server bỏ qua tin trùng msgId).
      if (_disposed || !_isPending(m.id)) return;
      unawaited(_deliver(m, rearm: false));
      _retryTimers[m.id] = Timer(_failAfter - _retryAfter, () {
        if (!_disposed && _isPending(m.id)) unawaited(_markFailed(m.id));
      });
    });
  }

  bool _isPending(String id) {
    for (final t in _threads.values) {
      final i = t.indexWhere((x) => x.id == id);
      if (i >= 0) return t[i].status == ChatStatus.sending;
    }
    return false;
  }

  Future<void> _markFailed(String id) async {
    _retryTimers.remove(id)?.cancel();
    for (final t in _threads.values) {
      final i = t.indexWhere((x) => x.id == id);
      if (i >= 0 && t[i].status == ChatStatus.sending) {
        final u = t[i].withStatus(ChatStatus.failed);
        t[i] = u;
        await _store.save(u);
        _emit(u);
        _notify();
        return;
      }
    }
    // Thread chưa mở: tìm trong kho.
    for (final p in await _store.peers()) {
      for (final x in await _store.load(p)) {
        if (x.id == id && x.status == ChatStatus.sending) {
          await _store.save(x.withStatus(ChatStatus.failed));
          return;
        }
      }
    }
  }

  void close(String peerId) {
    if (_openPeer == peerId) _openPeer = null;
  }

  /// Gửi tin. Trả false nếu nội dung rỗng hoặc quá dài.
  Future<bool> send(String peerId, String raw) async {
    final text = raw.trim();
    if (text.isEmpty || text.length > maxChars) return false;
    final m = ChatMessage(
      id: _newId(),
      peerId: peerId,
      mine: true,
      text: text,
      at: DateTime.now(),
      status: ChatStatus.sending,
    );
    await _store.save(m);
    (_threads[peerId] ??= <ChatMessage>[]).add(m);
    _emit(m);
    _notify();
    unawaited(_deliver(m));
    return true;
  }

  /// Gửi tệp trực tiếp (chỉ khi người kia đang online). Trả `null` nếu xong, hoặc mã lỗi của [FileTransfer.send].
  Future<String?> sendFile(String peerId, String name, Uint8List bytes) async {
    final f = _files;
    if (f == null) return 'offline';
    await _ensureInit();
    String? sentId;
    final err = await f.send(peerId, name, bytes, onStart: (id) => sentId = id);
    final id = sentId;
    if (err == null && id != null) {
      final m = ChatMessage(id: id, peerId: peerId, mine: true, text: '\u{1F4CE} ${FileTransfer.safeName(name)}', at: DateTime.now(), status: ChatStatus.sent);
      await _store.save(m);
      (_threads[peerId] ??= <ChatMessage>[]).add(m);
      _emit(m);
      _notify();
    }
    return err;
  }

  List<FileOffer> offersFrom(String peerId) => _offers.where((o) => o.peerId == peerId).toList(growable: false);
  ValueNotifier<double>? fileProgress(String id) => _files?.progress[id];

  void acceptOffer(String id) {
    _files?.accept(id);
    _offers.removeWhere((o) => o.id == id);
    _notify();
  }

  void declineOffer(String id) {
    _files?.decline(id);
    _offers.removeWhere((o) => o.id == id);
    _notify();
  }

  /// Đường dẫn tệp đã lưu của một tin dạng tệp (null nếu không phải tin tệp).
  Future<String?> filePathOf(ChatMessage m) async {
    if (!m.text.startsWith('\u{1F4CE} ')) return null;
    return _files?.pathFor(m.peerId, m.id, m.text.substring(3));
  }

  Future<void> _fileReceived(String peer, String id, String name, int size) async {
    _offers.removeWhere((o) => o.id == id);
    final m = ChatMessage(id: id, peerId: peer, mine: false, text: '\u{1F4CE} $name', at: DateTime.now(), status: ChatStatus.received);
    await _store.save(m);
    final t = _threads[peer];
    if (t != null) {
      t.add(m);
      t.sort((a, b) => a.at.compareTo(b.at));
    }
    if (_openPeer != peer) _unread[peer] = (_unread[peer] ?? 0) + 1;
    _emit(m);
    _notify();
  }

  /// Khóa công khai của mình và của `peerId` (null nếu chưa lấy được) – dùng để tính mã an toàn.
  Future<({String mine, String? peer})> keysFor(String peerId) async {
    await _ensureInit();
    return (mine: await _crypto.publicKeyBase64(), peer: await _peerKey(peerId));
  }

  /// Tuần tự hóa mọi thao tác mã hóa/giải mã của một cuộc trò chuyện (trạng thái ratchet không được chạy song song).
  Future<T> _locked<T>(String peerId, Future<T> Function() fn) {
    final prev = _convLocks[peerId] ?? Future<void>.value();
    final c = Completer<T>();
    _convLocks[peerId] = prev.then((_) async {
      try {
        c.complete(await fn());
      } on Object catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<RatchetConversation> _conv(String peerId, String peerKeyB64) async {
    final c = _convs[peerId];
    if (c != null && base64.encode(c.peerPub) == peerKeyB64) return c;
    final raw = await _store.readKv('dr:$peerId');
    Map<String, dynamic>? state;
    if (raw != null) {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['peer'] == peerKeyB64) state = Map<String, dynamic>.from(j['state'] as Map); // khóa đổi => bỏ phiên cũ
    }
    final conv = await RatchetConversation.restore(
      me: _crypto.identity!,
      peerPub: Uint8List.fromList(base64.decode(peerKeyB64)),
      state: state,
    );
    return _convs[peerId] = conv;
  }

  Future<void> _persistConv(String peerId, RatchetConversation c) =>
      _store.writeKv('dr:$peerId', jsonEncode(<String, Object?>{'peer': base64.encode(c.peerPub), 'state': c.snapshot()}));

  /// Mã hóa một tin gửi đi; cùng `msgId` thì dùng lại đúng bản mã (gửi lại không làm tiêu khóa).
  Future<String> _encryptBody(String peerId, String peerKey, String msgId, String text) {
    if (!_useRatchet) return _crypto.encrypt(peerKey, text);
    return _locked(peerId, () async {
      final cached = _bodyCache[msgId];
      if (cached != null) return cached;
      final c = await _conv(peerId, peerKey);
      final body = await c.encrypt(text);
      await _persistConv(peerId, c); // lưu trước khi gửi
      if (_bodyCache.length > 200) _bodyCache.remove(_bodyCache.keys.first);
      return _bodyCache[msgId] = body;
    });
  }

  Future<String> _decryptBody(String peerId, String peerKey, String body) async {
    if (!body.startsWith('dr2:')) return _crypto.decrypt(peerKey, body);
    final c = await _conv(peerId, peerKey);
    final text = await c.decrypt(body);
    await _persistConv(peerId, c);
    return text;
  }

  Future<String?> _peerKey(String peerId) async {
    final cached = _peerKeys[peerId];
    if (cached != null) return cached;
    try {
      final k = await _api.getChatKey(peerId);
      if (k != null) _peerKeys[peerId] = k;
      return k;
    } on Object {
      return null;
    }
  }

  /// Gửi qua server NGAY (WebSocket đã mở, vài chục mili giây); kênh trực tiếp chỉ là đường tắt khi đã mở sẵn.
  /// Trước đây app chờ dựng kênh trực tiếp tới 6 giây (+4 giây chờ báo nhận) rồi mới gửi qua server nên tin bị trễ.
  Future<void> _deliver(ChatMessage m, {bool rearm = true}) async {
    if (!_ws.isConnected) return; // sẽ gửi lại khi kết nối
    try {
      await _ensureInit();
      final key = await _peerKey(m.peerId);
      if (key == null) {
        // Người kia chưa có khóa mã hóa (chưa mở phần nhắn tin lần nào): báo lỗi để bấm gửi lại sau.
        await _markFailed(m.id);
        return;
      }
      final body = await _encryptBody(m.peerId, key, m.id, m.text);
      final direct = _direct;
      if (direct != null &&
          direct.isOpen(m.peerId) &&
          await direct.send(m.peerId, m.id, <String, dynamic>{'body': body, 'at': m.at.toUtc().toIso8601String()})) {
        await _markSent(m.id);
        return;
      }
      _ws.send('dm.send', <String, dynamic>{'toUserId': m.peerId, 'msgId': m.id, 'body': body});
      direct?.warmUp(m.peerId);
      if (rearm) _armRetry(m);
    } on Object catch (e) {
      debugPrint('chat: deliver failed: $e');
    }
  }

  Future<void> _onConnected() async {
    try {
      await _ensureInit();
    } on Object catch (e) {
      debugPrint('chat: init failed: $e');
      _init = null;
      return;
    }
    if (!_keyPublished) {
      try {
        await _api.putChatKey(await _crypto.publicKeyBase64());
        _keyPublished = true;
      } on Object catch (e) {
        debugPrint('chat: publish key failed: $e');
      }
    }
    _ws.send('dm.sync');
    await _flush();
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      for (final m in await _store.pending()) {
        await _deliver(m);
      }
    } on Object catch (e) {
      debugPrint('chat: flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  void _onMessage(ServerMessage m) {
    switch (m) {
      case DmSent(:final msgId):
        _retryTimers.remove(msgId)?.cancel();
        unawaited(_markSent(msgId));
      case final DmTyping t:
        _onTyping(t.fromUserId);
      case final DmRead r:
        unawaited(_onReadReceipt(r));
      case final DmReceived r:
        unawaited(_receive(r));
      default:
        break;
    }
  }

  Future<void> _markSent(String id) async {
    for (final entry in _threads.entries) {
      final i = entry.value.indexWhere((x) => x.id == id);
      if (i >= 0) {
        if (entry.value[i].status == ChatStatus.read) return; // báo đã đọc tới trước dm.sent
        final u = entry.value[i].withStatus(ChatStatus.sent);
        entry.value[i] = u;
        await _store.save(u);
        _emit(u);
        _notify();
        return;
      }
    }
    // Thread chưa mở: tìm trong kho (tin đang chờ).
    for (final p in await _store.peers()) {
      for (final x in await _store.load(p)) {
        if (x.id == id && x.status == ChatStatus.sending) {
          await _store.save(x.withStatus(ChatStatus.sent));
          return;
        }
      }
    }
  }

  /// Tin đến qua kênh trực tiếp: dữ liệu từ máy bạn bè nên kiểm tra chặt. Không `dm.ack` vì không nằm trong hộp thư server.
  void _onDirect(String peerId, Map<String, dynamic> msg) {
    final id = msg['id'];
    final body = msg['body'];
    final at = msg['at'] is String ? DateTime.tryParse(msg['at'] as String) : null;
    if (id is! String || body is! String || body.isEmpty || body.length > 8192) return;
    final now = DateTime.now();
    final sentAt = (at == null || at.isAfter(now)) ? now : at;
    unawaited(_receive(DmReceived(id, peerId, body, sentAt), viaServer: false));
  }

  Future<void> _receive(DmReceived r, {bool viaServer = true}) =>
      _locked(r.fromUserId, () => _receiveLocked(r, viaServer: viaServer));

  Future<void> _receiveLocked(DmReceived r, {required bool viaServer}) async {
    if (await _store.has(r.fromUserId, r.msgId)) {
      if (viaServer) _ws.send('dm.ack', <String, dynamic>{'msgIds': <String>[r.msgId]});
      return;
    }
    String text;
    try {
      await _ensureInit();
      final key = await _peerKey(r.fromUserId);
      text = key == null ? '⚠ (không giải mã được)' : await _decryptBody(r.fromUserId, key, r.body);
    } on Object {
      text = '⚠ (không giải mã được)';
    }
    final m = ChatMessage(
      id: r.msgId,
      peerId: r.fromUserId,
      mine: false,
      text: text,
      at: r.sentAt,
      status: ChatStatus.received,
    );
    await _store.save(m);
    final t = _threads[r.fromUserId];
    if (t != null) {
      t.add(m);
      t.sort((a, b) => a.at.compareTo(b.at));
    }
    if (_openPeer != r.fromUserId) _unread[r.fromUserId] = (_unread[r.fromUserId] ?? 0) + 1;
    if (viaServer) _ws.send('dm.ack', <String, dynamic>{'msgIds': <String>[r.msgId]});
    _stopTyping(r.fromUserId);
    _emit(m);
    _notify();
    if (_openPeer == r.fromUserId) unawaited(_sendReadReceipts(r.fromUserId));
  }

  /// Đăng xuất: xóa lịch sử và khóa trên máy.
  Future<void> reset() async {
    await _store.clearAll();
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
    _threads.clear();
    _unread.clear();
    _peerKeys.clear();
    _convs.clear();
    _bodyCache.clear();
    _keyPublished = false;
    _init = null;
    _notify();
  }

  void _emit(ChatMessage m) {
    if (!_changes.isClosed) _changes.add(m);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in [..._retryTimers.values, ..._typingTimers.values]) {
      t.cancel();
    }
    _files?.dispose();
    unawaited(_direct?.dispose());
    unawaited(_msgSub?.cancel());
    unawaited(_stateSub?.cancel());
    unawaited(_changes.close());
    super.dispose();
  }
}
