import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cham/services/ratchet.dart';
import 'package:flutter_test/flutter_test.dart';

// Đối chiếu với tools/ratchet-ref/vectors.json do bản Node sinh. Chạy: flutter test test/ratchet_vectors_test.dart
Uint8List _hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
Uint8List Function() _seeded(int tag) {
  var i = 0;
  return () => Uint8List.fromList(List<int>.filled(32, (tag * 37 + ++i) & 0xff));
}

void main() {
  final v = jsonDecode(File('test/fixtures/ratchet_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  Future<void> replay(List steps) async {
    final lo = await RatchetKey.fromSeed(_hex(v['idSeed']['lo'] as String));
    final hi = await RatchetKey.fromSeed(_hex(v['idSeed']['hi'] as String));
    final a = RatchetConversation(me: lo, peerPub: hi.pub, rand: _seeded(1));
    final b = RatchetConversation(me: hi, peerPub: lo.pub, rand: _seeded(2));
    final by = {'lo': a, 'hi': b};
    for (final s in steps) {
      final c = by[s['who']]!;
      if (s['op'] == 'encrypt') {
        expect(await c.encrypt(s['text'] as String), s['wire']);
      } else {
        await c.decrypt(s['wire'] as String);
      }
    }
  }

  test('kịch bản lo gửi trước khớp bản Node', () => replay(v['scenarios']['loFirst'] as List));
  test('kịch bản hi gửi trước khớp bản Node', () => replay(v['scenarios']['hiFirst'] as List));

  test('giải mã được bản mã của Node và lưu/khôi phục trạng thái', () async {
    final steps = v['scenarios']['loFirst'] as List;
    final lo = await RatchetKey.fromSeed(_hex(v['idSeed']['lo'] as String));
    final hi = await RatchetKey.fromSeed(_hex(v['idSeed']['hi'] as String));
    final b = RatchetConversation(me: hi, peerPub: lo.pub, rand: _seeded(2));
    expect(await b.decrypt(steps[0]['wire'] as String), 'một');
    final b2 = await RatchetConversation.restore(me: hi, peerPub: lo.pub, rand: _seeded(2), state: jsonDecode(jsonEncode(b.snapshot())) as Map<String, dynamic>);
    expect(await b2.decrypt(steps[1]['wire'] as String), 'hai');
  });
}
