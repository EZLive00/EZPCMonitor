import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useHistoryStats } from "../lib/useHistory";
import { MAX_MS, MIN_MS, PRESETS, intervalLabel, retentionLabel } from "../lib/useSettings";
import { bytes } from "../lib/format";
import type { AppSettings } from "../lib/types";

interface Props {
  settings: AppSettings;
  update: (patch: Partial<AppSettings>) => void;
  onClose: () => void;
  onOpenHistory: () => void;
}

/** 毫秒 → 输入框里的「秒」文本：1000 → "1"，2500 → "2.5" */
function secText(ms: number): string {
  return ms % 1000 === 0 ? String(ms / 1000) : (ms / 1000).toFixed(1);
}

const UNITS: { key: string; secs: number; label: string }[] = [
  { key: "min", secs: 60, label: "分钟" },
  { key: "hour", secs: 3600, label: "小时" },
  { key: "day", secs: 86_400, label: "天" },
];

/** 秒 → 最适合的输入单位，让 86400 显示成「1 天」而不是「24 小时」 */
function pickUnit(secs: number) {
  if (secs % 86_400 === 0) return UNITS[2];
  if (secs % 3600 === 0) return UNITS[1];
  return UNITS[0];
}

/**
 * 设置弹窗。
 *
 * 从右上角的齿轮、托盘菜单的「设置…」都能进；分组是为了以后加项时不至于变成一长条。
 * 所有改动都走 `update_settings` 一个命令——夹取、落盘、广播都在后端做一次，
 * 前端不重复实现规则。
 */
export function SettingsModal({ settings, update, onClose, onOpenHistory }: Props) {
  const { stats, reload } = useHistoryStats();
  const [draftMs, setDraftMs] = useState(secText(settings.intervalMs));

  const initialUnit = pickUnit(settings.historyRetentionSecs);
  const [unit, setUnit] = useState(initialUnit.key);
  const [amount, setAmount] = useState(String(settings.historyRetentionSecs / initialUnit.secs));

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // 外部（托盘）改了值，输入框跟着对齐
  useEffect(() => {
    setDraftMs(secText(settings.intervalMs));
    const u = pickUnit(settings.historyRetentionSecs);
    setUnit(u.key);
    setAmount(String(settings.historyRetentionSecs / u.secs));
  }, [settings.intervalMs, settings.historyRetentionSecs]);

  const sampleSecs = stats?.sampleSecs ?? 10;
  const bpr = stats?.bytesPerRecord ?? 88;
  const presets = stats?.presets ?? [3600, 21_600, 86_400, 604_800, 2_592_000];
  const minRetention = stats?.minRetentionSecs ?? 600;
  const maxRetention = stats?.maxRetentionSecs ?? 7_776_000;

  /** 某档保留时长的预计占用 */
  const estimate = (secs: number) => bytes((secs / sampleSecs) * bpr);

  const ms = Number(draftMs);
  const msValid = Number.isFinite(ms) && ms * 1000 >= MIN_MS && ms * 1000 <= MAX_MS;

  const unitSecs = UNITS.find((u) => u.key === unit)?.secs ?? 3600;
  const retentionSecs = Math.round(Number(amount) * unitSecs);
  const retentionValid =
    Number.isFinite(retentionSecs) && retentionSecs >= minRetention && retentionSecs <= maxRetention;

  const clearHistory = async () => {
    try {
      await invoke("clear_history");
    } catch {
      /* ignore */
    }
    reload();
  };

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">设置</div>
            <div className="modal-sub">所有设置都存在本机，不上传任何数据</div>
          </div>
          <div className="modal-actions">
            <button className="modal-close" onClick={onClose} title="关闭（Esc）">
              ×
            </button>
          </div>
        </div>

        <div className="modal-body">
          {/* ---------------- 监控 ---------------- */}
          <div className="set-group">
            <div className="set-h">监控</div>
            <div className="set-row">
              <div className="set-label">
                采集频率
                <span>越短越灵敏，越长越省电</span>
              </div>
              <div className="set-ctrl">
                <div className="freq-opts">
                  {PRESETS.map((p) => (
                    <button
                      key={p.ms}
                      className={`freq-opt${settings.intervalMs === p.ms ? " on" : ""}`}
                      onClick={() => update({ intervalMs: p.ms })}
                      title={p.hint}
                    >
                      <b>{p.tier}</b>
                      <span>{intervalLabel(p.ms)}</span>
                    </button>
                  ))}
                </div>
                <div className="inline-input">
                  <span>自定义</span>
                  <input
                    value={draftMs}
                    onChange={(e) => setDraftMs(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && msValid) update({ intervalMs: Math.round(ms * 1000) });
                    }}
                    inputMode="decimal"
                    spellCheck={false}
                    className={msValid ? undefined : "bad"}
                  />
                  <span>秒</span>
                  <button
                    className="btn-primary sm"
                    disabled={!msValid}
                    onClick={() => update({ intervalMs: Math.round(ms * 1000) })}
                  >
                    应用
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* ---------------- 历史记录 ---------------- */}
          <div className="set-group">
            <div className="set-h">
              历史记录
              <button className="set-link" onClick={onOpenHistory}>
                查看历史 ›
              </button>
            </div>

            <div className="set-row">
              <div className="set-label">
                记录历史
                <span>每 {sampleSecs} 秒一条，与采集频率无关</span>
              </div>
              <div className="set-ctrl right">
                <button
                  className={`switch${settings.historyEnabled ? " on" : ""}`}
                  role="switch"
                  aria-checked={settings.historyEnabled}
                  onClick={() => update({ historyEnabled: !settings.historyEnabled })}
                >
                  <i />
                </button>
              </div>
            </div>

            <div className="set-row">
              <div className="set-label">
                保留时长
                <span>超期记录会自动删除</span>
              </div>
              <div className="set-ctrl">
                <div className="ret-opts">
                  {presets.map((p) => (
                    <button
                      key={p}
                      className={`ret-opt${settings.historyRetentionSecs === p ? " on" : ""}`}
                      onClick={() => update({ historyRetentionSecs: p })}
                    >
                      <b>{retentionLabel(p)}</b>
                      <span>{estimate(p)}</span>
                    </button>
                  ))}
                </div>
                <div className="inline-input">
                  <span>自定义</span>
                  <input
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === "Enter" && retentionValid)
                        update({ historyRetentionSecs: retentionSecs });
                    }}
                    inputMode="decimal"
                    spellCheck={false}
                    className={retentionValid ? undefined : "bad"}
                  />
                  {UNITS.map((u) => (
                    <button
                      key={u.key}
                      className={`chip tiny${unit === u.key ? " on" : ""}`}
                      onClick={() => setUnit(u.key)}
                    >
                      {u.label}
                    </button>
                  ))}
                  <button
                    className="btn-primary sm"
                    disabled={!retentionValid}
                    onClick={() => update({ historyRetentionSecs: retentionSecs })}
                  >
                    应用
                  </button>
                </div>
                {!retentionValid && (
                  <div className="set-note warn">
                    请填 {retentionLabel(minRetention)} 到 {retentionLabel(maxRetention)} 之间
                  </div>
                )}
              </div>
            </div>

            <div className="set-row">
              <div className="set-label">
                当前占用
                <span>
                  {stats
                    ? `${stats.count.toLocaleString()} 条 · 每条约 ${stats.bytesPerRecord} 字节`
                    : "读取中…"}
                </span>
              </div>
              <div className="set-ctrl right">
                <span className="set-value">{stats ? bytes(stats.bytes) : "—"}</span>
                <button className="mini" onClick={clearHistory} disabled={!stats || stats.count === 0}>
                  清空
                </button>
              </div>
            </div>

            {settings.historyEnabled && (
              <div className="set-note">
                按当前设置，保留 {retentionLabel(settings.historyRetentionSecs)} 约占
                {" "}
                {estimate(settings.historyRetentionSecs)}（每 10 秒一条）。
              </div>
            )}
          </div>

          {/* ---------------- 关于 ---------------- */}
          <div className="set-group">
            <div className="set-h">关于</div>
            <div className="set-row">
              <div className="set-label">
                EZPcMonitor
                <span>Tauri 2 · Rust · 数据全部在本机采集</span>
              </div>
              <div className="set-ctrl right">
                <span className="set-value dim">v0.1.0</span>
              </div>
            </div>
          </div>
        </div>

        <div className="modal-foot">
          改完立即生效，不需要重启。历史文件在应用数据目录下的 history.jsonl，随时可以清空。
        </div>
      </div>
    </div>
  );
}
