import { useMemo, useState } from "react";
import { useI18n } from "../i18n";
import {
  COL_LABEL,
  DIM_COLS,
  DIM_LABEL,
  DIMS,
  barScale,
  colFmt,
  colValue,
  peakTs,
  sortRows,
  type ColKey,
  type DimKey,
} from "../lib/leaders";
import type { ProcLeaders as ProcLeadersData } from "../lib/types";

/** 榜上显示几名。10 名之后的基本都是背景进程，多了只是噪音。 */
const TOP = 10;

interface Props {
  data: ProcLeadersData | null;
  loading: boolean;
  /** 跨天的时间窗要把日期也标上，否则「峰值 08:12」不知道是哪天的 */
  withDate: boolean;
}

/**
 * 高占用程序榜。
 *
 * 排序在本地做：后端一次把三个维度全算好了，切维度、点表头都不用再读文件。
 * **默认按峰值排**——按均值排的话，一个平时 2%、偶尔飙到 96% 的备份程序
 * 永远进不了前十，而那恰恰是最需要被看见的那种。
 */
export function ProcLeaders({ data, loading, withDate }: Props) {
  const i = useI18n();
  const [dim, setDim] = useState<DimKey>("cpu");
  const [col, setCol] = useState<ColKey>("peak");
  const [dir, setDir] = useState<"asc" | "desc">("desc");

  const rows = data?.rows ?? [];
  const sorted = useMemo(
    () => sortRows(rows, dim, col, dir).slice(0, TOP),
    [rows, dim, col, dir],
  );
  const scale = useMemo(() => barScale(sorted, dim), [sorted, dim]);

  const pick = (d: DimKey) => {
    setDim(d);
    // 「增长」只在内存维度里有，切到别的维度得退回一个存在的列
    if (!DIM_COLS[d].includes(col)) setCol("peak");
  };

  const onSort = (c: ColKey) => {
    if (c === col) {
      setDir(dir === "desc" ? "asc" : "desc");
    } else {
      setCol(c);
      setDir("desc");
    }
  };

  return (
    <>
      <div className="pl-dims">
        {DIMS.map((d) => (
          <button
            key={d}
            className={`chip${dim === d ? " on" : ""}`}
            onClick={() => pick(d)}
          >
            {i.t(DIM_LABEL[d])}
          </button>
        ))}
        {/* 系统不提供按进程的 GPU / 流量，标出来但点不动：
            藏掉会让人以为漏做了（跟磁盘那边的处理一致） */}
        <button className="chip" disabled title={i.t("hist.dimUnsupported", { v: i.t("hist.dimGpu") })}>
          {i.t("hist.dimGpu")}
        </button>
        <button className="chip" disabled title={i.t("hist.dimUnsupported", { v: i.t("hist.dimNet") })}>
          {i.t("hist.dimNet")}
        </button>
        <span className="hist-hint">
          {loading ? i.t("common.reading") : i.t("hist.procTotal", { n: i.num(data?.total ?? 0) })}
        </span>
      </div>

      {!loading && rows.length === 0 ? (
        <div className="hist-empty">
          <b>{i.t("hist.procEmpty")}</b>
          <span>{i.t("hist.procEmptyHint", { n: data?.sampleSecs ?? 30 })}</span>
        </div>
      ) : (
        <table className="pl-table">
          <thead>
            <tr>
              <th className="pl-rank" />
              <th>{i.t("hist.colProc")}</th>
              {DIM_COLS[dim].map((c) => (
                <th
                  key={c}
                  className={`pl-sort${c === col ? " on" : ""}`}
                  onClick={() => onSort(c)}
                >
                  {i.t(COL_LABEL[c])}
                  <b className="pl-arrow">{c === col ? (dir === "desc" ? "▼" : "▲") : ""}</b>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {sorted.map((r, idx) => {
              const mean = colValue(r, dim, "mean");
              const peak = colValue(r, dim, "peak");
              const meanPct = Math.min(100, (mean / scale) * 100);
              const peakPct = Math.min(100 - meanPct, ((peak - mean) / scale) * 100);
              return (
                <tr key={r.name}>
                  <td className="pl-rank">{idx + 1}</td>
                  <td className="name" title={r.name}>
                    {r.name}
                  </td>
                  {DIM_COLS[dim].map((c) => (
                    <td key={c} className="pl-num">
                      {c === "mean" && (
                        <span className="pl-bar" aria-hidden>
                          <i style={{ width: `${meanPct}%` }} />
                          <b style={{ left: `${meanPct}%`, width: `${Math.max(0, peakPct)}%` }} />
                        </span>
                      )}
                      <span
                        title={
                          c === "peak"
                            ? i.t("hist.peakAt", {
                                v: colFmt(dim, c, colValue(r, dim, c)),
                                t: i.clock(peakTs(r, dim), withDate),
                              })
                            : undefined
                        }
                      >
                        {colFmt(dim, c, colValue(r, dim, c))}
                      </span>
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
}
