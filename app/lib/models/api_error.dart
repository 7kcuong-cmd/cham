/// Lỗi từ REST (API.md §0.5) hoặc lỗi cục bộ.
///
/// `code` thuộc bảng API.md §0.6, cộng hai mã cục bộ: `NETWORK` (mất mạng/timeout)
/// và `AUTH_FAILED` (đăng nhập Firebase thất bại). App hiển thị chuỗi dịch theo
/// `code` (xem `errorText`), không bao giờ hiển thị `message` của server.
class ApiException implements Exception {
  const ApiException({required this.code, this.httpStatus, this.retryAfterSec});

  final String code;
  final int? httpStatus;
  final int? retryAfterSec;

  @override
  String toString() =>
      'ApiException(code: $code, httpStatus: $httpStatus, retryAfterSec: $retryAfterSec)';
}
