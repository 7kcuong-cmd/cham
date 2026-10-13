import 'dart:async';

import 'package:cham/models/wallet.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/state/wallet_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

LedgerEntry _entry(int seq, {int delta = 5, String reason = 'gift'}) => LedgerEntry(
      seq: seq,
      delta: delta,
      reason: reason,
      balanceAfter: 100 + seq,
      createdAt: DateTime.utc(2026, 10, 6, 9, seq % 60),
    );

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late int keyCounter;
  late WalletController c;

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    keyCounter = 0;
    c = WalletController(
      api: api,
      ws: ws,
      keyGenerator: () => 'key-${(++keyCounter).toString().padLeft(6, '0')}',
    );
  });

  tearDown(() => c.dispose());

  test('chưa biết số dư → null; refresh lấy từ server', () async {
    expect(c.balance, isNull);
    api.onGetWallet = () async => Wallet(balance: 140, updatedAt: DateTime.utc(2026, 10, 6));
    expect(await c.refresh(), isNull);
    expect(c.balance, 140);
  });

  test('refresh lỗi: giữ số dư cũ, trả mã lỗi', () async {
    api.onGetWallet = () async => const Wallet(balance: 10, updatedAt: null);
    await c.refresh();
    api.onGetWallet = () async => throw apiError('FEATURE_DISABLED', status: 403);
    expect(await c.refresh(), 'FEATURE_DISABLED');
    expect(c.balance, 10);
  });

  test('wallet.updated và gift.claimed chỉ GHI NHẬN số dư server gửi', () async {
    ws.emit(const WalletUpdated(152, 12, 'gift'));
    await _settle();
    expect(c.balance, 152);
    ws.emit(const GiftClaimed('g', 5, 157));
    await _settle();
    expect(c.balance, 157);
    // Số dư không phải 152 + 5: client không tự cộng.
    ws.emit(const WalletUpdated(1000, 1, 'heart_rx'));
    await _settle();
    expect(c.balance, 1000);
  });

  test('wallet.updated tới trong lúc GET /v1/wallet đang chờ → không bị bản cũ ghi đè', () async {
    final pending = Completer<Wallet>();
    api.onGetWallet = () => pending.future;
    final future = c.refresh();
    ws.emit(const WalletUpdated(200, 10, 'gift'));
    await _settle();
    pending.complete(const Wallet(balance: 190, updatedAt: null)); // bản cũ hơn
    await future;
    expect(c.balance, 200);
  });

  group('sổ cái', () {
    test('loadLedger + loadMoreLedger theo nextBefore, không trùng seq', () async {
      api.onGetLedger = ({int limit = 20, int? before}) async {
        if (before == null) {
          return LedgerPage(entries: [_entry(12), _entry(11)], nextBefore: 11);
        }
        expect(before, 11);
        return LedgerPage(entries: [_entry(11), _entry(10)], nextBefore: null);
      };
      await c.loadLedger();
      expect(c.ledger.map((e) => e.seq), [12, 11]);
      expect(c.ledgerHasMore, isTrue);

      await c.loadMoreLedger();
      expect(c.ledger.map((e) => e.seq), [12, 11, 10]);
      expect(c.ledgerHasMore, isFalse);

      await c.loadMoreLedger(); // hết rồi: không gọi API nữa
      expect(api.log.where((e) => e.startsWith('getLedger')), hasLength(2));
    });

    test('lỗi tải ghi vào ledgerError', () async {
      api.onGetLedger = ({int limit = 20, int? before}) async => throw apiError('NETWORK');
      await c.loadLedger();
      expect(c.ledgerError, 'NETWORK');
      expect(c.ledgerLoaded, isFalse);
    });
  });

  group('mở khóa', () {
    UnlockPurchase purchaseResult({int balance = 40, bool created = true}) => UnlockPurchase(
          unlock: ActiveUnlock(feature: 'strict_language', expiresAt: DateTime.utc(2026, 10, 13)),
          balance: balance,
          created: created,
        );

    test('mua thành công: số dư lấy từ server, danh sách active được cập nhật', () async {
      api.onGetUnlocks = () async => const UnlockStatus(
            catalog: [UnlockCatalogItem(feature: 'strict_language', cost: 100, durationDays: 7)],
            active: [],
          );
      await c.loadUnlocks();
      api.onPurchaseUnlock = (feature, key) async => purchaseResult(balance: 40);

      expect(await c.purchase('strict_language'), isNull);
      expect(c.balance, 40);
      final until = c.unlocks!.activeUntil('strict_language', DateTime.utc(2026, 10, 6));
      expect(until, DateTime.utc(2026, 10, 13));
      expect(c.purchasing, isNull);
    });

    test('mua lại sau lỗi mạng dùng CÙNG idempotencyKey; sau thành công đổi khóa mới', () async {
      final keys = <String>[];
      var fail = true;
      api.onPurchaseUnlock = (feature, key) async {
        keys.add(key);
        if (fail) throw apiError('NETWORK');
        return purchaseResult();
      };

      expect(await c.purchase('strict_language'), 'NETWORK');
      expect(await c.purchase('strict_language'), 'NETWORK');
      fail = false;
      expect(await c.purchase('strict_language'), isNull);
      expect(keys, ['key-000001', 'key-000001', 'key-000001']);

      // Lần bấm mua mới (ý định mới) → khóa mới.
      expect(await c.purchase('strict_language'), isNull);
      expect(keys.last, 'key-000002');
    });

    test('lỗi dứt khoát (INSUFFICIENT_POINTS) → lần mua sau là ý định mới, khóa mới', () async {
      final keys = <String>[];
      api.onPurchaseUnlock = (feature, key) async {
        keys.add(key);
        throw apiError('INSUFFICIENT_POINTS', status: 409);
      };
      expect(await c.purchase('strict_language'), 'INSUFFICIENT_POINTS');
      expect(await c.purchase('strict_language'), 'INSUFFICIENT_POINTS');
      expect(keys, ['key-000001', 'key-000002']);
    });

    test('đang mua thì bỏ qua lần bấm thứ hai (không gửi hai yêu cầu)', () async {
      final gate = Completer<UnlockPurchase>();
      var calls = 0;
      api.onPurchaseUnlock = (feature, key) {
        calls++;
        return gate.future;
      };
      final first = c.purchase('strict_language');
      expect(c.purchasing, 'strict_language');
      expect(await c.purchase('strict_language'), isNull);
      expect(calls, 1);
      gate.complete(purchaseResult());
      await first;
      expect(c.purchasing, isNull);
    });
  });

  test('reset quên số dư, sổ cái và khóa mua dở', () async {
    api.onGetWallet = () async => const Wallet(balance: 5, updatedAt: null);
    await c.refresh();
    api.onPurchaseUnlock = (feature, key) async => throw apiError('NETWORK');
    await c.purchase('strict_language');
    expect(c.pendingKeyFor('strict_language'), isNotNull);

    c.reset();
    expect(c.balance, isNull);
    expect(c.ledger, isEmpty);
    expect(c.pendingKeyFor('strict_language'), isNull);
  });

  test('generateIdempotencyKey khớp ^[A-Za-z0-9_-]{8,64}\$ và không lặp', () {
    final re = RegExp(r'^[A-Za-z0-9_-]{8,64}$');
    final keys = <String>{for (var i = 0; i < 50; i++) generateIdempotencyKey()};
    expect(keys, hasLength(50));
    expect(keys.every(re.hasMatch), isTrue);
  });
}
