import 'package:flutter_test/flutter_test.dart';

import 'package:cham/models/chat_message.dart';
import 'package:cham/services/backup_service.dart';
import 'package:cham/services/chat_store.dart';

void main() {
  ChatMessage msg(String id, {String peer = 'p1'}) => ChatMessage(
      id: id, peerId: peer, mine: true, text: 'xin chào $id', at: DateTime.utc(2026, 10, 9), status: ChatStatus.sent);

  test('sao lưu rồi khôi phục sang máy mới', () async {
    final a = MemoryChatStore();
    await a.writeSecret('SEED');
    await a.save(msg('1'));
    await a.save(msg('2', peer: 'p2'));
    final svc = BackupService(iterations: 100000);
    final blob = await svc.export(a, 'matkhau-dai');
    final b = MemoryChatStore();
    expect(await svc.restore(b, blob, 'matkhau-dai'), 2);
    expect(await b.readSecret(), 'SEED');
    expect((await b.load('p1')).single.text, 'xin chào 1');
    expect(await svc.restore(b, blob, 'matkhau-dai'), 0); // không trùng lặp
  });

  test('sai mật khẩu bị từ chối', () async {
    final a = MemoryChatStore()..save(msg('1'));
    final svc = BackupService(iterations: 100000);
    final blob = await svc.export(a, 'matkhau-dai');
    expect(() => svc.restore(MemoryChatStore(), blob, 'sai-mat-khau'), throwsA(isA<BackupException>()));
  });

  test('mật khẩu quá ngắn', () async {
    expect(() => BackupService().export(MemoryChatStore(), '123'), throwsA(isA<BackupException>()));
  });
}
