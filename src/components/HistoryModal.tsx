import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { HistoryChart } from "./HistoryChart";
import { ProcLeaders } from "./ProcLeaders";
import {
  fetchLeaders,
  sampleSeries,
  seriesStats,
  useHistory,
  useHistoryStats,
} from "../lib/useHistory";
import { useI18n, type Key } from "../i18n";
import { bytes, rate } from "../lib/format";
import { renderReport, reportName } from "../lib/report";
import type { HistPoint, ProcLeaders as ProcLeadersData } from "../lib/types";

interface Props {
  retentionSecs: number;
  enabled: boolean;
  host: string;
  os: string;
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
  { key: "cpu", titleKey: "hist.mCpu", color: "var(--c-cpu)", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "mem", titleKey: "hist.mMem", color: "var(--c-mem)", fmt: (v) => `${v.toFixed(0)}%` },
  { key: "temp", titleKey: "hist.mTemp", color: "var(--c-temp)", fmt: (v) => `${v.toFixed(0)}°C` },
  { key: "rx", titleKey: "hist.mRx", color: "var(--c-rx)", fmt: (v) => rate(v) },
  { key: "disk", titleKey: "hist.mDisk", color: "var(--c-disk)", fmt: (v) => rate(v) },
  { key: "gpu", titleKey: "hist.mGpu", color: "var(--c-gpu)", fmt: (v) => `${v.toFixed(0)}%` },
];

/**
 * 历史回溯。两种看法，同一份数据：
 *
 * - **曲线**：整机各指标的走势，回答「什么时候卡的」；
 * - **程序**：按进程名合并后的高占用榜，回答「是谁卡的」。
 *
 * 时间窗只列「保留时长以内」的档位：保留 24 小时的人点「7 天」只会看到一条直线，
 * 不如干脆不给他这个选项。程序榜跟曲线共用同一个窗口——它本来就是从同一段
 * 历史里算出来的，再给一套时间选择只会让人怀疑两边对不上。
 */
export function HistoryModal({
  retentionSecs,
  enabled,
  host,
  os,
  onClose,
  onOpenSettings,
}: Props) {
  const i = useI18n();
  const options = RANGES.filter((r) => r <= retentionSecs);
  const [range, setRange] = useState<number | null>(
    options.length ? options[options.length - 1] : null,
  );
  const [view, setView] = useState<"chart" | "proc">("chart");
  const { rows, loading } = useHistory(range);
  const { stats } = useHistoryStats();
  const [leaders, setLeaders] = useState<ProcLeadersData | null>(null);
  const [busy, setBusy] = useState<"report" | "copy" | null>(null);
  const [flash, setFlash] = useState("");

  // 报告图里要有程序榜，所以进弹窗就把榜取回来——不管当前在看哪个视图。
  // 曲线那份数据本来就几十万个点，多这一次目录扫描量级上算不上什么。
  useEffect(() => {
    let dead = false;
    setLeaders(null);
    fetchLeaders(range)
      .then((d) => {
        if (!dead) setLeaders(d);
      })
      .catch(() => {
        /* 拿不到就当没有 */
      });
    return () => {
      dead = true;
    };
  }, [range]);

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

  /**
   * 出图。两个按钮走同一条路：先落盘，再决定要不要放进剪贴板。
   * 复制也得有文件——macOS 那条通道读的就是文件。
   */
  const makeReport = async (copy: boolean) => {
    if (busy) return;
    setBusy(copy ? "copy" : "report");
    try {
      const now = Math.floor(Date.now() / 1000);
      const blob = await renderReport({
        host,
        os,
        rangeLabel: i.retention(range ?? retentionSecs),
        points: rows,
        procs: leaders?.rows ?? [],
        now,
        withDate,
        t: i.t,
        num: i.num,
        clock: i.clock,
      });
      const png = Array.from(new Uint8Array(await blob.arrayBuffer()));
      const path = await invoke<string>("save_report", { png, name: reportName(now) });

      if (copy) {
        try {
          await invoke("copy_image", { path });
        } catch {
          // 非 macOS，或者 osascript 被拦了：退回复制文件路径，至少还能粘到别处
          await navigator.clipboard?.writeText(path);
        }
        setFlash(i.t("hist.copied"));
      } else {
        setFlash(i.t("hist.reportSaved"));
      }
    } catch {
      setFlash(i.t("hist.copyFail"));
    } finally {
      setBusy(null);
      window.setTimeout(() => setFlash(""), 4000);
    }
  };

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
                    size: bytes(stats.bytes + stats.procBytes),
                    ret: i.retention(retentionSecs),
                  })
                : i.t("common.reading")}
            </div>
          </div>
          <div className="modal-actions">
            <span className={`hist-flash${flash ? " on" : ""}`}>{flash}</span>
            <span className="sort-tabs">
              <button
                className={view === "chart" ? "on" : undefined}
                onClick={() => setView("chart")}
              >
                {i.t("hist.viewCurve")}
              </button>
              <button
                className={view === "proc" ? "on" : undefined}
                onClick={() => setView("proc")}
              >
                {i.t("hist.viewProc")}
              </button>
            </span>
            <button
              className="mini"
              disabled={busy !== null || rows.length === 0}
              onClick={() => makeReport(false)}
            >
              {busy === "report" ? i.t("hist.reporting") : i.t("hist.report")}
            </button>
            <button
              className="mini"
              disabled={busy !== null || rows.length === 0}
              onClick={() => makeReport(true)}
            >
              {i.t("hist.copy")}
            </button>
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
                {view === "chart" && (
                  <span className="hist-hint">
                    {loading ? i.t("common.reading") : i.tn("p.points", rows.length)}
                  </span>
                )}
              </div>

              {view === "chart" ? (
                rows.length === 0 && !loading ? (
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
                )
              ) : (
                <ProcLeaders data={leaders} loading={leaders === null} withDate={withDate} />
              )}
            </>
          )}
        </div>

        <div className="modal-foot">
          {view === "proc"
            ? i.t("hist.procFoot", { n: stats?.procSampleSecs ?? 30 })
            : i.t("hist.foot", { n: stats?.sampleSecs ?? 10 })}
        </div>
      </div>
    </div>
  );
}
