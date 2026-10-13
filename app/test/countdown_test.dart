import 'package:cham/utils/countdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 9, 0, 0);

  test('trong [0, 120s] thì trả thời gian còn lại', () {
    expect(countdownRemaining(now.add(const Duration(seconds: 30)), now),
        const Duration(seconds: 30));
    expect(countdownRemaining(now, now), Duration.zero);
    expect(countdownRemaining(now.add(const Duration(seconds: 120)), now),
        const Duration(seconds: 120));
  });

  test('quá hạn hoặc xa hơn 120s (đồng hồ lệch) thì null', () {
    expect(countdownRemaining(now.subtract(const Duration(seconds: 1)), now), isNull);
    expect(countdownRemaining(now.add(const Duration(seconds: 121)), now), isNull);
    expect(countdownRemaining(now.add(const Duration(hours: 5)), now), isNull);
  });

  test('formatCountdown: m:ss, không âm', () {
    expect(formatCountdown(const Duration(seconds: 0)), '0:00');
    expect(formatCountdown(const Duration(seconds: 9)), '0:09');
    expect(formatCountdown(const Duration(seconds: 75)), '1:15');
    expect(formatCountdown(const Duration(seconds: 120)), '2:00');
    expect(formatCountdown(const Duration(seconds: -5)), '0:00');
  });
}
