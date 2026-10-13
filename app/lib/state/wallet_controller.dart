import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/api_error.dart';
import '../models/wallet.dart';
import '../models/ws_messages.dart';
import '../services/api_client.dart';
import '../services/ws_client.dart';

/// Ví điểm – T-209 (API-GD2-4 §2.2, §3.3).
///
/// Client KHÔNG BAO GIỜ tự cộng/trừ số dư: [balance] chỉ nhận giá trị server gửi
/// (`wallet.updated`, `gift.claimed`, `GET /v1/wallet`, `POST /v1/unlocks`).
class WalletController extends ChangeNotifier {
  WalletController({
    required ApiClient api,
    required WsClient ws,
    String Function()? keyGenerator,
  })  : _api = api,
        _ws = ws,
        _newKey = keyGenerator ?? generateIdempotencyKey {
    _msgSub = _ws.messages.listen(_onMessage);
  }

  /// Trang sổ cái mỗi lần tải.
  static const ledgerPageSize = 20;

  /// Mã lỗi mà sau đó vẫn dùng lại cùng `idempotencyKey` khi thử lại (có thể server đã xử lý).
  static const _retrySameKeyCodes = <String>{'NETWORK', 'INTERNAL'};

  final ApiClient _api;
  final WsClient _ws;
  final String Function() _newKey;

  late final StreamSubscription<ServerMessage> _msgSub;

  int? _balance;
  bool _loadingBalance = false;
  int _wsVersion = 0;

  List<LedgerEntry> _ledger = const <LedgerEntry>[];
  int? _nextBefore;
  bool _ledgerLoading = false;
  bool _ledgerLoaded = false;
  String? _ledgerError;

  UnlockStatus? _unlocks;
  String? _unlocksError;

  /// `feature` → khóa đang dùng cho lần mua chưa có kết quả dứt khoát.
  final Map<String, String> _purchaseKeys = <String, String>{};
  String? _purchasing;

  bool _disposed = false;

  /// `null` cho tới khi biết số dư từ server.
  int? get balance => _balance;
  bool get loadingBalance => _loadingBalance;

  List<LedgerEntry> get ledger => _ledger;
  bool get ledgerLoading => _ledgerLoading;
  bool get ledgerLoaded => _ledgerLoaded;
  bool get ledgerHasMore => _nextBefore != null;
  String? get ledgerError => _ledgerError;

  UnlockStatus? get unlocks => _unlocks;
  String? get unlocksError => _unlocksError;

  /// `feature` đang mua (vô hiệu hóa nút).
  String? get purchasing => _purchasing;

  /// Khóa idempotency đang giữ cho [feature] (chỉ để test).
  @visibleForTesting
  String? pendingKeyFor(String feature) => _purchaseKeys[feature];

  // --- REST ------------------------------------------------------------------------

  /// Tải số dư. Lỗi (mạng, `FEATURE_DISABLED`) → giữ giá trị cũ, trả mã lỗi.
  Future<String?> refresh() async {
    if (_loadingBalance) return null;
    _loadingBalance = true;
    final versionAtStart = _wsVersion;
    _notify();
    try {
      final wallet = await _api.getWallet();
      // Nếu trong lúc chờ có `wallet.updated` thì nó mới hơn: không ghi đè.
      if (_wsVersion == versionAtStart) _balance = wallet.balance;
      return null;
    } on ApiException catch (e) {
      return e.code;
    } finally {
      _loadingBalance = false;
      _notify();
    }
  }

  /// Tải lại sổ cái từ đầu.
  Future<void> loadLedger() async {
    if (_ledgerLoading) return;
    _ledgerLoading = true;
    _ledgerError = null;
    _notify();
    try {
      final page = await _api.getLedger(limit: ledgerPageSize);
      _ledger = List<LedgerEntry>.unmodifiable(page.entries);
      _nextBefore = page.nextBefore;
      _ledgerLoaded = true;
    } on ApiException catch (e) {
      _ledgerError = e.code;
    } finally {
      _ledgerLoading = false;
      _notify();
    }
  }

  /// Tải trang kế (cuộn vô hạn). Không làm gì khi đã hết hoặc đang tải.
  Future<void> loadMoreLedger() async {
    final before = _nextBefore;
    if (before == null || _ledgerLoading) return;
    _ledgerLoading = true;
    _ledgerError = null;
    _notify();
    try {
      final page = await _api.getLedger(limit: ledgerPageSize, before: before);
      final known = _ledger.map((e) => e.seq).toSet();
      _ledger = List<LedgerEntry>.unmodifiable(
        <LedgerEntry>[..._ledger, ...page.entries.where((e) => !known.contains(e.seq))],
      );
      _nextBefore = page.nextBefore;
    } on ApiException catch (e) {
      _ledgerError = e.code;
    } finally {
      _ledgerLoading = false;
      _notify();
    }
  }

  Future<void> loadUnlocks() async {
    try {
      _unlocks = await _api.getUnlocks();
      _unlocksError = null;
    } on ApiException catch (e) {
      _unlocksError = e.code;
    }
    _notify();
  }

  /// Mua [feature]. Trả mã lỗi, hoặc `null` nếu thành công.
  ///
  /// `idempotencyKey` được tạo MỘT LẦN cho mỗi ý định mua và dùng lại khi thử lại sau lỗi mạng
  /// (không biết server đã trừ điểm hay chưa); chỉ bỏ khi có kết quả dứt khoát.
  Future<String?> purchase(String feature) async {
    if (_purchasing != null) return null;
    final key = _purchaseKeys.putIfAbsent(feature, _newKey);
    _purchasing = feature;
    _notify();
    try {
      final result = await _api.purchaseUnlock(feature, key);
      _purchaseKeys.remove(feature);
      _balance = result.balance;
      _wsVersion++;
      await _mergeUnlock(result.unlock);
      return null;
    } on ApiException catch (e) {
      if (!_retrySameKeyCodes.contains(e.code)) _purchaseKeys.remove(feature);
      return e.code;
    } finally {
      _purchasing = null;
      _notify();
    }
  }

  Future<void> _mergeUnlock(ActiveUnlock unlock) async {
    final current = _unlocks;
    if (current == null) {
      await loadUnlocks();
      return;
    }
    final active = <ActiveUnlock>[
      ...current.active.where((a) => a.feature != unlock.feature),
      unlock,
    ];
    _unlocks = UnlockStatus(catalog: current.catalog, active: active);
  }

  // --- WebSocket ---------------------------------------------------------------------

  void _onMessage(ServerMessage m) {
    switch (m) {
      case final WalletUpdated e:
        _setBalanceFromServer(e.balance);
      case final GiftClaimed e:
        _setBalanceFromServer(e.balance);
      default:
        break;
    }
  }

  void _setBalanceFromServer(int balance) {
    _wsVersion++;
    _balance = balance;
    _notify();
  }

  /// Đăng xuất: quên số dư của người trước.
  void reset() {
    _balance = null;
    _ledger = const <LedgerEntry>[];
    _nextBefore = null;
    _ledgerLoaded = false;
    _ledgerError = null;
    _unlocks = null;
    _unlocksError = null;
    _purchaseKeys.clear();
    _wsVersion++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _msgSub.cancel();
    super.dispose();
  }
}

const String _keyAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';

/// 22 ký tự ngẫu nhiên an toàn, khớp `^[A-Za-z0-9_-]{8,64}$` (API-GD2-4 §1).
String generateIdempotencyKey() {
  final rng = Random.secure();
  final buf = StringBuffer();
  for (var i = 0; i < 22; i++) {
    buf.write(_keyAlphabet[rng.nextInt(_keyAlphabet.length)]);
  }
  return buf.toString();
}
