import 'json_utils.dart';

/// `GET /v1/wallet` – API-GD2-4 §2.2. Số dư chỉ do server quyết định.
class Wallet {
  const Wallet({required this.balance, required this.updatedAt});

  final int balance;

  /// `null` khi chưa có dòng sổ cái nào.
  final DateTime? updatedAt;

  /// Phần tử `wallet` của phản hồi. Trả `null` nếu thiếu/sai kiểu.
  static Wallet? tryParse(Object? json) {
    if (json is! Map) return null;
    final balance = jsonInt(json['balance']);
    if (balance == null) return null;
    return Wallet(balance: balance, updatedAt: jsonDate(json['updatedAt']));
  }
}

/// `LedgerEntry` – API-GD2-4 §1.1.
class LedgerEntry {
  const LedgerEntry({
    required this.seq,
    required this.delta,
    required this.reason,
    required this.balanceAfter,
    required this.createdAt,
  });

  final int seq;
  final int delta;

  /// `gift` | `heart_rx` | `heart_tx` | `unlock` | `game_fee` | `game_refund` |
  /// `game_win` | `game_draw` | `admin_adjust` (giữ nguyên chuỗi để chịu giá trị mới).
  final String reason;
  final int balanceAfter;
  final DateTime createdAt;

  static LedgerEntry? tryParse(Object? json) {
    if (json is! Map) return null;
    final seq = jsonInt(json['seq']);
    final delta = jsonInt(json['delta']);
    final reason = json['reason'];
    final balanceAfter = jsonInt(json['balanceAfter']);
    final createdAt = jsonDate(json['createdAt']);
    if (seq == null || delta == null || reason is! String) return null;
    if (balanceAfter == null || createdAt == null) return null;
    return LedgerEntry(
      seq: seq,
      delta: delta,
      reason: reason,
      balanceAfter: balanceAfter,
      createdAt: createdAt,
    );
  }
}

/// Một trang của `GET /v1/wallet/ledger`.
class LedgerPage {
  const LedgerPage({required this.entries, required this.nextBefore});

  final List<LedgerEntry> entries;

  /// `seq` để truyền vào `before` của trang kế; `null` = hết.
  final int? nextBefore;
}

/// Một mục của `catalog` trong `GET /v1/unlocks`.
class UnlockCatalogItem {
  const UnlockCatalogItem({
    required this.feature,
    required this.cost,
    required this.durationDays,
  });

  final String feature;
  final int cost;
  final int durationDays;

  static UnlockCatalogItem? tryParse(Object? json) {
    if (json is! Map) return null;
    final feature = json['feature'];
    final cost = jsonInt(json['cost']);
    final days = jsonInt(json['durationDays']);
    if (feature is! String || cost == null || days == null) return null;
    return UnlockCatalogItem(feature: feature, cost: cost, durationDays: days);
  }
}

/// Một mục của `active` trong `GET /v1/unlocks` (và `unlock` trong `POST /v1/unlocks`).
class ActiveUnlock {
  const ActiveUnlock({required this.feature, required this.expiresAt});

  final String feature;
  final DateTime expiresAt;

  static ActiveUnlock? tryParse(Object? json) {
    if (json is! Map) return null;
    final feature = json['feature'];
    final expiresAt = jsonDate(json['expiresAt']);
    if (feature is! String || expiresAt == null) return null;
    return ActiveUnlock(feature: feature, expiresAt: expiresAt);
  }
}

/// Phản hồi `GET /v1/unlocks`.
class UnlockStatus {
  const UnlockStatus({required this.catalog, required this.active});

  final List<UnlockCatalogItem> catalog;
  final List<ActiveUnlock> active;

  /// Hạn của [feature] nếu còn hiệu lực tại [now].
  DateTime? activeUntil(String feature, DateTime now) {
    for (final a in active) {
      if (a.feature == feature && a.expiresAt.isAfter(now)) return a.expiresAt;
    }
    return null;
  }
}

/// Kết quả `POST /v1/unlocks`.
class UnlockPurchase {
  const UnlockPurchase({
    required this.unlock,
    required this.balance,
    required this.created,
  });

  final ActiveUnlock unlock;
  final int balance;

  /// `true` khi HTTP 201 (lần này thật sự trừ điểm); `false` khi 200 (lần lặp).
  final bool created;
}
