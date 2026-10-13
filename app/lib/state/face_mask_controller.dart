import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/face_sample.dart';
import '../services/call_service.dart';

/// Danh sách mặt nạ (id cố định, dùng cả khi gửi qua DataChannel – đối phương chỉ nhận id nằm trong danh sách này).
const List<String> kFaceMaskIds = <String>[
  'cat', 'dog', 'bunny', 'clown', 'shades', 'crown',
  'fox', 'panda', 'bear', 'devil', 'halo', 'pirate', 'mustache', 'hearts', 'party', //
];

typedef FaceDetectFn = Future<FaceSample?> Function(Uint8List image);

/// Mặt lạ: mặt nạ bám theo khuôn mặt. Máy mình tìm mặt mình (ML Kit) khoảng 3 lần/giây, vẽ mặt nạ lên khung xem trước của
/// mình và gửi vị trí (toạ độ chuẩn hoá, không gửi hình) cho đối phương để họ vẽ lên hình của mình trên máy họ.
/// Giống cách làm đẹp: không sửa khung hình gửi đi (flutter_webrtc 1.x không có bộ xử lý khung hình).
class FaceMaskController extends ChangeNotifier {
  FaceMaskController(
    this._call, {
    FaceDetectFn? detect,
    Duration every = const Duration(milliseconds: 20),
    Duration peerTtl = const Duration(milliseconds: 1500),
  })  : _detect = detect,
        _every = every,
        _peerTtl = peerTtl {
    _sub = _call.dataMessages.listen(_onData);
  }

  final CallService _call;
  final FaceDetectFn? _detect;
  final Duration _every;
  final Duration _peerTtl;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Timer? _timer;
  Timer? _peerExpiry;
  bool _busy = false;
  bool _disposed = false;

  String? _maskId;
  FaceSample? _local;
  String? _peerMaskId;
  FaceSample? _peer;
  bool _reshape = false;
  int _peerChin = 0;
  int _peerEyes = 0;
  FaceSample? _peerFace;
  Timer? _peerFaceExpiry;

  /// Mặt nạ của mình đang bật (null = tắt).
  String? get maskId => _maskId;
  FaceSample? get local => _local;
  String? get peerMaskId => _peerMaskId;
  FaceSample? get peer => _peer;

  /// Bật/tắt theo dõi mặt để chỉnh nhọn cằm / mắt to (không cần mặt nạ).
  bool get reshapeTracking => _reshape;

  /// Mặt, mức nhọn cằm và mắt to của ĐỐI PHƯƠNG (0..100) để vẽ lên hình của họ trên máy mình.
  FaceSample? get peerFace => _peerFace;
  int get peerChin => _peerChin;
  int get peerEyes => _peerEyes;

  bool get _wantTrack => _maskId != null || _reshape;

  /// Thiết bị dùng được (có chụp khung + có bộ tìm mặt).
  bool get supported => _call is FrameCapturable && _detect != null;

  void setMask(String? id) {
    if (id != null && !kFaceMaskIds.contains(id)) return;
    if (id == _maskId) return;
    _maskId = id;
    _timer?.cancel();
    _timer = null;
    if (id == null) {
      _send(null);
      if (_reshape && supported) {
        _schedule(); // vẫn cần theo dõi mặt cho nhọn cằm / mắt to
      } else {
        _local = null;
      }
    } else if (supported) {
      _schedule(); // vòng lặp nối tiếp: đo xong là đo tiếp, tốc độ theo năng lực máy
    }
    _notify();
  }

  /// Bật/tắt theo dõi mặt cho nhọn cằm / mắt to. Tắt thì báo đối phương bỏ hiệu ứng.
  void setReshape(bool on) {
    if (on == _reshape) return;
    _reshape = on;
    if (!on) {
      if (_maskId == null) {
        _timer?.cancel();
        _timer = null;
        _local = null;
      }
      _sendFace(null);
    } else if (supported && _timer == null && !_busy) {
      _schedule();
    }
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_wantTrack || !supported) return;
    _timer = Timer(_every, () => unawaited(_tick()));
  }

  Future<void> _tick() async {
    final cam = _call;
    final detect = _detect;
    if (_busy || _disposed || !_wantTrack || cam is! FrameCapturable || detect == null) return;
    _busy = true;
    try {
      final img = await (cam as FrameCapturable).captureLocalFrame();
      if (img == null || _disposed || !_wantTrack) return;
      final found = await detect(img);
      if (_disposed || !_wantTrack) return;
      final prev = _local;
      // Làm mượt nhẹ giữa hai lần đo; 0.85 bám sát hơn (trước 0.7 gây cảm giác trễ).
      _local = (found != null && prev != null) ? FaceSample.lerp(prev, found, 0.85) : found;
      if (_maskId != null) _send(_local);
      if (_reshape) _sendFace(_local);
      _notify();
    } on Object catch (e) {
      debugPrint('face mask tick ignored: $e');
    } finally {
      _busy = false;
      _schedule();
    }
  }

  void _send(FaceSample? s) {
    _call.sendData(<String, dynamic>{
      'type': 'mask',
      'id': _maskId,
      'f': s?.toJson(),
    });
  }

  /// Số chỉnh (nhọn cằm / mắt to) hiện hành do UI đặt; gửi kèm toạ độ mặt.
  int Function() chinLevel = () => 0;
  int Function() eyesLevel = () => 0;

  void _sendFace(FaceSample? s) {
    _call.sendData(<String, dynamic>{
      'type': 'face',
      'chin': s == null ? 0 : chinLevel().clamp(0, 100),
      'eyes': s == null ? 0 : eyesLevel().clamp(0, 100),
      'f': s?.toJson(),
    });
  }

  void _onFace(Map<String, dynamic> m) {
    final s = FaceSample.fromJson(m['f']);
    final chin = m['chin'];
    final eyes = m['eyes'];
    if (s == null || chin is! num || eyes is! num) {
      _clearPeerFace();
      return;
    }
    _peerFace = s;
    _peerChin = chin.round().clamp(0, 100).toInt();
    _peerEyes = eyes.round().clamp(0, 100).toInt();
    _peerFaceExpiry?.cancel();
    _peerFaceExpiry = Timer(_peerTtl, _clearPeerFace);
    _notify();
  }

  void _clearPeerFace() {
    _peerFaceExpiry?.cancel();
    _peerFaceExpiry = null;
    if (_peerFace == null) return;
    _peerFace = null;
    _peerChin = 0;
    _peerEyes = 0;
    _notify();
  }

  void _onData(Map<String, dynamic> m) {
    if (m['type'] == 'face') {
      _onFace(m);
      return;
    }
    if (m['type'] != 'mask') return;
    final id = m['id'];
    if (id is! String || !kFaceMaskIds.contains(id)) {
      _clearPeer();
      return;
    }
    final s = FaceSample.fromJson(m['f']);
    _peerMaskId = id;
    _peer = s;
    _peerExpiry?.cancel();
    _peerExpiry = Timer(_peerTtl, _clearPeer);
    _notify();
  }

  void _clearPeer() {
    _peerExpiry?.cancel();
    _peerExpiry = null;
    if (_peerMaskId == null && _peer == null) return;
    _peerMaskId = null;
    _peer = null;
    _notify();
  }

  /// Sang cuộc gọi mới: quên mặt nạ của người cũ; mặt nạ của mình giữ nguyên và báo lại cho người mới.
  void reset() {
    _clearPeer();
    _clearPeerFace();
    if (_maskId != null) _send(_local);
    if (_reshape) _sendFace(_local);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _peerExpiry?.cancel();
    _peerFaceExpiry?.cancel();
    _sub.cancel();
    super.dispose();
  }
}
