import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cham/services/call_service.dart';
import 'package:cham/services/recording_privacy.dart';
import 'package:cham/services/screen_recorder.dart';
import 'package:cham/widgets/recording_layer.dart';
import 'package:cham/state/call_context.dart';
import 'package:cham/state/recording_controller.dart';
import 'package:cham/models/match_found.dart';

class _Call implements CallService {
  final StreamController<Map<String, dynamic>> in_ = StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool open = true;

  @override
  Stream<Map<String, dynamic>> get dataMessages => in_.stream;

  @override
  bool sendData(Map<String, dynamic> message) {
    if (!open) return false;
    sent.add(message);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room extends ChangeNotifier implements RoomSource {
  @override
  String? roomName = 'r1';

  @override
  Peer? get peer => null;

  void set(String? r) {
    roomName = r;
    notifyListeners();
  }
}

class _Rec implements ScreenRecorder {
  _Rec({this.ok = true, this.supported = true, this.gate});
  final bool ok;

  /// Nếu có: `start()` chờ tới khi gate hoàn tất (giả lập hộp thoại quyền chụp màn hình đang mở).
  final Completer<void>? gate;
  @override
  final bool supported;
  int starts = 0;
  int stops = 0;

  @override
  Future<bool> start() async {
    starts++;
    await gate?.future;
    return ok;
  }

  @override
  Future<String?> stop() async {
    stops++;
    return '/tmp/clip.mp4';
  }
}

class _ExtRec extends _Rec implements ExternalStopSource {
  final StreamController<String?> ext = StreamController<String?>.broadcast();
  @override
  Stream<String?> get externalStops => ext.stream;
}

void main() {
  late _Call call;
  late _Room room;
  late _Rec rec;
  late RecordingController c;
  late List<Timer> timers;
  late List<void Function()> fire;
  var id = 0;

  RecordingController make({_Rec? r}) {
    rec = r ?? _Rec();
    return RecordingController(
      call: call,
      room: room,
      recorder: rec,
      newId: () => 'id${++id}',
      timerFactory: (d, cb) {
        fire.add(cb);
        return Timer(const Duration(days: 1), () {});
      },
    );
  }

  setUp(() {
    call = _Call();
    room = _Room();
    timers = <Timer>[];
    fire = <void Function()>[];
    c = make();
  });
  tearDown(() => c.dispose());

  Future<void> peer(Map<String, dynamic> m) async {
    call.in_.add(m);
    await Future<void>.delayed(Duration.zero);
  }

  test('chỉ ghi sau khi bên kia rec.accept', () async {
    expect(c.request(RecPurpose.public), isTrue);
    expect(call.sent.single['t'], 'rec.request');
    expect(rec.starts, 0);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    await Future<void>.delayed(Duration.zero);
    expect(rec.starts, 1);
    expect(c.iAmRecording, isTrue);
  });

  test('làm mờ đối phương ngay khi bắt đầu gọi bộ ghi (trước khi start() trả về)', () async {
    final gate = Completer<void>();
    c.dispose();
    c = make(r: _Rec(gate: gate));
    c.request(RecPurpose.private);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    expect(rec.starts, 1);
    expect(c.isRecording, isFalse);
    expect(c.iAmRecording, isTrue); // đang chờ hộp thoại quyền: đã mờ
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(c.isRecording, isTrue);
    expect(c.iAmRecording, isTrue);
  });

  test('bị từ chối: không ghi, có thông báo', () async {
    c.request(RecPurpose.private);
    await peer({'t': 'rec.deny', 'recId': call.sent.single['recId']});
    expect(rec.starts, 0);
    expect(c.state, RecState.idle);
    expect(c.notice, 'rec_denied');
  });

  test('accept sai recId bị bỏ qua', () async {
    c.request(RecPurpose.private);
    await peer({'t': 'rec.accept', 'recId': 'khac'});
    expect(rec.starts, 0);
    expect(c.state, RecState.requesting);
  });

  test('quá hạn không trả lời -> hủy', () async {
    c.request(RecPurpose.private);
    fire.first();
    expect(c.state, RecState.idle);
    expect(c.notice, 'rec_timeout');
  });

  test('tối đa 2 yêu cầu mỗi cuộc gọi, đổi phòng thì tính lại', () async {
    for (var i = 0; i < 2; i++) {
      expect(c.request(RecPurpose.private), isTrue);
      await peer({'t': 'rec.deny', 'recId': call.sent.last['recId']});
    }
    expect(c.request(RecPurpose.private), isFalse);
    room.set('r2');
    expect(c.request(RecPurpose.private), isTrue);
  });

  test('bên được xin: đồng ý -> recording, không tự ghi; bên kia dừng -> kết thúc', () async {
    await peer({'t': 'rec.request', 'recId': 'x1', 'purpose': 'private'});
    expect(c.state, RecState.asking);
    c.respond(accept: true);
    expect(call.sent.last['t'], 'rec.accept');
    expect(c.isRecording, isTrue);
    expect(c.iAmRecording, isFalse);
    expect(rec.starts, 0);
    await peer({'t': 'rec.stop', 'recId': 'x1'});
    expect(c.state, RecState.idle);
    expect(c.notice, 'rec_ended');
  });

  test('bên được xin từ chối -> gửi rec.deny', () async {
    await peer({'t': 'rec.request', 'recId': 'x2', 'purpose': 'public'});
    c.respond(accept: false);
    expect(call.sent.last['t'], 'rec.deny');
    expect(c.state, RecState.idle);
  });

  test('đang bận thì tự từ chối yêu cầu thứ hai', () async {
    await peer({'t': 'rec.request', 'recId': 'a', 'purpose': 'private'});
    await peer({'t': 'rec.request', 'recId': 'b', 'purpose': 'private'});
    expect(call.sent.last, {'t': 'rec.deny', 'recId': 'b'});
  });

  test('chia sẻ công khai chỉ khi mục đích public', () async {
    c.request(RecPurpose.private);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    await Future<void>.delayed(Duration.zero);
    await c.stop();
    expect(c.lastClipPath, '/tmp/clip.mp4');
    expect(c.lastClipShareable, isFalse);
  });

  test('đổi phòng / mất kênh khi đang ghi -> dừng ngay', () async {
    c.request(RecPurpose.public);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    await Future<void>.delayed(Duration.zero);
    room.set(null);
    await Future<void>.delayed(Duration.zero);
    expect(c.state, RecState.idle);
    expect(rec.stops, 1);
  });

  test('người ghi bấm "Dừng" ở thông báo: dừng ngay, báo bên kia, giữ clip, không gọi stop() lần nữa', () async {
    final ext = _ExtRec();
    c.dispose();
    c = make(r: ext);
    c.request(RecPurpose.private);
    final reqId = call.sent.single['recId'];
    await peer({'t': 'rec.accept', 'recId': reqId});
    await Future<void>.delayed(Duration.zero);
    expect(c.iAmRecording, isTrue);

    ext.ext.add('/tmp/from_service.mp4');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(c.state, RecState.idle);
    expect(call.sent.last['t'], 'rec.stop');
    expect(ext.stops, 0);
    expect(c.lastClipPath, '/tmp/from_service.mp4');
  });

  testWidgets('RecordingBlur: chưa thấy mặt → làm mờ cả khung; tắt tùy chọn → không che; không ghi → không che', (tester) async {
    Widget host() => MultiProvider(
          providers: [
            ChangeNotifierProvider<RecordingController>.value(value: c),
            Provider<CallService>.value(value: call),
          ],
          child: const Directionality(textDirection: TextDirection.ltr, child: RecordingBlur(child: SizedBox(key: Key('v')))),
        );

    RecordingPrivacy.instance.debugSet(true);
    await tester.pumpWidget(host());
    expect(find.byType(ImageFiltered), findsNothing); // chưa ghi

    c.request(RecPurpose.private);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    await tester.pump();
    await tester.pump();
    expect(c.iAmRecording, isTrue);
    expect(find.byType(ImageFiltered), findsOneWidget); // không có mặt → che cả khung (an toàn khi lỗi)

    RecordingPrivacy.instance.debugSet(false);
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
    RecordingPrivacy.instance.debugSet(true);
    await tester.runAsync(() => c.stop());
    await tester.pumpWidget(const SizedBox());
  });

  test('máy không hỗ trợ ghi: không xin phép', () async {
    c.dispose();
    c = make(r: _Rec(supported: false));
    expect(c.request(RecPurpose.private), isFalse);
    expect(call.sent, isEmpty);
  });

  test('kênh dữ liệu chưa mở: không xin được', () async {
    call.open = false;
    expect(c.request(RecPurpose.private), isFalse);
    expect(c.notice, 'rec_failed');
  });

  test('bộ ghi lỗi: báo rec.stop cho bên kia', () async {
    c.dispose();
    c = make(r: _Rec(ok: false));
    c.request(RecPurpose.private);
    await peer({'t': 'rec.accept', 'recId': call.sent.single['recId']});
    await Future<void>.delayed(Duration.zero);
    expect(call.sent.last['t'], 'rec.stop');
    expect(c.state, RecState.idle);
  });
}
