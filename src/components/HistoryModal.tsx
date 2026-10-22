import { useEffect, useState } from "react";
import { HistoryChart } from "./HistoryChart";
import { sampleSeries, seriesStats, useHistory, useHistoryStats } from "../lib/useHistory";
import { useI18n, type Key } from "../i18n";
import { bytes, rate } from "../lib/format";
import type { HistPoint } from "../lib/types";

interface Props {
  retentionSecs: number;
  enabled: boolean;
  onClose: () => void;
  onOpenSettings: () => void;
}

/** 可选时间窗：1 小时 / 6 小时 / 24 小时 / 7 天 / 30 天 */
const RANGES = [3600, 21_600, 86_400, 604_800, 2_592_000];

type Metric = {
  key: keyof HistPoint;
  titleKey: Key;
  color: string;
  fmt: (v: number) => string;
};

const METRICS: Metric[] = [
  { key: "cpu", titleKey: "hist.mCpu", color: "#22d3ee", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "mem", titleKey: "hist.mMem", color: "#a78bfa", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "temp", titleKey: "hist.mTemp", color: "#fbbf24", fmt: (v) => `${v.toFixed(0)}°C` },
  { key: "rx", titleKey: "hist.mRx", color: "#38bdf8", fmt: (v) => rate(v) },
  { key: "disk", titleKey: "hist.mDisk", color: "#34d399", fmt: (v) => rate(v) },
  { key: "gpu", titleKey: "hist.mGpu", color: "#c084fc", fmt: (v) => `${v.toFixed(0)}%` },
];

/**
 * 历史回溯。
 *
 * 时间窗只列「保留时长以内」的档位：保留 24 小时的人点「7 天」只会看到一条直线，
 * 不如干脆不给他这个选项。
 */
export function HistoryModal({ retentionSecs, enabled, onClose, onOpenSettings }: Props) {
  const i = useI18n();
  const options = RANGES.filter((r) => r <= retentionSecs);
  const [range, setRange] = useState<number | null>(
    options.length ? options[options.length - 1] : null,
  );
  const { rows, loading } = useHistory(range);
  const { stats } = useHistoryStats();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const withDate = (range ?? retentionSecs) > 86_400;
  const bucketsOf = (key: keyof HistPoint) => sampleSeries(rows, key);

  // 时间轴三档：起点 / 中点 / 终点
  const times = (() => {
    if (rows.length < 2) return ["", "", ""];
    const first = rows[0].t;
    const last = rows[rows.length - 1].t;
    return [first, Math.round((first + last) / 2), last].map((t) => i.clock(t, withDate));
  })();

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal wide" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{i.t("hist.title")}</div>
            <div className="modal-sub">
              {stats
                ? i.t("hist.sub", {
                    count: i.tn("p.records", stats.count),
                    size: bytes(stats.bytes),
                    ret: i.retention(retentionSecs),
                  })
                : i.t("common.reading")}
            </div>
          </div>
          <div className="modal-actions">
            <button className="modal-close" onClick={onClose} title={i.t("common.closeEsc")}>
              ×
            </button>
          </div>
        </div>

        <div className="modal-body">
          {!enabled && rows.length === 0 ? (
            <div className="hist-empty">
              <b>{i.t("hist.off")}</b>
              <span>{i.t("hist.offHint", { n: stats?.sampleSecs ?? 10 })}</span>
              <button className="btn-primary" onClick={onOpenSettings}>
                {i.t("hist.enable")}
              </button>
            </div>
          ) : (
            <>
              <div className="hist-ranges">
                {options.map((r) => (
                  <button
                    key={r}
                    className={`chip${range === r ? " on" : ""}`}
                    onClick={() => setRange(r)}
                  >
                    {i.retention(r)}
                  </button>
                ))}
                <button
                  className={`chip${range === null ? " on" : ""}`}
                  onClick={() => setRange(null)}
                >
                  {i.t("hist.all")}
                </button>
                <span className="hist-hint">
                  {loading
                    ? i.t("common.reading")
                    : i.tn("p.points", rows.length)}
                </span>
              </div>

              {rows.length === 0 && !loading ? (
                <div className="hist-empty">
                  <b>{i.t("hist.empty")}</b>
                  <span>{i.t("hist.emptyHint", { n: stats?.sampleSecs ?? 10 })}</span>
                </div>
              ) : (
                <div className="hist-grid">
                  {METRICS.filter(
                    (m) => m.key !== "gpu" || seriesStats(rows, "gpu").max > 0,
                  ).map((m) => {
                    const s = seriesStats(rows, m.key);
                    return (
                      <div className="hist-card" key={m.key}>
                        <div className="hist-card-h">
                          {i.t(m.titleKey)}
                          <span>
                            {i.t("hist.peak")} <b>{m.fmt(s.max)}</b> · {i.t("hist.avg")}{" "}
                            {m.fmt(s.avg)}
                          </span>
                        </div>
                        <HistoryChart
                          id={`hist-${m.key}`}
                          buckets={bucketsOf(m.key)}
                          color={m.color}
                          timeLabels={times}
                        />
                      </div>
                    );
                  })}
                </div>
              )}
            </>
          )}
        </div>

        <div className="modal-foot">{i.t("hist.foot", { n: stats?.sampleSecs ?? 10 })}</div>
      </div>
    </div>
  );
}
