# Dựng phần nền tảng của app Chạm lần đầu (Windows PowerShell 5.1+ hoặc PowerShell 7).
# Chạy:  powershell -ExecutionPolicy Bypass -File app\tool\bootstrap.ps1   (có thể thêm -NoDevCleartext, -SkipTests)
# Các bước: flutter create -> khôi phục tệp của dự án -> chèn quyền -> pub get -> gen-l10n -> dart fix -> analyze -> test.
# Cần: Flutter stable >= 3.38 (flutter doctor), Node >= 20 (đã có vì chạy backend; chỉ dùng để chèn quyền).
# Lưu ý: iOS chỉ build được trên macOS; ở Windows script vẫn sinh ios/ và chèn Info.plist, còn Podfile làm trên Mac.
param(
  [switch]$NoDevCleartext,
  [switch]$SkipTests
)

$ErrorActionPreference = 'Continue'
$AppDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $AppDir

$Failed = New-Object System.Collections.ArrayList
$Manual = New-Object System.Collections.ArrayList

function Say([string]$Text) { Write-Host ""; Write-Host "==> $Text" }

function Invoke-Step([string]$Label, [scriptblock]$Block) {
  Say $Label
  & $Block | Out-Host
  if ($LASTEXITCODE -ne 0) {
    [void]$Failed.Add($Label)
    Write-Host "!! THẤT BẠI: $Label" -ForegroundColor Red
    return $false
  }
  return $true
}

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Host "Không thấy lệnh 'flutter'. Cài Flutter stable >= 3.38 rồi chạy lại: https://docs.flutter.dev/get-started/install" -ForegroundColor Red
  exit 1
}
if (-not (Get-Command dart -ErrorAction SilentlyContinue)) {
  Write-Host "Không thấy lệnh 'dart' (đi kèm Flutter)." -ForegroundColor Red
  exit 1
}

Say "Phiên bản Flutter"
& flutter --version
$verLine = (& flutter --version 2>$null | Select-Object -First 1)
if ($verLine -match 'Flutter\s+(\d+)\.(\d+)') {
  $maj = [int]$Matches[1]; $min = [int]$Matches[2]
  if ($maj -lt 3 -or ($maj -eq 3 -and $min -lt 38)) {
    Write-Host "Flutter $maj.$min quá cũ: pubspec.yaml yêu cầu >= 3.38 (livekit_client 2.13). Chạy 'flutter upgrade'." -ForegroundColor Red
    exit 1
  }
}

$HaveNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
$ClearArg = @()
if ($NoDevCleartext) { $ClearArg = @('--no-dev-cleartext') }

# 1. Sao lưu các tệp của dự án mà `flutter create` có thể ghi đè.
$Backup = Join-Path ([System.IO.Path]::GetTempPath()) ("cham-bootstrap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Backup | Out-Null
$Protected = @('pubspec.yaml', 'analysis_options.yaml', 'l10n.yaml', '.gitignore', 'lib\main.dart')
foreach ($f in $Protected) {
  if (Test-Path -LiteralPath $f) {
    $dest = Join-Path $Backup $f
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    Copy-Item -LiteralPath $f -Destination $dest -Force
  }
}

[void](Invoke-Step 'flutter create (com.kytuoi, android + ios)' { & flutter create --org com.kytuoi --project-name cham --platforms=android,ios . })

# 2. Khôi phục: tệp của dự án luôn thắng bản sinh tự động.
Say 'Khôi phục tệp của dự án nếu flutter create đã đổi'
foreach ($f in $Protected) {
  $b = Join-Path $Backup $f
  if (Test-Path -LiteralPath $b) {
    $same = (Test-Path -LiteralPath $f) -and ((Get-FileHash -LiteralPath $b).Hash -eq (Get-FileHash -LiteralPath $f).Hash)
    if (-not $same) { Copy-Item -LiteralPath $b -Destination $f -Force; Write-Host "đã khôi phục $f" }
  }
}
Remove-Item -LiteralPath 'test\widget_test.dart' -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue

# 3. Chèn quyền.
function Invoke-Patch([string]$PatchStep, [string]$ManualNote) {
  if (-not $HaveNode) {
    Write-Host "Không có Node: bỏ qua chèn tự động ($PatchStep). Làm tay theo tasks\02-code\APP-CHAY-THU.md mục 2-3." -ForegroundColor Yellow
    [void]$Manual.Add($ManualNote)
    return
  }
  & node tool/patch-platforms.mjs --app-dir . --step $PatchStep @ClearArg
  if ($LASTEXITCODE -ne 0) { [void]$Manual.Add($ManualNote) }
}
Say 'Chèn quyền camera/micro/internet (Android)'
Invoke-Patch 'android' 'Android: quyền/minSdk - xem APP-CHAY-THU.md mục 2'
Say 'Chèn quyền (iOS Info.plist)'
Invoke-Patch 'ios-plist' 'iOS Info.plist - xem APP-CHAY-THU.md mục 3.1/3.3'

# 4. Gói + l10n.
[void](Invoke-Step 'flutter pub get' { & flutter pub get })
[void](Invoke-Step 'flutter gen-l10n' { & flutter gen-l10n })

if (Test-Path -LiteralPath 'ios\Podfile') {
  Say 'Chèn cấu hình Podfile (iOS)'
  Invoke-Patch 'ios-podfile' 'iOS Podfile - xem APP-CHAY-THU.md mục 3.2'
} else {
  [void]$Manual.Add('iOS Podfile: chưa có (chỉ sinh trên macOS). Trên Mac chạy: node tool/patch-platforms.mjs --step ios-podfile')
}

# 5. Sửa lint tự động, phân tích, test.
[void](Invoke-Step 'dart fix --apply' { & dart fix --apply })
[void](Invoke-Step 'flutter analyze' { & flutter analyze })
if (-not $SkipTests) {
  [void](Invoke-Step 'flutter test' { & flutter test })
  if ($HaveNode) { [void](Invoke-Step 'node --test (kiểm tra bộ chèn quyền)' { & node --test tool/patch-platforms.test.mjs }) }
}

Say 'TỔNG KẾT'
if ($Manual.Count -gt 0) { Write-Host 'Việc cần làm tay:'; foreach ($m in $Manual) { Write-Host "  - $m" } }
if ($Failed.Count -gt 0) {
  Write-Host 'Bước thất bại:'; foreach ($m in $Failed) { Write-Host "  - $m" }
  Write-Host "Gửi nguyên văn lỗi ở trên cho Developer. Đừng 'sửa cho qua' bằng cách tắt lint hoặc bỏ test."
  exit 1
}
Write-Host 'Xong. Tiếp theo: cấu hình Firebase nếu cần (APP-CHAY-THU.md mục 5), rồi chạy thử 2 máy (T-013).'
if ($Manual.Count -gt 0) { exit 2 }
exit 0
