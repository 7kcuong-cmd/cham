import 'dart:convert';

import 'package:cham/models/api_error.dart';
import 'package:cham/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fakes.dart';

const _userJson = <String, dynamic>{
  'id': 'Xk3vN0aQp1L7cWm2RtY8bA',
  'displayName': 'Minh',
  'birthYear': null,
  'language': 'vi',
  'status': 'active',
  'profileComplete': false,
  'createdAt': '2026-10-05T09:30:00.000Z',
};

http.Response _json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

void main() {
  late FakeAuthService auth;

  setUp(() {
    auth = FakeAuthService(signedIn: true, tokens: ['dev:alice']);
  });

  ApiClient clientFor(MockClientHandler handler) =>
      ApiClient(baseUrl: 'http://localhost:8080/', auth: auth, client: MockClient(handler));

  test('createSession gửi đúng body, không có header Authorization, và parse kết quả', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return _json({'user': _userJson, 'isNew': true}, 200);
    });

    final result = await api.createSession(language: 'vi');

    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'http://localhost:8080/v1/auth/session');
    expect(jsonDecode(seen.body), {'idToken': 'dev:alice', 'language': 'vi'});
    expect(seen.headers['content-type'], startsWith('application/json'));
    expect(seen.headers.containsKey('authorization'), isFalse);
    expect(result.isNew, isTrue);
    expect(result.user.profileComplete, isFalse);
    expect(result.user.birthYear, isNull);
    expect(result.user.displayName, 'Minh');
  });

  test('403 UNDERAGE → ApiException(UNDERAGE, 403)', () async {
    final api = clientFor((req) async => _json({
          'error': {'code': 'UNDERAGE', 'message': 'User must be at least 18'},
        }, 403));

    await expectLater(
      api.updateMe(birthYear: 2010),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'UNDERAGE')
          .having((e) => e.httpStatus, 'httpStatus', 403)),
    );
  });

  test('429 có details.retryAfterSec → retryAfterSec == 5', () async {
    final api = clientFor((req) async => _json({
          'error': {
            'code': 'RATE_LIMITED',
            'message': 'Too many requests',
            'details': {'retryAfterSec': 5},
          },
        }, 429));

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'RATE_LIMITED')
          .having((e) => e.retryAfterSec, 'retryAfterSec', 5)),
    );
  });

  test('401 lần đầu, 200 lần hai → thành công; getIdToken(forceRefresh: true) đúng 1 lần', () async {
    auth.tokens = ['old-token', 'new-token'];
    final seenAuth = <String?>[];
    var calls = 0;
    final api = clientFor((req) async {
      seenAuth.add(req.headers['authorization']);
      calls++;
      if (calls == 1) {
        return _json({
          'error': {'code': 'UNAUTHENTICATED', 'message': 'expired'},
        }, 401);
      }
      return _json({'user': _userJson}, 200);
    });

    final user = await api.getMe();

    expect(user.id, 'Xk3vN0aQp1L7cWm2RtY8bA');
    expect(calls, 2);
    expect(seenAuth, ['Bearer old-token', 'Bearer new-token']);
    expect(auth.tokenCalls.where((forced) => forced).length, 1);
  });

  test('401 hai lần liên tiếp → ném UNAUTHENTICATED, chỉ thử lại một lần', () async {
    var calls = 0;
    final api = clientFor((req) async {
      calls++;
      return _json({
        'error': {'code': 'UNAUTHENTICATED', 'message': 'bad'},
      }, 401);
    });

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED')),
    );
    expect(calls, 2);
  });

  test('body HTML với 500 → INTERNAL', () async {
    final api = clientFor((req) async => http.Response('<html>oops</html>', 500));

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiException>()
          .having((e) => e.code, 'code', 'INTERNAL')
          .having((e) => e.httpStatus, 'httpStatus', 500)),
    );
  });

  test('lỗi mạng → NETWORK', () async {
    final api = clientFor((req) async => throw http.ClientException('no route'));

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK')),
    );
  });

  test('chưa đăng nhập (token null) → UNAUTHENTICATED, không gọi mạng', () async {
    auth.signedIn = false;
    var calls = 0;
    final api = clientFor((req) async {
      calls++;
      return _json({'user': _userJson}, 200);
    });

    await expectLater(
      api.getMe(),
      throwsA(isA<ApiException>().having((e) => e.code, 'code', 'UNAUTHENTICATED')),
    );
    expect(calls, 0);
  });

  test('updateMe chỉ gửi các trường được đặt, kèm Bearer', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return _json({'user': _userJson}, 200);
    });

    await api.updateMe(birthYear: 1998, displayName: 'Minh');

    expect(seen.method, 'PUT');
    expect(seen.url.path, '/v1/me');
    expect(seen.headers['authorization'], 'Bearer dev:alice');
    expect(jsonDecode(seen.body), {'birthYear': 1998, 'displayName': 'Minh'});
  });

  test('block: POST /v1/blocks {userId}; 200 và 201 đều thành công', () async {
    final bodies = <Object?>[];
    var status = 201;
    final api = clientFor((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/blocks');
      bodies.add(jsonDecode(req.body));
      return _json({
        'block': {'userId': 'Q9pLm2vX0aB7cWn3RtY1kZ', 'createdAt': '2026-10-05T09:31:00.000Z'},
      }, status);
    });

    await api.block('Q9pLm2vX0aB7cWn3RtY1kZ');
    status = 200;
    await api.block('Q9pLm2vX0aB7cWn3RtY1kZ');

    expect(bodies, [
      {'userId': 'Q9pLm2vX0aB7cWn3RtY1kZ'},
      {'userId': 'Q9pLm2vX0aB7cWn3RtY1kZ'},
    ]);
  });

  test('report: gửi reason/roomName/note, bỏ note rỗng', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = clientFor((req) async {
      expect(req.url.path, '/v1/reports');
      bodies.add(jsonDecode(req.body) as Map<String, dynamic>);
      return _json({
        'report': {'id': '0b1f9a7e-2c3d-4e5f-8a9b-0c1d2e3f4a5b', 'createdAt': '2026-10-05T09:32:00.000Z'},
      }, 201);
    });

    await api.report(
      userId: 'Q9pLm2vX0aB7cWn3RtY1kZ',
      reason: 'spam',
      roomName: 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11',
      note: '  quảng cáo  ',
    );
    await api.report(userId: 'Q9pLm2vX0aB7cWn3RtY1kZ', reason: 'other', note: '   ');

    expect(bodies[0], {
      'userId': 'Q9pLm2vX0aB7cWn3RtY1kZ',
      'reason': 'spam',
      'roomName': 'r_3f0a3c1e-5b7d-4c2a-9a51-0f6f0b8f7c11',
      'note': 'quảng cáo',
    });
    expect(bodies[1], {'userId': 'Q9pLm2vX0aB7cWn3RtY1kZ', 'reason': 'other'});
  });
}
