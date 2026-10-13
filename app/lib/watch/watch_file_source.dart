import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'watch_host.dart';

/// Đọc byte từ tệp trên máy. Các lần đọc được xếp hàng vì chỉ có một con trỏ tệp.
class FileByteSource implements ByteSource {
  FileByteSource._(this._file, this.length);

  final RandomAccessFile _file;

  @override
  final int length;

  Future<void> _lock = Future<void>.value();

  static Future<FileByteSource> open(String path) async {
    final raf = await File(path).open();
    return FileByteSource._(raf, await raf.length());
  }

  @override
  Future<Uint8List> read(int start, int len) {
    final next = _lock.then((_) async {
      await _file.setPosition(start);
      return _file.read(len);
    });
    _lock = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<void> close() async {
    await _lock;
    await _file.close();
  }
}
