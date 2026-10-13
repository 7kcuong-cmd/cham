import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/remote_config.dart';
import 'game_models.dart';
import 'game_session.dart';

/// Chọn game để mời đối phương chơi trong cuộc gọi.
Future<void> showGamePicker(BuildContext context) {
  final session = context.read<GameSessionController>();
  final remote = context.read<RemoteConfigService>();
  final lang = Localizations.localeOf(context).languageCode;
  final list = GameCatalogEntry.parseAll(remote.games);
  return showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: list.isEmpty
          ? const Padding(padding: EdgeInsets.all(24), child: Text('Chưa có game nào'))
          : ListView(shrinkWrap: true, children: [
              for (final g in list)
                ListTile(
                  leading: const Icon(Icons.sports_esports),
                  title: Text(g.name(lang)),
                  subtitle: Text('v${g.version}'),
                  onTap: () {
                    Navigator.pop(ctx);
                    session.invite(g);
                  },
                ),
            ]),
    ),
  );
}

/// Thanh trạng thái lời mời/kết quả hiển thị trên màn hình gọi.
class GameStatusBanner extends StatelessWidget {
  const GameStatusBanner({super.key, required this.peerName});
  final String peerName;

  static String _noteText(String n) => switch (n) {
        'no_p2p' => 'Cuộc gọi này không hỗ trợ chơi game (không P2P)',
        'download' => 'Không tải được game',
        'timeout' => 'Đối phương không phản hồi',
        'declined' || 'cancel' => 'Đối phương từ chối',
        'busy' => 'Đối phương đang bận',
        'unsupported' => 'Đối phương chưa có game này, cần cập nhật',
        'peer_left' => 'Đối phương đã thoát',
        _ => n,
      };

  @override
  Widget build(BuildContext context) {
    final s = context.watch<GameSessionController>();
    final name = s.entry?.nameVi ?? '';
    Widget? child;
    switch (s.phase) {
      case GamePhase.preparing:
        child = Text('Đang chuẩn bị $name…');
      case GamePhase.inviting:
        child = Row(children: [
          Expanded(child: Text('Đã mời $peerName chơi $name…')),
          TextButton(onPressed: s.cancelInvite, child: const Text('Huỷ')),
        ]);
      case GamePhase.incoming:
        child = Row(children: [
          Expanded(child: Text('$peerName mời bạn chơi $name')),
          TextButton(onPressed: s.decline, child: const Text('Từ chối')),
          FilledButton(onPressed: s.accept, child: const Text('Chơi')),
        ]);
      case GamePhase.ended:
        final r = s.result;
        final text = s.notice != null
            ? _noteText(s.notice!)
            : r == 'win'
                ? 'Bạn thắng!'
                : r == 'lose'
                    ? 'Bạn thua'
                    : 'Hoà';
        child = Row(children: [Expanded(child: Text(text)), TextButton(onPressed: s.reset, child: const Text('Đóng'))]);
      case GamePhase.idle:
      case GamePhase.playing:
        return const SizedBox.shrink();
    }
    return Material(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(12),
      child: DefaultTextStyle(style: const TextStyle(color: Colors.white), child: Padding(padding: const EdgeInsets.all(10), child: child)),
    );
  }
}
