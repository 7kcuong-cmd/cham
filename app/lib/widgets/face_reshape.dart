import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/face_sample.dart';

/// Nhọn cằm + mắt to: biến dạng nhẹ hình video theo vị trí khuôn mặt, bằng một shader (`shaders/face_warp.frag`).
/// Chỉ hiển thị (không sửa khung hình gửi đi), giống làm đẹp và mặt nạ. Mức 0 hoặc chưa có mặt → trả nguyên [child].
/// Nếu máy không hỗ trợ shader làm bộ lọc ảnh (cần Impeller) thì tự bỏ qua, không lỗi.
class FaceReshape extends StatefulWidget {
  const FaceReshape({
    super.key,
    required this.sample,
    required this.chin,
    required this.eyes,
    required this.child,
    this.mirror = false,
  });

  final FaceSample? sample;

  /// 0..100.
  final int chin;
  final int eyes;
  final Widget child;

  /// Khung xem trước camera trước hiển thị đối xứng gương.
  final bool mirror;

  @override
  State<FaceReshape> createState() => _FaceReshapeState();
}

class _FaceReshapeState extends State<FaceReshape> with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _loading;
  static bool _unsupported = false;

  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  ui.FragmentShader? _shader;
  FaceSample? _from;
  FaceSample? _to;
  DateTime _lastAt = DateTime.now();

  static Future<ui.FragmentProgram?> _load() {
    return _loading ??= () async {
      try {
        return await ui.FragmentProgram.fromAsset('shaders/face_warp.frag');
      } on Object catch (e) {
        debugPrint('face_warp shader unavailable: $e');
        _unsupported = true;
        return null;
      }
    }();
  }

  bool get _active => widget.chin > 0 || widget.eyes > 0;

  @override
  void initState() {
    super.initState();
    _to = widget.sample;
    if (_active) _ensureShader();
  }

  void _ensureShader() {
    if (_shader != null || _unsupported) return;
    _load().then((p) {
      if (!mounted || p == null) return;
      setState(() => _shader = p.fragmentShader());
    });
  }

  @override
  void didUpdateWidget(FaceReshape old) {
    super.didUpdateWidget(old);
    if (_active) _ensureShader();
    final s = widget.sample;
    if (identical(s, old.sample)) return;
    if (s == null) {
      _from = _to = null;
      return;
    }
    final now = DateTime.now();
    _ctl.duration = Duration(milliseconds: now.difference(_lastAt).inMilliseconds.clamp(80, 300).toInt());
    _lastAt = now;
    _from = _current() ?? s;
    _to = s;
    _ctl.forward(from: 0);
  }

  FaceSample? _current() {
    final t = _to;
    final f = _from;
    if (t == null) return null;
    if (f == null) return t;
    return FaceSample.lerp(f, t, _ctl.value);
  }

  @override
  void dispose() {
    _ctl.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shader = _shader;
    if (!_active || shader == null || _to == null || _unsupported) return widget.child;
    return AnimatedBuilder(
      animation: _ctl,
      child: widget.child,
      builder: (_, child) {
        final cur = _current();
        if (cur == null) return child!;
        final face = widget.mirror ? cur.mirrored() : cur;
        return LayoutBuilder(builder: (_, box) {
          final size = box.biggest;
          if (!size.isFinite || size.isEmpty) return child!;
          final applied = _apply(shader, face, size);
          if (!applied) return child!;
          return ImageFiltered(imageFilter: ui.ImageFilter.shader(shader), child: child);
        });
      },
    );
  }

  /// Nạp các uniform theo thứ tự khai báo trong face_warp.frag. Trả false nếu số liệu không hợp lệ.
  bool _apply(ui.FragmentShader sh, FaceSample s, Size size) {
    Offset uv(Offset norm) {
      final p = FaceSample.toView(norm, size, s.imageAspect);
      return Offset(p.dx / size.width, p.dy / size.height);
    }

    final cover = FaceSample.coverSize(size, s.imageAspect);
    final faceWpx = s.width * cover.width;
    if (faceWpx < 12) return false;
    final c = uv(s.center);
    final le = uv(s.leftEye ?? Offset(s.center.dx - 0.2 * s.width, s.center.dy - 0.1 * s.height));
    final re = uv(s.rightEye ?? Offset(s.center.dx + 0.2 * s.width, s.center.dy - 0.1 * s.height));
    final chin = uv(Offset(s.center.dx, (s.center.dy + 0.5 * s.height).clamp(0.0, 1.0).toDouble()));
    final halfW = (faceWpx / 2) / size.width;
    final eyeR = (faceWpx * 0.17) / size.height;
    final vals = <double>[
      size.width, size.height, //
      le.dx, le.dy, re.dx, re.dy, //
      chin.dx, chin.dy, c.dx, c.dy, //
      halfW, eyeR, //
      widget.eyes / 100.0, widget.chin / 100.0,
    ];
    if (vals.any((v) => v.isNaN || v.isInfinite)) return false;
    for (var i = 0; i < vals.length; i++) {
      sh.setFloat(i, vals[i]);
    }
    return true;
  }
}
