import 'package:cham/models/match_found.dart';
import 'package:cham/state/safety_controller.dart';
import 'package:cham/state/swipe_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

class _FakeSwipe implements SwipeActions {
  final List<String> log;
  _FakeSwipe(this.log);

  @override
  Future<void> next() async => log.add('swipe.next');
}

void main() {
  const peer = Peer(id: 'Q9pLm2vX0aB7cWn3RtY1kZ', displayName: 'Anna', language: 'en');
  late FakeApiClient api;
  late List<String> log;
  late SafetyController safety;

  setUp(() {
    api = FakeApiClient();
    log = <String>[];
    api.onReport = (userId, reason, roomName, note) async => log.add('api.report($reason)');
    api.onBlock = (userId) async => log.add('api.block');
    safety = SafetyController(api: api, swipe: _FakeSwipe(log));
  });

  test('1. report(alsoBlock:true) → api.report rồi api.block, KHÔNG gọi swipe.next()', () async {
    final outcome = await safety.report(peer: peer, reason: 'spam', alsoBlock: true, roomName: 'r_x');
    expect(log, ['api.report(spam)', 'api.block']);
    expect(outcome, ReportOutcome.done);
  });

  test('2. report(alsoBlock:false) → api.report, rồi swipe.next(), không gọi api.block', () async {
    final outcome = await safety.report(peer: peer, reason: 'nudity', alsoBlock: false);
    expect(log, ['api.report(nudity)', 'swipe.next']);
    expect(outcome, ReportOutcome.done);
  });

  test('3. block → api.block, không next()', () async {
    await safety.block(peer);
    expect(log, ['api.block']);
  });

  test('4. api.block lỗi sau khi report thành công → swipe.next() vẫn được gọi', () async {
    api.onBlock = (userId) async => throw apiError('INTERNAL', status: 500);
    final outcome = await safety.report(peer: peer, reason: 'harassment', alsoBlock: true);
    expect(log, ['api.report(harassment)', 'swipe.next']);
    expect(outcome, ReportOutcome.doneBlockFailed);
  });

  test('report lỗi (RATE_LIMITED) → ném lại, không block, không next', () async {
    api.onReport = (userId, reason, roomName, note) async =>
        throw apiError('RATE_LIMITED', status: 429, retryAfterSec: 9);
    await expectLater(
      safety.report(peer: peer, reason: 'spam', alsoBlock: true),
      throwsA(isA<Exception>()),
    );
    expect(log, isEmpty);
  });

  test('truyền đúng userId/roomName/note xuống API', () async {
    String? seenUser, seenRoom, seenNote;
    api.onReport = (userId, reason, roomName, note) async {
      seenUser = userId;
      seenRoom = roomName;
      seenNote = note;
    };
    await safety.report(
      peer: peer,
      reason: 'other',
      note: 'abc',
      alsoBlock: false,
      roomName: 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11',
    );
    expect(seenUser, peer.id);
    expect(seenRoom, 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11');
    expect(seenNote, 'abc');
  });

  test('kReportReasons đúng 6 giá trị enum của API.md §1.5', () {
    expect(kReportReasons, ['nudity', 'harassment', 'underage', 'spam', 'violence', 'other']);
  });
}
