import 'package:shared_preferences/shared_preferences.dart';

import 'chat_store.dart';
import 'secure_vault.dart';

/// Xóa sạch dữ liệu của app trên máy. Thứ tự quan trọng: HỦY KHÓA MÃ HÓA TRƯỚC (từ đó dữ liệu còn sót
/// cũng không đọc được), rồi mới xóa tệp, tùy chọn, và cuối cùng đăng xuất.
class AppWiper {
  AppWiper({required this.vault, required this.store, this.signOut, this.extra});

  final SecureVault vault;
  final ChatStore store;
  final Future<void> Function()? signOut;
  final Future<void> Function()? extra;

  Future<void> wipe() async {
    Future<void> safe(Future<void> Function() f) async {
      try {
        await f();
      } on Object {
        // một bước lỗi không được chặn các bước sau
      }
    }

    await safe(() => vault.delete('db_key'));
    await safe(() => vault.deleteAll());
    await safe(store.clearAll);
    await safe(() async => (await SharedPreferences.getInstance()).clear());
    if (extra != null) await safe(extra!);
    if (signOut != null) await safe(signOut!);
  }
}
