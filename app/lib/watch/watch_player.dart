import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// Trình phát tối giản cho "xem/nghe chung" (tách khỏi `video_player` để controller test được).
abstract class WatchPlayer {
  Future<void> init();
  bool get playing;
  int get positionMs;
  int get durationMs;
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(int ms);

  /// Thay đổi trạng thái (vị trí, phát/dừng, độ dài).
  Listenable get changes;

  /// Khung hình (video) hoặc hình bìa (nhạc).
  Widget view({required bool audioOnly});
  Future<void> dispose();
}

class VideoWatchPlayer implements WatchPlayer {
  VideoWatchPlayer.file(String path) : _c = VideoPlayerController.file(File(path));
  VideoWatchPlayer.network(Uri url) : _c = VideoPlayerController.networkUrl(url);

  final VideoPlayerController _c;

  @override
  Future<void> init() => _c.initialize();

  @override
  bool get playing => _c.value.isPlaying;

  @override
  int get positionMs => _c.value.position.inMilliseconds;

  @override
  int get durationMs => _c.value.duration.inMilliseconds;

  @override
  Future<void> play() => _c.play();

  @override
  Future<void> pause() => _c.pause();

  @override
  Future<void> seekTo(int ms) => _c.seekTo(Duration(milliseconds: ms));

  @override
  Listenable get changes => _c;

  @override
  Widget view({required bool audioOnly}) {
    if (audioOnly) {
      return const Center(child: Icon(Icons.music_note_rounded, size: 72, color: Colors.white70));
    }
    final ar = _c.value.isInitialized && _c.value.aspectRatio > 0 ? _c.value.aspectRatio : 16 / 9;
    return Center(child: AspectRatio(aspectRatio: ar, child: VideoPlayer(_c)));
  }

  @override
  Future<void> dispose() => _c.dispose();
}
