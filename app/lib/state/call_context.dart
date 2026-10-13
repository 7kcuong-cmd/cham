import 'package:flutter/foundation.dart';

import '../models/match_found.dart';

/// Phòng gọi hiện tại – `SwipeController` triển khai. Các controller GĐ3–4 chỉ cần biết
/// "đang ở phòng nào, với ai" và được báo khi nó đổi, nên không phụ thuộc cả `SwipeController`
/// (test dùng bản giả).
abstract interface class RoomSource implements Listenable {
  /// `null` khi không có cuộc gọi.
  String? get roomName;

  /// Đối phương trong phòng hiện tại; `null` khi không có cuộc gọi.
  Peer? get peer;
}

/// Phần của `SwipeController` mà `InviteController` cần (API-GD2-4 §3.2: cuộc gọi lại bạn dùng
/// lại `match.found` y hệt cuộc gọi ngẫu nhiên).
abstract interface class InvitedCallHost {
  /// Đang kết nối hoặc đang trong một cuộc gọi (khi đó server coi là `busy`).
  bool get inCallOrConnecting;

  /// "`match.found` sắp tới là cuộc gọi lại bạn bè": `SwipeController` nhận cuộc gọi đó dù
  /// đang không ở tab Lướt.
  void expectInvitedCall();

  /// Lời mời không thành cuộc gọi (từ chối, hết giờ, lỗi…): thôi chờ.
  void clearInvitedCall();
}
