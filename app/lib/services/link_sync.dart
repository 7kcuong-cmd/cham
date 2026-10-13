import 'dart:async';

import '../models/chat_message.dart';
import 'link_channel.dart';

/// Phần của app trên điện thoại mà web được phép dùng (đọc lịch sử, nhận tin mới, gửi tin).
abstract class LinkChatPort {
  Future<List<String>> peers();
  Future<List<ChatMessage>> load(String peerId);

  /// Tin mới (nhận được hoặc đổi trạng thái) để đẩy sang web.
  Stream<ChatMessage> get changes;

  Future<bool> send(String peerId, String text);

  /// Tên hiển thị theo `peerId` (web không có danh bạ).
  Future<Map<String, String>> names();
}

/// Phía ĐIỆN THOẠI: như "server nhỏ" cho web. Chỉ hoạt động sau khi người dùng đã so khớp mã 6 số
/// và bấm [approve]. Web yêu cầu: `sync.request`, `send`. Điện thoại trả: `sync.chunk`, `sync.done`, `msg`, `sent`.
class LinkHost {
  LinkHost({required LinkChannel channel, required LinkChatPort chat, this.chunkSize = 200})
      : _ch = channel,
        _chat = chat;

  final LinkChannel _ch;
  final LinkChatPort _chat;
  final int chunkSize;
  StreamSubscription<Map<String, dynamic>>? _in;
  StreamSubscription<ChatMessage>? _changes;
  bool _approved = false;

  /// Người dùng đã thấy mã khớp và đồng ý cho web truy cập.
  void approve() {
    if (_approved) return;
    _approved = true;
    unawaited(_ch.send(<String, dynamic>{'t': 'approved'}));
    _in = _ch.messages.listen((m) => unawaited(_onMessage(m)));
    _changes = _chat.changes.listen((m) => unawaited(_ch.send(<String, dynamic>{'t': 'msg', 'm': m.toJson()})));
  }

  Future<void> _onMessage(Map<String, dynamic> m) async {
    switch (m['t']) {
      case 'sync.request':
        await _syncAll();
      case 'send':
        final peer = m['peerId'];
        final text = m['text'];
        final ref = m['ref'];
        if (peer is String && text is String && ref is String) {
          final ok = await _chat.send(peer, text);
          await _ch.send(<String, dynamic>{'t': 'sent', 'ref': ref, 'ok': ok});
        }
    }
  }

  Future<void> _syncAll() async {
    await _ch.send(<String, dynamic>{'t': 'names', 'names': await _chat.names()});
    var total = 0;
    for (final p in await _chat.peers()) {
      final all = await _chat.load(p);
      for (var i = 0; i < all.length; i += chunkSize) {
        final part = all.sublist(i, i + chunkSize > all.length ? all.length : i + chunkSize);
        total += part.length;
        await _ch.send(<String, dynamic>{'t': 'sync.chunk', 'peerId': p, 'messages': [for (final x in part) x.toJson()]});
      }
    }
    await _ch.send(<String, dynamic>{'t': 'sync.done', 'total': total});
  }

  Future<void> dispose() async {
    await _in?.cancel();
    await _changes?.cancel();
    await _ch.close();
  }
}

/// Phía WEB: giữ lịch sử trong BỘ NHỚ (đóng tab là mất), không ghi đĩa.
class LinkClient {
  LinkClient(this._ch) {
    _sub = _ch.messages.listen(_onMessage);
  }

  final LinkChannel _ch;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  final Map<String, Map<String, ChatMessage>> _byPeer = <String, Map<String, ChatMessage>>{};
  final StreamController<void> _changed = StreamController<void>.broadcast();
  final Map<String, String> _names = <String, String>{};
  final Completer<void> _approvedC = Completer<void>();
  final Map<String, Completer<bool>> _pendingSends = <String, Completer<bool>>{};
  Completer<int>? _syncDone;
  int _ref = 0;

  Stream<void> get changed => _changed.stream;

  /// Điện thoại đã bấm "Cho phép".
  Future<void> get approved => _approvedC.future;

  String nameOf(String peerId) => _names[peerId] ?? peerId;
  List<String> get peers => _byPeer.keys.toList();

  List<ChatMessage> messages(String peerId) {
    final list = (_byPeer[peerId]?.values ?? const <ChatMessage>[]).toList();
    list.sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  /// Bấm "Đồng bộ": xin toàn bộ lịch sử. Trả tổng số tin.
  Future<int> sync() {
    _syncDone = Completer<int>();
    unawaited(_ch.send(<String, dynamic>{'t': 'sync.request'}));
    return _syncDone!.future;
  }

  Future<bool> send(String peerId, String text) {
    final ref = 'r${++_ref}';
    final c = _pendingSends[ref] = Completer<bool>();
    unawaited(_ch.send(<String, dynamic>{'t': 'send', 'peerId': peerId, 'text': text, 'ref': ref}));
    return c.future;
  }

  void _put(ChatMessage? m) {
    if (m == null) return;
    (_byPeer[m.peerId] ??= <String, ChatMessage>{})[m.id] = m;
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['t']) {
      case 'approved':
        if (!_approvedC.isCompleted) _approvedC.complete();
      case 'names':
        final n = m['names'];
        if (n is Map) {
          for (final e in n.entries) {
            if (e.key is String && e.value is String) _names[e.key as String] = e.value as String;
          }
        }
      case 'sync.chunk':
        for (final x in (m['messages'] as List? ?? const <Object?>[])) {
          _put(ChatMessage.tryParse(x));
        }
        _changed.add(null);
      case 'sync.done':
        final total = m['total'];
        _syncDone?.complete(total is int ? total : 0);
        _syncDone = null;
      case 'msg':
        _put(ChatMessage.tryParse(m['m']));
        _changed.add(null);
      case 'sent':
        _pendingSends.remove(m['ref'])?.complete(m['ok'] == true);
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    _byPeer.clear();
    await _changed.close();
    await _ch.close();
  }
}
