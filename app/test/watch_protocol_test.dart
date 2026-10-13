import 'dart:async';
import 'dart:typed_data';

import 'package:cham/services/call_service.dart';
import 'package:cham/watch/watch_host.dart';
import 'package:cham/watch/watch_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hai đầu kênh nhị phân nối thẳng nhau trong bộ nhớ.
class _Pipe implements BinaryChannel {
  _Pipe();
  late _Pipe other;
  final StreamController<Uint8List> _in = StreamController<Uint8List>.broadcast(sync: true);
  int buffered = 0;
  bool open = true;

  static (_Pipe, _Pipe) pair() {
    final a = _Pipe();
    final b = _Pipe();
    a.other = b;
    b.other = a;
    return (a, b);
  }

  @override
  Stream<Uint8List> get binaryMessages => _in.stream;
  @override
  bool get binaryOpen => open;
  @override
  int get binaryBuffered => buffered;
  @override
  bool sendBinary(Uint8List data) {
    if (!open) return false;
    other._in.add(Uint8List.fromList(data));
    return true;
  }
}

void main() {
  test('khung mã hóa/giải mã khứ hồi; khung hỏng bị bỏ', () {
    final f = decodeFrame(encodeFrame(FrameType.data, 0xDEADBEEF, Uint8List.fromList([1, 2, 3])))!;
    expect(f.type, FrameType.data);
    expect(f.id, 0xDEADBEEF);
    expect(f.payload, [1, 2, 3]);
    expect(decodeFrame(Uint8List.fromList([1, 0, 0])), isNull);
    expect(decodeFrame(Uint8List.fromList([99, 0, 0, 0, 1])), isNull);
  });

  test('REQ giữ nguyên start/length lớn hơn 4 GiB', () {
    final f = decodeFrame(encodeReq(7, 5 * 1024 * 1024 * 1024 + 3, 1234))!;
    final r = decodeReq(f)!;
    expect(r.start, 5 * 1024 * 1024 * 1024 + 3);
    expect(r.length, 1234);
  });

  test('parseHttpRange', () {
    expect(parseHttpRange(null, 100), isA<FullRange>());
    expect(parseHttpRange('bytes=0-9', 100), isA<PartialRange>().having((r) => r.length, 'len', 10));
    final open = parseHttpRange('bytes=90-', 100) as PartialRange;
    expect([open.start, open.end], [90, 99]);
    final suffix = parseHttpRange('bytes=-10', 100) as PartialRange;
    expect([suffix.start, suffix.end], [90, 99]);
    final big = parseHttpRange('bytes=0-9999', 100) as PartialRange;
    expect(big.end, 99);
    expect(parseHttpRange('bytes=100-', 100), isA<BadRange>());
    expect(parseHttpRange('bytes=50-10', 100), isA<BadRange>());
    expect(parseHttpRange('bytes=-', 100), isA<BadRange>());
    final multi = parseHttpRange('bytes=0-4,10-14', 100) as PartialRange;
    expect([multi.start, multi.end], [0, 4]);
    expect(parseHttpRange('items=1-2', 100), isA<FullRange>());
  });

  test('driftTarget chỉ nhảy khi lệch quá ngưỡng', () {
    expect(driftTarget(localMs: 1000, remoteMs: 1500), isNull);
    expect(driftTarget(localMs: 1000, remoteMs: 2500), 2500);
    expect(driftTarget(localMs: 1000, remoteMs: 1300, thresholdMs: 250), 1300);
  });

  test('mime theo đuôi tệp', () {
    expect(mimeForName('Phim.MP4'), 'video/mp4');
    expect(mimeForName('a.mp3'), 'audio/mpeg');
    expect(isAudioName('a.flac'), isTrue);
    expect(isAudioName('a.mkv'), isFalse);
  });

  test('WatchHost trả đúng byte theo từng đoạn, kèm END; cắt ở cuối tệp', () async {
    final (viewer, host) = _Pipe.pair();
    final data = Uint8List.fromList(List<int>.generate(40000, (i) => i % 251));
    final h = WatchHost(channel: host, source: MemoryByteSource(data))..start();
    addTearDown(h.dispose);

    final got = <int>[];
    final ended = Completer<void>();
    viewer.binaryMessages.listen((b) {
      final f = decodeFrame(b)!;
      if (f.type == FrameType.data && f.id == 5) got.addAll(f.payload);
      if (f.type == FrameType.end && f.id == 5) ended.complete();
    });
    viewer.sendBinary(encodeReq(5, 100, 39000));
    await ended.future.timeout(const Duration(seconds: 2));
    expect(got.length, 39000);
    expect(got, data.sublist(100, 39100));

    // Xin quá cuối tệp: chỉ nhận phần còn lại.
    got.clear();
    final ended2 = Completer<void>();
    viewer.binaryMessages.listen((b) {
      final f = decodeFrame(b)!;
      if (f.type == FrameType.data && f.id == 6) got.addAll(f.payload);
      if (f.type == FrameType.end && f.id == 6) ended2.complete();
    });
    viewer.sendBinary(encodeReq(6, 39990, 5000));
    await ended2.future.timeout(const Duration(seconds: 2));
    expect(got.length, 10);
  });

  test('WatchHost: start ngoài tệp -> ERR; CANCEL dừng sớm', () async {
    final (viewer, host) = _Pipe.pair();
    final data = Uint8List(1000000);
    var waits = 0;
    final h = WatchHost(
      channel: host,
      source: MemoryByteSource(data),
      delay: (_) async {
        waits++;
        await Future<void>.delayed(Duration.zero);
      },
    )..start();
    addTearDown(h.dispose);
    final types = <FrameType>[];
    var bytes = 0;
    viewer.binaryMessages.listen((b) {
      final f = decodeFrame(b)!;
      types.add(f.type);
      if (f.type == FrameType.data) bytes += f.payload.length;
    });

    viewer.sendBinary(encodeReq(1, 5000000, 10));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(types, [FrameType.err]);

    // Hàng đợi đầy: host giãn nhịp thay vì đẩy tiếp; hủy thì không có END.
    types.clear();
    host.buffered = kHighWater + 1;
    viewer.sendBinary(encodeReq(2, 0, 900000));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(waits, greaterThan(0));
    expect(bytes, 0);
    viewer.sendBinary(encodeFrame(FrameType.cancel, 2));
    host.buffered = 0;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(types, isNot(contains(FrameType.end)));
  });
}
