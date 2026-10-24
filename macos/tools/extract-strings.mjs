/**
 * 把 `src/i18n/*.ts` 导出成 `macos/Resources/strings.json`。
 *
 * 原生分支的界面是 Swift 写的，但文案不该重打一遍——那 181 个键、7 种语言
 * 是 WebView 版攒下来的，重抄一遍必然走样。这里用 Node 的类型剥离直接 import
 * 那几个 TS 文件（它们只是 `export const strings = {...}`，没有运行时依赖），
 * 拼成一张 `{ "zh-CN": {...}, "en": {...} }` 的表，Swift 侧启动时读一次。
 *
 * 跑法：node macos/tools/extract-strings.mjs
 * build.sh 会顺手调一次，所以改完 TS 字典不用手动同步。
 */
import { writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const LANGS = ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "es"];

const out = {};
for (const lang of LANGS) {
  const mod = await import(join(root, "src", "i18n", `${lang}.ts`));
  const strings = mod.strings;
  const bad = Object.entries(strings).filter(([, v]) => typeof v !== "string");
  if (bad.length) {
    throw new Error(`${lang}: ${bad.length} 个值不是字符串，导出脚本要跟着改`);
  }
  out[lang] = strings;
}

// 七份的键集合必须完全一致，否则界面上会出现「英文有、日文没有」的洞
const base = Object.keys(out["zh-CN"]).sort();
for (const lang of LANGS.slice(1)) {
  const keys = Object.keys(out[lang]).sort();
  const missing = base.filter((k) => !(k in out[lang]));
  const extra = keys.filter((k) => !(k in out["zh-CN"]));
  if (missing.length || extra.length) {
    throw new Error(
      `${lang} 与 zh-CN 的键对不上：缺 ${missing.slice(0, 5).join(",")}，多 ${extra.slice(0, 5).join(",")}`,
    );
  }
}

const target = join(root, "macos", "Resources", "strings.json");
await mkdir(dirname(target), { recursive: true });
await writeFile(target, JSON.stringify(out, null, 2) + "\n", "utf8");
console.log(`wrote ${target}: ${LANGS.length} 种语言 × ${base.length} 键`);
