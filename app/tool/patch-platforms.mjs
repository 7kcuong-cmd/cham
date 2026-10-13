#!/usr/bin/env node
// Chèn quyền camera/micro/internet vào android/ và ios/ SAU `flutter create`.
// Chạy bởi tool/bootstrap.sh và tool/bootstrap.ps1. Idempotent (chạy lại không nhân đôi).
// Mỗi bước: nếu không tìm thấy chỗ chèn chắc chắn thì KHÔNG sửa gì, in hướng dẫn làm tay (exit code 2 cho cả script).
//
//   node tool/patch-platforms.mjs [--app-dir <thư mục app>] [--step android|ios-plist|ios-podfile|all] [--no-dev-cleartext]
//
// --no-dev-cleartext: không thêm cho phép HTTP/WS không mã hóa (chỉ dùng khi build phát hành).
import { readdirSync, readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ANDROID_PERMISSIONS = [
  "android.permission.INTERNET",
  "android.permission.CAMERA",
  "android.permission.RECORD_AUDIO",
  "android.permission.MODIFY_AUDIO_SETTINGS",
  "android.permission.ACCESS_NETWORK_STATE",
  "android.permission.CHANGE_NETWORK_STATE",
  "android.permission.BLUETOOTH_CONNECT",
  // GĐ2 (T-108): hiện thông báo cuộc gọi từ bạn bè trên Android 13+ (firebase_messaging có thể đã tự gộp;
  // khai báo thêm không hại, CẦN KIỂM TRA theo phiên bản plugin).
  "android.permission.POST_NOTIFICATIONS",
  // Khóa ứng dụng bằng vân tay/khuôn mặt (local_auth).
  "android.permission.USE_BIOMETRIC",
  // Cuộc gọi đến toàn màn hình trên màn hình khóa (FULLSCREEN_CALL).
  "android.permission.USE_FULL_SCREEN_INTENT",
  // Giữ màn hình sáng trong cuộc gọi (wakelock_plus).
  "android.permission.WAKE_LOCK",
  // Bộ chọn video/nhạc trong app (photo_manager): Android 13+ dùng READ_MEDIA_*, cũ hơn dùng READ_EXTERNAL_STORAGE.
  "android.permission.READ_MEDIA_VIDEO",
  "android.permission.READ_MEDIA_AUDIO",
];
const ANDROID_FEATURES = ["android.hardware.camera", "android.hardware.camera.autofocus"];

const MARKER = "cham-bootstrap";

/** @returns {{ text: string, changed: boolean, ok: boolean, note?: string }} */
export function patchMainManifest(xml) {
  const idx = xml.indexOf("<application");
  if (idx < 0) return { text: xml, changed: false, ok: false, note: "không thấy thẻ <application>" };
  const lineStart = xml.lastIndexOf("\n", idx) + 1;
  const indent = /^[ \t]*/.exec(xml.slice(lineStart, idx))[0];
  const lines = [];
  for (const f of ANDROID_FEATURES) {
    if (!xml.includes(`android:name="${f}"`)) lines.push(`<uses-feature android:name="${f}" android:required="false" />`);
  }
  for (const p of ANDROID_PERMISSIONS) {
    if (!xml.includes(`android:name="${p}"`)) lines.push(`<uses-permission android:name="${p}" />`);
  }
  // BLUETOOTH cũ chỉ cho Android <= 11.
  if (!xml.includes('android:name="android.permission.BLUETOOTH"')) {
    lines.push('<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />');
  }
  let text = xml;
  if (lines.length > 0) {
    const block = `${indent}<!-- ${MARKER}: quyền cho cuộc gọi video (LiveKit + permission_handler) -->\n` + lines.map((l) => `${indent}${l}\n`).join("");
    text = xml.slice(0, lineStart) + block + xml.slice(lineStart);
  }
  // Cho phép Activity hiện trên màn hình khóa và bật màn hình khi có cuộc gọi đến.
  if (!text.includes("android:showWhenLocked")) {
    text = text.replace(/<activity(\s)/, '<activity android:showWhenLocked="true" android:turnScreenOn="true"$1');
  }
  return { text, changed: text !== xml, ok: true };
}

/** local_auth cần Activity là FlutterFragmentActivity (Kotlin hoặc Java). */
export function patchMainActivity(src) {
  if (src.includes("FlutterFragmentActivity")) return { text: src, changed: false, ok: true };
  if (!/\bFlutterActivity\b/.test(src)) return { text: src, changed: false, ok: false, note: "không thấy FlutterActivity" };
  const text = src.replace(/io\.flutter\.embedding\.android\.FlutterActivity/g, "io.flutter.embedding.android.FlutterFragmentActivity").replace(/\bFlutterActivity\b/g, "FlutterFragmentActivity");
  return { text, changed: true, ok: true };
}

/** Tắt sao lưu tự động của Android (adb backup / Google backup) để không ai lấy dữ liệu app qua đường đó. */
export function patchAllowBackup(xml) {
  if (/android:allowBackup\s*=\s*"false"/.test(xml)) return { text: xml, changed: false, ok: true };
  if (/android:allowBackup\s*=/.test(xml)) {
    return { text: xml.replace(/android:allowBackup\s*=\s*"[^"]*"/, 'android:allowBackup="false"'), changed: true, ok: true };
  }
  const app = /<application\b/.exec(xml);
  if (!app) return { text: xml, changed: false, ok: false, note: "không thấy thẻ <application>" };
  const text = xml.slice(0, app.index) + '<application android:allowBackup="false" ' + xml.slice(app.index + "<application".length).replace(/^\s*/, "");
  return { text, changed: true, ok: true };
}

/** android/app/src/debug/AndroidManifest.xml: cho phép HTTP/WS rõ tới backend dev (chỉ bản debug). */
export function patchDebugManifest(xml) {
  if (xml.includes("usesCleartextTraffic")) return { text: xml, changed: false, ok: true };
  const app = /<application\b/.exec(xml);
  if (app) {
    const text = xml.slice(0, app.index) + '<application android:usesCleartextTraffic="true" ' + xml.slice(app.index + "<application".length).replace(/^\s*/, "");
    return { text, changed: true, ok: true };
  }
  const close = xml.lastIndexOf("</manifest>");
  if (close < 0) return { text: xml, changed: false, ok: false, note: "không thấy </manifest>" };
  const text = xml.slice(0, close) + `    <!-- ${MARKER}: chỉ bản debug -->\n    <application android:usesCleartextTraffic="true" />\n` + xml.slice(close);
  return { text, changed: true, ok: true };
}

/**
 * Xem/nghe chung: trình phát (ExoPlayer) mở http://127.0.0.1 nên Android phải cho phép HTTP rõ tới địa chỉ vòng lặp.
 * Chỉ 127.0.0.1/localhost; mọi nơi khác vẫn bắt buộc HTTPS (bản dev: giữ cho phép HTTP rõ như trước vì
 * networkSecurityConfig đè lên usesCleartextTraffic).
 */
export function networkSecurityConfigXml({ devCleartext = true } = {}) {
  return `<?xml version="1.0" encoding="utf-8"?>
<!-- ${MARKER}: xem/nghe chung phát qua http://127.0.0.1 -->
<network-security-config>
    <base-config cleartextTrafficPermitted="${devCleartext ? "true" : "false"}" />
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="false">127.0.0.1</domain>
        <domain includeSubdomains="false">localhost</domain>
    </domain-config>
</network-security-config>
`;
}

/** Gắn android:networkSecurityConfig vào <application> (nếu chưa có). */
export function patchNetworkSecurityAttr(xml) {
  if (xml.includes("android:networkSecurityConfig")) return { text: xml, changed: false, ok: true };
  const app = /<application\b/.exec(xml);
  if (!app) return { text: xml, changed: false, ok: false, note: "không thấy thẻ <application>" };
  const text = xml.slice(0, app.index) + '<application android:networkSecurityConfig="@xml/network_security_config" ' + xml.slice(app.index + "<application".length).replace(/^\s*/, "");
  return { text, changed: true, ok: true };
}

/** build.gradle(.kts): minSdk 24 (flutter_webrtc/firebase yêu cầu >= 23). */
export function patchGradleMinSdk(src, minSdk = 24) {
  const kts = /(\bminSdk\s*=\s*)flutter\.minSdkVersion\b/;
  const groovy = /(\bminSdkVersion\s+)flutter\.minSdkVersion\b/;
  const groovyEq = /(\bminSdk(?:Version)?\s*=\s*)flutter\.minSdkVersion\b/;
  for (const re of [kts, groovy, groovyEq]) {
    if (re.test(src)) return { text: src.replace(re, `$1${minSdk}`), changed: true, ok: true };
  }
  // đã là số cố định: chỉ cần >= 23
  const fixed = /\bminSdk(?:Version)?\s*(?:=\s*|\s)(\d+)/.exec(src);
  if (fixed) return { text: src, changed: false, ok: Number(fixed[1]) >= 23, note: fixed[1] < 23 ? `minSdk hiện là ${fixed[1]} (< 23)` : undefined };
  return { text: src, changed: false, ok: false, note: "không thấy dòng minSdk" };
}

/** build.gradle(.kts): bật core library desugaring (flutter_local_notifications yêu cầu), thêm thư viện desugar_jdk_libs. */
export function patchGradleDesugar(src) {
  const isKts = /\bminSdk\s*=|\bnamespace\s*=|\bisMinifyEnabled\b|\bid\("/.test(src) && !/^\s*apply plugin:/m.test(src) && !/\bminSdkVersion\s+\d/.test(src);
  const lib = "com.android.tools:desugar_jdk_libs:2.1.4";
  let text = src;
  let changed = false;
  if (!/isCoreLibraryDesugaringEnabled|coreLibraryDesugaringEnabled/.test(text)) {
    const flag = isKts ? "isCoreLibraryDesugaringEnabled = true" : "coreLibraryDesugaringEnabled true";
    if (/compileOptions\s*\{/.test(text)) text = text.replace(/compileOptions\s*\{/, (m) => `${m}\n        ${flag}`);
    else if (/\bandroid\s*\{/.test(text)) text = text.replace(/\bandroid\s*\{/, (m) => `${m}\n    compileOptions {\n        ${flag}\n    }`);
    else return { text: src, changed: false, ok: false, note: "không thấy khối android { }" };
    changed = true;
  }
  if (!/coreLibraryDesugaring\s*[("']/.test(text)) {
    const dep = isKts ? `coreLibraryDesugaring("${lib}")` : `coreLibraryDesugaring '${lib}'`;
    text = `${text.replace(/\s*$/, "")}\n\ndependencies {\n    ${dep}\n}\n`;
    changed = true;
  }
  return { text, changed, ok: true };
}

/** android/build.gradle(.kts) gốc: ép compileSdk >= 36 cho mọi plugin thư viện (file_picker... mặc định 34 -> lỗi checkDebugAarMetadata). */
export function patchRootCompileSdk(src, isKts, sdk = 36) {
  if (src.includes("cham: compileSdk")) return { text: src, changed: false, ok: true };
  const block = isKts
    ? `// cham: compileSdk ${sdk} cho plugin cũ (AAR metadata yêu cầu)
subprojects {
    afterEvaluate {
        if (name != "app") {
            val ext = extensions.findByName("android")
            if (ext != null) {
                try {
                    ext.javaClass.getMethod("setCompileSdkVersion", Int::class.javaPrimitiveType).invoke(ext, ${sdk})
                } catch (_: Throwable) {
                    try {
                        ext.javaClass.getMethod("setCompileSdk", Integer::class.javaObjectType).invoke(ext, ${sdk})
                    } catch (_: Throwable) {
                    }
                }
            }
        }
    }
}

`
    : `// cham: compileSdk ${sdk} cho plugin cũ (AAR metadata yêu cầu)
subprojects {
    afterEvaluate { p ->
        if (p.name != 'app' && p.hasProperty('android')) {
            try { p.android.compileSdkVersion ${sdk} } catch (Throwable ignored) { }
        }
    }
}

`;
  const m = /^[ \t]*subprojects\s*\{/m.exec(src);
  const text = m ? src.slice(0, m.index) + block + src.slice(m.index) : src.replace(/\s*$/, "") + "\n\n" + block;
  return { text, changed: true, ok: true };
}

export function patchInfoPlist(xml, { devCleartext = true } = {}) {
  const end = xml.lastIndexOf("</dict>");
  if (end < 0 || xml.indexOf("</plist>") < end) return { text: xml, changed: false, ok: false, note: "không thấy </dict> cuối của Info.plist" };
  const entries = [];
  if (!xml.includes("<key>NSCameraUsageDescription</key>")) {
    entries.push("<key>NSCameraUsageDescription</key>\n\t<string>Chạm needs your camera for video calls. Nothing is recorded.</string>");
  }
  if (!xml.includes("<key>NSMicrophoneUsageDescription</key>")) {
    entries.push("<key>NSMicrophoneUsageDescription</key>\n\t<string>Chạm needs your microphone for video calls, and for screen recordings you start yourself.</string>");
  }
  if (!xml.includes("<key>NSFaceIDUsageDescription</key>")) {
    entries.push("<key>NSFaceIDUsageDescription</key>\n\t<string>Chạm uses Face ID to unlock the app if you turn on app lock.</string>");
  }
  if (!xml.includes("<key>NSPhotoLibraryUsageDescription</key>")) {
    entries.push("<key>NSPhotoLibraryUsageDescription</key>\n\t<string>Chạm needs access to your photos so you can choose a profile picture.</string>");
  }
  // GĐ2 (T-108): thông báo đẩy khi app ở nền cần UIBackgroundModes chứa remote-notification.
  // Push Notifications capability + khóa APNs vẫn phải bật tay trong Xcode/Firebase (xem APP-CHAY-THU.md).
  let needManualBackground = false;
  if (!xml.includes("<key>UIBackgroundModes</key>")) {
    entries.push("<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>remote-notification</string>\n\t</array>");
  } else if (!xml.includes("<string>remote-notification</string>")) {
    needManualBackground = true;
  }
  if (devCleartext && !xml.includes("<key>NSAppTransportSecurity</key>")) {
    // Chỉ cho địa chỉ cục bộ (localhost, IP LAN, *.local). GỠ trước khi phát hành lên App Store.
    entries.push("<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>");
  }
  const note = needManualBackground ? "UIBackgroundModes đã có nhưng thiếu remote-notification: thêm tay" : undefined;
  if (entries.length === 0) return { text: xml, changed: false, ok: !needManualBackground, note };
  const text = xml.slice(0, end) + entries.map((e) => `\t${e}\n`).join("") + xml.slice(end);
  return { text, changed: true, ok: !needManualBackground, note };
}

export function patchPodfile(src) {
  let text = src;
  let changed = false;
  const notes = [];
  const platformLine = /^[ \t]*platform :ios, ['"](\d+)(?:\.\d+)?['"]/m.exec(text);
  if (platformLine) {
    if (Number(platformLine[1]) < 13) {
      text = text.replace(/^([ \t]*)platform :ios, ['"][\d.]+['"]/m, "$1platform :ios, '13.0'");
      changed = true;
    }
  } else if (/^[ \t]*#\s*platform :ios, ['"][\d.]+['"]/m.test(text)) {
    text = text.replace(/^([ \t]*)#\s*platform :ios, ['"][\d.]+['"]/m, "$1platform :ios, '13.0'");
    changed = true;
  } else {
    notes.push("không thấy dòng `platform :ios` để đặt 13.0");
  }
  if (!text.includes("PERMISSION_CAMERA")) {
    const re = /^([ \t]*)flutter_additional_ios_build_settings\(target\)[ \t]*$/m;
    const m = re.exec(text);
    if (m) {
      const i = m[1];
      const add =
        `\n${i}target.build_configurations.each do |config|\n` +
        `${i}  # ${MARKER}: permission_handler chỉ bật nhóm quyền có macro tương ứng\n` +
        `${i}  config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)']\n` +
        `${i}  config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] += ['PERMISSION_CAMERA=1', 'PERMISSION_MICROPHONE=1']\n` +
        `${i}end`;
      text = text.replace(re, m[0] + add);
      changed = true;
    } else {
      notes.push("không thấy `flutter_additional_ios_build_settings(target)` trong post_install");
    }
  }
  return { text, changed, ok: notes.length === 0, note: notes.join("; ") || undefined };
}

// ---------------------------------------------------------------- chạy thật

const MANUAL = {
  android: "Mở tasks/02-code/APP-CHAY-THU.md mục 2 và làm tay (AndroidManifest.xml, debug/AndroidManifest.xml, minSdk).",
  "ios-plist": "Mở tasks/02-code/APP-CHAY-THU.md mục 3.1/3.3 và làm tay (Info.plist).",
  "ios-podfile": "Mở tasks/02-code/APP-CHAY-THU.md mục 3.2 và làm tay (Podfile: platform :ios, '13.0' + macro PERMISSION_CAMERA/PERMISSION_MICROPHONE).",
};

function findFile(dir, re, depth = 0) {
  if (depth > 6 || !existsSync(dir)) return null;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      const r = findFile(p, re, depth + 1);
      if (r) return r;
    } else if (re.test(e.name)) return p;
  }
  return null;
}

function applyFile(path, fn, label, report) {
  if (!existsSync(path)) {
    report.push({ label, status: "missing", note: `không có tệp ${path}` });
    return;
  }
  const before = readFileSync(path, "utf8");
  const r = fn(before);
  if (r.changed) writeFileSync(path, r.text);
  report.push({ label, status: !r.ok ? "manual" : r.changed ? "patched" : "unchanged", note: r.note });
}

// Âm thanh cho kênh thông báo Android (chuông cuộc gọi, tiếng tin nhắn): phải nằm ở res/raw.
export const RAW_SOUNDS = [
  ["ring_chuong.mp3", "ring_chuong.mp3"],
  ["msg_ding.wav", "msg_ding.wav"],
];

export function copyRawSounds(appDir) {
  const out = join(appDir, "android", "app", "src", "main", "res", "raw");
  const results = [];
  for (const [from, to] of RAW_SOUNDS) {
    const src = join(appDir, "assets", "audio", from);
    if (!existsSync(src)) {
      results.push({ file: to, status: "missing" });
      continue;
    }
    mkdirSync(out, { recursive: true });
    const dst = join(out, to);
    const data = readFileSync(src);
    if (existsSync(dst) && readFileSync(dst).equals(data)) {
      results.push({ file: to, status: "unchanged" });
      continue;
    }
    writeFileSync(dst, data);
    results.push({ file: to, status: "patched" });
  }
  return results;
}

export function run({ appDir, step = "all", devCleartext = true }) {
  const report = [];
  const want = (s) => step === "all" || step === s;
  if (want("android")) {
    const a = join(appDir, "android", "app");
    applyFile(join(a, "src", "main", "AndroidManifest.xml"), patchMainManifest, "android main manifest", report);
    applyFile(join(a, "src", "main", "AndroidManifest.xml"), patchAllowBackup, "android allowBackup=false", report);
    if (devCleartext) applyFile(join(a, "src", "debug", "AndroidManifest.xml"), patchDebugManifest, "android debug manifest", report);
    applyFile(join(a, "src", "main", "AndroidManifest.xml"), patchNetworkSecurityAttr, "android networkSecurityConfig", report);
    const xmlDir = join(a, "src", "main", "res", "xml");
    const xmlPath = join(xmlDir, "network_security_config.xml");
    if (!existsSync(join(a, "src", "main"))) {
      report.push({ label: "android network_security_config.xml", status: "missing", note: "không có thư mục android/app/src/main" });
    } else if (!existsSync(xmlPath)) {
      mkdirSync(xmlDir, { recursive: true });
      writeFileSync(xmlPath, networkSecurityConfigXml({ devCleartext }));
      report.push({ label: "android network_security_config.xml", status: "patched" });
    } else {
      report.push({ label: "android network_security_config.xml", status: "unchanged" });
    }
    const act = findFile(join(a, "src", "main"), /^MainActivity\.(kt|java)$/);
    if (act) applyFile(act, patchMainActivity, "android MainActivity (FlutterFragmentActivity)", report);
    const kts = join(a, "build.gradle.kts");
    applyFile(existsSync(kts) ? kts : join(a, "build.gradle"), (s) => patchGradleMinSdk(s), "android minSdk", report);
    applyFile(existsSync(kts) ? kts : join(a, "build.gradle"), (s) => patchGradleDesugar(s), "android core library desugaring", report);
    const rootKts = join(appDir, "android", "build.gradle.kts");
    const rootIsKts = existsSync(rootKts);
    applyFile(rootIsKts ? rootKts : join(appDir, "android", "build.gradle"), (s) => patchRootCompileSdk(s, rootIsKts), "android compileSdk 36 cho plugin", report);
  }
  if (want("android") && existsSync(join(appDir, "android", "app", "src", "main"))) {
    for (const r of copyRawSounds(appDir)) {
      report.push({ label: `android res/raw/${r.file}`, status: r.status === "missing" ? "skipped" : r.status, note: r.status === "missing" ? "thiếu tệp assets/audio" : undefined });
    }
  }
  if (want("ios-plist")) applyFile(join(appDir, "ios", "Runner", "Info.plist"), (s) => patchInfoPlist(s, { devCleartext }), "ios Info.plist", report);
  if (want("ios-podfile")) {
    const pod = join(appDir, "ios", "Podfile");
    if (!existsSync(pod)) report.push({ label: "ios Podfile", status: "skipped", note: "chưa có ios/Podfile (chỉ sinh trên macOS sau `flutter pub get`); chạy lại bước này trên Mac" });
    else applyFile(pod, patchPodfile, "ios Podfile", report);
  }
  return report;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const get = (name, def) => {
    const i = args.indexOf(name);
    return i >= 0 && args[i + 1] ? args[i + 1] : def;
  };
  const step = get("--step", "all");
  if (!["all", "android", "ios-plist", "ios-podfile"].includes(step)) {
    console.error(`--step không hợp lệ: ${step}`);
    process.exit(64);
  }
  const report = run({ appDir: resolve(get("--app-dir", ".")), step, devCleartext: !args.includes("--no-dev-cleartext") });
  let needManual = false;
  for (const r of report) {
    console.log(`[${r.status}] ${r.label}${r.note ? " - " + r.note : ""}`);
    if (r.status === "manual" || r.status === "missing") {
      needManual = true;
      const key = r.label.startsWith("android") ? "android" : r.label.includes("Podfile") ? "ios-podfile" : "ios-plist";
      console.log(`    -> KHÔNG sửa tệp này. ${MANUAL[key]}`);
    }
  }
  process.exit(needManual ? 2 : 0);
}
