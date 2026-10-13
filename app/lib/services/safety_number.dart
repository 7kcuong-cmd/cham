import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// "Mã so khớp an toàn": 60 chữ số (12 nhóm × 5) tính từ HAI khóa công khai chat. Hai người đọc cho nhau
/// (hoặc so trên hai màn hình); trùng nhau nghĩa là server không thay khóa ở giữa. Đối xứng: A–B = B–A.
Future<String> safetyNumber(String keyAB64, String keyBB64) async {
  final a = base64.decode(keyAB64);
  final b = base64.decode(keyBB64);
  final ordered = _less(a, b) ? [...a, ...b] : [...b, ...a];
  var digest = (await Sha256().hash([...utf8.encode('cham-safety-v1'), ...ordered])).bytes;
  // Làm chậm dò ngược một chút (không cần mạnh: đây không phải mật khẩu).
  for (var i = 0; i < 1000; i++) {
    digest = (await Sha256().hash([...digest, ...ordered])).bytes;
  }
  final wide = (await Sha512().hash([...digest, ...ordered])).bytes;
  final groups = <String>[];
  for (var i = 0; i < 12; i++) {
    final n = (wide[i * 5] << 32) | (wide[i * 5 + 1] << 24) | (wide[i * 5 + 2] << 16) | (wide[i * 5 + 3] << 8) | wide[i * 5 + 4];
    groups.add((n % 100000).toString().padLeft(5, '0'));
  }
  return groups.join(' ');
}

bool _less(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] < b[i];
  }
  return a.length <= b.length;
}
