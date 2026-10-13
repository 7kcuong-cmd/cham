import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cham/services/safety_number.dart';

void main() {
  String key(int seed) => base64.encode(List<int>.generate(32, (i) => (i * seed + seed) % 256));

  test('đối xứng và ổn định', () async {
    final a = key(3);
    final b = key(7);
    final ab = await safetyNumber(a, b);
    expect(ab, await safetyNumber(b, a));
    expect(ab.split(' ').length, 12);
    expect(RegExp(r'^(\d{5} ){11}\d{5}$').hasMatch(ab), isTrue);
  });

  test('đổi một khóa thì mã đổi (phát hiện bị thay khóa)', () async {
    expect(await safetyNumber(key(3), key(7)), isNot(await safetyNumber(key(3), key(9))));
  });
}
