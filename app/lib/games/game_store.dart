import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import 'game_models.dart';

class GameStoreException implements Exception {
  GameStoreException(this.message);
  final String message;
  @override
  String toString() => 'GameStoreException: $message';
}

/// Tải, kiểm (sha256 + Ed25519), giải nén an toàn và giữ tối đa 2 phiên bản mỗi game.
class GameStore {
  GameStore({
    required this.rootDir,
    required this.publicKey,
    http.Client? client,
    this.maxBundleBytes = 20 * 1024 * 1024,
    this.maxUnpackedBytes = 60 * 1024 * 1024,
    this.baseUrl = '',
  }) : _http = client ?? http.Client();

  /// Thư mục gốc (tạo lười; app dùng getApplicationSupportDirectory()/games).
  final Future<Directory> Function() rootDir;
  final List<int> publicKey;
  final http.Client _http;
  final int maxBundleBytes;
  final int maxUnpackedBytes;

  /// Ghép với URL tương đối (`/media/...`) của catalogue.
  final String baseUrl;

  static List<int> hexToBytes(String h) => [for (var i = 0; i + 1 < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

  static String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  /// Thông điệp ký — khớp `cham-game-pack`.
  static List<int> sigMessage(String id, String version, String shaHex) => utf8.encode('cgp1:$id:$version:$shaHex');

  Future<bool> verify(GameCatalogEntry e, Uint8List data) async {
    if (publicKey.length != 32) return false;
    final digest = hex((await Sha256().hash(data)).bytes);
    if (digest != e.sha256) return false;
    try {
      return await Ed25519().verify(
        sigMessage(e.id, e.version, digest),
        signature: Signature(base64.decode(e.sig), publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
      );
    } on Object {
      return false;
    }
  }

  Future<Directory> _gameDir(String id) async => Directory('${(await rootDir()).path}/$id');

  /// Bản đã cài của [id] ở đúng [version] (và sha nếu có), hoặc null.
  Future<InstalledGame?> installed(String id, {String? version, String? sha256}) async {
    final gd = await _gameDir(id);
    final cur = File('${gd.path}/current.json');
    if (!await cur.exists()) return null;
    try {
      final m = jsonDecode(await cur.readAsString()) as Map<String, dynamic>;
      final v = m['version'] as String, s = m['sha256'] as String;
      if (version != null && v != version) return null;
      if (sha256 != null && s != sha256) return null;
      final d = Directory('${gd.path}/$v');
      if (!await d.exists()) return null;
      return InstalledGame(id: id, version: v, sha256: s, dir: d.path);
    } on Object {
      return null;
    }
  }

  Future<List<InstalledGame>> allInstalled() async {
    final root = await rootDir();
    if (!await root.exists()) return const [];
    final out = <InstalledGame>[];
    await for (final e in root.list()) {
      if (e is Directory) {
        final g = await installed(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
        if (g != null) out.add(g);
      }
    }
    return out;
  }

  final Map<String, Future<InstalledGame>> _inflight = {};

  /// Đảm bảo có đúng bản [e] trên máy (tải nếu thiếu). Gộp các lệnh đồng thời.
  Future<InstalledGame> ensure(GameCatalogEntry e, {Duration timeout = const Duration(seconds: 20)}) {
    return _inflight.putIfAbsent('${e.id}@${e.version}', () => _ensure(e, timeout).whenComplete(() => _inflight.remove('${e.id}@${e.version}')));
  }

  Future<InstalledGame> _ensure(GameCatalogEntry e, Duration timeout) async {
    if (e.apiLevel > kGameApiLevel) throw GameStoreException('apiLevel');
    final have = await installed(e.id, version: e.version, sha256: e.sha256);
    if (have != null) return have;
    final url = e.url.startsWith('/') ? '$baseUrl${e.url}' : e.url;
    final res = await _http.get(Uri.parse(url)).timeout(timeout);
    if (res.statusCode != 200) throw GameStoreException('http ${res.statusCode}');
    final data = res.bodyBytes;
    if (data.length > maxBundleBytes) throw GameStoreException('too big');
    if (!await verify(e, data)) throw GameStoreException('bad signature');
    return _install(e, data);
  }

  Future<InstalledGame> _install(GameCatalogEntry e, Uint8List data) async {
    final archive = ZipDecoder().decodeBytes(data);
    var total = 0;
    final gd = await _gameDir(e.id);
    final tmp = Directory('${gd.path}/.tmp-${e.version}');
    if (await tmp.exists()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    try {
      var hasManifest = false;
      for (final f in archive) {
        if (!f.isFile) continue;
        final name = f.name.replaceAll('\\', '/');
        if (name.startsWith('/') || name.split('/').contains('..') || name.split('/').any((s) => s.isEmpty)) {
          throw GameStoreException('bad path');
        }
        total += f.size;
        if (total > maxUnpackedBytes) throw GameStoreException('unpacked too big');
        final out = File('${tmp.path}/$name');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(f.content as List<int>);
        if (name == 'manifest.json') {
          hasManifest = true;
          final m = jsonDecode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
          if (m['id'] != e.id || m['version'] != e.version) throw GameStoreException('manifest mismatch');
        }
      }
      if (!hasManifest) throw GameStoreException('no manifest');
      final dest = Directory('${gd.path}/${e.version}');
      if (await dest.exists()) await dest.delete(recursive: true);
      await tmp.rename(dest.path);
      await File('${gd.path}/current.json').writeAsString(jsonEncode({'version': e.version, 'sha256': e.sha256}));
      await _prune(gd, keep: e.version);
      return InstalledGame(id: e.id, version: e.version, sha256: e.sha256, dir: dest.path);
    } finally {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    }
  }

  /// Giữ bản mới + 1 bản trước.
  Future<void> _prune(Directory gd, {required String keep}) async {
    final dirs = <Directory>[];
    await for (final d in gd.list()) {
      if (d is Directory && !d.path.contains('.tmp-')) dirs.add(d);
    }
    dirs.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    final old = dirs.where((d) => !d.path.endsWith('/$keep')).toList();
    while (old.length > 1) {
      await old.removeAt(0).delete(recursive: true);
    }
  }
}
