import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import 'secure_vault.dart';

/// Kho tin nhắn TRÊN MÁY. Mỗi người một tệp JSON-lines. Server không giữ lịch sử.
abstract class ChatStore {
  Future<List<ChatMessage>> load(String peerId);
  Future<void> save(ChatMessage m);
  Future<List<ChatMessage>> pending();
  Future<bool> has(String peerId, String id);
  Future<List<String>> peers();
  Future<String?> readSecret();
  Future<void> writeSecret(String value);
  Future<void> clearAll();

  /// Kho khóa-giá trị nhỏ cho trạng thái Double Ratchet (cùng chỗ với lịch sử, bị xóa cùng `clearAll`).
  Future<String?> readKv(String k);
  Future<void> writeKv(String k, String v);
}

class MemoryChatStore implements ChatStore {
  final Map<String, Map<String, ChatMessage>> _byPeer = <String, Map<String, ChatMessage>>{};
  String? _secret;
  final Map<String, String> _kv = <String, String>{};

  @override
  Future<String?> readKv(String k) async => _kv[k];

  @override
  Future<void> writeKv(String k, String v) async => _kv[k] = v;

  @override
  Future<List<ChatMessage>> load(String peerId) async {
    final list = (_byPeer[peerId]?.values ?? const <ChatMessage>[]).toList();
    list.sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  @override
  Future<void> save(ChatMessage m) async => (_byPeer[m.peerId] ??= <String, ChatMessage>{})[m.id] = m;

  @override
  Future<List<ChatMessage>> pending() async => [
        for (final box in _byPeer.values)
          for (final m in box.values)
            if (m.mine && m.status == ChatStatus.sending) m,
      ];

  @override
  Future<bool> has(String peerId, String id) async => _byPeer[peerId]?.containsKey(id) ?? false;

  @override
  Future<List<String>> peers() async => _byPeer.keys.toList();

  @override
  Future<String?> readSecret() async => _secret;

  @override
  Future<void> writeSecret(String value) async => _secret = value;

  @override
  Future<void> clearAll() async {
    _byPeer.clear();
    _secret = null;
    _kv.clear();
  }
}

class FileChatStore implements ChatStore {
  Directory? _dir;
  final Map<String, Map<String, ChatMessage>> _cache = <String, Map<String, ChatMessage>>{};

  Future<Directory> _root() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/chat');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<Map<String, ChatMessage>> _box(String peerId) async {
    final cached = _cache[peerId];
    if (cached != null) return cached;
    final map = <String, ChatMessage>{};
    final f = File('${(await _root()).path}/${_safe(peerId)}.jsonl');
    if (await f.exists()) {
      for (final line in await f.readAsLines()) {
        if (line.trim().isEmpty) continue;
        try {
          final m = ChatMessage.tryParse(jsonDecode(line));
          if (m != null) map[m.id] = m;
        } on FormatException {
          // bỏ dòng hỏng
        }
      }
    }
    return _cache[peerId] = map;
  }

  Future<void> _rewrite(String peerId) async {
    final f = File('${(await _root()).path}/${_safe(peerId)}.jsonl');
    final box = _cache[peerId] ?? <String, ChatMessage>{};
    final msgs = box.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    await f.writeAsString(msgs.map((m) => jsonEncode(m.toJson())).join('\n') + (msgs.isEmpty ? '' : '\n'));
  }

  @override
  Future<List<ChatMessage>> load(String peerId) async {
    final list = (await _box(peerId)).values.toList()..sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  @override
  Future<void> save(ChatMessage m) async {
    final box = await _box(m.peerId);
    final isNew = !box.containsKey(m.id);
    box[m.id] = m;
    if (isNew) {
      final f = File('${(await _root()).path}/${_safe(m.peerId)}.jsonl');
      await f.writeAsString('${jsonEncode(m.toJson())}\n', mode: FileMode.append);
    } else {
      await _rewrite(m.peerId);
    }
  }

  @override
  Future<List<ChatMessage>> pending() async {
    final out = <ChatMessage>[];
    for (final p in await peers()) {
      out.addAll((await _box(p)).values.where((m) => m.mine && m.status == ChatStatus.sending));
    }
    return out;
  }

  @override
  Future<bool> has(String peerId, String id) async => (await _box(peerId)).containsKey(id);

  @override
  Future<List<String>> peers() async {
    final names = <String>{..._cache.keys};
    final d = await _root();
    await for (final e in d.list()) {
      if (e is File && e.path.endsWith('.jsonl')) {
        final n = e.uri.pathSegments.last;
        names.add(n.substring(0, n.length - '.jsonl'.length));
      }
    }
    return names.toList();
  }

  @override
  Future<String?> readKv(String k) async => (await SharedPreferences.getInstance()).getString('chat_kv_$k');

  @override
  Future<void> writeKv(String k, String v) async => (await SharedPreferences.getInstance()).setString('chat_kv_$k', v);

  @override
  Future<String?> readSecret() async => (await SharedPreferences.getInstance()).getString('chat_seed');

  @override
  Future<void> writeSecret(String value) async =>
      (await SharedPreferences.getInstance()).setString('chat_seed', value);

  @override
  Future<void> clearAll() async {
    final d = await _root();
    if (await d.exists()) await d.delete(recursive: true);
    _dir = null;
    _cache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_seed');
    for (final k in prefs.getKeys().where((k) => k.startsWith('chat_kv_')).toList()) {
      await prefs.remove(k);
    }
  }
}

/// Kho SQLite trên máy (sqflite). Thay cho tệp JSON-lines: truy vấn theo người, chỉ mục theo thời gian,
/// ghi một dòng thay vì viết lại cả tệp. Lần mở đầu tiên tự nhập lịch sử cũ từ [FileChatStore].
///
/// Nội dung tin được mã hóa từng dòng (AES-256-GCM, tiền tố `e1:`) bằng khóa ngẫu nhiên giữ trong
/// [SecureVault] (Keystore/Keychain); khóa chat riêng cũng nằm ở đó. Tên người, thời gian vẫn là chữ thường.
/// Hủy khóa `db_key` là mất toàn bộ nội dung ngay cả khi tệp còn lại.
class SqliteChatStore implements ChatStore {
  SqliteChatStore({SecureVault? vault}) : _vault = vault ?? FlutterSecureVault();

  final SecureVault _vault;
  Database? _db;
  SecretKey? _key;
  final AesGcm _aes = AesGcm.with256bits();

  Future<SecretKey> _dataKey() async {
    final cached = _key;
    if (cached != null) return cached;
    var b64 = await _vault.read('db_key');
    if (b64 == null) {
      final rnd = Random.secure();
      b64 = base64.encode(List<int>.generate(32, (_) => rnd.nextInt(256)));
      await _vault.write('db_key', b64);
    }
    return _key = SecretKey(base64.decode(b64));
  }

  Future<String> _seal(String plain) async {
    final box = await _aes.encrypt(utf8.encode(plain), secretKey: await _dataKey());
    return 'e1:${base64.encode(box.concatenation())}';
  }

  Future<String?> _unseal(String stored) async {
    if (!stored.startsWith('e1:')) return stored; // dòng cũ chưa mã hóa
    try {
      final box = SecretBox.fromConcatenation(base64.decode(stored.substring(3)), nonceLength: 12, macLength: 16);
      return utf8.decode(await _aes.decrypt(box, secretKey: await _dataKey()));
    } on Object {
      return null; // khóa đã bị hủy / dữ liệu hỏng
    }
  }

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      '$dir/cham_chat.db',
      version: 1,
      onCreate: (d, _) async {
        await d.execute('CREATE TABLE msg('
            'id TEXT NOT NULL, peer TEXT NOT NULL, mine INTEGER NOT NULL, text TEXT NOT NULL, '
            'at INTEGER NOT NULL, status TEXT NOT NULL, PRIMARY KEY(peer, id))');
        await d.execute('CREATE INDEX msg_peer_at ON msg(peer, at)');
        await d.execute('CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT NOT NULL)');
      },
    );
    _db = db;
    await _importLegacy(db);
    await _sealPlainRows(db);
    return db;
  }

  /// Mã hóa nốt các dòng còn ở dạng chữ thường (từ bản trước).
  Future<void> _sealPlainRows(Database db) async {
    try {
      final rows = await db.query('msg', columns: ['peer', 'id', 'text'], where: "text NOT LIKE 'e1:%'");
      for (final r in rows) {
        await db.update(
          'msg',
          {'text': await _seal(r['text']! as String)},
          where: 'peer = ? AND id = ?',
          whereArgs: [r['peer'], r['id']],
        );
      }
    } catch (_) {
      // lần mở sau thử lại
    }
  }

  Future<void> _importLegacy(Database db) async {
    try {
      final done = await db.query('kv', where: 'k = ?', whereArgs: ['legacy_imported']);
      if (done.isNotEmpty) return;
      final old = FileChatStore();
      final batch = db.batch();
      for (final p in await old.peers()) {
        for (final m in await old.load(p)) {
          batch.insert('msg', await _row(m), conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      final seed = await old.readSecret();
      if (seed != null) {
        batch.insert('kv', {'k': 'seed', 'v': seed}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      batch.insert('kv', {'k': 'legacy_imported', 'v': '1'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await batch.commit(noResult: true);
    } catch (_) {
      // không nhập được thì thôi, không chặn app
    }
  }

  Future<Map<String, Object?>> _row(ChatMessage m) async => <String, Object?>{
        'id': m.id,
        'peer': m.peerId,
        'mine': m.mine ? 1 : 0,
        'text': await _seal(m.text),
        'at': m.at.toUtc().millisecondsSinceEpoch,
        'status': m.status.name,
      };

  Future<ChatMessage?> _from(Map<String, Object?> r) async {
    final st = ChatStatus.values.where((s) => s.name == r['status']);
    if (st.isEmpty) return null;
    final text = await _unseal(r['text']! as String);
    if (text == null) return null;
    return ChatMessage(
      id: r['id']! as String,
      peerId: r['peer']! as String,
      mine: (r['mine']! as int) == 1,
      text: text,
      at: DateTime.fromMillisecondsSinceEpoch(r['at']! as int, isUtc: true),
      status: st.first,
    );
  }

  @override
  Future<List<ChatMessage>> load(String peerId) async {
    final db = await _open();
    final rows = await db.query('msg', where: 'peer = ?', whereArgs: [peerId], orderBy: 'at ASC');
    return [for (final r in rows) ?await _from(r)];
  }

  @override
  Future<void> save(ChatMessage m) async {
    final db = await _open();
    await db.insert('msg', await _row(m), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<List<ChatMessage>> pending() async {
    final db = await _open();
    final rows = await db.query('msg', where: 'mine = 1 AND status = ?', whereArgs: [ChatStatus.sending.name]);
    return [for (final r in rows) ?await _from(r)];
  }

  @override
  Future<bool> has(String peerId, String id) async {
    final db = await _open();
    final rows = await db.query('msg', columns: ['id'], where: 'peer = ? AND id = ?', whereArgs: [peerId, id], limit: 1);
    return rows.isNotEmpty;
  }

  @override
  Future<List<String>> peers() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT DISTINCT peer FROM msg');
    return [for (final r in rows) r['peer']! as String];
  }

  @override
  Future<String?> readSecret() async {
    final v = await _vault.read('chat_seed');
    if (v != null) return v;
    // Di chuyển khóa chat từ bảng kv (bản cũ) sang kho bảo mật.
    final db = await _open();
    final rows = await db.query('kv', where: 'k = ?', whereArgs: ['seed']);
    final old = rows.isEmpty ? null : rows.first['v'] as String?;
    if (old != null) {
      await _vault.write('chat_seed', old);
      await db.delete('kv', where: 'k = ?', whereArgs: ['seed']);
    }
    return old;
  }

  @override
  Future<String?> readKv(String k) async {
    final db = await _open();
    final rows = await db.query('kv', where: 'k = ?', whereArgs: ['x:$k']);
    if (rows.isEmpty) return null;
    return _unseal(rows.first['v']! as String);
  }

  @override
  Future<void> writeKv(String k, String v) async {
    final db = await _open();
    await db.insert('kv', <String, Object?>{'k': 'x:$k', 'v': await _seal(v)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> writeSecret(String value) => _vault.write('chat_seed', value);

  @override
  Future<void> clearAll() async {
    final db = await _open();
    await _vault.delete('db_key'); // hủy khóa trước
    _key = null;
    await db.delete('msg');
    await db.delete('kv');
    await _vault.delete('chat_seed');
    await FileChatStore().clearAll();
  }
}
