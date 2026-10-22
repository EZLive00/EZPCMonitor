import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import type { HistPoint, HistoryStats } from "./types";

/** 历史文件现状（条数 / 占用 / 每条大小）。设置弹窗和历史弹窗都要用。 */
export function useHistoryStats() {
  const [stats, setStats] = useState<HistoryStats | null>(null);

  const reload = useCallback(async () => {
    try {
      setStats(await invoke<HistoryStats>("history_stats"));
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  return { stats, reload };
}

/**
 * 按时间范围拉历史点。`null` = 不限起点（受保留时长约束）。
 *
 * 一次性拉全量而不是分页：最多几万条、十几 MB，一次读完比翻页简单，
 * 也避免拖动时间轴时反复发请求。
 */
export function useHistory(rangeSecs: number | null) {
  const [rows, setRows] = useState<HistPoint[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let dead = false;
    setLoading(true);
    const from = rangeSecs ? Math.floor(Date.now() / 1000) - rangeSecs : null;
    invoke<HistPoint[]>("history_range", { from })
      .then((r) => {
        if (dead) return;
        setRows(r);
        setLoading(false);
      })
      .catch(() => {
        if (dead) return;
        setRows([]);
        setLoading(false);
      });
    return () => {
      dead = true;
    };
  }, [rangeSecs]);

  return { rows, loading };
}

export interface Bucket {
  t: number;
  /** 桶内均值：代表「常态」 */
  avg: number;
  /** 桶内峰值：代表「最坏的那一下」 */
  max: number;
}

/**
 * 把几万个点压成 ~180 个桶。
 *
 * 直接用均值会抹掉尖峰（CPU 飙到 100% 的那 10 秒会被平均成 20%），
 * 所以每桶同时保留 avg 和 max：画线用 max，填充用 avg。
 */
export function sampleSeries(rows: HistPoint[], key: keyof HistPoint, buckets = 180): Bucket[] {
  if (rows.length === 0) return [];
  const val = (r: HistPoint) => Number(r[key]) || 0;
  if (rows.length <= buckets) {
    return rows.map((r) => ({ t: r.t, avg: val(r), max: val(r) }));
  }
  const out: Bucket[] = [];
  const step = rows.length / buckets;
  for (let i = 0; i < buckets; i++) {
    const start = Math.floor(i * step);
    const end = Math.max(start + 1, Math.floor((i + 1) * step));
    let sum = 0;
    let peak = -Infinity;
    for (let j = start; j < end; j++) {
      const v = val(rows[j]);
      sum += v;
      if (v > peak) peak = v;
    }
    const n = end - start;
    out.push({ t: rows[start].t, avg: sum / n, max: peak === -Infinity ? 0 : peak });
  }
  return out;
}

/** 整段区间的均值与峰值（用原始点算，不经过分桶） */
export function seriesStats(rows: HistPoint[], key: keyof HistPoint) {
  if (rows.length === 0) return { avg: 0, max: 0 };
  let sum = 0;
  let peak = 0;
  for (const r of rows) {
    const v = Number(r[key]) || 0;
    sum += v;
    if (v > peak) peak = v;
  }
  return { avg: sum / rows.length, max: peak };
}

/** unix 秒 → "14:05"（跨天时补上日期 "10-22 14:05"） */
export function clockLabel(ts: number, withDate = false): string {
  const d = new Date(ts * 1000);
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  if (!withDate) return hm;
  return `${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${hm}`;
}
