import 'dart:typed_data';

/// Giao thức "xem/nghe chung" trên DataChannel nhị phân `media`.
///
/// Khung: `[loại:1][id:4 big-endian][dữ liệu...]`.
///  - [FrameType.req]   (người xem → chủ file): `start:8` + `length:8` (big-endian) – xin đoạn byte `[start, start+length)`.
///  - [FrameType.data]  (chủ → người xem): một mảnh byte của yêu cầu `id`.
///  - [FrameType.end]   (chủ → người xem): đã gửi đủ yêu cầu `id`.
///  - [FrameType.err]   (chủ → người xem): không đọc được yêu cầu `id`.
///  - [FrameType.cancel](người xem → chủ): bỏ yêu cầu `id`.
enum FrameType {
  req(1),
  data(2),
  end(3),
  err(4),
  cancel(5);

  const FrameType(this.code);
  final int code;

  static FrameType? of(int code) {
    for (final t in values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

class Frame {
  const Frame(this.type, this.id, this.payload);
  final FrameType type;
  final int id;
  final Uint8List payload;
}

/// SCTP/DataChannel an toàn ở ~16 KiB mỗi tin; chừa 5 byte đầu khung.
const int kChunkBytes = 16 * 1024 - 5;

/// Ngưỡng hàng đợi gửi: vượt ngưỡng này bên gửi chờ cho thoát bớt.
const int kHighWater = 1024 * 1024;

Uint8List encodeFrame(FrameType type, int id, [Uint8List? payload]) {
  final p = payload ?? Uint8List(0);
  final out = Uint8List(5 + p.length);
  final bd = ByteData.sublistView(out);
  bd.setUint8(0, type.code);
  bd.setUint32(1, id & 0xFFFFFFFF);
  out.setRange(5, out.length, p);
  return out;
}

Frame? decodeFrame(Uint8List bytes) {
  if (bytes.length < 5) return null;
  final type = FrameType.of(bytes[0]);
  if (type == null) return null;
  final id = ByteData.sublistView(bytes).getUint32(1);
  return Frame(type, id, Uint8List.sublistView(bytes, 5));
}

Uint8List encodeReq(int id, int start, int length) {
  final p = Uint8List(16);
  final bd = ByteData.sublistView(p);
  // Hai nửa 32 bit để chạy được cả khi dịch sang web; tệp < 2^53 byte.
  bd.setUint32(0, start ~/ 0x100000000);
  bd.setUint32(4, start % 0x100000000);
  bd.setUint32(8, length ~/ 0x100000000);
  bd.setUint32(12, length % 0x100000000);
  return encodeFrame(FrameType.req, id, p);
}

/// `(start, length)` của khung REQ, hoặc null nếu sai dạng.
({int start, int length})? decodeReq(Frame f) {
  if (f.type != FrameType.req || f.payload.length != 16) return null;
  final bd = ByteData.sublistView(f.payload);
  final start = bd.getUint32(0) * 0x100000000 + bd.getUint32(4);
  final length = bd.getUint32(8) * 0x100000000 + bd.getUint32(12);
  return (start: start, length: length);
}

/// Kết quả phân tích tiêu đề HTTP `Range` cho tệp dài [total] byte.
sealed class RangeResult {
  const RangeResult();
}

/// Không có Range: trả toàn bộ (HTTP 200).
final class FullRange extends RangeResult {
  const FullRange();
}

/// Đoạn `[start, end]` (cả hai đầu gồm; HTTP 206).
final class PartialRange extends RangeResult {
  const PartialRange(this.start, this.end);
  final int start;
  final int end;
  int get length => end - start + 1;
}

/// Range không thỏa mãn (HTTP 416).
final class BadRange extends RangeResult {
  const BadRange();
}

/// Hỗ trợ `bytes=a-b`, `bytes=a-`, `bytes=-n`. Nhiều khoảng (`a-b,c-d`) chỉ lấy khoảng đầu.
RangeResult parseHttpRange(String? header, int total) {
  if (header == null || header.trim().isEmpty) return const FullRange();
  final m = RegExp(r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*(?:,.*)?$').firstMatch(header);
  if (m == null) return const FullRange(); // lạ: bỏ qua theo RFC 7233 (trả toàn bộ)
  final a = m.group(1)!;
  final b = m.group(2)!;
  if (total <= 0) return const BadRange();
  if (a.isEmpty && b.isEmpty) return const BadRange();
  if (a.isEmpty) {
    final n = int.parse(b);
    if (n == 0) return const BadRange();
    final start = n >= total ? 0 : total - n;
    return PartialRange(start, total - 1);
  }
  final start = int.parse(a);
  if (start >= total) return const BadRange();
  var end = b.isEmpty ? total - 1 : int.parse(b);
  if (end >= total) end = total - 1;
  if (end < start) return const BadRange();
  return PartialRange(start, end);
}

/// Đồng bộ vị trí: trả vị trí cần nhảy tới, hoặc null nếu lệch chưa đáng kể.
int? driftTarget({required int localMs, required int remoteMs, int thresholdMs = 800}) {
  return (localMs - remoteMs).abs() > thresholdMs ? remoteMs : null;
}

String mimeForName(String name) {
  final i = name.lastIndexOf('.');
  final ext = i < 0 ? '' : name.substring(i + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'mov' => 'video/quicktime',
    '3gp' => 'video/3gpp',
    'mp3' => 'audio/mpeg',
    'm4a' || 'aac' => 'audio/mp4',
    'ogg' || 'opus' => 'audio/ogg',
    'wav' => 'audio/wav',
    'flac' => 'audio/flac',
    _ => 'application/octet-stream',
  };
}

bool isAudioName(String name) => mimeForName(name).startsWith('audio/');

const List<String> kWatchExtensions = [
  'mp4', 'm4v', 'mkv', 'webm', 'mov', '3gp', //
  'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'flac',
];
