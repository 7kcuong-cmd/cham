import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/chat_message.dart';
import 'chat_store.dart';

/// Nơi cất bản sao lưu (đã mã hóa). Cài đặt Google Drive (thư mục ẩn của app) gắn vào đây sau.
abstract class BackupSink {
  Future<void> upload(Uint8List blob);
  Future<Uint8List?> download();
}

class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => 'BackupException: $message';
}

/// Sao lưu/khôi phục lịch sử chat + khóa chat, mã hóa bằng MẬT KHẨU của người dùng
/// (PBKDF2-HMAC-SHA256 → AES-256-GCM). Quên mật khẩu = không khôi phục được; không ai khác giải mã được.
/// Định dạng: "CHAMBK1" ‖ iterations(4B) ‖ salt(16) ‖ nonce(12) ‖ bản mã ‖ mac(16).
class BackupService {
  BackupService({this.iterations = 210000});

  final int iterations;
  static const _magic = 'CHAMBK1';
  final AesGcm _aes = AesGcm.with256bits();

  Future<SecretKey> _key(String password, List<int> salt, int iters) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iters, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);

  Future<Uint8List> export(ChatStore store, String password) async {
    if (password.length < 8) throw BackupException('Mật khẩu tối thiểu 8 ký tự');
    final msgs = <Map<String, dynamic>>[];
    for (final p in await store.peers()) {
      for (final m in await store.load(p)) {
        msgs.add(m.toJson());
      }
    }
    final payload = jsonEncode(<String, dynamic>{'v': 1, 'seed': await store.readSecret(), 'messages': msgs});
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    final box = await _aes.encrypt(utf8.encode(payload), secretKey: await _key(password, salt, iterations));
    final head = utf8.encode(_magic);
    final it = ByteData(4)..setUint32(0, iterations);
    return Uint8List.fromList([...head, ...it.buffer.asUint8List(), ...salt, ...box.concatenation()]);
  }

  /// Trả số tin đã khôi phục. Sai mật khẩu/tệp hỏng -> [BackupException].
  Future<int> restore(ChatStore store, Uint8List blob, String password) async {
    final h = utf8.encode(_magic).length;
    if (blob.length < h + 4 + 16 + 12 + 16 || utf8.decode(blob.sublist(0, h), allowMalformed: true) != _magic) {
      throw BackupException('Không phải tệp sao lưu của Chạm');
    }
    final iters = ByteData.sublistView(blob, h, h + 4).getUint32(0);
    if (iters < 100000 || iters > 5000000) throw BackupException('Tệp sao lưu không hợp lệ');
    final salt = blob.sublist(h + 4, h + 20);
    final String clear;
    try {
      final box = SecretBox.fromConcatenation(blob.sublist(h + 20), nonceLength: 12, macLength: 16);
      clear = utf8.decode(await _aes.decrypt(box, secretKey: await _key(password, salt, iters)));
    } on Object {
      throw BackupException('Sai mật khẩu hoặc tệp bị hỏng');
    }
    final j = jsonDecode(clear);
    if (j is! Map || j['v'] != 1) throw BackupException('Phiên bản sao lưu không hỗ trợ');
    if (await store.readSecret() == null && j['seed'] is String) await store.writeSecret(j['seed'] as String);
    var n = 0;
    for (final raw in (j['messages'] as List? ?? const <Object?>[])) {
      final m = ChatMessage.tryParse(raw);
      if (m == null) continue;
      if (!await store.has(m.peerId, m.id)) {
        await store.save(m);
        n++;
      }
    }
    return n;
  }

  Future<void> backupTo(BackupSink sink, ChatStore store, String password) async =>
      sink.upload(await export(store, password));

  Future<int> restoreFrom(BackupSink sink, ChatStore store, String password) async {
    final blob = await sink.download();
    if (blob == null) throw BackupException('Chưa có bản sao lưu');
    return restore(store, blob, password);
  }
}
