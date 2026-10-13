import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// Một bản nhạc (nhạc chờ hoặc chuông) trong cấu hình từ xa.
class MediaItem {
  const MediaItem({required this.id, required this.title, required this.url, this.sha256, this.bytes});

  final String id;
  final String title;
  final String url;
  final String? sha256;
  final int? bytes;

  static MediaItem? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    final title = j['title'];
    final url = j['url'];
    if (id is! String || title is! String || url is! String) return null;
    return MediaItem(
      id: id,
      title: title,
      url: url,
      sha256: j['sha256'] is String ? j['sha256'] as String : null,
      bytes: j['bytes'] is num ? (j['bytes'] as num).toInt() : null,
    );
  }
}

/// Cấu hình từ xa: lấy từ `GET /v1/config`, lưu bản cuối trên máy, tải nhạc về một lần.
/// Thêm/đổi nhạc hay chuông chỉ cần sửa cấu hình trên server, không phải cập nhật app.
class RemoteConfigService extends ChangeNotifier {
  RemoteConfigService({required ApiClient api, http.Client? client, int maxTrackBytes = 8 * 1024 * 1024})
      : _api = api,
        _http = client ?? http.Client(),
        _maxTrackBytes = maxTrackBytes;

  final ApiClient _api;
  final http.Client _http;
  final int _maxTrackBytes;

  List<MediaItem> waitingMusic = const <MediaItem>[];
  List<MediaItem> ringtones = const <MediaItem>[];
  List<MediaItem> backgrounds = const <MediaItem>[];
  List<Map<String, dynamic>> themes = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> games = const <Map<String, dynamic>>[];
  final Map<String, File> _files = <String, File>{};
  bool _refreshing = false;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/media');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  List<MediaItem> _items(Object? v) =>
      v is List ? v.map(MediaItem.tryParse).whereType<MediaItem>().toList(growable: false) : const <MediaItem>[];

  List<Map<String, dynamic>> _maps(Object? v) =>
      v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList(growable: false) : const <Map<String, dynamic>>[];

  /// Tải cấu hình (lỗi mạng: dùng bản đã lưu) rồi tải các bài nhạc còn thiếu.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final dir = await _dir();
      final cache = File('${dir.path}/config.json');
      Map<String, dynamic>? cfg;
      try {
        cfg = await _api.getRemoteConfig();
        await cache.writeAsString(jsonEncode(cfg));
      } on Object {
        if (await cache.exists()) {
          final decoded = jsonDecode(await cache.readAsString());
          if (decoded is Map) cfg = Map<String, dynamic>.from(decoded);
        }
      }
      if (cfg == null) return;
      waitingMusic = _items(cfg['waitingMusic']);
      ringtones = _items(cfg['ringtones']);
      backgrounds = _items(cfg['backgrounds']);
      themes = _maps(cfg['themes']);
      games = _maps(cfg['games']);
      notifyListeners();
      for (final item in <MediaItem>[...waitingMusic, ...ringtones, ...backgrounds]) {
        await _ensureDownloaded(dir, item);
      }
      notifyListeners();
    } on Object catch (e) {
      debugPrint('remote config: $e');
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _ensureDownloaded(Directory dir, MediaItem item) async {
    final safe = item.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final file = File('${dir.path}/$safe.${(item.sha256 != null && item.sha256!.length >= 12) ? item.sha256!.substring(0, 12) : 'bin'}');
    if (await file.exists()) {
      _files[item.id] = file;
      return;
    }
    if (!item.url.startsWith('https://')) return; // chỉ tải qua HTTPS
    try {
      final res = await _http.get(Uri.parse(item.url)).timeout(const Duration(seconds: 60));
      if (res.statusCode != 200 || res.bodyBytes.length > _maxTrackBytes) return;
      final want = item.sha256;
      if (want != null) {
        final got = await Sha256().hash(res.bodyBytes);
        final hex = got.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (hex != want) return; // sai mã băm: bỏ
      }
      await file.writeAsBytes(res.bodyBytes);
      _files[item.id] = file;
    } on Object catch (e) {
      debugPrint('media download failed (${item.id}): $e');
    }
  }

  /// Một bài nhạc chờ ngẫu nhiên đã tải xong (hoặc null).
  File? randomWaitingTrack([Random? rng]) {
    final ready = waitingMusic.where((m) => _files.containsKey(m.id)).toList();
    if (ready.isEmpty) return null;
    return _files[ready[(rng ?? Random()).nextInt(ready.length)].id];
  }

  File? ringtoneFile(String id) => _files[id];

  /// Ảnh nền cuộc gọi đã tải xong (hoặc null).
  File? backgroundFile(String id) => _files[id];

  @override
  void dispose() {
    _http.close();
    super.dispose();
  }
}

/// Âm thanh lặp: nhạc chờ (đang tìm người / đang chờ bạn nghe máy) và chuông (có cuộc gọi đến khi app đang mở).
/// Ưu tiên bài tải từ máy chủ (remote-config); chưa có thì dùng bài ĐÓNG GÓI sẵn trong app nên luôn có tiếng.
class WaitingMusic {
  WaitingMusic(this._config, {AudioPlayer? player, this.ringing = false}) : _player = player;

  static const bundledWaiting = ['audio/wait_diu.mp3', 'audio/wait_tram.mp3', 'audio/wait_sang.mp3'];
  static const bundledRings = ['audio/ring_chuong.mp3', 'audio/ring_nhip.mp3', 'audio/ring_sang.mp3'];

  final RemoteConfigService _config;
  final bool ringing;
  AudioPlayer? _player;
  bool _on = false;

  bool get isPlaying => _on;

  Future<void> start() async {
    if (_on) return;
    _on = true;
    try {
      final p = _player ??= AudioPlayer();
      await p.setReleaseMode(ReleaseMode.loop);
      await p.setVolume(ringing ? 0.9 : 0.5);
      final rng = Random();
      final remote = ringing ? null : _config.randomWaitingTrack(rng);
      if (remote != null) {
        await p.play(DeviceFileSource(remote.path));
      } else {
        final list = ringing ? bundledRings : bundledWaiting;
        await p.play(AssetSource(list[rng.nextInt(list.length)]));
      }
    } on Object catch (e) {
      debugPrint('waiting music: $e');
      _on = false;
    }
  }

  Future<void> stop() async {
    if (!_on) return;
    _on = false;
    try {
      await _player?.stop();
    } on Object {
      // bỏ qua
    }
  }

  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
  }
}
