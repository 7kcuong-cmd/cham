import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/face_sample.dart';
import '../state/face_mask_controller.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

String faceMaskLabel(BuildContext c, String id) => switch (id) {
      'cat' => tr(c, 'Mèo', 'Cat'),
      'dog' => tr(c, 'Chó', 'Dog'),
      'bunny' => tr(c, 'Thỏ', 'Bunny'),
      'clown' => tr(c, 'Hề', 'Clown'),
      'shades' => tr(c, 'Kính ngầu', 'Shades'),
      'crown' => tr(c, 'Vương miện', 'Crown'),
      'fox' => tr(c, 'Cáo', 'Fox'),
      'panda' => tr(c, 'Gấu trúc', 'Panda'),
      'bear' => tr(c, 'Gấu', 'Bear'),
      'devil' => tr(c, 'Ác quỷ', 'Devil'),
      'halo' => tr(c, 'Thiên thần', 'Angel'),
      'pirate' => tr(c, 'Hải tặc', 'Pirate'),
      'mustache' => tr(c, 'Ria mép', 'Mustache'),
      'hearts' => tr(c, 'Mắt tim', 'Heart eyes'),
      'party' => tr(c, 'Nón tiệc', 'Party hat'),
      _ => id,
    };

String faceMaskEmoji(String id) => switch (id) {
      'cat' => '🐱',
      'dog' => '🐶',
      'bunny' => '🐰',
      'clown' => '🤡',
      'shades' => '😎',
      'crown' => '👑',
      'fox' => '🦊',
      'panda' => '🐼',
      'bear' => '🐻',
      'devil' => '😈',
      'halo' => '😇',
      'pirate' => '🏴‍☠️',
      'mustache' => '🥸',
      'hearts' => '😍',
      'party' => '🥳',
      _ => '🙂',
    };

/// Vẽ mặt nạ lên video. [sample] đổi mỗi ~350 ms nên có nội suy 250 ms giữa hai lần đo để mượt.
/// [mirror]: khung xem trước camera trước hiển thị đối xứng gương → lật ngang toạ độ.
class FaceMaskOverlay extends StatefulWidget {
  const FaceMaskOverlay({super.key, required this.maskId, required this.sample, this.mirror = false});

  final String? maskId;
  final FaceSample? sample;
  final bool mirror;

  @override
  State<FaceMaskOverlay> createState() => _FaceMaskOverlayState();
}

class _FaceMaskOverlayState extends State<FaceMaskOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 150));
  FaceSample? _from;
  FaceSample? _to;
  DateTime _lastAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _to = widget.sample;
  }

  @override
  void didUpdateWidget(FaceMaskOverlay old) {
    super.didUpdateWidget(old);
    final s = widget.sample;
    if (identical(s, old.sample)) return;
    if (s == null) {
      _from = _to = null;
      return;
    }
    // Thời gian nội suy = khoảng cách thật giữa hai lần đo (80–300 ms): mặt nạ bám sát mà vẫn mượt.
    final now = DateTime.now();
    final dt = now.difference(_lastAt).inMilliseconds.clamp(80, 300).toInt();
    _lastAt = now;
    _ctl.duration = Duration(milliseconds: dt);
    _from = _current() ?? s;
    _to = s;
    _ctl.forward(from: 0);
  }

  FaceSample? _current() {
    final t = _to;
    final f = _from;
    if (t == null) return null;
    if (f == null) return t;
    return FaceSample.lerp(f, t, _ctl.value); // tuyến tính: không bị chậm dần cuối mỗi đoạn
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.maskId;
    if (id == null || _to == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (_, __) {
          var s = _current();
          if (s == null) return const SizedBox.shrink();
          if (widget.mirror) s = s.mirrored();
          return CustomPaint(size: Size.infinite, painter: FaceMaskPainter(id: id, sample: s));
        },
      ),
    );
  }
}

/// Vẽ bằng hình học (không cần tệp ảnh). Đơn vị `u` = bề rộng mặt; gốc toạ độ = tâm mặt, trục Y hướng xuống.
class FaceMaskPainter extends CustomPainter {
  FaceMaskPainter({required this.id, required this.sample});

  final String id;
  final FaceSample sample;

  @override
  void paint(Canvas canvas, Size size) {
    final cover = FaceSample.coverSize(size, sample.imageAspect);
    final u = sample.width * cover.width;
    if (u < 8) return;
    final c = FaceSample.toView(sample.center, size, sample.imageAspect);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-sample.rollRad); // ML Kit: dương = nghiêng ngược chiều kim đồng hồ; Canvas: dương = thuận chiều kim đồng hồ.
    // Toạ độ tương đối tâm mặt (đơn vị u) của một điểm chuẩn hoá.
    Offset rel(Offset? p, Offset fallback) {
      if (p == null) return fallback;
      final v = FaceSample.toView(p, size, sample.imageAspect) - c;
      // Xoay ngược để về hệ trục của đầu (đã xoay ở trên).
      final cs = math.cos(sample.rollRad), sn = math.sin(sample.rollRad);
      return Offset((v.dx * cs - v.dy * sn) / u, (v.dx * sn + v.dy * cs) / u);
    }

    final le = rel(sample.leftEye, const Offset(-0.22, -0.12));
    final re = rel(sample.rightEye, const Offset(0.22, -0.12));
    final nose = rel(sample.nose, const Offset(0, 0.1));
    final top = -(sample.height / sample.width) * 0.5; // mép trán (đơn vị u)
    canvas.scale(u);
    final fill = Paint()..style = PaintingStyle.fill;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.012
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;

    Path tri(Offset a, Offset b, Offset c2) => Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(c2.dx, c2.dy)
      ..close();

    switch (id) {
      case 'cat':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawPath(tri(Offset(sgn * 0.48, top + 0.12), Offset(sgn * 0.42, top - 0.28), Offset(sgn * 0.10, top + 0.02)), fill..color = const Color(0xFF444444));
          canvas.drawPath(tri(Offset(sgn * 0.40, top + 0.08), Offset(sgn * 0.37, top - 0.18), Offset(sgn * 0.18, top + 0.02)), fill..color = const Color(0xFFFF8FA3));
        }
        canvas.drawPath(tri(nose + const Offset(-0.05, -0.02), nose + const Offset(0.05, -0.02), nose + const Offset(0, 0.04)), fill..color = const Color(0xFFFF4D73));
        for (final sgn in <double>[-1, 1]) {
          for (final dy in <double>[-0.03, 0.03]) {
            canvas.drawLine(nose + Offset(sgn * 0.08, dy), nose + Offset(sgn * 0.40, dy * 3), line);
          }
        }
      case 'dog':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawOval(Rect.fromCenter(center: Offset(sgn * 0.52, top + 0.22), width: 0.26, height: 0.5), fill..color = const Color(0xFF8B5A2B));
        }
        canvas.drawOval(Rect.fromCenter(center: nose + const Offset(0, 0.02), width: 0.14, height: 0.10), fill..color = const Color(0xFF222222));
        canvas.drawOval(Rect.fromCenter(center: nose + const Offset(0, 0.20), width: 0.10, height: 0.16), fill..color = const Color(0xFFFF6F91));
      case 'bunny':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawOval(Rect.fromCenter(center: Offset(sgn * 0.20, top - 0.30), width: 0.20, height: 0.70), fill..color = Colors.white);
          canvas.drawOval(Rect.fromCenter(center: Offset(sgn * 0.20, top - 0.30), width: 0.10, height: 0.55), fill..color = const Color(0xFFFFB3C6));
        }
        canvas.drawCircle(nose, 0.04, fill..color = const Color(0xFFFF8FA3));
      case 'clown':
        canvas.drawCircle(nose, 0.09, fill..color = const Color(0xFFE53935));
        for (final sgn in <double>[-1, 1]) {
          canvas.drawCircle(Offset(sgn * 0.50, top + 0.10), 0.20, fill..color = const Color(0xFFFF7043));
        }
      case 'shades':
        final w = (re - le).distance * 0.62;
        for (final e in <Offset>[le, re]) {
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: e, width: w, height: w * 0.72), Radius.circular(w * 0.2)), fill..color = const Color(0xE6101010));
        }
        canvas.drawLine(le + Offset(w / 2, 0), re - Offset(w / 2, 0), line..color = const Color(0xFF101010));
        line.color = Colors.white;
      case 'fox':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawPath(tri(Offset(sgn * 0.50, top + 0.14), Offset(sgn * 0.40, top - 0.34), Offset(sgn * 0.08, top + 0.02)), fill..color = const Color(0xFFE8731A));
          canvas.drawPath(tri(Offset(sgn * 0.40, top + 0.08), Offset(sgn * 0.36, top - 0.20), Offset(sgn * 0.16, top + 0.02)), fill..color = const Color(0xFFFFFFFF));
        }
        canvas.drawOval(Rect.fromCenter(center: nose + const Offset(0, 0.03), width: 0.13, height: 0.09), fill..color = const Color(0xFF1A1A1A));
        for (final sgn in <double>[-1, 1]) {
          canvas.drawPath(tri(nose + Offset(sgn * 0.10, 0.04), nose + Offset(sgn * 0.46, 0.0), nose + Offset(sgn * 0.30, 0.20)), fill..color = const Color(0xCCFFFFFF));
        }
      case 'panda':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawCircle(Offset(sgn * 0.44, top + 0.06), 0.15, fill..color = const Color(0xFF1A1A1A));
        }
        for (final e in <Offset>[le, re]) {
          canvas.save();
          canvas.translate(e.dx, e.dy);
          canvas.rotate(e == le ? 0.5 : -0.5);
          canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 0.20, height: 0.30), fill..color = const Color(0xCC1A1A1A));
          canvas.restore();
        }
        canvas.drawOval(Rect.fromCenter(center: nose, width: 0.10, height: 0.07), fill..color = const Color(0xFF1A1A1A));
      case 'bear':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawCircle(Offset(sgn * 0.44, top + 0.04), 0.15, fill..color = const Color(0xFF8B5A2B));
          canvas.drawCircle(Offset(sgn * 0.44, top + 0.04), 0.08, fill..color = const Color(0xFFD2A679));
        }
        canvas.drawOval(Rect.fromCenter(center: nose + const Offset(0, 0.10), width: 0.30, height: 0.22), fill..color = const Color(0xCCD2A679));
        canvas.drawOval(Rect.fromCenter(center: nose + const Offset(0, 0.02), width: 0.11, height: 0.08), fill..color = const Color(0xFF222222));
      case 'devil':
        for (final sgn in <double>[-1, 1]) {
          canvas.drawPath(tri(Offset(sgn * 0.20, top + 0.06), Offset(sgn * 0.30, top - 0.30), Offset(sgn * 0.04, top + 0.02)), fill..color = const Color(0xFFD32F2F));
        }
        final tail = Path()
          ..moveTo(-0.28, top + 0.0)
          ..quadraticBezierTo(0, top - 0.06, 0.28, top + 0.0);
        canvas.drawPath(tail, line..color = const Color(0xFFD32F2F));
        line.color = Colors.white;
      case 'halo':
        canvas.drawOval(Rect.fromCenter(center: Offset(0, top - 0.14), width: 0.62, height: 0.16), line..color = const Color(0xFFFFD54F)..strokeWidth = 0.035);
        line
          ..color = Colors.white
          ..strokeWidth = 0.012;
      case 'pirate':
        canvas.drawLine(Offset(-0.52, top + 0.16), Offset(0.52, top + 0.16), line..color = const Color(0xFF111111)..strokeWidth = 0.05);
        canvas.drawLine(le + const Offset(-0.12, -0.12), re + const Offset(0.12, -0.12), line..strokeWidth = 0.012);
        canvas.drawOval(Rect.fromCenter(center: re, width: 0.24, height: 0.20), fill..color = const Color(0xFF111111));
        line
          ..color = Colors.white
          ..strokeWidth = 0.012;
      case 'mustache':
        final my = nose.dy + 0.12;
        final m = Path()
          ..moveTo(0, my)
          ..cubicTo(-0.10, my - 0.08, -0.30, my - 0.04, -0.34, my + 0.08)
          ..cubicTo(-0.22, my + 0.02, -0.10, my + 0.06, 0, my + 0.04)
          ..cubicTo(0.10, my + 0.06, 0.22, my + 0.02, 0.34, my + 0.08)
          ..cubicTo(0.30, my - 0.04, 0.10, my - 0.08, 0, my)
          ..close();
        canvas.drawPath(m, fill..color = const Color(0xFF3E2723));
      case 'hearts':
        for (final e in <Offset>[le, re]) {
          final r = 0.085;
          final h = Path()
            ..moveTo(e.dx, e.dy + r * 1.1)
            ..cubicTo(e.dx - r * 2.2, e.dy - r * 0.2, e.dx - r * 0.8, e.dy - r * 1.8, e.dx, e.dy - r * 0.7)
            ..cubicTo(e.dx + r * 0.8, e.dy - r * 1.8, e.dx + r * 2.2, e.dy - r * 0.2, e.dx, e.dy + r * 1.1)
            ..close();
          canvas.drawPath(h, fill..color = const Color(0xFFFF2D6F));
        }
      case 'party':
        final base2 = top + 0.02;
        final hat = Path()
          ..moveTo(-0.24, base2)
          ..lineTo(0.0, base2 - 0.55)
          ..lineTo(0.24, base2)
          ..close();
        canvas.drawPath(hat, fill..color = const Color(0xFF7E57C2));
        for (var i = 0; i < 3; i++) {
          final y = base2 - 0.10 - i * 0.14;
          canvas.drawLine(Offset(-0.20 + i * 0.045, y), Offset(0.20 - i * 0.045, y), line..color = const Color(0xFFFFEB3B)..strokeWidth = 0.025);
        }
        canvas.drawCircle(Offset(0, base2 - 0.57), 0.05, fill..color = const Color(0xFFFF5252));
        line
          ..color = Colors.white
          ..strokeWidth = 0.012;
      case 'crown':
        final base = top - 0.02;
        final p = Path()
          ..moveTo(-0.30, base)
          ..lineTo(-0.30, base - 0.22)
          ..lineTo(-0.15, base - 0.10)
          ..lineTo(0, base - 0.28)
          ..lineTo(0.15, base - 0.10)
          ..lineTo(0.30, base - 0.22)
          ..lineTo(0.30, base)
          ..close();
        canvas.drawPath(p, fill..color = const Color(0xFFFFC107));
        canvas.drawPath(p, line..color = const Color(0xFFB8860B));
        line.color = Colors.white;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(FaceMaskPainter old) => old.id != id || old.sample != sample;
}

/// Bảng chọn mặt nạ.
Future<void> showMaskSheet(BuildContext context, FaceMaskController c) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: c,
        builder: (_, __) => Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(ctx, 'Mặt lạ', 'Face masks'), style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpace.sm),
              if (!c.supported)
                Text(
                  tr(ctx, 'Máy này chưa hỗ trợ mặt lạ.', 'Face masks are not supported on this device.'),
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                )
              else
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  children: [
                    _Chip(label: tr(ctx, 'Tắt', 'Off'), emoji: '🚫', selected: c.maskId == null, onTap: () => c.setMask(null)),
                    for (final id in kFaceMaskIds)
                      _Chip(label: faceMaskLabel(ctx, id), emoji: faceMaskEmoji(id), selected: c.maskId == id, onTap: () => c.setMask(id)),
                  ],
                ),
              const SizedBox(height: AppSpace.sm),
              Text(
                tr(ctx, 'Mặt được nhận diện trên máy bạn; chỉ vị trí mặt nạ được gửi cho người kia, không gửi hình.',
                    'Faces are detected on your device; only the mask position is sent, never your image.'),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.emoji, required this.selected, required this.onTap});

  final String label;
  final String emoji;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text('$emoji  $label'),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.primary.withValues(alpha: 0.25),
    );
  }
}
