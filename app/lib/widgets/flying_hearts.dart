import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Cho phép màn hình cuộc gọi bắn trái tim bay mà không giữ `State` của [FlyingHearts].
class FlyingHeartsController {
  _FlyingHeartsState? _state;

  /// Bắn [count] trái tim. [fromRight]: từ nút tim ở mép phải (mình thả); ngược lại từ cạnh trái
  /// (nhận từ đối phương).
  void burst(int count, {required bool fromRight}) => _state?._spawn(count, fromRight);
}

/// Lớp trái tim bay (600 ms mỗi trái, không âm thanh). Phủ toàn khung, không nhận chạm.
class FlyingHearts extends StatefulWidget {
  const FlyingHearts({super.key, required this.controller});

  final FlyingHeartsController controller;

  /// Thời gian bay của một trái tim.
  static const Duration flight = Duration(milliseconds: 600);

  /// Giãn cách giữa các trái trong một lượt bắn.
  static const Duration stagger = Duration(milliseconds: 60);

  /// Số trái tối đa trên màn hình cùng lúc.
  static const int maxOnScreen = 30;

  @override
  State<FlyingHearts> createState() => _FlyingHeartsState();
}

class _HeartSpec {
  const _HeartSpec(this.id, this.fromRight, this.delay, this.drift);

  final int id;
  final bool fromRight;
  final Duration delay;

  /// Độ lệch ngang khi bay lên (dp).
  final double drift;
}

class _FlyingHeartsState extends State<FlyingHearts> {
  final List<_HeartSpec> _hearts = <_HeartSpec>[];
  final Random _random = Random();
  int _nextId = 0;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void didUpdateWidget(FlyingHearts old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller._state = null;
      widget.controller._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller._state == this) widget.controller._state = null;
    super.dispose();
  }

  void _spawn(int count, bool fromRight) {
    if (!mounted || count <= 0) return;
    setState(() {
      for (var i = 0; i < count && _hearts.length < FlyingHearts.maxOnScreen; i++) {
        _hearts.add(
          _HeartSpec(
            _nextId++,
            fromRight,
            FlyingHearts.stagger * i,
            (_random.nextDouble() - 0.5) * 48,
          ),
        );
      }
    });
  }

  void _remove(int id) {
    if (!mounted) return;
    setState(() => _hearts.removeWhere((h) => h.id == id));
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final h in _hearts)
                _FlyingHeart(
                  key: ValueKey<int>(h.id),
                  spec: h,
                  area: box.biggest,
                  onDone: () => _remove(h.id),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FlyingHeart extends StatefulWidget {
  const _FlyingHeart({super.key, required this.spec, required this.area, required this.onDone});

  final _HeartSpec spec;
  final Size area;
  final VoidCallback onDone;

  @override
  State<_FlyingHeart> createState() => _FlyingHeartState();
}

class _FlyingHeartState extends State<_FlyingHeart> with SingleTickerProviderStateMixin {
  static const double _size = 28;
  static const double _rise = 220;

  late final AnimationController _ctrl;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    final total = FlyingHearts.flight + widget.spec.delay;
    _ctrl = AnimationController(vsync: this, duration: total);
    final begin = widget.spec.delay.inMilliseconds / total.inMilliseconds;
    _t = CurvedAnimation(parent: _ctrl, curve: Interval(begin, 1.0, curve: Curves.easeOut));
    _ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    });
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final startX = spec.fromRight
        ? widget.area.width - AppSpace.lg - AppSize.minTouch / 2 - _size / 2
        : AppSpace.lg;
    final startY = widget.area.height - 140;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _t.value;
        // Chưa tới lượt bay (delay): ẩn.
        final visible = _ctrl.value * (FlyingHearts.flight + spec.delay).inMilliseconds >=
            spec.delay.inMilliseconds;
        return Positioned(
          left: startX + spec.drift * t,
          top: startY - _rise * t,
          child: Opacity(opacity: visible ? 1 - t : 0, child: child),
        );
      },
      child: const Icon(Icons.favorite_rounded, size: _size, color: AppColors.primary),
    );
  }
}
