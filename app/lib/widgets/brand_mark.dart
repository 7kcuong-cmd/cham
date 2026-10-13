import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Logo Chạm (hai bong bóng chồng nhau), vẽ bằng code theo branding/icon.svg (viewBox 1024).
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Chạm',
      image: true,
      child: SizedBox(width: size, height: size, child: CustomPaint(painter: _BrandPainter())),
    );
  }
}

class _BrandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Vùng nội dung của logo trong viewBox: x 200..824, y 270..860 -> đưa vào giữa ô vuông.
    const left = 200.0, top = 270.0, w = 624.0, h = 590.0;
    final k = size.width / (w > h ? w : h);
    canvas.save();
    canvas.translate((size.width - w * k) / 2, (size.height - h * k) / 2);
    canvas.scale(k);
    canvas.translate(-left, -top);

    final pink = Paint()..color = AppColors.primary;
    final white = Paint()..color = AppColors.textPrimary;
    final ring = Paint()
      ..color = AppColors.bg
      ..style = PaintingStyle.stroke
      ..strokeWidth = 24
      ..strokeJoin = StrokeJoin.round;

    Path tail(double x1, double y1, double x2, double y2, double x3, double y3) =>
        Path()..moveTo(x1, y1)..lineTo(x2, y2)..lineTo(x3, y3)..close();

    // Bong bóng hồng (sau).
    canvas.drawPath(tail(250, 580, 214, 700, 346, 594), pink);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(200, 270, 400, 330), const Radius.circular(150)), pink);

    // Bong bóng trắng (trước) có viền cùng màu nền để tách khỏi bong bóng hồng.
    final tailWhite = tail(750, 738, 806, 860, 664, 752);
    final bodyWhite = RRect.fromRectAndRadius(const Rect.fromLTWH(424, 424, 400, 330), const Radius.circular(150));
    canvas.drawPath(tailWhite, white);
    canvas.drawPath(tailWhite, ring);
    canvas.drawRRect(bodyWhite, white);
    canvas.drawRRect(bodyWhite, ring);
    canvas.drawPath(tailWhite, white);
    canvas.drawRRect(bodyWhite.deflate(12), white);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
