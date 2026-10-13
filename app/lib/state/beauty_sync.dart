import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/beauty.dart';
import '../services/call_service.dart';

/// Gửi mức làm đẹp của mình cho đối phương (DataChannel `cham`, tin `{type:'beauty', level}`) và nhận mức của họ để
/// vẽ hiệu ứng lên hình của họ trên máy mình. Chỉ ảnh hưởng hiển thị; giá trị nhận được luôn bị chặn trong 0..100.
class BeautySync {
  BeautySync(this._call, {Duration every = const Duration(seconds: 5)}) {
    _sub = _call.dataMessages.listen(_onData);
    BeautySettings.instance.addListener(send);
    _timer = Timer.periodic(every, (_) => send());
  }

  final CallService _call;
  late final StreamSubscription<Map<String, dynamic>> _sub;
  Timer? _timer;

  /// Mức làm đẹp đối phương đang dùng.
  final ValueNotifier<int> peerLevel = ValueNotifier<int>(0);

  void send() {
    _call.sendData(<String, dynamic>{'type': 'beauty', 'level': BeautySettings.instance.level});
  }

  /// Sang cuộc gọi mới: quên mức của người cũ và báo mức của mình cho người mới.
  void reset() {
    peerLevel.value = 0;
    send();
  }

  void _onData(Map<String, dynamic> m) {
    if (m['type'] != 'beauty') return;
    final l = m['level'];
    if (l is num) peerLevel.value = l.round().clamp(0, 100).toInt();
  }

  void dispose() {
    _timer?.cancel();
    _sub.cancel();
    BeautySettings.instance.removeListener(send);
    peerLevel.dispose();
  }
}
