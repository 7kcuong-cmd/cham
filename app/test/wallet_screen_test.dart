import 'package:cham/l10n/app_localizations.dart';
import 'package:cham/models/api_error.dart';
import 'package:cham/models/wallet.dart';
import 'package:cham/models/ws_messages.dart';
import 'package:cham/screens/wallet_screen.dart';
import 'package:cham/state/wallet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';
import 'helpers/harness.dart';

final _now = DateTime.utc(2026, 10, 6, 9);

LedgerEntry _entry(int seq, int delta, String reason) => LedgerEntry(
      seq: seq,
      delta: delta,
      reason: reason,
      balanceAfter: 100,
      createdAt: DateTime.utc(2026, 10, 6, 8, seq),
    );

const _catalog = UnlockCatalogItem(feature: 'strict_language', cost: 50, durationDays: 7);

void main() {
  late FakeApiClient api;
  late FakeWsClient ws;
  late WalletController wallet;

  Widget app({Locale locale = const Locale('vi'), double textScale = 1.0}) => harness(
        wallet: wallet,
        locale: locale,
        textScale: textScale,
        home: WalletScreen(now: () => _now),
      );

  setUp(() {
    api = FakeApiClient();
    ws = FakeWsClient();
    wallet = WalletController(api: api, ws: ws, keyGenerator: () => 'key-0000001');
  });

  tearDown(() => wallet.dispose());

  testWidgets('hiện số dư của server, sổ cái và nhãn lý do', (tester) async {
    api.onGetWallet = () async => Wallet(balance: 120, updatedAt: _now);
    api.onGetLedger = ({int limit = 20, int? before}) async => LedgerPage(
          entries: [_entry(2, 5, 'gift'), _entry(1, -10, 'game_fee'), _entry(0, 3, 'zzz_new')],
          nextBefore: null,
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Điểm của tôi'), findsOneWidget);
    expect(find.text('120 điểm'), findsOneWidget);
    expect(find.text('Quà'), findsOneWidget);
    expect(find.text('+5'), findsOneWidget);
    expect(find.text('-10'), findsOneWidget);
    // Mã lạ (server mới hơn app) không làm vỡ màn hình.
    expect(find.text(ledgerReasonLabelFor(tester, 'zzz_new')), findsOneWidget);
  });

  testWidgets('sổ cái rỗng: hiện thông báo chưa có giao dịch', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Chưa có giao dịch điểm nào.'), findsOneWidget);
  });

  testWidgets('lỗi tải sổ cái: hiện lỗi và nút Thử lại', (tester) async {
    api.onGetLedger = ({int limit = 20, int? before}) async =>
        throw const ApiException(code: 'NETWORK');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Không có kết nối mạng.'), findsOneWidget);
    expect(find.text('Thử lại'), findsOneWidget);
  });

  testWidgets('mua mở khóa: gọi purchaseUnlock một lần, số dư theo server', (tester) async {
    api.onGetWallet = () async => Wallet(balance: 80, updatedAt: _now);
    api.onGetUnlocks = () async =>
        const UnlockStatus(catalog: <UnlockCatalogItem>[_catalog], active: <ActiveUnlock>[]);
    api.onPurchaseUnlock = (feature, key) async => UnlockPurchase(
          unlock: ActiveUnlock(feature: feature, expiresAt: _now.add(const Duration(days: 7))),
          balance: 30,
          created: true,
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Chỉ ghép cùng ngôn ngữ'), findsOneWidget);
    await tester.tap(find.text('Mở khóa · 50 điểm'));
    await tester.pumpAndSettle();

    expect(api.log.where((e) => e.startsWith('purchaseUnlock')), ['purchaseUnlock(strict_language, key-0000001)']);
    expect(find.text('30 điểm'), findsOneWidget);
    expect(find.text('Đã mở khóa.'), findsOneWidget);
  });

  testWidgets('mua thiếu điểm: báo lỗi, số dư không đổi', (tester) async {
    api.onGetWallet = () async => Wallet(balance: 10, updatedAt: _now);
    api.onGetUnlocks = () async =>
        const UnlockStatus(catalog: <UnlockCatalogItem>[_catalog], active: <ActiveUnlock>[]);
    api.onPurchaseUnlock = (feature, key) async =>
        throw const ApiException(code: 'INSUFFICIENT_POINTS');
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mở khóa · 50 điểm'));
    await tester.pumpAndSettle();

    expect(find.text('Bạn chưa đủ điểm.'), findsOneWidget);
    expect(find.text('10 điểm'), findsOneWidget);
  });

  testWidgets('mở khóa còn hạn: hiện "Đang bật đến"', (tester) async {
    api.onGetUnlocks = () async => UnlockStatus(
          catalog: const <UnlockCatalogItem>[_catalog],
          active: <ActiveUnlock>[
            ActiveUnlock(feature: 'strict_language', expiresAt: _now.add(const Duration(days: 3))),
          ],
        );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('Đang bật đến'), findsOneWidget);
  });

  testWidgets('wallet.updated từ WS đổi số dư hiển thị', (tester) async {
    api.onGetWallet = () async => Wallet(balance: 10, updatedAt: _now);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('10 điểm'), findsOneWidget);

    ws.emit(const WalletUpdated(15, 5, 'gift'));
    await tester.pumpAndSettle();
    expect(find.text('15 điểm'), findsOneWidget);
  });

  testWidgets('en, 320dp, chữ 1,3: không tràn', (tester) async {
    useNarrowSurface(tester);
    api.onGetWallet = () async => Wallet(balance: 1234567, updatedAt: _now);
    api.onGetUnlocks = () async =>
        const UnlockStatus(catalog: <UnlockCatalogItem>[_catalog], active: <ActiveUnlock>[]);
    api.onGetLedger = ({int limit = 20, int? before}) async => LedgerPage(
          entries: [_entry(1, 5, 'game_refund'), _entry(0, -5, 'heart_tx')],
          nextBefore: null,
        );
    await tester.pumpWidget(app(locale: const Locale('en'), textScale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('My points'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// Nhãn của mã lạ theo ngôn ngữ vi (khóa `pointsReasonOther`).
String ledgerReasonLabelFor(WidgetTester tester, String reason) {
  final context = tester.element(find.byType(WalletScreen));
  return ledgerReasonLabel(AppLocalizations.of(context), reason);
}
