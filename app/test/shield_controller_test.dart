import 'package:cham/security/shield_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime clock;
  late ShieldController s;
  setUp(() {
    clock = DateTime.utc(2026, 10, 10, 9);
    s = ShieldController(now: () => clock);
  });

  test('mặc định bật, chưa có Khiên', () {
    expect(s.enabled, isTrue);
    expect(s.shieldActive, isFalse);
    expect(s.pauseRemaining, Duration.zero);
  });

  test('một sự cố: chưa bật Khiên', () {
    expect(s.recordIncident(), isFalse);
    expect(s.shieldActive, isFalse);
    expect(s.pauseRemaining, Duration.zero);
  });

  test('hai sự cố trong 15 phút: bật Khiên 30 phút và tạm dừng 60 giây', () {
    s.recordIncident();
    clock = clock.add(const Duration(minutes: 5));
    expect(s.recordIncident(), isTrue);
    expect(s.shieldActive, isTrue);
    expect(s.pauseRemaining, ShieldController.pauseDuration);
    clock = clock.add(const Duration(seconds: 61));
    expect(s.pauseRemaining, Duration.zero);
    expect(s.shieldActive, isTrue);
    clock = clock.add(const Duration(minutes: 31));
    expect(s.shieldActive, isFalse);
  });

  test('hai sự cố cách nhau > 15 phút: không leo thang', () {
    s.recordIncident();
    clock = clock.add(const Duration(minutes: 16));
    expect(s.recordIncident(), isFalse);
    expect(s.shieldActive, isFalse);
  });

  test('tắt bảo vệ: không ghi nhận, không Khiên', () async {
    s.resetForTest();
    await s.setEnabled(false);
    expect(s.recordIncident(), isFalse);
    expect(s.shieldActive, isFalse);
    expect(s.pauseRemaining, Duration.zero);
  });
}
