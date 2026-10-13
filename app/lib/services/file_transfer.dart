import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'chat_crypto.dart';
import 'direct_dm.dart';

/// Lời đề nghị gửi tệp đang chờ người nhận đồng ý.
class FileOffer {
  const FileOffer({required this.id, required this.peerId, required this.name, required this.size});
  final String id;
  final String peerId;
  final String name;
  final int size;
}

/// Gửi tệp TRỰC TIẾP giữa hai bạn bè đang cùng online (WebRTC DataChannel qua [DirectDm]).
/// Tệp không đi qua server và không được lưu ở đâu ngoài hai máy. Mỗi tệp một khóa AES-256-GCM ngẫu nhiên
/// (gói bằng khóa chung của hai người), mỗi mảnh gắn mã tệp + số thứ tự. Người nhận phải đồng ý trước.
/// Offline thì không gửi được (không có hộp thư cho tệp). CHƯA THỬ TRÊN MÁY THẬT.
class FileTransfer {
  FileTransfer({
    required DirectDm direct,
    required ChatCrypto crypto,
    required Future<String?> Function(String peerId) peerKey,
    required Future<Directory> Function() baseDir,
    required void Function(FileOffer offer) onOffer,
    required void Function(String peerId, String id, String name, int size, String path) onReceived,
  })  : _direct = direct,
        _crypto = crypto,
        _peerKey = peerKey,
        _baseDir = baseDir,
        _onOffer = onOffer,
        _onReceived = onReceived;

  static const maxBytes = 25 * 1024 * 1024;
  static const chunkBytes = 8 * 1024;
  static const window = 8; // số mảnh gửi trước khi chờ báo nhận
  static const waitAccept = Duration(seconds: 60);
  static const waitAck = Duration(seconds: 15);

  final DirectDm _direct;
  final ChatCrypto _crypto;
  final Future<String?> Function(String peerId) _peerKey;
  final Future<Directory> Function() _baseDir;
  final void Function(FileOffer offer) _onOffer;
  final void Function(String peerId, String id, String name, int size, String path) _onReceived;

  /// Tiến độ 0..1 theo mã tệp (gửi hoặc nhận); UI lắng nghe.
  final Map<String, ValueNotifier<double>> progress = <String, ValueNotifier<double>>{};

  final Map<String, Completer<bool>> _accepts = <String, Completer<bool>>{};
  final Map<String, Completer<int>> _acks = <String, Completer<int>>{};
  final Map<String, Completer<bool>> _results = <String, Completer<bool>>{};
  final Map<String, _Incoming> _incoming = <String, _Incoming>{};

  static String safeName(String raw) {
    final base = raw.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[\u0000-\u001F<>:"|?*]'), '_').trim();
    final n = base.isEmpty || base == '.' || base == '..' ? 'tep' : base;
    return n.length > 80 ? n.substring(n.length - 80) : n;
  }

  /// Đường dẫn cố định của tệp đã nhận (UI dùng để mở lại).
  Future<String> pathFor(String peerId, String id, String name) async {
    final d = await _baseDir();
    return '${d.path}/cham_files/$peerId/${id}_${safeName(name)}';
  }

  static String _newId() {
    final r = Random.secure();
    return List<int>.generate(12, (_) => r.nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // --- gửi -------------------------------------------------------------------------

  /// Trả `null` nếu gửi xong; ngược lại mã lỗi: `too_big`, `offline`, `no_key`, `declined`, `timeout`, `failed`.
  Future<String?> send(String peerId, String name, Uint8List bytes, {void Function(String id)? onStart}) async {
    if (bytes.isEmpty || bytes.length > maxBytes) return 'too_big';
    if (!await _direct.ensureOpen(peerId)) return 'offline';
    final peerKey = await _peerKey(peerId);
    if (peerKey == null) return 'no_key';
    final id = _newId();
    onStart?.call(id);
    final prog = progress[id] = ValueNotifier<double>(0);
    try {
      final key = await _crypto.newFileKey();
      final sha = base64.encode((await Sha256().hash(bytes)).bytes);
      final accept = _accepts[id] = Completer<bool>();
      final offer = <String, dynamic>{
        't': 'ft.offer',
        'id': id,
        'name': safeName(name),
        'size': bytes.length,
        'sha': sha,
        'key': await _crypto.wrapFileKey(peerKey, key),
      };
      if (!_direct.sendRaw(peerId, offer)) return 'offline';
      final ok = await accept.future.timeout(waitAccept, onTimeout: () => false);
      if (!ok) return accept.isCompleted ? 'declined' : 'timeout';
      final total = (bytes.length + chunkBytes - 1) ~/ chunkBytes;
      for (var n = 0; n < total; n++) {
        final part = Uint8List.sublistView(bytes, n * chunkBytes, min(bytes.length, (n + 1) * chunkBytes));
        final sealed = await _crypto.sealChunk(key, part, '$id:$n');
        if (!_direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.chunk', 'id': id, 'n': n, 'd': base64.encode(sealed)})) return 'failed';
        prog.value = (n + 1) / total * 0.95;
        if ((n + 1) % window == 0 && n + 1 < total) {
          final ack = _acks[id] = Completer<int>();
          final upto = await ack.future.timeout(waitAck, onTimeout: () => -1);
          if (upto < n) return 'timeout';
        }
      }
      final res = _results[id] = Completer<bool>();
      if (!_direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.done', 'id': id})) return 'failed';
      final fin = await res.future.timeout(waitAck, onTimeout: () => false);
      if (!fin) return 'failed';
      prog.value = 1;
      return null;
    } on Object catch (e) {
      debugPrint('file send failed: $e');
      return 'failed';
    } finally {
      _accepts.remove(id);
      _acks.remove(id);
      _results.remove(id);
    }
  }

  // --- nhận ------------------------------------------------------------------------

  void accept(String id) {
    final inc = _incoming[id];
    if (inc == null || inc.accepted) return;
    inc.accepted = true;
    progress[id] = ValueNotifier<double>(0);
    _direct.sendRaw(inc.peerId, <String, dynamic>{'t': 'ft.accept', 'id': id});
  }

  void decline(String id) {
    final inc = _incoming.remove(id);
    if (inc != null) _direct.sendRaw(inc.peerId, <String, dynamic>{'t': 'ft.deny', 'id': id});
  }

  /// Khung `ft.*` từ máy bạn bè (dữ liệu không tin cậy: kiểm tra chặt).
  void handle(String peerId, Map<String, dynamic> m) {
    unawaited(_handle(peerId, m).catchError((Object e) {
      debugPrint('file transfer error: $e');
      final id = m['id'];
      if (id is String) _drop(id);
    }));
  }

  Future<void> _handle(String peerId, Map<String, dynamic> m) async {
    final id = m['id'];
    if (id is! String || id.isEmpty || id.length > 40) return;
    switch (m['t']) {
      case 'ft.offer':
        final name = m['name'];
        final size = m['size'];
        final sha = m['sha'];
        final wrapped = m['key'];
        if (name is! String || size is! int || size <= 0 || size > maxBytes || sha is! String || wrapped is! String) {
          _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.deny', 'id': id});
          return;
        }
        if (_incoming.length >= 3 || _incoming.containsKey(id)) return; // chống tràn bộ nhớ / lặp
        final peerKey = await _peerKey(peerId);
        if (peerKey == null) return;
        final key = await _crypto.unwrapFileKey(peerKey, wrapped);
        _incoming[id] = _Incoming(peerId, safeName(name), size, sha, key);
        Timer(const Duration(minutes: 2), () {
          final inc = _incoming[id];
          if (inc != null && !inc.accepted) decline(id); // không trả lời thì từ chối
        });
        _onOffer(FileOffer(id: id, peerId: peerId, name: safeName(name), size: size));
      case 'ft.accept':
        _accepts[id]?.complete(true);
      case 'ft.deny':
        _accepts[id]?.complete(false);
      case 'ft.ack':
        final upto = m['upto'];
        if (upto is int) _acks[id]?.complete(upto);
      case 'ft.ok':
        _results[id]?.complete(true);
      case 'ft.bad':
        _results[id]?.complete(false);
      case 'ft.chunk':
        final inc = _incoming[id];
        final n = m['n'];
        final d = m['d'];
        if (inc == null || !inc.accepted || inc.peerId != peerId || n is! int || d is! String) return;
        if (n != inc.next) {
          _drop(id); // sai thứ tự: hủy
          _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.bad', 'id': id});
          return;
        }
        final plain = await _crypto.openChunk(inc.key, base64.decode(d), '$id:$n');
        inc.buf.add(plain);
        inc.next++;
        if (inc.buf.length > inc.size) {
          _drop(id);
          _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.bad', 'id': id});
          return;
        }
        progress[id]?.value = inc.buf.length / inc.size * 0.95;
        if (inc.next % window == 0) {
          _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.ack', 'id': id, 'upto': n});
        }
      case 'ft.done':
        final inc = _incoming[id];
        if (inc == null || !inc.accepted || inc.peerId != peerId) return;
        final data = inc.buf.takeBytes();
        final sha = base64.encode((await Sha256().hash(data)).bytes);
        if (data.length != inc.size || sha != inc.sha) {
          _drop(id);
          _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.bad', 'id': id});
          return;
        }
        final path = await pathFor(peerId, id, inc.name);
        final f = File(path);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(data, flush: true);
        _incoming.remove(id);
        progress[id]?.value = 1;
        _direct.sendRaw(peerId, <String, dynamic>{'t': 'ft.ok', 'id': id});
        _onReceived(peerId, id, inc.name, inc.size, path);
    }
  }

  void _drop(String id) {
    _incoming.remove(id);
  }

  void dispose() {
    for (final c in [..._accepts.values]) {
      if (!c.isCompleted) c.complete(false);
    }
    _incoming.clear();
  }
}

class _Incoming {
  _Incoming(this.peerId, this.name, this.size, this.sha, this.key);
  final String peerId;
  final String name;
  final int size;
  final String sha;
  final SecretKey key;
  final BytesBuilder buf = BytesBuilder(copy: false);
  bool accepted = false;
  int next = 0;
}
