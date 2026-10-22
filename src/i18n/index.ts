/**
 * 多语言。
 *
 * 没有引第三方库：这里只需要「查表 + 插值 + 单复数」三件事，i18next 那套命名空间、
 * 后端加载、插件生态对一个桌面小工具来说是纯粹的负担。
 *
 * 状态用**模块级 store + useSyncExternalStore** 而不是 React Context：
 * 主面板和悬浮窗是两个独立的 React root，各自还有好几层组件要读文案；
 * Context 就得从根上往下穿一遍，而 `useI18n()` 直接在任意位置调用即可。
 *
 * 真值在 Rust 侧（`settings.language`）。这里只镜像：启动拉一次，
 * 之后靠 `settings:changed` 跟着变——和 `useSettings` 是同一套模式。
 */
import { useSyncExternalStore } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import * as zhCN from "./zh-CN";
import * as zhTW from "./zh-TW";
import * as en from "./en";
import * as ja from "./ja";
import * as ko from "./ko";
import * as fr from "./fr";
import * as es from "./es";
import type { Dict, Key, PluralKey, Plurals, Vars } from "./types";

export type { Key, PluralKey, Vars };

export type Lang = "zh-CN" | "zh-TW" | "en" | "ja" | "ko" | "fr" | "es";

/** 设置界面里的语言列表。每种语言用**自己的文字**写名字——找不到自己母语的人才最需要翻译。 */
export const LANGS: { tag: Lang; name: string }[] = [
  { tag: "zh-CN", name: "简体中文" },
  { tag: "zh-TW", name: "繁體中文" },
  { tag: "en", name: "English" },
  { tag: "ja", name: "日本語" },
  { tag: "ko", name: "한국어" },
  { tag: "fr", name: "Français" },
  { tag: "es", name: "Español" },
];

const DICTS: Record<Lang, { strings: Dict; plurals: Plurals }> = {
  "zh-CN": zhCN,
  "zh-TW": zhTW,
  en,
  ja,
  ko,
  fr,
  es,
};

export interface I18n {
  lang: Lang;
  /** 查一条文案并填充 `{var}` */
  t(key: Key, vars?: Vars): string;
  /** 单复数短语：`n === 1` 取第一项，其余取第二项 */
  tn(key: PluralKey, n: number, vars?: Vars): string;
  /** 按当前语言格式化数字（千分位、小数逗号） */
  num(n: number, frac?: number): string;
  /** 秒 → "2 天 5 小时" / "3 minutes" */
  duration(secs: number): string;
  /** 秒 → "1 天" / "1.5 小时" / "10 分钟" */
  retention(secs: number): string;
  /** 毫秒 → "1 秒" / "2.5 s" */
  interval(ms: number): string;
  /** unix 秒 → "14:05"，跨天时 "10-22 14:05" */
  clock(ts: number, withDate?: boolean): string;
}

function fill(s: string, vars?: Vars): string {
  if (!vars) return s;
  return s.replace(/\{(\w+)\}/g, (m, k) => (k in vars ? String(vars[k]) : m));
}

/** 系统语言标签 → 七种之一。`auto` 交给调用方解析成 detect 的结果。 */
export function resolveLang(tag: string): Lang {
  const t = (tag || "").trim().toLowerCase().replace("_", "-");
  if (t.startsWith("zh")) {
    const traditional =
      t.includes("hant") || t.includes("-tw") || t.includes("-hk") || t.includes("-mo");
    return traditional ? "zh-TW" : "zh-CN";
  }
  if (t.startsWith("ja")) return "ja";
  if (t.startsWith("ko")) return "ko";
  if (t.startsWith("fr")) return "fr";
  if (t.startsWith("es")) return "es";
  return "en";
}

function makeI18n(lang: Lang): I18n {
  const dict = DICTS[lang];
  const nf = new Map<number, Intl.NumberFormat>();
  const nfFor = (frac: number) => {
    let f = nf.get(frac);
    if (!f) {
      f = new Intl.NumberFormat(lang, {
        minimumFractionDigits: frac,
        maximumFractionDigits: frac,
      });
      nf.set(frac, f);
    }
    return f;
  };
  const num = (n: number, frac = 0) => (Number.isFinite(n) ? nfFor(frac).format(n) : "—");

  const t = (key: Key, vars?: Vars) => fill(dict.strings[key] ?? key, vars);
  const tn = (key: PluralKey, n: number, vars?: Vars) => {
    const pair = dict.plurals[key];
    const text = pair[n === 1 ? 0 : 1] ?? key;
    // 小数按需保留一位：2.5 秒 而不是 2.5000001 秒
    const shown = Number.isInteger(n) ? num(n) : num(n, 1);
    return fill(text, { n: shown, ...vars });
  };

  return {
    lang,
    t,
    tn,
    num,
    duration(secs) {
      const d = Math.floor(secs / 86_400);
      const h = Math.floor((secs % 86_400) / 3600);
      const m = Math.floor((secs % 3600) / 60);
      if (d > 0) return `${tn("p.day", d)} ${tn("p.hour", h)}`;
      if (h > 0) return `${tn("p.hour", h)} ${tn("p.min", m)}`;
      return tn("p.min", m);
    },
    retention(secs) {
      if (secs % 86_400 === 0) return tn("p.day", secs / 86_400);
      if (secs % 3600 === 0) return tn("p.hour", secs / 3600);
      if (secs % 60 === 0 && secs < 3600) return tn("p.min", secs / 60);
      return tn("p.hour", Math.round((secs / 3600) * 10) / 10);
    },
    interval(ms) {
      return tn("p.sec", Math.round(ms / 100) / 10);
    },
    clock(ts, withDate = false) {
      const d = new Date(ts * 1000);
      const opts: Intl.DateTimeFormatOptions = withDate
        ? { month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }
        : { hour: "2-digit", minute: "2-digit" };
      // h23 而不是默认的 12 小时制：时间轴标签要短，且不想出现 AM/PM
      return new Intl.DateTimeFormat(lang, { ...opts, hourCycle: "h23" }).format(d);
    },
  };
}

// ---------------------------------------------------------------- store

let detected: Lang = "en";
let current: I18n = makeI18n("en");
const subs = new Set<() => void>();

function setLang(lang: Lang) {
  if (current.lang === lang) return;
  current = makeI18n(lang);
  // 交给浏览器做字体回退（:lang(ja) 之类）和断词
  document.documentElement.lang = lang;
  subs.forEach((fn) => fn());
}

/** 任意组件里读当前语言对象；语言一变就重渲染。 */
export function useI18n(): I18n {
  return useSyncExternalStore(
    (fn) => {
      subs.add(fn);
      return () => subs.delete(fn);
    },
    () => current,
    () => current,
  );
}

/** 不参与渲染的地方（比如事件回调）用这个取当前值 */
export function i18n(): I18n {
  return current;
}

/**
 * 启动时对齐一次语言，之后跟着设置走。
 *
 * 主面板和悬浮窗各调一次；`started` 保证重复调用不会挂多个监听。
 */
let started = false;
export function initLocale() {
  if (started) return;
  started = true;

  (async () => {
    try {
      detected = resolveLang(await invoke<string>("get_locale"));
    } catch {
      /* 浏览器预览下没有后端，保持 en */
    }

    try {
      const s = await invoke<{ language?: string }>("get_settings");
      const choice = s?.language ?? "auto";
      setLang(choice === "auto" ? detected : resolveLang(choice));
    } catch {
      setLang(detected);
    }

    try {
      await listen<{ language?: string }>("settings:changed", (e) => {
        const choice = e.payload?.language ?? "auto";
        setLang(choice === "auto" ? detected : resolveLang(choice));
      });
    } catch {
      /* ignore */
    }
  })();
}
