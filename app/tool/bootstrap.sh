#!/usr/bin/env bash
# Dựng phần nền tảng của app Chạm lần đầu (Android + iOS). Chạy từ bất kỳ đâu: bash app/tool/bootstrap.sh
# Các bước: flutter create -> khôi phục tệp của dự án -> chèn quyền -> pub get -> gen-l10n -> dart fix -> analyze -> test.
# Cần: Flutter stable >= 3.38 (flutter doctor), Node >= 20 (đã có vì chạy backend; chỉ dùng để chèn quyền).
# Tùy chọn: --no-dev-cleartext (build phát hành: không cho phép http/ws rõ), --skip-tests.
set -u

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$APP_DIR" || exit 1

DEV_CLEARTEXT=()
SKIP_TESTS=0
for a in "$@"; do
  case "$a" in
    --no-dev-cleartext) DEV_CLEARTEXT=(--no-dev-cleartext) ;;
    --skip-tests) SKIP_TESTS=1 ;;
    *) echo "Tham số lạ: $a" >&2; exit 64 ;;
  esac
done

FAILED=()
MANUAL=()
say() { printf '\n==> %s\n' "$*"; }
step() { # step "mô tả" lệnh...   (lỗi thì ghi nhận và đi tiếp)
  local label="$1"; shift
  say "$label"
  if ! "$@"; then FAILED+=("$label"); echo "!! THẤT BẠI: $label" >&2; return 1; fi
}

if ! command -v flutter >/dev/null 2>&1; then
  echo "Không thấy lệnh 'flutter'. Cài Flutter stable >= 3.38 rồi chạy lại: https://docs.flutter.dev/get-started/install" >&2
  exit 1
fi
if ! command -v dart >/dev/null 2>&1; then echo "Không thấy lệnh 'dart' (đi kèm Flutter)." >&2; exit 1; fi

say "Phiên bản Flutter"
flutter --version
VER_LINE="$(flutter --version 2>/dev/null | head -n1)"
if [[ "$VER_LINE" =~ Flutter\ ([0-9]+)\.([0-9]+) ]]; then
  if (( BASH_REMATCH[1] < 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] < 38) )); then
    echo "Flutter ${BASH_REMATCH[1]}.${BASH_REMATCH[2]} quá cũ: pubspec.yaml yêu cầu >= 3.38 (livekit_client 2.13). Chạy 'flutter upgrade'." >&2
    exit 1
  fi
fi

HAVE_NODE=1
command -v node >/dev/null 2>&1 || HAVE_NODE=0

# 1. Sao lưu các tệp của dự án mà `flutter create` có thể ghi đè.
BACKUP="$(mktemp -d)"
PROTECTED=(pubspec.yaml analysis_options.yaml l10n.yaml .gitignore lib/main.dart)
for f in "${PROTECTED[@]}"; do
  if [ -f "$f" ]; then mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"; fi
done

step "flutter create (com.kytuoi, android + ios)" flutter create --org com.kytuoi --project-name cham --platforms=android,ios .

# 2. Khôi phục: tệp của dự án luôn thắng bản sinh tự động.
say "Khôi phục tệp của dự án nếu flutter create đã đổi"
for f in "${PROTECTED[@]}"; do
  if [ -f "$BACKUP/$f" ] && ! cmp -s "$BACKUP/$f" "$f"; then
    cp "$BACKUP/$f" "$f"; echo "đã khôi phục $f"
  fi
done
rm -f test/widget_test.dart
rm -rf "$BACKUP"

# 3. Chèn quyền Android + iOS Info.plist.
patch_step() { # patch_step <bước>
  if (( HAVE_NODE == 0 )); then
    echo "Không có Node: bỏ qua chèn tự động ($1). Làm tay theo tasks/02-code/APP-CHAY-THU.md mục 2-3." >&2
    return 2
  fi
  node tool/patch-platforms.mjs --app-dir . --step "$1" ${DEV_CLEARTEXT[@]+"${DEV_CLEARTEXT[@]}"}
}
say "Chèn quyền camera/micro/internet (Android)"
patch_step android; rc=$?; (( rc != 0 )) && MANUAL+=("Android: quyền/minSdk - xem APP-CHAY-THU.md mục 2")
say "Chèn quyền (iOS Info.plist)"
patch_step ios-plist; rc=$?; (( rc != 0 )) && MANUAL+=("iOS Info.plist - xem APP-CHAY-THU.md mục 3.1/3.3")

# 4. Gói + l10n.
step "flutter pub get" flutter pub get
step "flutter gen-l10n" flutter gen-l10n

# Podfile chỉ có trên macOS sau pub get.
if [ -f ios/Podfile ]; then
  say "Chèn cấu hình Podfile (iOS)"
  patch_step ios-podfile; rc=$?; (( rc != 0 )) && MANUAL+=("iOS Podfile - xem APP-CHAY-THU.md mục 3.2")
else
  MANUAL+=("iOS Podfile: chưa có (chỉ sinh trên macOS). Trên Mac chạy lại: node tool/patch-platforms.mjs --step ios-podfile")
fi

# 5. Sửa lint tự động, phân tích, test.
step "dart fix --apply" dart fix --apply
step "flutter analyze" flutter analyze
if (( SKIP_TESTS == 0 )); then
  step "flutter test" flutter test
  if (( HAVE_NODE == 1 )); then step "node --test tool/ (kiểm tra bộ chèn quyền)" node --test tool/patch-platforms.test.mjs; fi
fi

say "TỔNG KẾT"
if (( ${#MANUAL[@]} > 0 )); then
  echo "Việc cần làm tay:"; for m in "${MANUAL[@]}"; do echo "  - $m"; done
fi
if (( ${#FAILED[@]} > 0 )); then
  echo "Bước thất bại:"; for m in "${FAILED[@]}"; do echo "  - $m"; done
  echo "Gửi nguyên văn lỗi ở trên cho Developer. Đừng 'sửa cho qua' bằng cách tắt lint hoặc bỏ test."
  exit 1
fi
echo "Xong. Tiếp theo: cấu hình Firebase nếu cần (APP-CHAY-THU.md mục 5), rồi chạy thử 2 máy (T-013)."
(( ${#MANUAL[@]} > 0 )) && exit 2
exit 0
