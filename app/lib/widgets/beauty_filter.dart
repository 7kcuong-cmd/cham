import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/beauty.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Làm đẹp bằng bộ lọc hiển thị: chỉnh sáng/độ tương phản nhẹ rồi chồng một lớp mờ (soft-glow) lên hình gốc,
/// nên da mịn hơn nhưng mắt/tóc vẫn còn nét. [level] 0..100; 0 = giữ nguyên hình.
class BeautyFilter extends StatelessWidget {
  const BeautyFilter({super.key, required this.level, required this.builder});

  final int level;

  /// Dựng lại hình gốc (gọi 1-2 lần; cùng một renderer nên không tốn thêm luồng).
  final WidgetBuilder builder;

  static ColorFilter _tone(double t) {
    final s = 1 - 0.06 * t; // giảm tương phản
    final o = 255 * 0.03 * t + 10 * t; // sáng lên
    return ColorFilter.matrix(<double>[
      s, 0, 0, 0, o + 2 * t, //
      0, s, 0, 0, o, //
      0, 0, s, 0, o - 3 * t, //
      0, 0, 0, 1, 0,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    if (level <= 0) return builder(context);
    final t = (level.clamp(0, 100)) / 100.0;
    final sigma = 2.0 + 6.0 * t;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(colorFilter: _tone(t), child: builder(context)),
        Opacity(
          opacity: 0.55 * t,
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp),
            child: ColorFiltered(colorFilter: _tone(t), child: builder(context)),
          ),
        ),
      ],
    );
  }
}

/// Bảng chỉnh mức làm đẹp mở từ cột nút bên phải khi đang gọi.
Future<void> showBeautySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) {
      final b = BeautySettings.instance;
      return SafeArea(
        child: ListenableBuilder(
          listenable: b,
          builder: (ctx, _) => Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr(ctx, 'Làm đẹp', 'Beauty'), style: AppText.title),
                const SizedBox(height: AppSpace.sm),
                Text(
                  b.level == 0 ? tr(ctx, 'Đang tắt', 'Off') : tr(ctx, 'Mức ${b.level}%', 'Level ${b.level}%'),
                  style: AppText.label,
                ),
                Slider(
                  value: b.level.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: '${b.level}',
                  onChanged: (v) => b.setLevel(v.round()),
                ),
                Wrap(
                  spacing: AppSpace.sm,
                  children: [
                    for (final p in <(String, String, int)>[
                      ('Tắt', 'Off', 0),
                      ('Nhẹ', 'Light', 30),
                      ('Vừa', 'Medium', 60),
                      ('Mạnh', 'Strong', 85),
                    ])
                      ChoiceChip(
                        label: Text(tr(ctx, p.$1, p.$2)),
                        selected: b.level == p.$3,
                        onSelected: (_) => b.setLevel(p.$3),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.md),
                Text(tr(ctx, 'Nhọn cằm ${b.chin}%', 'Slim chin ${b.chin}%'), style: AppText.label),
                Slider(
                  value: b.chin.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: '${b.chin}',
                  onChanged: (v) => unawaited(b.setChin(v.round())),
                ),
                Text(tr(ctx, 'Mắt to ${b.eyes}%', 'Bigger eyes ${b.eyes}%'), style: AppText.label),
                Slider(
                  value: b.eyes.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: '${b.eyes}',
                  onChanged: (v) => unawaited(b.setEyes(v.round())),
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  tr(
                    ctx,
                    'Nhọn cằm / mắt to cần theo dõi khuôn mặt nên dùng thêm pin; mặc định tắt (0%). Người đối diện thấy hiệu ứng nếu họ dùng bản Chạm mới.',
                    'Slim chin / bigger eyes track your face, so they use more battery; off by default (0%). The other person sees it if they use the latest Chạm.',
                  ),
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  tr(
                    ctx,
                    'Làm mịn và sáng da nhẹ. Người đối diện thấy hình của bạn đã làm đẹp nếu họ dùng bản Chạm mới. Mức cao có thể tốn pin hơn.',
                    'Softens and brightens skin. The other person sees your enhanced picture if they use the latest Chạm. Higher levels can use more battery.',
                  ),
                  style: AppText.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
