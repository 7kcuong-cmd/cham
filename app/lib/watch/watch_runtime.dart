import 'package:file_picker/file_picker.dart';
import '../services/media_pick_guard.dart';

import '../services/call_service.dart';
import 'watch_file_source.dart';
import 'watch_host.dart';
import 'watch_player.dart';
import 'watch_protocol.dart';
import 'watch_proxy.dart';

/// Tệp người dùng chọn để chia sẻ.
class PickedMedia {
  const PickedMedia({required this.path, required this.name, required this.size});
  final String path;
  final String name;
  final int size;
}

/// Một phiên đang chạy: trình phát + cách dọn dẹp.
class WatchSession {
  WatchSession(this.player, this.close);
  final WatchPlayer player;
  final Future<void> Function() close;
}

abstract class WatchRuntime {
  /// [audio] = true: chọn nhạc; ngược lại chọn video. Dùng bộ chọn media của hệ thống (không duyệt cả thư mục).
  Future<PickedMedia?> pick({bool audio = false});

  /// Chủ tệp: mở tệp, bắt đầu phục vụ người xem, phát tệp cục bộ.
  Future<WatchSession> openHost(BinaryChannel ch, PickedMedia media);

  /// Người xem: dựng proxy cục bộ rồi phát qua URL đó.
  Future<WatchSession> openViewer(BinaryChannel ch, {required int size, required String mime});
}

class DeviceWatchRuntime implements WatchRuntime {
  const DeviceWatchRuntime();

  @override
  Future<PickedMedia?> pick({bool audio = false}) async {
    final r = await MediaPickGuard.run(() => FilePicker.platform.pickFiles(type: audio ? FileType.audio : FileType.video));
    final f = r?.files.single;
    final path = f?.path;
    if (f == null || path == null) return null;
    return PickedMedia(path: path, name: f.name, size: f.size);
  }

  @override
  Future<WatchSession> openHost(BinaryChannel ch, PickedMedia media) async {
    final src = await FileByteSource.open(media.path);
    final host = WatchHost(channel: ch, source: src)..start();
    final player = VideoWatchPlayer.file(media.path);
    return WatchSession(player, () async {
      await host.dispose();
      await player.dispose();
    });
  }

  @override
  Future<WatchSession> openViewer(BinaryChannel ch, {required int size, required String mime}) async {
    final proxy = WatchProxy(channel: ch, size: size, mime: mime);
    final url = await proxy.start();
    final player = VideoWatchPlayer.network(url);
    return WatchSession(player, () async {
      await player.dispose();
      await proxy.dispose();
    });
  }
}
