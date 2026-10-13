import 'package:flutter_test/flutter_test.dart';

import 'package:cham/state/privacy_settings.dart';

void main() {
  final servers = <Map<String, dynamic>>[
    {'urls': ['stun:s:3478']},
    {'urls': ['turn:t:3478'], 'username': 'u', 'credential': 'c'},
  ];

  test('thường: bỏ TURN, chính sách all', () {
    final c = PrivacySettings.iceConfig(servers, relayOnly: false)!;
    expect((c['iceServers'] as List).length, 1);
    expect(c.containsKey('iceTransportPolicy'), isFalse);
  });

  test('riêng tư: chỉ TURN và chính sách relay', () {
    final c = PrivacySettings.iceConfig(servers, relayOnly: true)!;
    expect(c['iceTransportPolicy'], 'relay');
    expect((c['iceServers'] as List).single['username'], 'u');
  });

  test('riêng tư mà server không có TURN: từ chối (không lộ IP)', () {
    expect(PrivacySettings.iceConfig([servers.first], relayOnly: true), isNull);
  });
}
