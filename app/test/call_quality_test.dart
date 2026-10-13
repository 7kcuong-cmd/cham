import 'package:cham/services/call_quality.dart';
import 'package:flutter_test/flutter_test.dart';

Duration s(int n) => Duration(seconds: n);

List<PathStat> stats({required String local, required String remote, String state = 'succeeded', bool viaTransport = true}) => [
      PathStat('L', 'local-candidate', {'candidateType': local}),
      PathStat('R', 'remote-candidate', {'candidateType': remote}),
      PathStat('P', 'candidate-pair', {'localCandidateId': 'L', 'remoteCandidateId': 'R', 'state': state, 'nominated': true}),
      if (viaTransport) const PathStat('T', 'transport', {'selectedCandidatePairId': 'P'}),
    ];

void main() {
  group('pathFromStats', () {
    test('srflx/host -> p2p; relay ở một phía -> relay; thiếu dữ liệu -> unknown', () {
      expect(pathFromStats(stats(local: 'srflx', remote: 'host')), CallPath.p2p);
      expect(pathFromStats(stats(local: 'host', remote: 'relay')), CallPath.relay);
      expect(pathFromStats(stats(local: 'relay', remote: 'srflx', viaTransport: false)), CallPath.relay);
      expect(pathFromStats(const []), CallPath.unknown);
      expect(pathFromStats(stats(local: 'host', remote: 'host', state: 'in-progress', viaTransport: false).map((e) => e.type == 'candidate-pair' ? PathStat(e.id, e.type, {...e.values, 'nominated': false}) : e).toList()), CallPath.unknown);
    });
    test('hasSucceededDirectPair', () {
      expect(hasSucceededDirectPair(stats(local: 'srflx', remote: 'srflx')), isTrue);
      expect(hasSucceededDirectPair(stats(local: 'relay', remote: 'srflx')), isFalse);
    });
  });

  group('RelayGovernor gọi bạn', () {
    test('P2P: luôn đầy đủ, không thông báo', () {
      final g = RelayGovernor(profile: CallProfile.friend);
      for (var t = 0; t < 60; t += 5) {
        final d = g.evaluate(now: s(t), path: CallPath.p2p);
        expect(d.level, CallQualityLevel.full);
        expect(d.notice, isNull);
        expect(d.endCall, isFalse);
      }
    });

    test('relay: thấp -> 10s báo chậm (một lần) -> 20s chỉ tiếng -> 30s báo yếu và dừng', () {
      final g = RelayGovernor(profile: CallProfile.friend);
      expect(g.evaluate(now: s(1), path: CallPath.relay).level, CallQualityLevel.low);
      expect(g.evaluate(now: s(9), path: CallPath.relay).notice, isNull);
      final slow = g.evaluate(now: s(11), path: CallPath.relay);
      expect(slow.notice, CallNotice.relaySlow);
      expect(slow.level, CallQualityLevel.low);
      expect(g.evaluate(now: s(15), path: CallPath.relay).notice, isNull);
      final very = g.evaluate(now: s(21), path: CallPath.relay);
      expect(very.notice, CallNotice.relayVerySlow);
      expect(very.level, CallQualityLevel.audioOnly);
      expect(g.evaluate(now: s(25), path: CallPath.relay).notice, isNull);
      final end = g.evaluate(now: s(31), path: CallPath.relay);
      expect(end.endCall, isTrue);
      expect(end.notice, CallNotice.weakEnded);
      expect(g.evaluate(now: s(33), path: CallPath.relay).notice, isNull);
    });

    test('P2P nối được ở giây 17: về đầy đủ, báo đã khôi phục, đồng hồ reset', () {
      final g = RelayGovernor(profile: CallProfile.friend);
      g.evaluate(now: s(2), path: CallPath.relay);
      g.evaluate(now: s(12), path: CallPath.relay);
      final back = g.evaluate(now: s(17), path: CallPath.p2p);
      expect(back.level, CallQualityLevel.full);
      expect(back.notice, CallNotice.p2pRestored);
      expect(g.evaluate(now: s(18), path: CallPath.p2p).notice, isNull);
      // Mạng đổi, rơi về relay: đợt mới, đếm lại từ đầu.
      expect(g.evaluate(now: s(100), path: CallPath.relay).endCall, isFalse);
      expect(g.evaluate(now: s(105), path: CallPath.relay).notice, isNull);
      expect(g.evaluate(now: s(111), path: CallPath.relay).notice, CallNotice.relaySlow);
    });

    test('chưa nối được gì: 30s báo yếu và dừng; relay nối muộn (25s) vào thẳng chỉ-tiếng', () {
      final a = RelayGovernor(profile: CallProfile.friend);
      expect(a.evaluate(now: s(5), path: CallPath.unknown).endCall, isFalse);
      expect(a.evaluate(now: s(30), path: CallPath.unknown).endCall, isTrue);
      final b = RelayGovernor(profile: CallProfile.friend);
      b.evaluate(now: s(0), path: CallPath.unknown);
      expect(b.evaluate(now: s(25), path: CallPath.relay).level, CallQualityLevel.audioOnly);
    });

    test('đang relay: cứ 8s đề nghị thử lại P2P', () {
      final g = RelayGovernor(profile: CallProfile.friend);
      g.evaluate(now: s(0), path: CallPath.relay);
      expect(g.evaluate(now: s(4), path: CallPath.relay).retryP2p, isFalse);
      expect(g.evaluate(now: s(8), path: CallPath.relay).retryP2p, isTrue);
      expect(g.evaluate(now: s(10), path: CallPath.relay).retryP2p, isFalse);
      expect(g.evaluate(now: s(16), path: CallPath.relay).retryP2p, isTrue);
    });
  });

  group('RelayGovernor lướt', () {
    test('P2P phải ổn định (2 lần đo liên tiếp) mới tính; thoáng qua thì vẫn đếm giờ relay', () {
      final g = RelayGovernor(profile: CallProfile.swipe);
      g.evaluate(now: s(1), path: CallPath.relay);
      final blip = g.evaluate(now: s(2), path: CallPath.p2p); // mới 1 lần
      expect(blip.level, CallQualityLevel.low);
      expect(blip.notice, isNull);
      g.evaluate(now: s(3), path: CallPath.relay); // P2P rớt lại: chuỗi ổn định về 0
      expect(g.evaluate(now: s(4), path: CallPath.p2p).level, CallQualityLevel.low);
      final stable = g.evaluate(now: s(5), path: CallPath.p2p); // lần thứ 2 liên tiếp
      expect(stable.level, CallQualityLevel.full);
      expect(stable.endCall, isFalse);
    });

    test('relay chỉ được 10s rồi báo yếu và dừng; chất lượng thấp trong lúc đó', () {
      final g = RelayGovernor(profile: CallProfile.swipe);
      final a = g.evaluate(now: s(1), path: CallPath.relay);
      expect(a.level, CallQualityLevel.low);
      expect(a.endCall, isFalse);
      expect(g.evaluate(now: s(9), path: CallPath.relay).endCall, isFalse);
      final end = g.evaluate(now: s(11), path: CallPath.relay);
      expect(end.endCall, isTrue);
      expect(end.notice, CallNotice.weakEnded);
    });
    test('P2P: không bao giờ bị dừng', () {
      final g = RelayGovernor(profile: CallProfile.swipe);
      expect(g.evaluate(now: s(200), path: CallPath.p2p).endCall, isFalse);
    });
  });

  test('SenderLimits: tiết kiệm đúng thang', () {
    const c = CallQualityConfig();
    final full = SenderLimits.approxBitsPerSecond(CallQualityLevel.full, c);
    final low = SenderLimits.approxBitsPerSecond(CallQualityLevel.low, c);
    final audio = SenderLimits.approxBitsPerSecond(CallQualityLevel.audioOnly, c);
    expect(low, lessThan(full ~/ 3));
    expect(audio, lessThan(low ~/ 5));
    expect(SenderLimits.forLevel(CallQualityLevel.audioOnly, c).videoActive, isFalse);
  });
}
