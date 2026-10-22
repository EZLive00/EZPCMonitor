import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { AppSettings } from "./types";

/** 与 Rust 侧 settings.rs 保持一致 */
export const MIN_MS = 500;
export const MAX_MS = 60_000;
export const DEFAULT_MS = 1000;

/** 三档预设：高 / 中 / 低 */
export const PRESETS: { tier: string; ms: number; hint: string }[] = [
  { tier: "高", ms: 1000, hint: "1 秒，最灵敏" },
  { tier: "中", ms: 5000, hint: "5 秒，均衡" },
  { tier: "低", ms: 10_000, hint: "10 秒，最省电" },
];

export const FALLBACK: AppSettings = {
  intervalMs: DEFAULT_MS,
  historyEnabled: false,
  historyRetentionSecs: 86_400,
};

/** 1000 → "1 秒"，2500 → "2.5 秒" */
export function intervalLabel(ms: number): string {
  return ms % 1000 === 0 ? `${ms / 1000} 秒` : `${(ms / 1000).toFixed(1)} 秒`;
}

/** 保留时长文案：3600 → "1 小时"，5400 → "1.5 小时"，600 → "10 分钟" */
export function retentionLabel(secs: number): string {
  if (secs % 86_400 === 0) return `${secs / 86_400} 天`;
  if (secs % 3600 === 0) return `${secs / 3600} 小时`;
  if (secs % 60 === 0 && secs < 3600) return `${secs / 60} 分钟`;
  return `${(secs / 3600).toFixed(1)} 小时`;
}

/**
 * 应用设置。
 *
 * 真值在 Rust 那边（托盘菜单也能改），前端只是镜像：启动时拉一次，
 * 之后靠 `settings:changed` 事件同步，两边永远不会各说各话。
 */
export function useSettings() {
  const [settings, setSettings] = useState<AppSettings>(FALLBACK);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const off: UnlistenFn[] = [];
    let dead = false;

    (async () => {
      try {
        const s = await invoke<AppSettings>("get_settings");
        if (!dead) setSettings(s);
      } catch {
        /* 非 Tauri 环境（浏览器预览）下忽略 */
      }

      // 托盘里的「设置…」：主面板是被临时拉起来的，事件可能早于监听注册，
      // 所以后端还留了个标记，这里主动取一次。
      try {
        if (await invoke<boolean>("take_open_settings")) setOpen(true);
      } catch {
        /* ignore */
      }

      // 托盘改了频率 / 保留时长，主面板要跟着变
      off.push(
        await listen<AppSettings>("settings:changed", (e) => setSettings(e.payload)),
      );

      off.push(
        await listen("settings:open", async () => {
          setOpen(true);
          // 取走标记，否则下次重开面板又会自动弹出来
          try {
            await invoke("take_open_settings");
          } catch {
            /* ignore */
          }
        }),
      );

      if (dead) off.forEach((fn) => fn());
    })();

    return () => {
      dead = true;
      off.forEach((fn) => fn());
    };
  }, []);

  /** 只传要改的项；后端夹到合法区间后回传最终值，以后端为准 */
  const update = useCallback(async (patch: Partial<AppSettings>) => {
    try {
      setSettings(await invoke<AppSettings>("update_settings", { patch }));
    } catch {
      /* ignore */
    }
  }, []);

  return { settings, update, open, setOpen };
}

/** 点面板外面 / 按 Esc 关掉。传进来的 ref 是「不该被当成外面」的那块。 */
export function useDismiss(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    // mousedown 而不是 click：拖选文字松手在外面时不该误关
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);

  return ref;
}
