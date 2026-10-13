import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Khung camera của mình, kéo thả được trong khung gọi. Vị trí nhớ trong phiên (qua các cuộc gọi),
/// luôn nằm trọn trong màn hình và nhích vào sát mép trái/phải khi thả.
class DraggableSelfView extends StatefulWidget {
  const DraggableSelfView({
    super.key,
    required this.initialTop,
    required this.child,
    required this.onTap,
    this.tooltip,
  });

  final double initialTop;
  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  /// Vị trí (góc trên-trái) đã chọn, giữ trong phiên.
  static Offset? remembered;

  /// Giới hạn vị trí để khung không trượt ra ngoài màn hình hay chui dưới thanh trạng thái.
  static Offset clamp(Offset p, Size area, {required double minTop, double minBottomGap = AppSpace.sm}) {
    final maxX = (area.width - AppSize.selfViewWidth - AppSpace.sm).clamp(AppSpace.sm, double.infinity).toDouble();
    final maxY = (area.height - AppSize.selfViewHeight - minBottomGap).clamp(minTop, double.infinity).toDouble();
    return Offset(p.dx.clamp(AppSpace.sm, maxX).toDouble(), p.dy.clamp(minTop, maxY).toDouble());
  }

  @override
  State<DraggableSelfView> createState() => _DraggableSelfViewState();
}

class _DraggableSelfViewState extends State<DraggableSelfView> {
  Offset? _pos;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final area = MediaQuery.sizeOf(context);
    final minTop = widget.initialTop;
    final base = _pos ?? DraggableSelfView.remembered ?? Offset(area.width - AppSize.selfViewWidth - AppSpace.lg, widget.initialTop);
    final pos = DraggableSelfView.clamp(base, area, minTop: minTop);
    return AnimatedPositioned(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      left: pos.dx,
      top: pos.dy,
      width: AppSize.selfViewWidth,
      height: AppSize.selfViewHeight,
      child: Tooltip(
        message: widget.tooltip ?? '',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          // Nuốt kéo dọc/ngang để không bị tính là vuốt đổi người hoặc cúp máy.
          onPanStart: (_) => setState(() => _dragging = true),
          onPanUpdate: (d) => setState(() => _pos = DraggableSelfView.clamp((_pos ?? pos) + d.delta, area, minTop: minTop)),
          onPanEnd: (_) {
            final p = _pos ?? pos;
            final snapLeft = p.dx + AppSize.selfViewWidth / 2 < area.width / 2;
            final snapped = Offset(snapLeft ? AppSpace.lg : area.width - AppSize.selfViewWidth - AppSpace.lg, p.dy);
            setState(() {
              _dragging = false;
              _pos = DraggableSelfView.clamp(snapped, area, minTop: minTop);
              DraggableSelfView.remembered = _pos;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: _dragging ? AppColors.primary : AppColors.outline, width: _dragging ? 2 : 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
