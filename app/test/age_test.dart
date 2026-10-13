import 'package:cham/utils/age.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isAdult (API.md §0.4)', () {
    test('năm 2026: 2007 hợp lệ, 2008 bị chặn', () {
      expect(isAdult(2007, 2026), isTrue);
      expect(isAdult(2008, 2026), isFalse);
    });

    test('biên và giá trị cực đoan', () {
      expect(isAdult(1900, 2026), isTrue);
      expect(isAdult(2026, 2026), isFalse);
      expect(isAdult(2025, 2026), isFalse);
      expect(isAdult(2007, 2025), isFalse); // sang năm sau mới hợp lệ
      expect(isAdult(2007, 2026, minAge: 21), isFalse);
    });

    test('latestAdultBirthYear khớp isAdult', () {
      for (final now in [2026, 2030, 2100]) {
        final latest = latestAdultBirthYear(now);
        expect(isAdult(latest, now), isTrue);
        expect(isAdult(latest + 1, now), isFalse);
      }
      expect(latestAdultBirthYear(2026), 2007);
    });
  });

  test('isValidBirthYear: 1900..năm hiện tại', () {
    expect(isValidBirthYear(1899, 2026), isFalse);
    expect(isValidBirthYear(1900, 2026), isTrue);
    expect(isValidBirthYear(2026, 2026), isTrue);
    expect(isValidBirthYear(2027, 2026), isFalse);
  });

  test('birthYearChoices: năm hiện tại → năm hiện tại − 100, giảm dần', () {
    final years = birthYearChoices(2026);
    expect(years.first, 2026);
    expect(years.last, 1926);
    expect(years.length, 101);
    expect(years.toSet().length, years.length);
  });
}
