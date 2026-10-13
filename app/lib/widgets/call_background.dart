import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/remote_config.dart';
import '../state/call_background.dart';
import '../utils/tr.dart';

/// Ảnh nền người dùng đã chọn (lớp dưới màn hình chờ/kết nối). Không chọn hoặc chưa tải xong → trống.
class CallBackdrop extends StatelessWidget {
  const CallBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    RemoteConfigService? cfg;
    try {
      cfg = context.watch<RemoteConfigService>();
    } on Object {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: CallBackgroundSettings.instance,
      builder: (context, _) {
        final id = CallBackgroundSettings.instance.selectedId;
        final file = id.isEmpty ? null : cfg?.backgroundFile(id);
        if (file == null) return const SizedBox.shrink();
        return Stack(fit: StackFit.expand, children: [
          Image.file(file, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          const ColoredBox(color: Color(0x66000000)),
        ]);
      },
    );
  }
}

/// Chọn ảnh nền cuộc gọi trong danh sách do server cung cấp.
Future<void> showCallBackgroundPicker(BuildContext context) {
  final cfg = context.read<RemoteConfigService>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([cfg, CallBackgroundSettings.instance]),
        builder: (ctx, _) {
          final items = cfg.backgrounds.where((b) => cfg.backgroundFile(b.id) != null).toList();
          final sel = CallBackgroundSettings.instance.selectedId;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr(ctx, 'Ảnh nền cuộc gọi', 'Call background'), style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              if (items.isEmpty)
                Text(tr(ctx, 'Chưa có ảnh nền nào (hoặc đang tải).', 'No backgrounds yet (or still downloading).'))
              else
                Flexible(
                  child: GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 9 / 16,
                    children: [
                      _Tile(
                        selected: sel.isEmpty,
                        onTap: () => CallBackgroundSettings.instance.select(''),
                        child: Center(child: Text(tr(ctx, 'Không', 'None'))),
                      ),
                      for (final b in items)
                        _Tile(
                          selected: sel == b.id,
                          onTap: () => CallBackgroundSettings.instance.select(b.id),
                          child: Image.file(cfg.backgroundFile(b.id)!, fit: BoxFit.cover, cacheWidth: 300),
                        ),
                    ],
                  ),
                ),
            ]),
          );
        },
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  const _Tile({required this.selected, required this.onTap, required this.child});
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 3),
          ),
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      );
}
