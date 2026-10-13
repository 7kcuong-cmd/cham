import 'dart:convert';

import 'package:cham/models/api_error.dart';
import 'package:cham/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/fakes.dart';

http.Response _json(Object body, int status) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _noBody() => http.Response('', 204);

void main() {
  late FakeAuthService auth;

  setUp(() {
    auth = FakeAuthService(signedIn: true, tokens: ['dev:alice']);
  });

  ApiClient clientFor(MockClientHandler handler) =>
      ApiClient(baseUrl: 'http://localhost:8080', auth: auth, client: MockClient(handler));

  group('GĐ2: danh bạ, chặn, push token', () {
    test('getContacts: GET /v1/contacts có Bearer, bỏ phần tử sai dạng', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _json({
          'contacts': [
            {
              'id': 'Q9pLm2vX0aB7cWn3RtY1kZ',
              'displayName': 'Anna',
              'language': 'en',
              'online': false,
              'addedAt': '2026-10-06T09:30:00.000Z',
            },
            {'id': 'thieu-truong'},
          ],
        }, 200);
      });
      final list = await api.getContacts();
      expect(seen.method, 'GET');
      expect(seen.url.path, '/v1/contacts');
      expect(seen.headers['authorization'], 'Bearer dev:alice');
      expect(list, hasLength(1));
      expect(list.single.displayName, 'Anna');
      expect(list.single.addedAt, DateTime.utc(2026, 10, 6, 9, 30));
    });

    test('204 không body (removeContact) không ném', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _noBody();
      });
      await api.removeContact('Q9pLm2vX0aB7cWn3RtY1kZ');
      expect(seen.method, 'DELETE');
      expect(seen.url.path, '/v1/contacts/Q9pLm2vX0aB7cWn3RtY1kZ');
    });

    test('unblock: DELETE /v1/blocks/:userId, 204', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _noBody();
      });
      await api.unblock('Q9pLm2vX0aB7cWn3RtY1kZ');
      expect(seen.method, 'DELETE');
      expect(seen.url.path, '/v1/blocks/Q9pLm2vX0aB7cWn3RtY1kZ');
    });

    test('getBlocks parse userId/displayName/createdAt', () async {
      final api = clientFor((req) async => _json({
            'blocks': [
              {'userId': 'abc', 'displayName': 'Anna', 'createdAt': '2026-10-05T09:31:00.000Z'},
            ],
          }, 200));
      final blocks = await api.getBlocks();
      expect(blocks.single.userId, 'abc');
      expect(blocks.single.createdAt, DateTime.utc(2026, 10, 5, 9, 31));
    });

    test('setPushToken: PUT /v1/me/push-token với {token, platform}, 204', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _noBody();
      });
      await api.setPushToken('fcm-token', 'android');
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/v1/me/push-token');
      expect(jsonDecode(seen.body), {'token': 'fcm-token', 'platform': 'android'});
    });

    test('deletePushToken: DELETE kèm body {token}', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _noBody();
      });
      await api.deletePushToken('fcm-token');
      expect(seen.method, 'DELETE');
      expect(seen.url.path, '/v1/me/push-token');
      expect(jsonDecode(seen.body), {'token': 'fcm-token'});
    });

    test('lỗi CONTACT_LIMIT / CONTACT_NOT_FOUND ra ApiException.code', () async {
      final api = clientFor((req) async => _json({
            'error': {'code': 'CONTACT_LIMIT', 'message': 'full'},
          }, 409));
      await expectLater(
        api.getContacts(),
        throwsA(isA<ApiException>()
            .having((e) => e.code, 'code', 'CONTACT_LIMIT')
            .having((e) => e.httpStatus, 'httpStatus', 409)),
      );
    });

    test('mất mạng → NETWORK', () async {
      final api = clientFor((req) async => throw http.ClientException('boom'));
      await expectLater(
        api.getContacts(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'NETWORK')),
      );
    });

    test('phản hồi thiếu khóa contacts → INTERNAL (không ném lỗi lạ)', () async {
      final api = clientFor((req) async => _json({'x': 1}, 200));
      await expectLater(
        api.getContacts(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'INTERNAL')),
      );
    });

    test('401 → làm mới token rồi thử lại một lần', () async {
      auth.tokens = ['old', 'fresh'];
      final seen = <String?>[];
      final api = clientFor((req) async {
        seen.add(req.headers['authorization']);
        if (seen.length == 1) {
          return _json({'error': {'code': 'UNAUTHENTICATED', 'message': 'x'}}, 401);
        }
        return _json({'contacts': <Object>[]}, 200);
      });
      expect(await api.getContacts(), isEmpty);
      expect(seen, ['Bearer old', 'Bearer fresh']);
    });
  });

  group('GĐ3: ví, sổ cái, mở khóa', () {
    test('getWallet', () async {
      final api = clientFor((req) async => _json({
            'wallet': {'balance': 140, 'updatedAt': '2026-10-06T09:30:00.000Z'},
          }, 200));
      final w = await api.getWallet();
      expect(w.balance, 140);
      expect(w.updatedAt, DateTime.utc(2026, 10, 6, 9, 30));
    });

    test('getWallet chưa có dòng nào: updatedAt null', () async {
      final api = clientFor((req) async => _json({
            'wallet': {'balance': 0, 'updatedAt': null},
          }, 200));
      final w = await api.getWallet();
      expect(w.balance, 0);
      expect(w.updatedAt, isNull);
    });

    test('getLedger: query limit/before, nextBefore', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _json({
          'entries': [
            {
              'seq': 12,
              'delta': 15,
              'reason': 'gift',
              'balanceAfter': 140,
              'createdAt': '2026-10-06T09:30:00.000Z',
            },
          ],
          'nextBefore': 12,
        }, 200);
      });
      final page = await api.getLedger(limit: 20, before: 13);
      expect(seen.url.path, '/v1/wallet/ledger');
      expect(seen.url.queryParameters, {'limit': '20', 'before': '13'});
      expect(page.entries.single.seq, 12);
      expect(page.entries.single.balanceAfter, 140);
      expect(page.nextBefore, 12);
    });

    test('getLedger trang cuối: nextBefore null; không gửi before khi null', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _json({'entries': <Object>[], 'nextBefore': null}, 200);
      });
      final page = await api.getLedger();
      expect(seen.url.queryParameters, {'limit': '20'});
      expect(page.nextBefore, isNull);
    });

    test('getUnlocks', () async {
      final api = clientFor((req) async => _json({
            'catalog': [
              {'feature': 'strict_language', 'cost': 100, 'durationDays': 7},
            ],
            'active': [
              {'feature': 'strict_language', 'expiresAt': '2026-10-13T09:30:00.000Z'},
            ],
          }, 200));
      final u = await api.getUnlocks();
      expect(u.catalog.single.cost, 100);
      expect(u.catalog.single.durationDays, 7);
      expect(
        u.activeUntil('strict_language', DateTime.utc(2026, 10, 6)),
        DateTime.utc(2026, 10, 13, 9, 30),
      );
      expect(u.activeUntil('strict_language', DateTime.utc(2026, 10, 14)), isNull);
    });

    test('purchaseUnlock 201 → created=true; gửi đúng body', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _json({
          'unlock': {'feature': 'strict_language', 'expiresAt': '2026-10-13T09:30:00.000Z'},
          'balance': 40,
        }, 201);
      });
      final r = await api.purchaseUnlock('strict_language', 'k7f3c1e5b7d4c2a9a510f6f0b8f7c11');
      expect(seen.method, 'POST');
      expect(seen.url.path, '/v1/unlocks');
      expect(jsonDecode(seen.body), {
        'feature': 'strict_language',
        'idempotencyKey': 'k7f3c1e5b7d4c2a9a510f6f0b8f7c11',
      });
      expect(r.created, isTrue);
      expect(r.balance, 40);
      expect(r.unlock.expiresAt, DateTime.utc(2026, 10, 13, 9, 30));
    });

    test('purchaseUnlock 200 (lần lặp) → created=false', () async {
      final api = clientFor((req) async => _json({
            'unlock': {'feature': 'strict_language', 'expiresAt': '2026-10-13T09:30:00.000Z'},
            'balance': 40,
          }, 200));
      expect((await api.purchaseUnlock('strict_language', 'k7f3c1e5b7d4c2a9a510f6f0b8f7c11')).created, isFalse);
    });

    test('purchaseUnlock 409 INSUFFICIENT_POINTS / IDEMPOTENCY_CONFLICT', () async {
      for (final code in ['INSUFFICIENT_POINTS', 'IDEMPOTENCY_CONFLICT']) {
        final api = clientFor((req) async => _json({'error': {'code': code, 'message': 'x'}}, 409));
        await expectLater(
          api.purchaseUnlock('strict_language', 'k7f3c1e5b7d4c2a9a510f6f0b8f7c11'),
          throwsA(isA<ApiException>().having((e) => e.code, 'code', code)),
        );
      }
    });
  });

  group('GĐ4: trò chơi', () {
    test('getGames', () async {
      final api = clientFor((req) async => _json({
            'games': [
              {'type': 'tictactoe', 'entryFee': 0, 'winPoints': 10, 'drawPoints': 3, 'turnSeconds': 15},
            ],
          }, 200));
      final games = await api.getGames();
      expect(games.single.type, 'tictactoe');
      expect(games.single.winPoints, 10);
      expect(games.single.turnSeconds, 15);
    });

    test('getGameHistory: before là ISO UTC, nextBefore parse', () async {
      late http.Request seen;
      final api = clientFor((req) async {
        seen = req;
        return _json({
          'results': [
            {
              'gameId': '6c1e1d3a-8f0b-4c55-9e43-1f4f7f0a2b11',
              'gameType': 'tictactoe',
              'outcome': 'win',
              'reason': 'win',
              'reward': 10,
              'opponent': {'id': 'Q9pLm2vX0aB7cWn3RtY1kZ', 'displayName': 'Anna'},
              'endedAt': '2026-10-06T09:35:00.000Z',
            },
          ],
          'nextBefore': '2026-10-06T09:35:00.000Z',
        }, 200);
      });
      final page = await api.getGameHistory(limit: 20, before: DateTime.utc(2026, 10, 6, 9, 40));
      expect(seen.url.path, '/v1/games/history');
      expect(seen.url.queryParameters['limit'], '20');
      expect(seen.url.queryParameters['before'], '2026-10-06T09:40:00.000Z');
      expect(page.results.single.outcome, 'win');
      expect(page.results.single.opponentName, 'Anna');
      expect(page.results.single.reward, 10);
      expect(page.nextBefore, DateTime.utc(2026, 10, 6, 9, 35));
    });

    test('getGameHistory hết trang: nextBefore null', () async {
      final api = clientFor((req) async => _json({'results': <Object>[], 'nextBefore': null}, 200));
      final page = await api.getGameHistory();
      expect(page.results, isEmpty);
      expect(page.nextBefore, isNull);
    });

    test('403 FEATURE_DISABLED', () async {
      final api = clientFor((req) async => _json({'error': {'code': 'FEATURE_DISABLED', 'message': 'x'}}, 403));
      await expectLater(
        api.getGames(),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'FEATURE_DISABLED')),
      );
    });
  });
}
