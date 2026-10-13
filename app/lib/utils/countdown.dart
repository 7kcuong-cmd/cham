/// Đếm ngược theo `expiresAt` của server (backlog "Quy ước chung GĐ2–4").
///
/// Trả thời gian còn lại nếu nằm trong [0, [maxCountdown]] (đồng hồ máy hợp lý), ngược lại
/// `null` – khi đó UI ẩn đếm ngược và KHÔNG tự hủy; server vẫn là nơi quyết định hết hạn.
Duration? countdownRemaining(DateTime expiresAt, DateTime now) {
  final remaining = expiresAt.difference(now);
  if (remaining.isNegative || remaining > maxCountdown) return null;
  return remaining;
}

const Duration maxCountdown = Duration(seconds: 120);

/// "m:ss" cho đếm ngược; không đổi theo ngôn ngữ (chỉ số và dấu hai chấm).
String formatCountdown(Duration d) {
  final total = d.isNegative ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
