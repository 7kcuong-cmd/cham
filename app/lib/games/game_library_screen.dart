import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/remote_config.dart';
import 'game_models.dart';

/// Tab Trò chơi: danh mục game lấy từ server (cập nhật không cần ra bản app mới).
/// Chơi thật diễn ra trong cuộc gọi (nút game ở mép phải).
class GameLibraryScreen extends StatelessWidget {
  const GameLibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final remote = context.watch<RemoteConfigService>();
    final lang = Localizations.localeOf(context).languageCode;
    final list = GameCatalogEntry.parseAll(remote.games);
    return RefreshIndicator(
      onRefresh: remote.refresh,
      child: list.isEmpty
          ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Chưa có game nào'))])
          : ListView(children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Mở game trong lúc gọi video: bấm nút tay cầm ở mép phải màn hình gọi.'),
              ),
              for (final g in list)
                ListTile(
                  leading: const Icon(Icons.sports_esports),
                  title: Text(g.name(lang)),
                  subtitle: Text('v${g.version} · ${g.mode == 'turn' ? 'theo lượt' : 'thời gian thực'}'),
                ),
            ]),
    );
  }
}
