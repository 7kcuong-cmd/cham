import 'dart:async';
import 'dart:typed_data';

import 'package:cham/services/call_service.dart';
import 'package:cham/state/watch_controller.dart';
import 'package:cham/watch/watch_player.dart';
import 'package:cham/watch/watch_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _DataCall extends FakeCallService implements BinaryChannel {
  final StreamController<Map<String, dynamic>> incoming = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool open = true;

  @override
  Stream<Map<String, dynamic>> get dataMessages => incoming.stream;

  @override
  bool sendData(Map<String, dynamic> message) {
    sent.add(message);
    return true;
  }

  @override
  Stream<Uint8List> get binaryMessages => const Stream<Uint8List>.empty();
  @override
  bool get binaryOpen => open;
  @override
  bool sendBinary(Uint8List data) => true;
  @override
  int get binaryBuffered => 0;

  List<String> get sentTypes => sent.map((m) => m['type'] as String).toList();
}

class _Player extends ChangeNotifier implements WatchPlayer {
  @override
  bool playing = false;
  @override
  int positionMs = 0;
  @override
  int durationMs = 600000;
  bool disposed = false;
  final List<String> log = <String>[];

  @override
  Future<void> init() async => log.add('init');
  @override
  Future<void> play() async {
    playing = true;
    log.add('play');
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    log.add('pause');
    notifyListeners();
  }

  @override
  Future<void> seekTo(int ms) async {
    positionMs = ms;
    log.add('seek $ms');
  }

  @override
  Listenable get changes => this;
  @override
  Widget view({required bool audioOnly}) => const SizedBox.shrink();
  @override
  Future<void> dispose() async => disposed = true;
}

class _Runtime implements WatchRuntime {
  _Runtime({this.pickResult, this.failViewer = false});
  PickedMedia? pickResult;
  bool failViewer;
  final List<_Player> players = <_Player>[];
  int closed = 0;

  WatchSession _session() {
    final p = _Player();
    players.add(p);
    return WatchSession(p, () async => closed++);
  }

  @override
  Future<PickedMedia?> pick({bool audio = false}) async => pickResult;
  @override
  Future<WatchSession> openHost(BinaryChannel ch, PickedMedia media) async => _session();
  @override
  Future<WatchSession> openViewer(BinaryChannel ch, {required int size, required String mime}) async {
    if (failViewer) throw StateError('no proxy');
    return _session();
  }
}

void main() {
  late _DataCall call;
  late FakeRoom room;
  late FakeTimers timers;
  late _Runtime runtime;
  late WatchTogetherController host;
  late WatchTogetherController viewer;
  late _DataCall hostCall;
  var relay = false;

  // Hai controller nối chéo: tin host gửi -> viewer nhận và ngược lại.
  setUp(() {
    relay = false;
    call = _DataCall();
    hostCall = _DataCall();
    room = FakeRoom(room: 'r1');
    timers = FakeTimers();
    runtime = _Runtime(pickResult: const PickedMedia(path: '/x/phim.mp4', name: 'phim.mp4', size: 5000));
    host = WatchTogetherController(call: hostCall, room: room, runtime: runtime, relayOnly: () => relay, timerFactory: timers.create, idGen: () => 'w1');
    viewer = WatchTogetherController(call: call, room: FakeRoom(room: 'r1'), runtime: runtime, timerFactory: timers.create);
  });

  tearDown(() {
    host.dispose();
    viewer.dispose();
  });

  void pump(_DataCall from, _DataCall to) {
    final msgs = List<Map<String, dynamic>>.of(from.sent);
    from.sent.clear();
    for (final m in msgs) {
      to.incoming.add(m);
    }
  }

  test('định dạng chưa hỗ trợ: báo lỗi, không gửi lời mời', () async {
    runtime.pickResult = const PickedMedia(path: '/x/a.wma', name: 'a.wma', size: 100);
    expect(await host.startOffer(audio: true), 'WATCH_ERROR');
    expect(host.phase, WatchPhase.idle);
    expect(hostCall.sentTypes, isEmpty);
  });

  test('mời -> đồng ý -> cả hai ở watching; chủ phát và gửi trạng thái', () async {
    expect(await host.startOffer(), isNull);
    expect(host.phase, WatchPhase.offering);
    expect(hostCall.sentTypes, ['watch.offer']);
    expect(hostCall.sent.single['mime'], 'video/mp4');

    pump(hostCall, call);
    expect(viewer.phase, WatchPhase.incoming);
    expect(viewer.offer?.name, 'phim.mp4');

    await viewer.accept();
    expect(viewer.phase, WatchPhase.watching);
    expect(call.sentTypes, ['watch.accept']);

    pump(call, hostCall);
    await _settle();
    await _settle();
    expect(host.phase, WatchPhase.watching);
    expect(host.player, isNotNull);
    expect((host.player as _Player).playing, isTrue);
    expect(hostCall.sentTypes, contains('watch.state'));
  });

  test('từ chối -> chủ nhận WATCH_DECLINED và về idle', () async {
    final notices = <String>[];
    host.notices.listen(notices.add);
    await host.startOffer();
    pump(hostCall, call);
    viewer.decline();
    pump(call, hostCall);
    await _settle();
    expect(host.phase, WatchPhase.idle);
    expect(notices, ['WATCH_DECLINED']);
    expect(viewer.phase, WatchPhase.idle);
  });

  test('lời mời được gửi lại định kỳ; bên nhận bỏ qua bản trùng, không tự từ chối', () async {
    await host.startOffer();
    pump(hostCall, call);
    expect(viewer.phase, WatchPhase.incoming);
    call.sent.clear();
    timers.fire(WatchTogetherController.resendEvery);
    expect(hostCall.sentTypes, ['watch.offer']);
    pump(hostCall, call);
    expect(viewer.phase, WatchPhase.incoming);
    expect(call.sent, isEmpty); // không phản hồi decline cho bản gửi lại
    await viewer.accept();
    pump(call, hostCall);
    await _settle();
    timers.fire(WatchTogetherController.resendEvery);
    expect(hostCall.sent.where((m) => m['type'] == 'watch.offer'), isEmpty); // đã được nhận lời: dừng gửi lại
  });

  test('đang bận: offer thứ hai bị từ chối ngay', () async {
    await host.startOffer();
    pump(hostCall, call);
    call.incoming.add(<String, dynamic>{'type': 'watch.offer', 'id': 'w2', 'name': 'b.mp3', 'size': 10, 'mime': 'audio/mpeg'});
    expect(call.sent.last['type'], 'watch.decline');
    expect(call.sent.last['id'], 'w2');
    expect(viewer.offer?.id, 'w1');
  });

  test('chế độ riêng tư / kênh chưa mở: không mời được', () async {
    relay = true;
    expect(await host.startOffer(), 'WATCH_PRIVACY');
    relay = false;
    hostCall.open = false;
    expect(await host.startOffer(), 'WATCH_NO_CHANNEL');
    expect(host.phase, WatchPhase.idle);
    expect(hostCall.sent, isEmpty);
  });

  test('hết 60 giây không ai trả lời -> hủy và báo WATCH_NO_ANSWER', () async {
    final notices = <String>[];
    host.notices.listen(notices.add);
    await host.startOffer();
    timers.fire(WatchTogetherController.offerTimeout);
    await _settle();
    expect(host.phase, WatchPhase.idle);
    expect(notices, ['WATCH_NO_ANSWER']);
    expect(hostCall.sentTypes.last, 'watch.stop');
  });

  test('đồng bộ: trạng thái từ chủ làm người xem phát và nhảy tới đúng vị trí; không phát lại trạng thái (không vọng)', () async {
    await host.startOffer();
    pump(hostCall, call);
    await viewer.accept();
    call.sent.clear();

    call.incoming.add(<String, dynamic>{'type': 'watch.state', 'id': 'w1', 'playing': true, 'pos': 90000});
    await _settle();
    await _settle();
    final p = viewer.player as _Player;
    expect(p.playing, isTrue);
    expect(p.positionMs, 90000);
    expect(call.sent.where((m) => m['type'] == 'watch.state'), isEmpty);

    // Lệch nhỏ: không nhảy.
    p.log.clear();
    call.incoming.add(<String, dynamic>{'type': 'watch.state', 'id': 'w1', 'playing': true, 'pos': 90300});
    await _settle();
    expect(p.log.where((l) => l.startsWith('seek')), isEmpty);

    call.incoming.add(<String, dynamic>{'type': 'watch.state', 'id': 'w1', 'playing': false, 'pos': 90300});
    await _settle();
    expect(p.playing, isFalse);
  });

  test('người xem bấm tạm dừng -> gửi watch.state; id lạ bị bỏ qua', () async {
    await host.startOffer();
    pump(hostCall, call);
    await viewer.accept();
    call.sent.clear();
    await viewer.togglePlay();
    expect(call.sent.single['type'], 'watch.state');
    expect(call.sent.single['playing'], true);

    call.incoming.add(<String, dynamic>{'type': 'watch.state', 'id': 'khac', 'playing': false, 'pos': 0});
    await _settle();
    expect((viewer.player as _Player).playing, isTrue);
  });

  test('một bên dừng -> bên kia nhận WATCH_STOPPED_BY_PEER, dọn trình phát', () async {
    final notices = <String>[];
    viewer.notices.listen(notices.add);
    await host.startOffer();
    pump(hostCall, call);
    await viewer.accept();
    pump(call, hostCall);
    await _settle();
    await _settle();

    host.stop();
    pump(hostCall, call);
    await _settle();
    expect(viewer.phase, WatchPhase.idle);
    expect(notices, ['WATCH_STOPPED_BY_PEER']);
    expect(runtime.closed, greaterThanOrEqualTo(1));
  });

  test('đổi/mất phòng gọi -> dọn phiên, không gửi gì', () async {
    await host.startOffer();
    hostCall.sent.clear();
    room.leave();
    await _settle();
    expect(host.phase, WatchPhase.idle);
    expect(hostCall.sent, isEmpty);
  });

  test('viewer mở proxy lỗi -> báo WATCH_ERROR và gửi stop', () async {
    runtime.failViewer = true;
    final notices = <String>[];
    viewer.notices.listen(notices.add);
    await host.startOffer();
    pump(hostCall, call);
    await viewer.accept();
    await _settle();
    expect(viewer.phase, WatchPhase.idle);
    expect(notices, ['WATCH_ERROR']);
    expect(call.sentTypes, contains('watch.stop'));
  });

  test('offer sai dạng bị bỏ qua', () async {
    for (final bad in [
      {'type': 'watch.offer', 'id': 'a', 'name': 'x', 'size': -1, 'mime': 'video/mp4'},
      {'type': 'watch.offer', 'id': 'a', 'name': 'x', 'size': 5, 'mime': 'application/zip'},
      {'type': 'watch.offer', 'name': 'x', 'size': 5, 'mime': 'video/mp4'},
    ]) {
      call.incoming.add(bad);
    }
    expect(viewer.phase, WatchPhase.idle);
  });
}
