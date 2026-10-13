/// Quy tắc 18+ – API.md §0.4 (bản sao phía app; server là bên quyết định).
const int kMinAge = 18;

/// `isAdult(birthYear, now) = (yearUTC(now) - birthYear - 1) >= MIN_AGE`.
/// Chỉ có năm sinh nên lấy trường hợp xấu nhất (sinh nhật cuối năm chưa tới).
bool isAdult(int birthYear, int nowYear, {int minAge = kMinAge}) {
  return (nowYear - birthYear - 1) >= minAge;
}

/// Năm sinh hợp lệ về mặt dữ liệu: `1900 <= birthYear <= nowYear`.
bool isValidBirthYear(int birthYear, int nowYear) {
  return birthYear >= 1900 && birthYear <= nowYear;
}

/// Năm sinh lớn nhất còn đủ tuổi (ví dụ 2026 → 2007).
int latestAdultBirthYear(int nowYear, {int minAge = kMinAge}) {
  return nowYear - minAge - 1;
}

/// Các năm cho bánh xe chọn: năm hiện tại → năm hiện tại − 100 (giảm dần).
/// Cố ý gồm cả năm chưa đủ tuổi: người dùng khai thật thì server mới chặn
/// (DESIGN.md S2 → S2b).
List<int> birthYearChoices(int nowYear, {int span = 100}) {
  return <int>[for (var i = 0; i <= span; i++) nowYear - i];
}
