import 'dart:async';

import 'package:cham/models/api_error.dart';
import 'package:cham/services/push_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

class FakePort implements PushMessagingPort {
  bool permission = true;
  bool permissionThrows = false;
  String? token = 'fcm-token-1';
  bool tokenThrows = false;
  Map<String, String>? initial;
  final StreamController<String> refresh = StreamController<String>.broadcast();
  final StreamController<Map<String, String>> opened =
      StreamController<Map<String, String>>.broadcast();

  @override
  Future<bool> requestPermission() async {
    if (permissionThrows) throw StateError('perm');
    return permission;
  }

  @override
  Future<String?> getToken() async {
    if (tokenThrows) throw StateError('apns');
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  @override
  Stream<Map<String, String>> get onOpened => opened.stream;

  @override
  Future<Map<String, String>?> getInitialOpened() async => initial;
}

void main() {
  late FakeApiClient api;
  late FakePort port;
  late FirebasePushService push;

  setUp(() {
    api = FakeApiClient();
    port = FakePort();
    push = FirebasePushService(api: api, port: port, platform: () => 'android');
  });

  tearDown(() => push.dispose());

  test('start: xin quyền rồi đăng ký token lên server', () async {
    await push.start();
    expect(push.notificationsEnabled.value, isTrue);
    expect(api.log, contains('setPushToken(fcm-token-1, android)'));
  });

  test('start là idempotent', () async {
    await push.start();
    await push.start();
    expect(api.log.where((e) => e.startsWith('setPushToken')), hasLength(1));
  });

  test('từ chối quyền: notificationsEnabled=false nhưng vẫn không ném', () async {
    port.permission = false;
    await push.start();
    expect(push.notificationsEnabled.value, isFalse);
  });

  test('requestPermission ném: bỏ qua, vẫn lấy token', () async {
    port.permissionThrows = true;
    await push.start();
    expect(api.log, contains('setPushToken(fcm-token-1, android)'));
  });

  test('getToken ném (iOS chưa có APNs): không đăng ký, token đến qua onTokenRefresh', () async {
    port.tokenThrows = true;
    await push.start();
    expect(api.log.where((e) => e.startsWith('setPushToken')), isEmpty);
    port.refresh.add('fcm-token-2');
    await _settle();
    expect(api.log, contains('setPushToken(fcm-token-2, android)'));
  });

  test('setPushToken lỗi API: không ném', () async {
    api.onSetPushToken = (t, p) async => throw const ApiException(code: 'NETWORK');
    await push.start();
    expect(push.notificationsEnabled.value, isTrue);
  });

  test('bấm thông báo call_invite khi app ở nền: phát inviteId', () async {
    final ids = <String>[];
    push.openedInviteIds.listen(ids.add);
    await push.start();
    port.opened.add(<String, String>{'kind': 'call_invite', 'inviteId': 'inv_1'});
    await _settle();
    expect(ids, <String>['inv_1']);
  });

  test('app mở từ trạng thái tắt bằng thông báo: phát inviteId', () async {
    port.initial = <String, String>{'kind': 'call_invite', 'inviteId': 'inv_2'};
    final ids = <String>[];
    push.openedInviteIds.listen(ids.add);
    await push.start();
    await _settle();
    expect(ids, <String>['inv_2']);
  });

  test('thông báo khác kind hoặc thiếu inviteId: bỏ qua', () async {
    final ids = <String>[];
    push.openedInviteIds.listen(ids.add);
    await push.start();
    port.opened.add(<String, String>{'kind': 'call_missed', 'inviteId': 'inv_3'});
    port.opened.add(<String, String>{'kind': 'call_invite'});
    port.opened.add(<String, String>{'kind': 'call_invite', 'inviteId': ''});
    await _settle();
    expect(ids, isEmpty);
  });

  test('unregister: DELETE token hiện tại; start lại được', () async {
    await push.start();
    await push.unregister();
    expect(api.log, contains('deletePushToken(fcm-token-1)'));
    await push.start();
    expect(api.log.where((e) => e.startsWith('setPushToken')), hasLength(2));
  });

  test('unregister: lỗi API không ném', () async {
    await push.start();
    api.onDeletePushToken = (t) async => throw const ApiException(code: 'NETWORK');
    await push.unregister();
  });

  test('NoopPushService không làm gì', () async {
    final noop = NoopPushService();
    await noop.start();
    await noop.unregister();
    expect(noop.notificationsEnabled.value, isTrue);
    await noop.dispose();
  });
}
