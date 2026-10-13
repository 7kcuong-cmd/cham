#!/usr/bin/env node
// Developer APP: kiểm TĨNH app Flutter với khối JSON `contractIndex` của API-GD2-4.md §9 (không cần Flutter SDK).
//
// Dùng:  node tool/check-app-gd24.mjs [--root <thư mục gốc repo cham>] [--phase gd2|gd3|gd4|all] [--strict-app]
// Mặc định root = thư mục cha của app/, phase = all. Thoát 0 nếu khớp, 1 nếu có thiếu sót.
//
// Kiểm:
//   1. mỗi REST trong contractIndex.rest có trong lib/services/api_client.dart (đường dẫn + phương thức);
//   2. mỗi thông điệp client->server được app gửi (chuỗi 'type' trong lib/);
//   3. mỗi thông điệp server->client có `case 'type'` trong lib/models/ws_messages.dart và mọi
//      trường của nó được đọc (chuỗi 'trường' trong lib/models/);
//   4. mỗi mã lỗi có chuỗi dịch trong lib/l10n_errors.dart (trừ INVALID_STATE... nếu ghi chú rơi vào chung);
//   --strict-app: mỗi thông điệp server->client và mỗi REST có nhắc tới trong test/ (test hợp đồng).
// Backend CHƯA xong thì chỉ kiểm phía app; script này không đọc backend/.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const opt = (name, def) => (args.includes(name) ? args[args.indexOf(name) + 1] : def);
const root = path.resolve(opt("--root", path.join(here, "../..")));
const phase = opt("--phase", "all");
const strict = args.includes("--strict-app");
const app = path.join(root, "app");

const read = (p) => fs.readFileSync(p, "utf8");
const walk = (dir) =>
  fs.existsSync(dir)
    ? fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
        const p = path.join(dir, e.name);
        return e.isDirectory() ? walk(p) : p.endsWith(".dart") ? [p] : [];
      })
    : [];

const spec = read(path.join(root, "tasks/01-plan/API-GD2-4.md"));
const block = [...spec.matchAll(/```json\n([\s\S]*?)```/g)]
  .map((m) => m[1])
  .find((b) => b.includes('"contractIndex"'));
if (!block) {
  console.error("Không thấy khối contractIndex trong API-GD2-4.md");
  process.exit(2);
}
const idx = JSON.parse(block).contractIndex;
const inPhase = (item) => phase === "all" || (idx.phases[phase] ?? []).includes(item);

const lib = walk(path.join(app, "lib")).filter((f) => !/app_localizations/.test(f));
const libText = lib.map(read).join("\n");
const modelsText = walk(path.join(app, "lib/models")).map(read).join("\n");
const apiClient = read(path.join(app, "lib/services/api_client.dart"));
const wsMessages = read(path.join(app, "lib/models/ws_messages.dart"));
const errorsText = read(path.join(app, "lib/l10n_errors.dart"));
const testText = walk(path.join(app, "test")).map(read).join("\n");

const problems = [];
const notes = [];
const bad = (m) => problems.push(m);

// 1. REST: literal '<đường dẫn>' (tham số :x -> ${...}) có 'METHOD' ngay phía trước (trong 120 ký tự).
const esc = (t) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
for (const entry of idx.rest.filter(inPhase)) {
  const [method, p] = entry.split(" ");
  const pathRe = esc(p).replace(/:\w+/g, "\\$\\{[^}]*\\}");
  const re = new RegExp(`'${method}'[^;]{0,120}?'${pathRe}'`);
  if (!re.test(apiClient)) bad(`REST ${entry}: không thấy trong lib/services/api_client.dart`);
}

// 2. WS client -> server
for (const t of idx.wsClient.filter(inPhase)) {
  if (!libText.includes(`'${t}'`)) bad(`WS c->s ${t}: app không gửi (không có chuỗi '${t}' trong lib/)`);
}

// 3. WS server -> client (+ trường)
for (const [t, fields] of Object.entries(idx.wsServer).filter(([t]) => inPhase(t))) {
  // `call.invite` và `game.invite`/`game.end` là hai chiều; vẫn phải có case ở bộ phân tích.
  if (!wsMessages.includes(`case '${t}'`)) bad(`WS s->c ${t}: ws_messages.dart không có case '${t}'`);
  for (const f of fields) {
    if (!modelsText.includes(`'${f}'`)) bad(`WS s->c ${t}.${f}: không thấy app đọc khóa '${f}' trong lib/models/`);
  }
}

// 4. mã lỗi
for (const code of Object.keys(idx.errors).filter(inPhase)) {
  if (!errorsText.includes(`'${code}'`)) {
    notes.push(`mã lỗi ${code}: không có chuỗi riêng trong l10n_errors.dart (rơi vào lỗi chung)`);
  }
}

// strict-app: có test nhắc tới
const inTests = (t) => testText.includes(`'${t}'`) || new RegExp(`"type"\\s*:\\s*"${t.replace(/\./g, "\\.")}"`).test(testText);
if (strict) {
  for (const t of Object.keys(idx.wsServer).filter(inPhase)) {
    if (!inTests(t)) bad(`strict: không test nào nhắc thông điệp '${t}'`);
  }
  for (const entry of idx.rest.filter(inPhase)) {
    const p = entry.split(" ")[1].replace(/:\w+$/, "");
    if (!testText.includes(p)) bad(`strict: không test nào nhắc đường dẫn ${p}`);
  }
  for (const t of idx.wsClient.filter(inPhase)) {
    if (!inTests(t)) bad(`strict: không test nào nhắc thông điệp gửi đi '${t}'`);
  }
}

console.log(`Kiểm app theo API-GD2-4  root=${root}  phase=${phase}${strict ? "  strict-app" : ""}`);
console.log(
  `contractIndex: ${idx.rest.length} REST, ${idx.wsClient.length} WS c->s, ${Object.keys(idx.wsServer).length} WS s->c, ${Object.keys(idx.errors).length} mã lỗi`,
);
for (const n of notes) console.log(`  ghi chú: ${n}`);
for (const p of problems) console.log(`  THIẾU: ${p}`);
console.log(problems.length === 0 ? "KẾT QUẢ: app khớp contractIndex" : `KẾT QUẢ: ${problems.length} THIẾU SÓT`);
process.exit(problems.length === 0 ? 0 : 1);
