import 'package:cham/security/ice_guard.dart';
import 'package:flutter_test/flutter_test.dart';

String cand(String addr, int port, {String type = 'srflx', String transport = 'udp', String extra = ''}) =>
    'candidate:842163049 1 $transport 1677729535 $addr $port typ $type $extra'.trim();

void main() {
  late DateTime clock;
  late IceGuard g;
  setUp(() {
    clock = DateTime.utc(2026, 10, 10, 9);
    g = IceGuard(now: () => clock);
  });

  group('địa chỉ', () {
    test('IPv4 không công khai', () {
      for (final a in ['10.0.0.1', '127.0.0.1', '192.168.1.5', '172.16.0.1', '172.31.255.1', '169.254.1.1', '0.0.0.0', '100.64.0.1', '224.0.0.1', '255.255.255.255']) {
        expect(isNonPublicAddress(a), isTrue, reason: a);
      }
      for (final a in ['8.8.8.8', '172.32.0.1', '172.15.0.1', '1.1.1.1', '203.0.114.1']) {
        expect(isNonPublicAddress(a), isFalse, reason: a);
      }
    });
    test('IPv6', () {
      for (final a in ['::1', '::', 'fe80::1', 'fc00::1', 'fd12:3456::1', 'ff02::1', '2001:db8::1', '::ffff:192.168.0.1', '::ffff:10.0.0.1']) {
        expect(isNonPublicAddress(a), isTrue, reason: a);
      }
      for (final a in ['2001:4860:4860::8888', '2a00:1450:4001::1', '::ffff:8.8.8.8']) {
        expect(isNonPublicAddress(a), isFalse, reason: a);
      }
    });
    test('phân loại', () {
      expect(classifyAddress('1.2.3.4'), AddrKind.v4);
      expect(classifyAddress('2001:db8::1'), AddrKind.v6);
      expect(classifyAddress('abc-123.local'), AddrKind.mdns);
      expect(classifyAddress('evil.example.com'), AddrKind.invalid);
      expect(classifyAddress('1.2.3'), AddrKind.invalid);
      expect(classifyAddress('300.1.1.1'), AddrKind.invalid);
      expect(classifyAddress('1::2::3'), AddrKind.invalid);
    });
  });

  group('phân tích ứng viên', () {
    test('hợp lệ và có tiền tố a=', () {
      final c = IceCandidateInfo.tryParse('a=${cand('8.8.8.8', 40000)}');
      expect(c, isNotNull);
      expect(c!.address, '8.8.8.8');
      expect(c.port, 40000);
      expect(c.type, 'srflx');
    });
    test('sai cú pháp', () {
      expect(IceCandidateInfo.tryParse(null), isNull);
      expect(IceCandidateInfo.tryParse(''), isNull);
      expect(IceCandidateInfo.tryParse('candidate:1 1 udp 1 8.8.8.8 40000'), isNull);
      expect(IceCandidateInfo.tryParse('candidate:1 9 udp 1 8.8.8.8 40000 typ host'), isNull);
      expect(IceCandidateInfo.tryParse('candidate:1 1 sctp 1 8.8.8.8 40000 typ host'), isNull);
      expect(IceCandidateInfo.tryParse('candidate:1 1 udp 1 8.8.8.8 40000 typ weird'), isNull);
      expect(IceCandidateInfo.tryParse('x' * 600), isNull);
    });
  });

  group('L0 chiều gửi', () {
    test('bỏ host IP riêng tư, giữ host công khai và mDNS', () {
      expect(g.sanitizeOutgoing(cand('192.168.1.5', 5000, type: 'host'), relayOnly: false), isNull);
      expect(g.sanitizeOutgoing(cand('fe80::1', 5000, type: 'host'), relayOnly: false), isNull);
      expect(g.sanitizeOutgoing(cand('abcd-ef.local', 5000, type: 'host'), relayOnly: false), isNotNull);
      expect(g.sanitizeOutgoing(cand('8.8.8.8', 5000, type: 'host'), relayOnly: false), isNotNull);
    });
    test('bỏ prflx, TCP và dòng không hiểu', () {
      expect(g.sanitizeOutgoing(cand('8.8.8.8', 5000, type: 'prflx'), relayOnly: false), isNull);
      expect(g.sanitizeOutgoing(cand('8.8.8.8', 5000, type: 'host', transport: 'tcp', extra: 'tcptype passive'), relayOnly: false), isNull);
      expect(g.sanitizeOutgoing('garbage', relayOnly: false), isNull);
    });
    test('relay-only: chỉ relay', () {
      expect(g.sanitizeOutgoing(cand('8.8.8.8', 5000), relayOnly: true), isNull);
      expect(g.sanitizeOutgoing(cand('8.8.4.4', 3478, type: 'relay'), relayOnly: true), isNotNull);
    });
    test('che raddr/rport (kể cả của relay)', () {
      final s = g.sanitizeOutgoing(cand('8.8.4.4', 3478, type: 'relay', extra: 'raddr 1.2.3.4 rport 5555'), relayOnly: true)!;
      expect(s.contains('1.2.3.4'), isFalse);
      expect(s.contains('raddr 0.0.0.0 rport 0'), isTrue);
    });
    test('strictIpv6 bỏ host IPv6 công khai', () {
      final strict = IceGuard(now: () => clock, strictIpv6: true);
      expect(strict.sanitizeOutgoing(cand('2001:4860::1', 5000, type: 'host'), relayOnly: false), isNull);
      expect(g.sanitizeOutgoing(cand('2001:4860::1', 5000, type: 'host'), relayOnly: false), isNotNull);
    });
    test('sanitizeSdp chiều gửi xoá dòng riêng tư, giữ dòng khác', () {
      const nl = '\r\n';
      final sdp = ['v=0', 'a=${cand('192.168.1.5', 5000, type: 'host')}', 'a=${cand('8.8.8.8', 5001)}', 'm=video 9 UDP/TLS/RTP/SAVPF 96'].join(nl);
      final out = g.sanitizeSdp(sdp, outgoing: true);
      expect(out.contains('192.168.1.5'), isFalse);
      expect(out.contains('8.8.8.8'), isTrue);
      expect(out.contains('m=video'), isTrue);
    });
  });

  group('L0 chiều nhận + điểm', () {
    test('ứng viên hợp lệ được nhận, không có điểm', () {
      expect(g.checkIncoming(cand('8.8.8.8', 40000)), IncomingVerdict.accept);
      expect(g.score, 0);
      expect(g.anomaly, isFalse);
    });
    test('IP riêng tư/loopback → bất thường ngay', () {
      expect(g.checkIncoming(cand('192.168.0.10', 40000, type: 'host')), IncomingVerdict.drop);
      expect(g.anomaly, isTrue);
      expect(g.signals.single.code, 'cand_private');
    });
    test('127.0.0.1 → bất thường', () {
      g.checkIncoming(cand('127.0.0.1', 22, type: 'host'));
      expect(g.anomaly, isTrue);
    });
    test('mDNS bị bỏ nhưng không bị phạt; prflx qua tín hiệu bị phạt nhẹ', () {
      expect(g.checkIncoming(cand('abc.local', 5000, type: 'host')), IncomingVerdict.drop);
      expect(g.score, 0);
      expect(g.checkIncoming(cand('8.8.8.8', 5000, type: 'prflx')), IncomingVerdict.drop);
      expect(g.score, AbuseCode.signalReplay.points);
      expect(g.anomaly, isFalse);
    });
    test('sai cú pháp: 2 điểm mỗi lần, ba lần là bất thường', () {
      g.checkIncoming('rác 1');
      g.checkIncoming('rác 2');
      expect(g.anomaly, isFalse);
      g.checkIncoming('rác 3');
      expect(g.anomaly, isTrue);
    });
    test('cổng đặc biệt bị bỏ; 3478 được phép', () {
      expect(g.checkIncoming(cand('8.8.8.8', 22)), IncomingVerdict.drop);
      expect(g.score, AbuseCode.candPorts.points);
      final g2 = IceGuard(now: () => clock);
      expect(g2.checkIncoming(cand('8.8.4.4', 3478, type: 'relay')), IncomingVerdict.accept);
    });
    test('TCP không phải relay bị bỏ im lặng', () {
      expect(g.checkIncoming(cand('8.8.8.8', 40000, transport: 'tcp', type: 'host', extra: 'tcptype active')), IncomingVerdict.drop);
      expect(g.score, 0);
    });
    test('bão ứng viên (> 16) → candFlood', () {
      for (var i = 0; i < 17; i++) {
        clock = clock.add(const Duration(seconds: 2));
        g.checkIncoming(cand('8.8.8.${i + 1}', 40000 + i));
      }
      expect(g.signals.any((s) => s.code == 'cand_flood'), isTrue);
      expect(g.anomaly, isTrue);
    });
    test('quá 20 ứng viên trong 1 giây → candFlood', () {
      final fast = IceGuard(now: () => clock, maxCandidates: 100);
      for (var i = 0; i < 21; i++) {
        fast.checkIncoming(cand('8.8.8.${i + 1}', 40000));
      }
      expect(fast.anomaly, isTrue);
    });
    test('quét dải cổng trên một IP → candPorts', () {
      for (var i = 0; i < 6; i++) {
        clock = clock.add(const Duration(seconds: 1));
        g.checkIncoming(cand('8.8.8.8', 40000 + i));
      }
      expect(g.signals.any((s) => s.code == 'cand_ports'), isTrue);
    });
    test('sanitizeSdp chiều nhận loại dòng độc và tính điểm', () {
      const nl = '\n';
      final sdp = ['v=0', 'a=${cand('10.1.1.1', 5000, type: 'host')}', 'a=${cand('8.8.8.8', 5001)}'].join(nl);
      final out = g.sanitizeSdp(sdp, outgoing: false);
      expect(out.contains('10.1.1.1'), isFalse);
      expect(out.contains('8.8.8.8'), isTrue);
      expect(g.anomaly, isTrue);
    });
  });

  group('L2 thống kê', () {
    test('một prflx lạ là bình thường, đến địa chỉ thứ ba thì bất thường', () {
      StatReport rc(String ip) => StatReport('remote-candidate', {'candidateType': 'prflx', 'address': ip});
      g.onStats([rc('9.9.9.1')]);
      expect(g.score, 0);
      g.onStats([rc('9.9.9.2')]);
      expect(g.anomaly, isFalse);
      g.onStats([rc('9.9.9.3')]);
      expect(g.anomaly, isTrue);
    });
    test('prflx trùng ứng viên đã nhận thì không phạt', () {
      g.checkIncoming(cand('9.9.9.1', 40000));
      g.onStats([const StatReport('remote-candidate', {'candidateType': 'prflx', 'address': '9.9.9.1'})]);
      g.onStats([const StatReport('remote-candidate', {'candidateType': 'prflx', 'address': '9.9.9.1'})]);
      expect(g.score, 0);
    });
    test('STUN không mời > 50 trên cặp chưa nominate', () {
      g.onStats([const StatReport('candidate-pair', {'nominated': false, 'requestsReceived': 60})]);
      expect(g.signals.single.code, 'stun_unsolicited');
      expect(g.score, AbuseCode.stunUnsolicited.points);
      final g2 = IceGuard(now: () => clock);
      g2.onStats([const StatReport('candidate-pair', {'nominated': true, 'requestsReceived': 600})]);
      expect(g2.score, 0);
    });
    test('requestsReceived dạng chuỗi vẫn đọc được', () {
      g.onStats([const StatReport('candidate-pair', {'nominated': 'false', 'requestsReceived': '80'})]);
      expect(g.score, AbuseCode.stunUnsolicited.points);
    });
    test('ICE nối nhưng 5 s không có media → điểm nhẹ, không tự bất thường', () {
      g.noteIceConnected();
      clock = clock.add(const Duration(seconds: 6));
      g.tick();
      expect(g.score, AbuseCode.iceOnlyProbe.points);
      expect(g.anomaly, isFalse);
      g.tick(); // không cộng lại
      expect(g.score, AbuseCode.iceOnlyProbe.points);
    });
    test('có media thì không phạt; cúp < 3 s sau khi nối thì phạt nhẹ', () {
      g.noteIceConnected();
      g.noteMedia();
      clock = clock.add(const Duration(seconds: 6));
      g.tick();
      expect(g.score, 0);
      final g2 = IceGuard(now: () => clock);
      g2.noteIceConnected();
      clock = clock.add(const Duration(seconds: 1));
      g2.noteRemoteLeft();
      expect(g2.score, AbuseCode.iceOnlyProbe.points);
    });
  });

  test('signals không chứa IP', () {
    g.checkIncoming(cand('192.168.0.10', 40000, type: 'host'));
    final json = g.signals.map((s) => s.toJson().toString()).join();
    expect(json.contains('192.168'), isFalse);
  });
}
