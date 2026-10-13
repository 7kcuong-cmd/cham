import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'edge_actions.dart';

/// Nút tim ở mép màn hình: nảy nhẹ mỗi lần chạm (T-209). Gộp chạm và gửi thông điệp do
/// `CallExtrasController.tapHeart` lo; trái tim bay do [FlyingHearts].
class HeartButton extends StatefulWidget {
  const HeartButton({super.key, required this.tooltip, required this.onPressed});

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<HeartButton> createState() => _HeartButtonState();
}

class _HeartButtonState extends State<HeartButton> with SingleTickerProviderStateMixin {
  late final AnimationController _bump;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _bump = AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
    _scale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween<double>(begin: 1.0, end: 1.2), weight: 50),
      TweenSequenceItem(tween: Tween<double>(begin: 1.2, end: 1.0), weight: 50),
    ]).animate(_bump);
  }

  @override
  void dispose() {
    _bump.dispose();
    super.dispose();
  }

  void _tap() {
    _bump.forward(from: 0);
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: EdgeButton(
        icon: Icons.favorite_rounded,
        tooltip: widget.tooltip,
        iconColor: AppColors.primary,
        onPressed: _tap,
      ),
    );
  }
}
