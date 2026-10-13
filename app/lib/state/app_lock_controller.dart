import 'package:flutter/widgets.dart';

import '../services/app_lock_service.dart';
import '../services/biometric_port.dart';

/// Trạng thái khóa màn hình. Khóa lại khi app ở nền quá [AppLockService.lockAfterSeconds] giây.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({required AppLockService service, BiometricPort? biometrics, DateTime Function()? now})
      : _svc = service,
        _bio = biometrics ?? const NoBiometrics(),
        _now = now ?? DateTime.now {
    WidgetsBinding.instance.addObserver(this);
  }

  final AppLockService _svc;
  final BiometricPort _bio;
  bool _bioOn = false;
  final DateTime Function() _now;
  bool _locked = false;
  bool _enabled = false;
  DateTime? _pausedAt;
  int? _remaining;
  bool _wiped = false;

  bool get locked => _locked;
  bool get enabled => _enabled;

  /// Có hiện nút vân tay/khuôn mặt ở màn khóa.
  bool get biometricOn => _bioOn;

  Future<bool> get biometricAvailable => _bio.available;

  /// Số lần thử còn lại sau lần sai gần nhất; `null` nếu chưa sai.
  int? get remaining => _remaining;

  /// Vừa bị xóa sạch vì sai quá số lần.
  bool get wiped => _wiped;

  AppLockService get service => _svc;

  /// Gọi lúc khởi động: đang bật khóa thì khóa ngay.
  Future<void> init() async {
    _enabled = await _svc.isEnabled;
    _bioOn = _enabled && await _svc.biometricEnabled;
    _locked = _enabled;
    notifyListeners();
  }

  Future<void> refresh() async {
    _enabled = await _svc.isEnabled;
    _bioOn = _enabled && await _svc.biometricEnabled;
    if (!_enabled) _locked = false;
    notifyListeners();
  }

  Future<UnlockResult> unlock(String pin) async {
    final r = await _svc.verify(pin);
    switch (r.status) {
      case UnlockStatus.ok:
      case UnlockStatus.notEnabled:
        _locked = false;
        _remaining = null;
      case UnlockStatus.wrong:
        _remaining = r.remaining;
      case UnlockStatus.wiped:
        _wiped = true;
        _enabled = false;
        _locked = false;
        _remaining = null;
    }
    notifyListeners();
    return r;
  }

  /// Mở khóa bằng sinh trắc học (không tính vào số lần sai; thất bại thì cứ nhập PIN).
  Future<bool> tryBiometric(String reason) async {
    if (!_locked || !_bioOn) return false;
    final ok = await _bio.authenticate(reason);
    if (ok) {
      _locked = false;
      _remaining = null;
      notifyListeners();
    }
    return ok;
  }

  Future<void> setBiometric(bool on) async {
    if (on && !await _bio.available) return;
    await _svc.setBiometric(on);
    await refresh();
  }

  void lockNow() {
    if (!_enabled) return;
    _locked = true;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _pausedAt ??= _now();
    } else if (state == AppLifecycleState.resumed) {
      final at = _pausedAt;
      _pausedAt = null;
      if (at == null) return;
      _svc.lockAfterSeconds.then((s) {
        if (_now().difference(at).inSeconds >= s) {
          _locked = true;
          notifyListeners();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
