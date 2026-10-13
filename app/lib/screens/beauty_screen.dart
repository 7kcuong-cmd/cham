import 'package:flutter/material.dart';

import '../services/beauty.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

/// Chỉnh mức làm mịn da của camera trong cuộc gọi (Android, iOS).
class BeautyScreen extends StatelessWidget {
  const BeautyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final b = BeautySettings.instance;
    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'Làm mịn da', 'Skin smoothing'))),
      body: ListenableBuilder(
        listenable: b,
        builder: (context, _) {
          if (!b.supported) {
            return Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Text(tr(context, 'Tính năng này chưa có trên nền tảng này.', 'This feature is not available on this platform.')),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(
                b.level == 0 ? tr(context, 'Đang tắt', 'Off') : tr(context, 'Mức ${b.level}%', 'Level ${b.level}%'),
                style: AppText.label,
              ),
              Slider(
                value: b.level.toDouble(),
                max: 100,
                divisions: 20,
                label: '${b.level}',
                onChanged: (v) => b.setLevel(v.round()),
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                tr(
                  context,
                  'Làm mịn vùng da trên camera của bạn; người đối diện cũng thấy hình đã làm mịn. Mức cao có thể làm máy nóng và tốn pin hơn. Áp dụng ngay cả khi đang gọi.',
                  'Smooths skin on your camera; the other person sees the smoothed picture too. Higher levels can warm the phone and use more battery. Applies live during a call.',
                ),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          );
        },
      ),
    );
  }
}
