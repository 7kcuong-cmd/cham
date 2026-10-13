import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../services/call_service.dart';
import 'game_models.dart';
import 'game_store.dart';

enum GamePhase { idle, preparing, inviting, incoming, playing, ended }

/// Giao thức `game.*` qua kênh dữ liệu P2P `cham`. Mọi tin từ đối phương đều không đáng tin:
/// chỉ chuyển nguyên văn cho game (game tự kiểm luật), có giới hạn kích thước và tốc độ.
class GameSessionController extends ChangeNotifier {
  GameSessionController({
    required CallService call,
    required GameStore store,
    required List<GameCatalogEntry> Function() catalog,
    Random? random,
    DateTime Function()? now,
    this.inviteTimeout = const Duration(seconds: 30),
  })  : _call = call,
        _store = store,
        _catalog = catalog,
        _rng = random ?? Random.secure(),
        _now = now ?? DateTime.now {
    _sub = _call.dataMessages.listen(_onData);
  }

  static const int maxReliable = 8 * 1024;
  static const int maxFast = 1024;
  static const int maxPerSecond = 60;

  final CallService _call;
  final GameStore _store;
  final List<GameCatalogEntry> Function() _catalog;
  final Random _rng;
  final DateTime Function() _now;
  final Duration inviteTimeout;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _timer;

  GamePhase phase = GamePhase.idle;
  GameCatalogEntry? entry;
  InstalledGame? installed;
  int sid = 0;
  int me = 0;
  int seed = 0;
  String? result;
  String? notice;

  final StreamController<Map<String, dynamic>> _toGame = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> _buffer = [];
  bool _viewReady = false;
  Future<InstalledGame>? _preload;
  final List<DateTime> _recent = [];

  /// Tin gửi vào WebView (`init` / `msg`).
  Stream<Map<String, dynamic>> get toGame => _toGame.stream;

  bool get busy => phase != GamePhase.idle && phase != GamePhase.ended;

  void _set(GamePhase p, {String? note}) {
    phase = p;
    notice = note;
    notifyListeners();
  }

  void reset() {
    _timer?.cancel();
    phase = GamePhase.idle;
    entry = null;
    installed = null;
    result = null;
    notice = null;
    _viewReady = false;
    _buffer.clear();
    _preload = null;
    notifyListeners();
  }

  // ---- bên mời ----
  Future<void> invite(GameCatalogEntry e) async {
    if (busy) return;
    entry = e;
    result = null;
    _set(GamePhase.preparing);
    try {
      installed = await _store.ensure(e);
    } on Object {
      return _set(GamePhase.ended, note: 'download');
    }
    sid = _rng.nextInt(1 << 31);
    if (!_call.sendData({'type': 'game.invite', 'sid': sid, 'id': e.id, 'version': e.version, 'sha256': e.sha256})) {
      return _set(GamePhase.ended, note: 'no_p2p');
    }
    _set(GamePhase.inviting);
    _timer?.cancel();
    _timer = Timer(inviteTimeout, () {
      if (phase == GamePhase.inviting) {
        _call.sendData({'type': 'game.decline', 'sid': sid, 'reason': 'timeout'});
        _set(GamePhase.ended, note: 'timeout');
      }
    });
  }

  void cancelInvite() {
    if (phase == GamePhase.inviting) {
      _call.sendData({'type': 'game.decline', 'sid': sid, 'reason': 'cancel'});
      _set(GamePhase.ended);
    }
  }

  // ---- bên được mời ----
  Future<void> accept() async {
    if (phase != GamePhase.incoming) return;
    final pre = _preload;
    if (pre == null) return;
    try {
      installed = await pre;
    } on Object {
      _call.sendData({'type': 'game.decline', 'sid': sid, 'reason': 'download'});
      return _set(GamePhase.ended, note: 'download');
    }
    if (phase != GamePhase.incoming) return;
    _call.sendData({'type': 'game.accept', 'sid': sid});
  }

  void decline() {
    if (phase != GamePhase.incoming) return;
    _call.sendData({'type': 'game.decline', 'sid': sid, 'reason': 'declined'});
    _set(GamePhase.ended);
  }

  // ---- thoát ----
  void close() {
    if (phase == GamePhase.playing) _call.sendData({'type': 'game.end', 'sid': sid, 'result': 'abort'});
    if (phase == GamePhase.inviting) cancelInvite();
    reset();
  }

  // ---- cầu nối WebView ----
  /// Tin từ game (JS) — [raw] là chuỗi JSON.
  void fromGame(String raw) {
    if (phase != GamePhase.playing) return;
    Map<String, dynamic> m;
    try {
      final d = jsonDecode(raw);
      if (d is! Map<String, dynamic>) return;
      m = d;
    } on Object {
      return;
    }
    switch (m['t']) {
      case 'ready':
        _viewReady = true;
        _toGame.add({
          't': 'init',
          'data': {'me': me, 'seed': seed, 'mode': entry?.mode ?? 'turn', 'apiLevel': kGameApiLevel, 'peer': {}},
        });
        for (final b in _buffer) {
          _toGame.add(b);
        }
        _buffer.clear();
      case 'send':
        final ch = m['ch'] == 'fast' ? 'fast' : 'reliable';
        final data = m['data'];
        final size = utf8.encode(jsonEncode(data)).length;
        if (size > (ch == 'fast' ? maxFast : maxReliable) || !_allowRate()) return;
        _call.sendData({'type': 'game.msg', 'sid': sid, 'ch': ch, 'data': data});
      case 'end':
        final r = m['result'];
        final res = r is Map && r['result'] is String ? r['result'] as String : 'draw';
        result = res;
        _call.sendData({'type': 'game.end', 'sid': sid, 'result': 'done'});
        _set(GamePhase.ended);
    }
  }

  bool _allowRate() {
    final t = _now();
    _recent.removeWhere((x) => t.difference(x).inMilliseconds >= 1000);
    if (_recent.length >= maxPerSecond) return false;
    _recent.add(t);
    return true;
  }

  // ---- tin từ đối phương ----
  void _onData(Map<String, dynamic> m) {
    final type = m['type'];
    if (type is! String || !type.startsWith('game.')) return;
    final s = m['sid'];
    if (s is! int) return;
    switch (type) {
      case 'game.invite':
        _onInvite(s, m);
      case 'game.accept':
        if (phase == GamePhase.inviting && s == sid) {
          _timer?.cancel();
          me = 0;
          seed = _rng.nextInt(1 << 31);
          _call.sendData({'type': 'game.start', 'sid': sid, 'seed': seed});
          _begin();
        }
      case 'game.decline':
        if ((phase == GamePhase.inviting || phase == GamePhase.incoming) && s == sid) {
          _timer?.cancel();
          _set(GamePhase.ended, note: m['reason'] is String ? m['reason'] as String : 'declined');
        }
      case 'game.start':
        if (phase == GamePhase.incoming && s == sid && m['seed'] is int) {
          me = 1;
          seed = m['seed'] as int;
          _timer?.cancel();
          _begin();
        }
      case 'game.msg':
        if (phase != GamePhase.playing || s != sid) return;
        final ch = m['ch'] == 'fast' ? 'fast' : 'reliable';
        if (utf8.encode(jsonEncode(m['data'])).length > (ch == 'fast' ? maxFast : maxReliable)) return;
        final ev = {'t': 'msg', 'ch': ch, 'data': m['data']};
        if (_viewReady) {
          _toGame.add(ev);
        } else if (_buffer.length < 200) {
          _buffer.add(ev);
        }
      case 'game.end':
        if (phase == GamePhase.playing && s == sid) {
          result = m['result'] == 'abort' ? 'abort' : result;
          _set(GamePhase.ended, note: m['result'] == 'abort' ? 'peer_left' : null);
        }
    }
  }

  void _begin() {
    _viewReady = false;
    _buffer.clear();
    _set(GamePhase.playing);
  }

  void _onInvite(int s, Map<String, dynamic> m) {
    GameCatalogEntry? e;
    for (final c in _catalog()) {
      if (c.id == m['id'] && c.version == m['version'] && c.sha256 == m['sha256']) e = c;
    }
    if (busy || e == null) {
      _call.sendData({'type': 'game.decline', 'sid': s, 'reason': busy ? 'busy' : 'unsupported'});
      return;
    }
    entry = e;
    sid = s;
    result = null;
    // Tải ngay khi nhận lời mời để bấm "Chơi" là vào được (timeout 20 s trong store).
    _preload = _store.ensure(e);
    unawaited(_preload!.then((_) {}, onError: (_) {}));
    _set(GamePhase.incoming);
    _timer?.cancel();
    _timer = Timer(inviteTimeout, () {
      if (phase == GamePhase.incoming) _set(GamePhase.ended, note: 'timeout');
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _toGame.close();
    super.dispose();
  }
}
