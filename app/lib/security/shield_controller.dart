import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Khiên" chống dò IP của chính thiết bị (CHONG-QUET-IP-P2P.md, L3):
///  - [enabled]: bật/tắt toàn bộ bộ lọc + phát hiện (mặc định bật; lưu trên máy);
///  - sau ≥ [incidentsToShield] sự cố trong [incidentWindow]: [shieldActive] trong [shieldDuration]
///    (cuộc gọi đi qua relay nếu server có TURN) và tạm dừng ghép [pauseDuration].
/// Chỉ giữ trong RAM; không lưu IP hay danh tính đối phương.
class ShieldController extends ChangeNotifier {
  ShieldController({DateTime Function()? now}) : _now = now ?? DateTime.now;
  static final ShieldController instance = ShieldController();

  static const String _key = 'ice_guard_enabled';
  static const int incidentsToShield = 2;
  static const Duration incidentWindow = Duration(minutes: 15);
  static const Duration shieldDuration = Duration(minutes: 30);
  static const Duration pauseDuration = Duration(seconds: 60);

  final DateTime Function() _now;
  bool _enabled = true;
  final List<DateTime> _incidents = <DateTime>[];
  DateTime? _shieldUntil;
  DateTime? _pauseUntil;

  bool get enabled => _enabled;
  int get recentIncidents {
    _prune();
    return _incidents.length;
  }

  bool get shieldActive {
    final u = _shieldUntil;
    return _enabled && u != null && _now().isBefore(u);
  }

  /// Thời gian còn phải tạm dừng ghép (0 nếu không).
  Duration get pauseRemaining {
    final u = _pauseUntil;
    if (!_enabled || u == null) return Duration.zero;
    final d = u.difference(_now());
    return d.isNegative ? Duration.zero : d;
  }

  Future<void> load() async {
    try {
      _enabled = (await SharedPreferences.getInstance()).getBool(_key) ?? true;
      notifyListeners();
    } on Object {
      // giữ mặc định (bật)
    }
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setBool(_key, on);
    } on Object {
      // không lưu được: vẫn áp dụng cho phiên hiện tại
    }
  }

  void _prune() {
    final t = _now();
    _incidents.removeWhere((x) => t.difference(x) > incidentWindow);
  }

  /// Ghi một sự cố (đã phát hiện đối phương bất thường). Trả `true` nếu vừa bật Khiên/tạm dừng.
  bool recordIncident() {
    if (!_enabled) return false;
    final t = _now();
    _prune();
    _incidents.add(t);
    var escalated = false;
    if (_incidents.length >= incidentsToShield) {
      _shieldUntil = t.add(shieldDuration);
      _pauseUntil = t.add(pauseDuration);
      escalated = true;
    }
    notifyListeners();
    return escalated;
  }

  @visibleForTesting
  void resetForTest() {
    _incidents.clear();
    _shieldUntil = null;
    _pauseUntil = null;
    _enabled = true;
  }
}
