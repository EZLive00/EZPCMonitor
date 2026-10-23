import { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Ring, Sparkline } from "./components/Charts";
import { useMetrics } from "./lib/useMetrics";
import { splitRate, tempColor } from "./lib/format";
import { initLocale, useI18n } from "./i18n";
import { initTheme } from "./lib/theme";
import type { WidgetMode } from "./lib/types";
import "./styles.css";

initLocale();
initTheme();

/** 从 localStorage 取上次的不透明度；真正的效果由 Rust 改 NSWindow.alphaValue 实现 */
function storedOpacity(): number {
  const v = Number(localStorage.getItem("ezpcm.opacity"));
  return v >= 0.3 && v <= 1 ? v : 1;
}

function compact(v: number): string {
  if (!v || v < 1) return "0";
  const u = ["B", "K", "M", "G"];
  let i = 0;
  let n = v;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i += 1;
  }
  return `${n < 10 ? n.toFixed(1) : Math.round(n)}${u[i]}`;
}

export default function Widget() {
  const { snap, series } = useMetrics(72);
  const i = useI18n();
  const [mode, setMode] = useState<WidgetMode>(() =>
    localStorage.getItem("ezpcm.mode") === "bar" ? "bar" : "card",
  );
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  // 紧凑条只有 46px 高，任何浮层都会被窗口边界裁掉，所以条模式下右键直接把整条换成操作按钮
  const [barMenu, setBarMenu] = useState(false);
  const [pinned, setPinned] = useState(true);
  const [opacity, setOpacity] = useState(storedOpacity);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    invoke("set_widget_mode", { mode }).catch(() => {});
    localStorage.setItem("ezpcm.mode", mode);
    setBarMenu(false);
  }, [mode]);

  useEffect(() => {
    localStorage.setItem("ezpcm.opacity", String(opacity));
  }, [opacity]);

  // 托盘菜单是另一条驱动链路：形态 / 不透明度都从那边推过来
  useEffect(() => {
    const offMode = listen<string>("widget:mode", (e) => {
      setMode(e.payload === "bar" ? "bar" : "card");
    });
    // 只有拿不到原生整窗透明度的平台才会让 css=true（macOS 由 Rust 直接改 NSWindow）
    const offOpacity = listen<{ value: number; css: boolean }>("widget:opacity", (e) => {
      const { value, css } = e.payload;
      if (value >= 0.3 && value <= 1) {
        setOpacity(value);
        if (css) document.documentElement.style.opacity = String(value);
      }
    });
    // 首帧把本地偏好告诉后端，让托盘勾选和实际状态一致
    invoke("sync_widget_prefs", { mode, opacity }).catch(() => {});
    return () => {
      offMode.then((f) => f()).catch(() => {});
      offOpacity.then((f) => f()).catch(() => {});
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    const close = () => {
      setMenu(null);
      setBarMenu(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    window.addEventListener("click", close);
    window.addEventListener("blur", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("blur", close);
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  const onContextMenu = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    const w = 140;
    const h = 168;
    setMenu({
      x: Math.min(e.clientX, window.innerWidth - w - 4),
      y: Math.min(e.clientY, window.innerHeight - h - 4),
    });
  }, []);

  const togglePin = useCallback(() => {
    setPinned((p) => {
      getCurrentWindow().setAlwaysOnTop(!p).catch(() => {});
      return !p;
    });
  }, []);


  const cpu = snap?.cpu.usage ?? 0;
  const memPct = snap && snap.mem.total > 0 ? (snap.mem.used / snap.mem.total) * 100 : 0;
  const primary = snap?.temps.find((t) => t.primary);
  const temp = primary?.value ?? 0;
  const mainDisk = snap?.disks[0];
  const diskPct = mainDisk && mainDisk.total > 0 ? (mainDisk.used / mainDisk.total) * 100 : 0;
  const rx = splitRate(snap?.net.rxBps ?? 0);
  const tx = splitRate(snap?.net.txBps ?? 0);

  const menuNode = menu && (
    <div className="ctx" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()}>
      <button onClick={() => setMode(mode === "card" ? "bar" : "card")}>
        {mode === "card" ? i.t("w.toBar") : i.t("w.toCard")}
      </button>
      <button
        onClick={() => {
          togglePin();
          setMenu(null);
        }}
      >
        {pinned ? i.t("w.unpin") : i.t("w.pin")}
        <span className="kbd">{pinned ? "ON" : "OFF"}</span>
      </button>
      <button
        onClick={() => {
          invoke("set_click_through", { on: true }).catch(() => {});
          setMenu(null);
        }}
      >
        {i.t("w.clickThrough")}
      </button>
      <button onClick={() => invoke("open_dashboard").catch(() => {})}>{i.t("w.openDash")}</button>
      <hr />
      <button className="danger" onClick={() => invoke("quit_app").catch(() => {})}>
        {i.t("w.quit")}
      </button>
    </div>
  );

  if (mode === "bar") {
    return (
      <div
        className="widget bar"
        data-tauri-drag-region
        onContextMenu={(e) => {
          e.preventDefault();
          setBarMenu(true);
        }}
        onDoubleClick={() => setMode("card")}
        ref={rootRef}
      >
        {barMenu ? (
          <div className="bar-actions">
            <button
              onClick={() => {
                setBarMenu(false);
                setMode("card");
              }}
              title={i.t("w.restoreCard")}
            >
              {i.t("w.card")}
            </button>
            <button className={pinned ? "on" : ""} onClick={togglePin} title={pinned ? i.t("w.unpin") : i.t("w.pin")}>
              {i.t("w.pinShort")}
            </button>
            <button
              onClick={() => {
                setBarMenu(false);
                invoke("set_click_through", { on: true }).catch(() => {});
              }}
              title={i.t("w.throughHint")}
            >
              {i.t("w.throughShort")}
            </button>
            <button
              onClick={() => {
                setBarMenu(false);
                invoke("open_dashboard").catch(() => {});
              }}
              title={i.t("w.openDash")}
            >
              {i.t("w.dashShort")}
            </button>
            <button className="danger" onClick={() => invoke("quit_app").catch(() => {})} title={i.t("w.quit")}>
              {i.t("w.quit")}
            </button>
          </div>
        ) : (
          <>
            <div className="bar-item">
              <span className="bar-k">CPU</span>
              <span className="bar-v">
                {Math.round(cpu)}
                <i>%</i>
              </span>
            </div>
            <div className="sep" />
            <div className="bar-item">
              <span className="bar-k">MEM</span>
              <span className="bar-v">
                {Math.round(memPct)}
                <i>%</i>
              </span>
            </div>
            <div className="sep" />
            <div className="bar-item">
              <span className="bar-v" style={{ color: primary ? tempColor(temp) : "var(--muted)" }}>
                {primary ? Math.round(temp) : "--"}
                <i>°C</i>
              </span>
            </div>
            <div className="sep" />
            <div className="bar-item">
              <span className="bar-v" style={{ fontSize: 11 }}>
                <i style={{ color: "var(--accent)" }}>↓</i>
                {compact(snap?.net.rxBps ?? 0)}
                <i style={{ color: "var(--accent-2)", marginLeft: 4 }}>↑</i>
                {compact(snap?.net.txBps ?? 0)}
              </span>
            </div>
          </>
        )}
      </div>
    );
  }

  return (
    <div
      className="widget"
      data-tauri-drag-region
      onContextMenu={onContextMenu}
      onDoubleClick={(e) => {
        // 双击卡片空白处开主面板（别抢按钮的点击）
        if ((e.target as HTMLElement).closest("button")) return;
        invoke("open_dashboard").catch(() => {});
      }}
      ref={rootRef}
    >
      <div className="w-head" data-tauri-drag-region>
        <span className="w-dot" />
        <span className="w-title" data-tauri-drag-region>
          EZPcMonitor
        </span>
        <div className="w-actions">
          <button className="w-btn" title={i.t("w.compact")} onClick={() => setMode("bar")}>
            <svg width="10" height="10" viewBox="0 0 10 10" fill="none">
              <rect x="0.5" y="3.2" width="9" height="1.6" rx="0.8" fill="currentColor" />
              <rect x="0.5" y="6.4" width="9" height="1.6" rx="0.8" fill="currentColor" opacity="0.5" />
            </svg>
          </button>
          <button
            className="w-btn w-close"
            title={i.t("w.hide")}
            onClick={() => invoke("toggle_widget").catch(() => {})}
          >
            <svg width="9" height="9" viewBox="0 0 9 9" fill="none">
              <path d="M1 1l7 7M8 1L1 8" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      </div>

      <div className="w-main" data-tauri-drag-region>
        <Ring id="rg-cpu" value={cpu} label="CPU" from="var(--c-cpu)" to="var(--c-cpu-2)" />
        <Ring id="rg-mem" value={memPct} label="MEM" from="var(--c-mem)" to="var(--c-mem-2)" />
        <div className="w-side" data-tauri-drag-region>
          <div className="w-temp">
            <span
              className="w-temp-num"
              style={{ color: primary ? tempColor(temp) : "var(--muted)" }}
            >
              {primary ? Math.round(temp) : "--"}
            </span>
            <span className="w-temp-unit">°C</span>
          </div>
          <div className="w-temp-label">TEMP</div>
        </div>
      </div>

      <div className="w-spark" data-tauri-drag-region>
        <Sparkline
          data={series.map((p) => p.cpu)}
          id="w-spark"
          height={34}
          minMax={20}
          color="var(--c-cpu)"
        />
      </div>

      <div className="w-foot" data-tauri-drag-region>
        <span>
          <span style={{ color: "var(--accent)" }}>↓</span> <b>{rx.value}</b> {rx.unit}
        </span>
        <div className="sep" />
        <span>
          <span style={{ color: "var(--accent-2)" }}>↑</span> <b>{tx.value}</b> {tx.unit}
        </span>
        <span className="push">
          <span style={{ color: "var(--dim)" }}>DISK</span>{" "}
          <b style={{ color: diskPct > 90 ? "var(--danger)" : "var(--text)" }}>
            {Math.round(diskPct)}%
          </b>
        </span>
      </div>

      {menuNode}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Widget />);
