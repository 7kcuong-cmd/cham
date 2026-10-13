import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_recorder.dart';

/// Bộ ghi màn hình thật qua plugin `cham_recorder` (Android MediaProjection / iOS ReplayKit).
/// Ghi hình + tiếng micro (xem ghi chú giới hạn trong RecorderService.kt). CHƯA THỬ TRÊN MÁY THẬT; bật bằng `--dart-define=NATIVE_RECORDER=true`.
class NativeScreenRecorder implements ScreenRecorder, ExternalStopSource {
  NativeScreenRecorder({MethodChannel? channel}) : _ch = channel ?? const MethodChannel('cham/recorder') {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'stopped') {
        final a = call.arguments;
        _stops.add(a is String ? a : null);
      }
    });
  }

  final MethodChannel _ch;
  final StreamController<String?> _stops = StreamController<String?>.broadcast();

  @override
  Stream<String?> get externalStops => _stops.stream;

  @override
  bool get supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  Future<bool> start() async {
    try {
      return (await _ch.invokeMethod<bool>('start', <String, dynamic>{'audio': true})) ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> stop() async {
    try {
      return await _ch.invokeMethod<String>('stop');
    } on PlatformException {
      return null;
    }
  }
}
