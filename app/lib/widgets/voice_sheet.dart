import 'package:flutter/material.dart';

import '../services/voice_changer.dart';
import '../theme/tokens.dart';
import '../utils/tr.dart';

String _name(BuildContext c, VoicePreset p) => switch (p) {
      VoicePreset.off => tr(c, 'Giọng thật', 'My voice'),
      VoicePreset.deep => tr(c, 'Trầm', 'Deep'),
      VoicePreset.high => tr(c, 'Cao', 'High'),
      VoicePreset.robot => tr(c, 'Robot', 'Robot'),
      VoicePreset.monster => tr(c, 'Quái vật', 'Monster'),
    };

/// Bảng chọn kiểu giọng khi đang gọi.
Future<void> showVoiceSheet(BuildContext context) {
  final v = VoiceChanger.instance;
  v.refreshStatus();
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceHigh,
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: v,
        builder: (ctx, _) => Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr(ctx, 'Đổi giọng', 'Voice changer'), style: AppText.title),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: [
                  for (final p in VoicePreset.values)
                    ChoiceChip(
                      label: Text(_name(ctx, p)),
                      selected: v.preset == p,
                      onSelected: (_) async {
                        final ok = await v.setPreset(p);
                        if (!ok && ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                            content: Text(tr(ctx, 'Chưa bật được đổi giọng trên máy này.', 'Voice changer is not available on this device.')),
                          ));
                        }
                      },
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Text(
                tr(
                  ctx,
                  'Người kia nghe giọng đã đổi; bạn vẫn nghe giọng thật của mình. Chỉ áp dụng cho giọng của bạn trong cuộc gọi này.',
                  'The other person hears the changed voice; you still hear your own. It only affects your voice in this call.',
                ),
                style: AppText.caption.copyWith(color: AppColors.textSecondary),
              ),
              if (v.status.isNotEmpty) ...[
                const SizedBox(height: AppSpace.sm),
                Text(v.status, style: AppText.caption.copyWith(color: AppColors.textSecondary, fontSize: 10)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
