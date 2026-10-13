import 'package:flutter/material.dart';

/// Token thiết kế – DESIGN.md §2. Đây là nơi DUY NHẤT được viết `Color(0x...)`.
abstract final class AppColors {
  static const bg = Color(0xFF0B0B0F);
  static const surface = Color(0xFF16161D);
  static const surfaceHigh = Color(0xFF1F1F29);
  static const outline = Color(0xFF2A2A35);
  static const primary = Color(0xFFFF4D73);
  static const onPrimary = Color(0xFF0B0B0F);
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFFA1A1AA);
  static const danger = Color(0xFFFF453A);

  /// `#0B0B0F` @ 45% alpha (0.45 * 255 = 114.75 → 0x73).
  static const scrim = Color(0x730B0B0F);

  /// Đầu trong suốt của dải gradient scrim (cùng màu, alpha 0).
  static const scrimClear = Color(0x000B0B0F);

  /// Hồng nhạt dùng cho viền/nền nhấn (primary @ 14%).
  static const primarySoft = Color(0x24FF4D73);

  /// Quầng sáng thương hiệu sau logo (primary @ 28%).
  static const primaryGlow = Color(0x47FF4D73);

  /// Nền thẻ nổi hơn `surface` một chút, dùng cho bong bóng chat của người kia.
  static const bubbleOther = Color(0xFF1B1B24);

  /// Thành công (online, đã xác minh).
  static const success = Color(0xFF30D158);

  /// Nút Apple (DESIGN.md S1: nền đen #000, viền outline, chữ trắng).
  static const appleButton = Color(0xFF000000);
}

abstract final class AppText {
  static const fontFamily = 'BeVietnamPro';

  static const display = TextStyle(
    fontFamily: fontFamily,
    fontSize: 32,
    height: 40 / 32,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const title = TextStyle(
    fontFamily: fontFamily,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );
  static const label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 20 / 15,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );
  static const caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
  );
}

abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadius {
  /// Nút chính (viên thuốc).
  static const double pill = 999;

  /// Sheet (góc trên).
  static const double sheet = 20;

  /// Ô nhập, thẻ, khung camera nhỏ.
  static const double card = 12;
}

/// Kích thước cố định khác trong DESIGN.md.
abstract final class AppSize {
  static const double buttonHeight = 52;
  static const double edgeButton = 44;
  static const double minTouch = 48;
  static const double navBarHeight = 64;
  static const double settingsRow = 56;
  static const double reasonRow = 52;
  static const double selfViewWidth = 96;
  static const double selfViewHeight = 128;
  static const double topScrimHeight = 96;
  static const double searchRing = 96;

  /// Hàng danh bạ / người đã chặn.
  static const double contactRow = 64;

  /// Nút tròn lớn của màn cuộc gọi đến/đi.
  static const double roundButton = 64;

  /// Chấm trạng thái online.
  static const double statusDot = 8;

  /// Bàn cờ caro: 3 x 72.
  static const double boardCell = 72;
  static const double boardSize = 216;

  /// Thẻ quà rơi.
  static const double giftCardWidth = 160;
  static const double giftCardHeight = 96;
}

abstract final class AppGradients {
  /// Hồng đậm -> hồng sáng, dùng cho nút nhấn chính và huy hiệu.
  static const brand = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFF6A8A), Color(0xFFFF3F6C)],
  );

  /// Quầng sáng tròn sau logo ở màn đăng nhập.
  static const glow = RadialGradient(
    colors: [AppColors.primaryGlow, AppColors.scrimClear],
    stops: [0, 1],
  );
}

abstract final class AppShadows {
  static const soft = [
    BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
  ];
}
