import 'package:cham/models/api_error.dart';
import 'package:cham/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryDevUidStore implements DevUidStore {
  MemoryDevUidStore([this.value]);

  String? value;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read() async {
    if (failReads) throw StateError('read failed');
    return value;
  }

  @override
  Future<void> write(String? uid) async {
    if (failWrites) throw StateError('write failed');
    value = uid;
  }
}

void main() {
  test('chưa lưu gì → chưa đăng nhập, token null', () async {
    final auth = DevAuthService(store: MemoryDevUidStore());
    await auth.init();
    expect(auth.isSignedIn, isFalse);
    expect(await auth.getIdToken(), isNull);
  });

  test('signInDev lưu uid; app mở lại (đối tượng mới, cùng kho) vẫn đăng nhập', () async {
    final store = MemoryDevUidStore();
    final first = DevAuthService(store: store);
    await first.init();
    await first.signInDev('alice');
    expect(await first.getIdToken(), 'dev:alice');
    expect(store.value, 'alice');

    final second = DevAuthService(store: store);
    await second.init();
    expect(second.isSignedIn, isTrue);
    expect(await second.getIdToken(), 'dev:alice');
  });

  test('signOut xóa uid đã lưu', () async {
    final store = MemoryDevUidStore('alice');
    final auth = DevAuthService(store: store);
    await auth.init();
    expect(auth.isSignedIn, isTrue);
    await auth.signOut();
    expect(auth.isSignedIn, isFalse);
    expect(store.value, isNull);

    final again = DevAuthService(store: store);
    await again.init();
    expect(again.isSignedIn, isFalse);
  });

  test('uid không hợp lệ bị từ chối và không được lưu', () async {
    final store = MemoryDevUidStore();
    final auth = DevAuthService(store: store);
    await expectLater(auth.signInDev('a b'), throwsA(isA<ApiException>()));
    await expectLater(auth.signInDev(''), throwsA(isA<ApiException>()));
    expect(store.value, isNull);
    expect(auth.isSignedIn, isFalse);
  });

  test('giá trị lưu hỏng bị bỏ qua; lỗi đọc/ghi kho không làm hỏng phiên', () async {
    final bad = DevAuthService(store: MemoryDevUidStore('bad uid!'));
    await bad.init();
    expect(bad.isSignedIn, isFalse);

    final store = MemoryDevUidStore()
      ..failReads = true
      ..failWrites = true;
    final auth = DevAuthService(store: store);
    await auth.init();
    expect(auth.isSignedIn, isFalse);
    await auth.signInDev('bob');
    expect(auth.isSignedIn, isTrue);
    expect(await auth.getIdToken(), 'dev:bob');
    await auth.signOut();
    expect(auth.isSignedIn, isFalse);
  });
}
