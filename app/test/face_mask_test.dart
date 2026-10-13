import 'dart:async';
import 'dart:typed_data';
import 'dart:ui';

import 'package:cham/models/face_sample.dart';
import 'package:cham/services/call_service.dart';
import 'package:cham/services/media_pick_guard.dart';
import 'package:cham/state/face_mask_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call implements CallService, FrameCapturable {
  final StreamController<Map<String, dynamic>> in_ = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  int captures = 0;

  @override
  Stream<Map<String, dynamic>> get dataMessages => in_.stream;

  @override
  bool sendData(Map<String, dynamic> message) {
    sent.add(message);
    return true;
  }

  @override
  Future<Uint8List?> captureLocalFrame() async {
    captures++;
    return Uint8List.fromList(<int>[1, 2, 3]);
  }

  @override
  Future<Uint8List?> captureRemoteFrame() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _s = FaceSample(center: Offset(0.5, 0.4), width: 0.3, height: 0.4, rollDeg: 10, imageAspect: 0.75, leftEye: Offset(0.4, 0.35), rightEye: Offset(0.6, 0.35));

void main() {
  group('FaceSample', () {
    test('JSON qua lại giữ nguyên giá trị', () {
      final r = FaceSample.fromJson(_s.toJson())!;
      expect(r.center, _s.center);
      expect(r.rollDeg, 10);
      expect(r.leftEye, const Offset(0.4, 0.35));
      expect(r.nose, isNull);
    });

    test('dữ liệu lạ từ đối phương bị chặn hoặc bỏ', () {
      expect(FaceSample.fromJson('x'), isNull);
      expect(FaceSample.fromJson(<String, dynamic>{'c': [0.5], 'w': 1, 'h': 1, 'r': 0, 'a': 1}), isNull);
      final r = FaceSample.fromJson(<String, dynamic>{'c': [9, -3], 'w': 99, 'h': 0, 'r': 500, 'a': 1})!;
      expect(r.center, const Offset(1, 0));
      expect(r.width, 1);
      expect(r.height, 0.02);
      expect(r.rollDeg, 90);
    });

    test('mirrored lật x, đổi mắt và dấu góc nghiêng', () {
      final m = _s.mirrored();
      expect(m.center.dx, closeTo(0.5, 1e-9));
      expect(m.rollDeg, -10);
      expect(m.leftEye!.dx, closeTo(0.4, 1e-9)); // 1 - 0.6
      expect(m.rightEye!.dx, closeTo(0.6, 1e-9));
    });

    test('toView: ô vuông, ảnh dọc kiểu cover cắt trên/dưới', () {
      const view = Size(100, 100);
      // ảnh cao gấp đôi bề ngang (aspect 0.5): phóng theo bề ngang → cao 200, lệch -50.
      final p = FaceSample.toView(const Offset(0.5, 0.5), view, 0.5);
      expect(p.dx, closeTo(50, 1e-9));
      expect(p.dy, closeTo(50, 1e-9));
      final top = FaceSample.toView(const Offset(0, 0.25), view, 0.5);
      expect(top.dy, closeTo(0, 1e-9)); // 0.25*200 - 50
    });

    test('lerp ở t=0/1 trả về hai đầu', () {
      const b = FaceSample(center: Offset(0.7, 0.6), width: 0.5, height: 0.6, rollDeg: -20, imageAspect: 0.75);
      expect(FaceSample.lerp(_s, b, 0).center, _s.center);
      expect(FaceSample.lerp(_s, b, 1).width, 0.5);
    });
  });

  group('MediaPickGuard', () {
    setUp(MediaPickGuard.reset);

    test('active trong lúc chạy và còn "ân hạn" ngắn sau đó', () async {
      expect(MediaPickGuard.active, isFalse);
      final gate = Completer<void>();
      final f = MediaPickGuard.run(() => gate.future);
      expect(MediaPickGuard.active, isTrue);
      gate.complete();
      await f;
      expect(MediaPickGuard.active, isTrue); // tail
    });

    test('lỗi trong bộ chọn vẫn hạ cờ', () async {
      await expectLater(MediaPickGuard.run<void>(() async => throw StateError('x')), throwsStateError);
      MediaPickGuard.reset();
      expect(MediaPickGuard.active, isFalse);
    });
  });

  group('FaceMaskController', () {
    test('bật mặt nạ → chụp, nhận diện, gửi vị trí; tắt → gửi id null', () async {
      final call = _Call();
      final c = FaceMaskController(call, detect: (_) async => _s, every: const Duration(milliseconds: 10));
      c.setMask('cat');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(call.captures, greaterThan(0));
      final m = call.sent.last;
      expect(m['type'], 'mask');
      expect(m['id'], 'cat');
      expect(m['f'], isA<Map<String, dynamic>>());
      c.setMask(null);
      expect(call.sent.last['id'], isNull);
      expect(c.local, isNull);
      c.dispose();
    });

    test('id lạ bị từ chối; không có bộ nhận diện thì không chạy', () {
      final call = _Call();
      final c = FaceMaskController(call);
      c.setMask('hacker');
      expect(c.maskId, isNull);
      expect(c.supported, isFalse);
      c.dispose();
    });

    test('nhận mặt nạ của đối phương, id lạ bị bỏ, hết hạn tự ẩn', () async {
      final call = _Call();
      final c = FaceMaskController(call, detect: (_) async => null, peerTtl: const Duration(milliseconds: 40));
      call.in_.add(<String, dynamic>{'type': 'mask', 'id': 'dog', 'f': _s.toJson()});
      await Future<void>.delayed(Duration.zero);
      expect(c.peerMaskId, 'dog');
      expect(c.peer, isNotNull);
      call.in_.add(<String, dynamic>{'type': 'mask', 'id': '<script>', 'f': _s.toJson()});
      await Future<void>.delayed(Duration.zero);
      expect(c.peerMaskId, isNull);
      call.in_.add(<String, dynamic>{'type': 'mask', 'id': 'cat', 'f': _s.toJson()});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.peerMaskId, isNull); // hết hạn
      c.dispose();
    });

    test('nhọn cằm / mắt to: theo dõi mặt không cần mặt nạ, gửi tin face (không gửi mask)', () async {
      final call = _Call();
      final c = FaceMaskController(call, detect: (_) async => _s, every: const Duration(milliseconds: 10))
        ..chinLevel = (() => 40)
        ..eyesLevel = (() => 70);
      c.setReshape(true);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(call.captures, greaterThan(0));
      expect(call.sent.where((m) => m['type'] == 'mask'), isEmpty);
      final f = call.sent.lastWhere((m) => m['type'] == 'face');
      expect(f['chin'], 40);
      expect(f['eyes'], 70);
      expect(f['f'], isA<Map<String, dynamic>>());
      c.setReshape(false);
      final off = call.sent.last;
      expect(off['type'], 'face');
      expect(off['chin'], 0);
      expect(off['f'], isNull);
      expect(c.local, isNull);
      c.dispose();
    });

    test('nhận tin face của đối phương: chặn giá trị, sai dạng thì bỏ, hết hạn tự ẩn', () async {
      final call = _Call();
      final c = FaceMaskController(call, detect: (_) async => null, peerTtl: const Duration(milliseconds: 40));
      call.in_.add(<String, dynamic>{'type': 'face', 'chin': 250, 'eyes': -5, 'f': _s.toJson()});
      await Future<void>.delayed(Duration.zero);
      expect(c.peerFace, isNotNull);
      expect(c.peerChin, 100);
      expect(c.peerEyes, 0);
      call.in_.add(<String, dynamic>{'type': 'face', 'chin': 'x', 'eyes': 1, 'f': _s.toJson()});
      await Future<void>.delayed(Duration.zero);
      expect(c.peerFace, isNull);
      call.in_.add(<String, dynamic>{'type': 'face', 'chin': 10, 'eyes': 10, 'f': _s.toJson()});
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(c.peerFace, isNull); // hết hạn
      c.dispose();
    });
  });
}
