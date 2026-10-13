// node --test tool/
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { networkSecurityConfigXml, patchNetworkSecurityAttr, patchAllowBackup, patchMainManifest, patchDebugManifest, patchGradleMinSdk, patchGradleDesugar, patchRootCompileSdk, patchInfoPlist, patchPodfile, run } from "./patch-platforms.mjs";

const MAIN = `<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="cham"
        android:name="\${applicationName}"
        android:icon="@mipmap/ic_launcher">
        <activity android:name=".MainActivity" android:exported="true">
        </activity>
    </application>
    <queries>
        <intent><action android:name="android.intent.action.PROCESS_TEXT"/><data android:mimeType="text/plain"/></intent>
    </queries>
</manifest>
`;
const DEBUG = `<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- The INTERNET permission is required for development. -->
    <uses-permission android:name="android.permission.INTERNET"/>
</manifest>
`;
const PLIST = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleName</key>
\t<string>cham</string>
\t<key>UIApplicationSceneManifest</key>
\t<dict>
\t\t<key>UIApplicationSupportsMultipleScenes</key>
\t\t<false/>
\t</dict>
</dict>
</plist>
`;
const POD = `# Uncomment this line to define a global platform for your project
# platform :ios, '13.0'

target 'Runner' do
  use_frameworks!
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
`;

test("manifest chính: thêm quyền trước <application>, idempotent, INTERNET chỉ một lần", () => {
  const a = patchMainManifest(MAIN);
  assert.ok(a.ok && a.changed);
  for (const p of ["INTERNET", "CAMERA", "RECORD_AUDIO", "MODIFY_AUDIO_SETTINGS", "BLUETOOTH_CONNECT", "POST_NOTIFICATIONS"]) assert.match(a.text, new RegExp(`android.permission.${p}"`));
  assert.ok(a.text.indexOf("uses-permission") < a.text.indexOf("<application"));
  assert.match(a.text, /BLUETOOTH" android:maxSdkVersion="30"/);
  const b = patchMainManifest(a.text);
  assert.equal(b.changed, false);
  assert.equal(b.text, a.text);
  assert.equal((a.text.match(/permission.INTERNET"/g) ?? []).length, 1);
  assert.equal(patchMainManifest("<manifest></manifest>").ok, false);
});

test("manifest debug: thêm usesCleartextTraffic, giữ INTERNET, idempotent", () => {
  const a = patchDebugManifest(DEBUG);
  assert.match(a.text, /<application android:usesCleartextTraffic="true" \/>/);
  assert.match(a.text, /permission.INTERNET"\/>/);
  assert.equal(patchDebugManifest(a.text).changed, false);
  const withApp = patchDebugManifest('<manifest><application android:label="x"/></manifest>');
  assert.match(withApp.text, /<application android:usesCleartextTraffic="true" android:label="x"\/>/);
});

test("gradle minSdk: kts / groovy / số cố định", () => {
  assert.match(patchGradleMinSdk("defaultConfig {\n        minSdk = flutter.minSdkVersion\n}").text, /minSdk = 24/);
  assert.match(patchGradleMinSdk("defaultConfig {\n        minSdkVersion flutter.minSdkVersion\n}").text, /minSdkVersion 24/);
  assert.match(patchGradleMinSdk("minSdkVersion = flutter.minSdkVersion").text, /minSdkVersion = 24/);
  const fixed = patchGradleMinSdk("minSdk = 21");
  assert.equal(fixed.ok, false);
  assert.equal(patchGradleMinSdk("minSdk = 26").ok, true);
  assert.equal(patchGradleMinSdk("nothing").ok, false);
});

test("Info.plist: thêm camera/micro/ATS cục bộ trước </dict> cuối, idempotent, --no-dev-cleartext", () => {
  const a = patchInfoPlist(PLIST);
  assert.ok(a.ok && a.changed);
  assert.match(a.text, /NSCameraUsageDescription/);
  assert.match(a.text, /NSMicrophoneUsageDescription/);
  assert.match(a.text, /NSAllowsLocalNetworking/);
  assert.ok(a.text.indexOf("NSCameraUsageDescription") > a.text.indexOf("UIApplicationSceneManifest"));
  assert.match(a.text, /<\/dict>\n<\/plist>/);
  assert.equal(patchInfoPlist(a.text).changed, false);
  assert.doesNotMatch(patchInfoPlist(PLIST, { devCleartext: false }).text, /NSAppTransportSecurity/);
  assert.equal(patchInfoPlist("<plist></plist>").ok, false);
});

test("Podfile: bỏ chú thích platform, thêm macro quyền, idempotent; mẫu lạ -> ok=false", () => {
  const a = patchPodfile(POD);
  assert.ok(a.ok && a.changed);
  assert.match(a.text, /^platform :ios, '13.0'/m);
  assert.match(a.text, /PERMISSION_CAMERA=1', 'PERMISSION_MICROPHONE=1/);
  assert.ok(a.text.indexOf("PERMISSION_CAMERA") > a.text.indexOf("flutter_additional_ios_build_settings"));
  const b = patchPodfile(a.text);
  assert.equal(b.changed, false);
  assert.equal(patchPodfile("platform :ios, '12.0'\n").text.startsWith("platform :ios, '13.0'"), true);
  assert.equal(patchPodfile("target 'x' do\nend\n").ok, false);
});

test("run(): trên cây thư mục giả; thiếu tệp -> missing; chạy hai lần không đổi", () => {
  const d = mkdtempSync(join(tmpdir(), "cham-patch-"));
  mkdirSync(join(d, "android/app/src/main"), { recursive: true });
  mkdirSync(join(d, "android/app/src/debug"), { recursive: true });
  mkdirSync(join(d, "ios/Runner"), { recursive: true });
  writeFileSync(join(d, "android/app/src/main/AndroidManifest.xml"), MAIN);
  writeFileSync(join(d, "android/app/src/debug/AndroidManifest.xml"), DEBUG);
  writeFileSync(join(d, "android/build.gradle.kts"), "allprojects {\n}\nsubprojects {\n    project.evaluationDependsOn(\":app\")\n}\n");
  writeFileSync(join(d, "android/app/build.gradle.kts"), "android {\n    compileOptions {\n        sourceCompatibility = JavaVersion.VERSION_17\n    }\n    defaultConfig {\n        minSdk = flutter.minSdkVersion\n    }\n}\n");
  writeFileSync(join(d, "ios/Runner/Info.plist"), PLIST);
  const r1 = run({ appDir: d });
  assert.deepEqual(r1.map((r) => r.status), ["patched", "patched", "patched", "patched", "patched", "patched", "patched", "patched", "skipped", "skipped", "patched", "skipped"]);
  const snap = readFileSync(join(d, "android/app/src/main/AndroidManifest.xml"), "utf8");
  const r2 = run({ appDir: d });
  assert.deepEqual(r2.map((r) => r.status), ["unchanged", "unchanged", "unchanged", "unchanged", "unchanged", "unchanged", "unchanged", "unchanged", "skipped", "skipped", "unchanged", "skipped"]);
  assert.equal(readFileSync(join(d, "android/app/src/main/AndroidManifest.xml"), "utf8"), snap);
  const e = run({ appDir: join(d, "nope"), step: "android" });
  assert.ok(e.every((r) => r.status === "missing"));
});

test("Info.plist GĐ2: thêm UIBackgroundModes remote-notification; đã có khóa nhưng thiếu -> ok=false, không nhân đôi", () => {
  const a = patchInfoPlist(PLIST);
  assert.match(a.text, /<key>UIBackgroundModes<\/key>\s*<array>\s*<string>remote-notification<\/string>/);
  assert.equal((a.text.match(/UIBackgroundModes/g) ?? []).length, 1);
  assert.equal(patchInfoPlist(a.text).changed, false);
  const withAudio = PLIST.replace("</dict>\n</plist>", "\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>\n</dict>\n</plist>");
  const b = patchInfoPlist(withAudio);
  assert.equal(b.ok, false);
  assert.match(b.note, /remote-notification/);
  assert.equal((b.text.match(/UIBackgroundModes/g) ?? []).length, 1);
});

test("patchAllowBackup: thêm/sửa allowBackup=false, idempotent", () => {
  const a = patchAllowBackup(MAIN);
  assert.equal(a.ok, true);
  assert.match(a.text, /android:allowBackup="false"/);
  assert.equal(patchAllowBackup(a.text).changed, false);
  const b = patchAllowBackup(MAIN.replace("<application", '<application android:allowBackup="true"'));
  assert.match(b.text, /allowBackup="false"/);
  assert.equal((b.text.match(/allowBackup/g) ?? []).length, 1);
});

test("patchMainActivity: FlutterActivity -> FlutterFragmentActivity, idempotent", async () => {
  const { patchMainActivity } = await import("./patch-platforms.mjs");
  const kt = "package x\n\nimport io.flutter.embedding.android.FlutterActivity\n\nclass MainActivity : FlutterActivity()\n";
  const a = patchMainActivity(kt);
  assert.equal(a.ok, true);
  assert.match(a.text, /class MainActivity : FlutterFragmentActivity\(\)/);
  assert.match(a.text, /android\.FlutterFragmentActivity/);
  assert.equal(patchMainActivity(a.text).changed, false);
});

test("xem/nghe chung: networkSecurityConfig cho phép HTTP tới 127.0.0.1; idempotent; bản phát hành chặn HTTP nơi khác", () => {
  const a = patchNetworkSecurityAttr(MAIN);
  assert.equal(a.changed, true);
  assert.match(a.text, /<application android:networkSecurityConfig="@xml\/network_security_config"/);
  assert.equal(patchNetworkSecurityAttr(a.text).changed, false);
  assert.equal(patchNetworkSecurityAttr("<manifest/>").ok, false);
  const dev = networkSecurityConfigXml({ devCleartext: true });
  const rel = networkSecurityConfigXml({ devCleartext: false });
  assert.match(dev, /<base-config cleartextTrafficPermitted="true"/);
  assert.match(rel, /<base-config cleartextTrafficPermitted="false"/);
  for (const x of [dev, rel]) {
    assert.match(x, /<domain includeSubdomains="false">127\.0\.0\.1<\/domain>/);
    assert.match(x, /<domain includeSubdomains="false">localhost<\/domain>/);
  }
});

test("run(): ghi res/xml/network_security_config.xml và không ghi đè tệp có sẵn", () => {
  const d = mkdtempSync(join(tmpdir(), "cham-patch-ns-"));
  mkdirSync(join(d, "android/app/src/main"), { recursive: true });
  writeFileSync(join(d, "android/app/src/main/AndroidManifest.xml"), MAIN);
  run({ appDir: d, step: "android", devCleartext: false });
  const f = join(d, "android/app/src/main/res/xml/network_security_config.xml");
  assert.match(readFileSync(f, "utf8"), /base-config cleartextTrafficPermitted="false"/);
  writeFileSync(f, "<custom/>");
  run({ appDir: d, step: "android" });
  assert.equal(readFileSync(f, "utf8"), "<custom/>");
});

test("patchGradleDesugar: kts và groovy, chạy lại không đổi", () => {
  const kts = 'plugins { id("com.android.application") }\nandroid {\n    namespace = "x"\n    compileOptions {\n        sourceCompatibility = JavaVersion.VERSION_17\n    }\n}\nflutter { source = "../.." }\n';
  const r = patchGradleDesugar(kts);
  assert.match(r.text, /isCoreLibraryDesugaringEnabled = true/);
  assert.match(r.text, /coreLibraryDesugaring\("com\.android\.tools:desugar_jdk_libs/);
  assert.equal(patchGradleDesugar(r.text).changed, false);
  const g = "apply plugin: 'com.android.application'\nandroid {\n    compileOptions {\n        sourceCompatibility 1.8\n    }\n}\n";
  const r2 = patchGradleDesugar(g);
  assert.match(r2.text, /coreLibraryDesugaringEnabled true/);
  assert.match(r2.text, /coreLibraryDesugaring 'com\.android/);
});

test("patchRootCompileSdk: chèn TRƯỚC subprojects{evaluationDependsOn}, idempotent, cả kts và groovy", () => {
  const kts = 'allprojects {\n}\n\nsubprojects {\n    project.evaluationDependsOn(":app")\n}\n';
  const r = patchRootCompileSdk(kts, true);
  assert.ok(r.text.indexOf("cham: compileSdk") < r.text.indexOf("evaluationDependsOn"));
  assert.match(r.text, /setCompileSdkVersion/);
  assert.equal(patchRootCompileSdk(r.text, true).changed, false);
  const g = patchRootCompileSdk("allprojects {\n}\nsubprojects {\n    project.evaluationDependsOn(':app')\n}\n", false);
  assert.match(g.text, /p\.android\.compileSdkVersion 36/);
  assert.ok(g.text.indexOf("cham: compileSdk") < g.text.indexOf("evaluationDependsOn"));
});

test("copyRawSounds: chép chuông + tiếng tin nhắn vào res/raw, chạy lại không đổi, thiếu tệp thì báo", async () => {
  const { copyRawSounds } = await import("./patch-platforms.mjs");
  const d = mkdtempSync(join(tmpdir(), "cham-raw-"));
  mkdirSync(join(d, "assets", "audio"), { recursive: true });
  mkdirSync(join(d, "android", "app", "src", "main"), { recursive: true });
  writeFileSync(join(d, "assets", "audio", "ring_chuong.mp3"), Buffer.from([1, 2, 3]));
  const a = copyRawSounds(d);
  assert.equal(a.find((r) => r.file === "ring_chuong.mp3").status, "patched");
  assert.equal(a.find((r) => r.file === "msg_ding.wav").status, "missing");
  assert.deepEqual([...readFileSync(join(d, "android", "app", "src", "main", "res", "raw", "ring_chuong.mp3"))], [1, 2, 3]);
  assert.equal(copyRawSounds(d).find((r) => r.file === "ring_chuong.mp3").status, "unchanged");
});
