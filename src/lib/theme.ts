/**
 * 深色 / 浅色主题。
 *
 * 和 `i18n` 一样用模块级 store + `useSyncExternalStore`：主面板和悬浮窗是两个
 * 独立的 React root，两边都要在配色变化时重画，但又都不能独占这份状态。
 *
 * 真正落地的动作只有一个——往 `<html>` 上写 `data-theme`，剩下的全在 CSS 里：
 * `:root` 是深色基准，`:root[data-theme="light"]` 覆盖成浅色。
 * 所以这里不需要给任何组件传色值，切换主题也不会触发大范围重渲染。
 *
 * 用户的选择存在 Rust 侧（`settings.theme`），`auto` 时由本文件监听
 * `prefers-color-scheme` 解析成实际的深浅。
 */
import { useSyncExternalStore } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type ThemeChoice = "auto" | "dark" | "light";
export type Resolved = "dark" | "light";

/** 设置界面里的三档，顺序即显示顺序 */
export const THEMES: { value: ThemeChoice; key: "set.themeAuto" | "set.themeDark" | "set.themeLight" }[] = [
  { value: "auto", key: "set.themeAuto" },
  { value: "dark", key: "set.themeDark" },
  { value: "light", key: "set.themeLight" },
];

/**
 * 解析后的深浅色缓存在 localStorage，只为**首帧**。
 *
 * 启动时 `get_settings` 要跨一次 IPC 才回来，那之前如果什么都不写，浅色系统上
 * 会先闪一下深色。缓存里存的是「上次解析出来的结果」而不是用户的选择——
 * 用户选的是 `auto` 还是 `light` 对首帧没意义，反正结果一样。
 */
const CACHE_KEY = "ezpc.theme";

const QUERY = "(prefers-color-scheme: dark)";

function mql(): MediaQueryList | null {
  try {
    return window.matchMedia(QUERY);
  } catch {
    return null;
  }
}

function systemResolved(): Resolved {
  const q = mql();
  // 拿不到媒体查询（很老的 WebView）就当深色，至少和默认样式一致
  return !q || q.matches ? "dark" : "light";
}

function readCache(): Resolved | null {
  try {
    const v = localStorage.getItem(CACHE_KEY);
    return v === "dark" || v === "light" ? v : null;
  } catch {
    return null;
  }
}

let choice: ThemeChoice = "auto";
let resolved: Resolved = systemResolved();
const subs = new Set<() => void>();

function notify() {
  subs.forEach((fn) => fn());
}

/** 把当前解析结果写到 `<html>` 上，并记住它给下次启动用 */
function paint() {
  resolved = choice === "auto" ? systemResolved() : choice;
  document.documentElement.dataset.theme = resolved;
  try {
    localStorage.setItem(CACHE_KEY, resolved);
  } catch {
    /* 隐私模式下写不进去，只影响首帧，不影响功能 */
  }
  notify();
}

// 模块加载就定一次色：此时 React 还没渲染，浏览器也还没画第一帧。
// 模块脚本是 defer 的，执行早于首帧，所以这一行就是「无闪烁」的全部秘密。
resolved = readCache() ?? systemResolved();
document.documentElement.dataset.theme = resolved;

/** 用户换主题：先本地生效（零延迟），再落盘 */
export async function setTheme(next: ThemeChoice) {
  if (choice === next) return;
  choice = next;
  paint();
  try {
    await invoke("update_settings", { patch: { theme: next } });
  } catch {
    /* 浏览器预览下没有后端，保持本地状态即可 */
  }
}

/**
 * 启动时对齐一次，之后跟着设置走。
 *
 * 主面板和悬浮窗各调一次；`started` 保证重复调用不会挂多个监听。
 */
let started = false;
export function initTheme() {
  if (started) return;
  started = true;

  // 系统配色变了：只有 `auto` 才跟着走，用户手选了就尊重用户
  const q = mql();
  const onSystem = () => {
    if (choice === "auto") paint();
  };
  q?.addEventListener("change", onSystem);

  (async () => {
    try {
      const s = await invoke<{ theme?: string }>("get_settings");
      const v = s?.theme;
      choice = v === "dark" || v === "light" ? v : "auto";
      paint();
    } catch {
      /* ignore */
    }

    try {
      await listen<{ theme?: string }>("settings:changed", (e) => {
        const v = e.payload?.theme;
        const next: ThemeChoice = v === "dark" || v === "light" ? v : "auto";
        if (next === choice) return;
        choice = next;
        paint();
      });
    } catch {
      /* ignore */
    }
  })();
}

/**
 * 读当前主题。返回的 `choice` 是用户的选择（设置界面打勾用），
 * `resolved` 是实际生效的深浅（「跟随系统」后面那个括号用）。
 */
export function useTheme(): { choice: ThemeChoice; resolved: Resolved } {
  // 快照拼成一个字符串：`useSyncExternalStore` 要求返回值可以按值比较，
  // 返回对象的话每次都是新引用，会无限重渲染。
  const key = useSyncExternalStore(
    (fn) => {
      subs.add(fn);
      return () => subs.delete(fn);
    },
    () => `${choice}|${resolved}`,
    () => `${choice}|${resolved}`,
  );
  const [c, r] = key.split("|");
  return { choice: c as ThemeChoice, resolved: r as Resolved };
}
