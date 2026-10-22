import { useEffect, useState } from "react";
import { HistoryChart } from "./HistoryChart";
import { clockLabel, sampleSeries, seriesStats, useHistory, useHistoryStats } from "../lib/useHistory";
import { bytes, rate } from "../lib/format";
import { retentionLabel } from "../lib/useSettings";
import type { HistPoint } from "../lib/types";

interface Props {
  retentionSecs: number;
  enabled: boolean;
  onClose: () => void;
  onOpenSettings: () => void;
}

/** 可选时间窗：1 小时 / 6 小时 / 24 小时 / 7 天 / 30 天 */
const RANGES = [3600, 21_600, 86_400, 604_800, 2_592_000];

function rangeLabel(secs: number | null): string {
  return secs == null ? "全部" : retentionLabel(secs);
}

type Metric = {
  key: keyof HistPoint;
  title: string;
  color: string;
  fmt: (v: number) => string;
};

const METRICS: Metric[] = [
  { key: "cpu", title: "CPU", color: "#22d3ee", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "mem", title: "内存", color: "#a78bfa", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "temp", title: "温度", color: "#fbbf24", fmt: (v) => `${v.toFixed(0)}°C` },
  { key: "rx", title: "网络 下行", color: "#38bdf8", fmt: (v) => rate(v) },
  { key: "disk", title: "磁盘 IO", color: "#34d399", fmt: (v) => rate(v) },
  { key: "gpu", title: "GPU", color: "#c084fc", fmt: (v) => `${v.toFixed(0)}%` },
];

/**
 * 历史回溯。
 *
 * 时间窗只列「保留时长以内」的档位：保留 24 小时的人点「7 天」只会看到一条直线，
 * 不如干脆不给他这个选项。
 */
export function HistoryModal({ retentionSecs, enabled, onClose, onOpenSettings }: Props) {
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
    return [first, Math.round((first + last) / 2), last].map((t) => clockLabel(t, withDate));
  })();

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal wide" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">历史记录</div>
            <div className="modal-sub">
              {stats
                ? `${stats.count.toLocaleString()} 条 · 占用 ${bytes(stats.bytes)} · 保留 ${retentionLabel(retentionSecs)}`
                : "正在读取…"}
            </div>
          </div>
          <div className="modal-actions">
            <button className="modal-close" onClick={onClose} title="关闭（Esc）">
              ×
            </button>
          </div>
        </div>

        <div className="modal-body">
          {!enabled && rows.length === 0 ? (
            <div className="hist-empty">
              <b>历史记录未开启</b>
              <span>开启后每 10 秒记一条，之后就能在这里回溯过去的状态。</span>
              <button className="btn-primary" onClick={onOpenSettings}>
                去设置里开启
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
                    {rangeLabel(r)}
                  </button>
                ))}
                <button
                  className={`chip${range === null ? " on" : ""}`}
                  onClick={() => setRange(null)}
                >
                  {rangeLabel(null)}
                </button>
                <span className="hist-hint">
                  {loading ? "读取中…" : `${rows.length.toLocaleString()} 个采样点`}
                </span>
              </div>

              {rows.length === 0 && !loading ? (
                <div className="hist-empty">
                  <b>这个时间窗里还没有数据</b>
                  <span>每 10 秒记一条，开着程序等一会儿就有了。</span>
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
                          {m.title}
                          <span>
                            峰值 <b>{m.fmt(s.max)}</b> · 均值 {m.fmt(s.avg)}
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

        <div className="modal-foot">
          每 10 秒记录一条（与采集频率无关）· 实线是区间内峰值，阴影是均值 ·
          数据只存在本机
        </div>
      </div>
    </div>
  );
}
