import 'dart:async';
import 'dart:typed_data';

import '../services/call_service.dart';
import 'watch_protocol.dart';

/// Nguồn byte (tệp nhạc/phim của chủ). Tách ra để test không cần đĩa.
abstract class ByteSource {
  int get length;

  /// Đọc tối đa [len] byte từ [start] (ít hơn nếu hết tệp).
  Future<Uint8List> read(int start, int len);

  Future<void> close();
}

class MemoryByteSource implements ByteSource {
  MemoryByteSource(this.bytes);
  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int start, int len) async {
    if (start >= bytes.length) return Uint8List(0);
    final end = (start + len) > bytes.length ? bytes.length : start + len;
    return Uint8List.sublistView(bytes, start, end);
  }

  @override
  Future<void> close() async {}
}

/// Phía CHỦ TỆP: trả lời yêu cầu đọc đoạn byte của người xem qua kênh `media`.
/// Tệp không bao giờ được chép sang máy kia; người xem chỉ nhận đúng các đoạn trình phát hỏi (phát tới đâu tải tới đó).
class WatchHost {
  WatchHost({
    required BinaryChannel channel,
    required ByteSource source,
    Future<void> Function(Duration)? delay,
    this.maxConcurrent = 6,
  })  : _channel = channel,
        _source = source,
        _delay = delay ?? Future<void>.delayed;

  final BinaryChannel _channel;
  final ByteSource _source;
  final Future<void> Function(Duration) _delay;
  final int maxConcurrent;

  StreamSubscription<Uint8List>? _sub;
  final Set<int> _cancelled = <int>{};
  final Set<int> _active = <int>{};
  bool _disposed = false;

  void start() {
    _sub ??= _channel.binaryMessages.listen(_onBytes);
  }

  void _onBytes(Uint8List bytes) {
    final f = decodeFrame(bytes);
    if (f == null) return;
    switch (f.type) {
      case FrameType.req:
        final r = decodeReq(f);
        if (r == null || _active.length >= maxConcurrent || _active.contains(f.id)) {
          _channel.sendBinary(encodeFrame(FrameType.err, f.id));
          return;
        }
        unawaited(_serve(f.id, r.start, r.length));
      case FrameType.cancel:
        if (_active.contains(f.id)) _cancelled.add(f.id);
      case FrameType.data || FrameType.end || FrameType.err:
        break; // chiều ngược lại, chủ không nhận
    }
  }

  Future<void> _serve(int id, int start, int length) async {
    _active.add(id);
    try {
      var pos = start;
      var remaining = length;
      final limit = _source.length;
      if (start < 0 || start >= limit) {
        _channel.sendBinary(encodeFrame(FrameType.err, id));
        return;
      }
      if (start + remaining > limit) remaining = limit - start;
      while (remaining > 0 && !_disposed && !_cancelled.contains(id)) {
        if (_channel.binaryBuffered > kHighWater) {
          await _delay(const Duration(milliseconds: 15));
          continue;
        }
        final want = remaining < kChunkBytes ? remaining : kChunkBytes;
        final chunk = await _source.read(pos, want);
        if (chunk.isEmpty) break;
        if (!_channel.sendBinary(encodeFrame(FrameType.data, id, chunk))) return; // kênh đóng
        pos += chunk.length;
        remaining -= chunk.length;
      }
      if (!_cancelled.contains(id) && !_disposed) {
        _channel.sendBinary(encodeFrame(FrameType.end, id));
      }
    } on Object {
      _channel.sendBinary(encodeFrame(FrameType.err, id));
    } finally {
      _active.remove(id);
      _cancelled.remove(id);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    await _source.close();
  }
}
