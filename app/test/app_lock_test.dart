import 'package:flutter_test/flutter_test.dart';

import 'package:cham/services/app_lock_service.dart';
import 'package:cham/services/app_wiper.dart';
import 'package:cham/services/chat_store.dart';
import 'package:cham/services/secure_vault.dart';

void main() {
  late MemorySecureVault vault;
  late int wipes;
  late AppLockService svc;

  setUp(() {
    vault = MemorySecureVault();
    wipes = 0;
    svc = AppLockService(vault: vault, onWipe: () async => wipes++, iterations: 1000);
  });

  test('mặc định tắt: không khóa, không đếm', () async {
    expect(await svc.isEnabled, isFalse);
    expect((await svc.verify('123456')).status, UnlockStatus.notEnabled);
    expect(wipes, 0);
  });

  test('PIN không hợp lệ bị từ chối khi bật', () async {
    expect(() => svc.enable('12345'), throwsArgumentError);
    expect(() => svc.enable('abcdef'), throwsArgumentError);
  });

  test('đúng PIN mở được và đặt lại bộ đếm', () async {
    await svc.enable('135790');
    expect((await svc.verify('000000')).remaining, 2);
    expect((await svc.verify('135790')).status, UnlockStatus.ok);
    expect((await svc.verify('000000')).remaining, 2); // đã đặt lại
    expect(wipes, 0);
  });

  test('sai đủ 3 lần thì xóa sạch', () async {
    await svc.enable('135790');
    expect((await svc.verify('111111')).remaining, 2);
    expect((await svc.verify('222222')).remaining, 1);
    expect((await svc.verify('333333')).status, UnlockStatus.wiped);
    expect(wipes, 1);
  });

  test('số lần tùy chỉnh (5)', () async {
    await svc.enable('135790', maxAttempts: 5);
    for (var i = 0; i < 4; i++) {
      expect((await svc.verify('000000')).status, UnlockStatus.wrong);
    }
    expect((await svc.verify('000000')).status, UnlockStatus.wiped);
  });

  test('lần sai được ghi trước khi kiểm tra (tắt app giữa chừng vẫn tính)', () async {
    await svc.enable('135790');
    await svc.verify('000000');
    // mô phỏng mở lại app: đọc bộ đếm từ kho
    final again = AppLockService(vault: vault, onWipe: () async => wipes++, iterations: 1000);
    expect((await again.verify('000000')).remaining, 1);
  });

  test('tắt khóa phải đúng PIN; sai vẫn tính', () async {
    await svc.enable('135790');
    expect((await svc.disable('000000')).status, UnlockStatus.wrong);
    expect(await svc.isEnabled, isTrue);
    expect((await svc.disable('135790')).status, UnlockStatus.ok);
    expect(await svc.isEnabled, isFalse);
  });

  test('AppWiper xóa khóa mã hóa, kho tin, bí mật và đăng xuất', () async {
    final store = MemoryChatStore();
    await store.writeSecret('S');
    await vault.write('db_key', 'k');
    await vault.write('chat_seed', 's');
    var out = 0;
    await AppWiper(vault: vault, store: store, signOut: () async => out++).wipe();
    expect(await vault.read('db_key'), isNull);
    expect(await vault.read('chat_seed'), isNull);
    expect(await store.readSecret(), isNull);
    expect(out, 1);
  });
}
