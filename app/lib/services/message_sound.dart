import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Âm báo ngắn khi có tin nhắn mới lúc đang mở app (không ở màn trò chuyện đó). Khi app ở nền thì thông báo hệ thống
/// tự phát âm của kênh "Tin nhắn". Tối đa 1 lần / 1,5 giây để không "reo" liên tục khi đồng bộ nhiều tin.
class MessageSound {
  MessageSound({AudioPlayer? player, DateTime Function()? now}) : _player = player, _now = now ?? DateTime.now;

  static const asset = 'audio/msg_ding.wav';
  static const Duration minGap = Duration(milliseconds: 1500);

  AudioPlayer? _player;
  final DateTime Function() _now;
  DateTime? _last;

  Future<void> play() async {
    final t = _now();
    final last = _last;
    if (last != null && t.difference(last) < minGap) return;
    _last = t;
    try {
      final p = _player ??= AudioPlayer();
      await p.setReleaseMode(ReleaseMode.stop);
      await p.setVolume(0.8);
      await p.play(AssetSource(asset));
    } on Object catch (e) {
      debugPrint('message sound: $e');
    }
  }

  Future<void> dispose() async {
    await _player?.dispose();
  }
}
