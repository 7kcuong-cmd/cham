/// Tiện ích đọc JSON dùng chung cho các model GĐ2–4. Không bao giờ ném.

/// Số nguyên từ JSON. Chấp nhận `5.0` (một số bộ giải mã trả double) nhưng không `5.5`.
int? jsonInt(Object? v) {
  if (v is int) return v;
  if (v is num && v.isFinite && v == v.truncateToDouble()) return v.toInt();
  return null;
}

/// Chuỗi ISO 8601 → [DateTime]; sai dạng/không phải chuỗi → `null`.
DateTime? jsonDate(Object? v) => v is String ? DateTime.tryParse(v) : null;
