import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useHistoryStats } from "../lib/useHistory";
import { MAX_MS, MIN_MS, PRESETS } from "../lib/useSettings";
import { LANGS, useI18n, type Lang } from "../i18n";
import { THEMES, setTheme, useTheme } from "../lib/theme";
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

const UNITS: { key: string; secs: number; labelKey: "set.unitMin" | "set.unitHour" | "set.unitDay" }[] = [
  { key: "min", secs: 60, labelKey: "set.unitMin" },
  { key: "hour", secs: 3600, labelKey: "set.unitHour" },
  { key: "day", secs: 86_400, labelKey: "set.unitDay" },
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
  const i = useI18n();
  const { stats, reload } = useHistoryStats();
  const { choice: themeChoice } = useTheme();
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

  /** 当前生效的语言标签：`auto` 时显示系统语言那个选项为选中 */
  const activeLang: string = settings.language;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{i.t("set.title")}</div>
            <div className="modal-sub">{i.t("set.sub")}</div>
          </div>
          <div className="modal-actions">
            <button className="modal-close" onClick={onClose} title={i.t("common.closeEsc")}>
              ×
            </button>
          </div>
        </div>

        <div className="modal-body">
          {/* ---------------- 监控 ---------------- */}
          <div className="set-group">
            <div className="set-h">{i.t("set.group.monitor")}</div>
            <div className="set-row">
              <div className="set-label">
                {i.t("set.freq")}
                <span>{i.t("set.freqHint")}</span>
              </div>
              <div className="set-ctrl">
                <div className="freq-opts">
                  {PRESETS.map((p) => (
                    <button
                      key={p.ms}
                      className={`freq-opt${settings.intervalMs === p.ms ? " on" : ""}`}
                      onClick={() => update({ intervalMs: p.ms })}
                      title={`${i.interval(p.ms)} · ${i.t(p.hintKey)}`}
                    >
                      <b>{i.t(p.tierKey)}</b>
                      <span>{i.interval(p.ms)}</span>
                    </button>
                  ))}
                </div>
                <div className="inline-input">
                  <span>{i.t("common.custom")}</span>
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
                  <span>{i.t("set.unitSec")}</span>
                  <button
                    className="btn-primary sm"
                    disabled={!msValid}
                    onClick={() => update({ intervalMs: Math.round(ms * 1000) })}
                  >
                    {i.t("common.apply")}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* ---------------- 通用：主题 ---------------- */}
          <div className="set-group">
            <div className="set-h">{i.t("set.group.general")}</div>
            <div className="set-row">
              <div className="set-label">
                {i.t("set.theme")}
                <span>{i.t("set.themeHint")}</span>
              </div>
              <div className="set-ctrl">
                <div className="theme-opts">
                  {THEMES.map((th) => (
                    <button
                      key={th.value}
                      className={`theme-opt${themeChoice === th.value ? " on" : ""}`}
                      onClick={() => setTheme(th.value)}
                    >
                      {/* 色块是「这个主题长什么样」的预览，所以写死，不跟当前主题走 */}
                      <i className={th.value} />
                      {i.t(th.key)}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div className="set-row">
              <div className="set-label">
                {i.t("set.language")}
                <span>{i.t("set.languageHint")}</span>
              </div>
              <div className="set-ctrl">
                <div className="lang-opts">
                  <button
                    className={`lang-opt${activeLang === "auto" ? " on" : ""}`}
                    onClick={() => update({ language: "auto" })}
                  >
                    {i.t("set.langAuto")}
                  </button>
                  {LANGS.map((l) => (
                    <button
                      key={l.tag}
                      className={`lang-opt${activeLang === l.tag ? " on" : ""}`}
                      onClick={() => update({ language: l.tag as Lang })}
                      lang={l.tag}
                    >
                      {l.name}
                    </button>
                  ))}
                </div>
              </div>
            </div>
          </div>

          {/* ---------------- 历史记录 ---------------- */}
          <div className="set-group">
            <div className="set-h">
              {i.t("set.group.history")}
              <button className="set-link" onClick={onOpenHistory}>
                {i.t("set.viewHistory")}
              </button>
            </div>

            <div className="set-row">
              <div className="set-label">
                {i.t("set.record")}
                <span>{i.t("set.recordHint", { n: sampleSecs })}</span>
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
                {i.t("set.retention")}
                <span>{i.t("set.retentionHint")}</span>
              </div>
              <div className="set-ctrl">
                <div className="ret-opts">
                  {presets.map((p) => (
                    <button
                      key={p}
                      className={`ret-opt${settings.historyRetentionSecs === p ? " on" : ""}`}
                      onClick={() => update({ historyRetentionSecs: p })}
                    >
                      <b>{i.retention(p)}</b>
                      <span>{estimate(p)}</span>
                    </button>
                  ))}
                </div>
                <div className="inline-input">
                  <span>{i.t("common.custom")}</span>
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
                      {i.t(u.labelKey)}
                    </button>
                  ))}
                  <button
                    className="btn-primary sm"
                    disabled={!retentionValid}
                    onClick={() => update({ historyRetentionSecs: retentionSecs })}
                  >
                    {i.t("common.apply")}
                  </button>
                </div>
                {!retentionValid && (
                  <div className="set-note warn">
                    {i.t("set.range", {
                      min: i.retention(minRetention),
                      max: i.retention(maxRetention),
                    })}
                  </div>
                )}
              </div>
            </div>

            <div className="set-row">
              <div className="set-label">
                {i.t("set.usage")}
                <span>
                  {stats
                    ? i.t("set.usageHint", {
                        count: i.tn("p.records", stats.count),
                        b: stats.bytesPerRecord,
                      })
                    : i.t("common.reading")}
                </span>
              </div>
              <div className="set-ctrl right">
                <span className="set-value">{stats ? bytes(stats.bytes) : "—"}</span>
                <button className="mini" onClick={clearHistory} disabled={!stats || stats.count === 0}>
                  {i.t("set.clear")}
                </button>
              </div>
            </div>

            {settings.historyEnabled && (
              <div className="set-note">
                {i.t("set.estimate", {
                  ret: i.retention(settings.historyRetentionSecs),
                  size: estimate(settings.historyRetentionSecs),
                  n: sampleSecs,
                })}
              </div>
            )}
          </div>

          {/* ---------------- 关于 ---------------- */}
          <div className="set-group">
            <div className="set-h">{i.t("set.group.about")}</div>
            <div className="set-row">
              <div className="set-label">
                EZPcMonitor
                <span>{i.t("set.aboutHint")}</span>
              </div>
              <div className="set-ctrl right">
                <span className="set-value dim">v0.1.0</span>
              </div>
            </div>
          </div>
        </div>

        <div className="modal-foot">{i.t("set.foot")}</div>
      </div>
    </div>
  );
}
