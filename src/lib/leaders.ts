/**
 * 程序榜的维度 / 列 / 排序 —— 表格和报告图共用一套定义。
 *
 * 三个维度里只有两个半是真能按进程拿到的：
 * - CPU、内存：sysinfo 直接给；
 * - 磁盘：sysinfo 给的是「自启动以来的累计读写」，我们自己做差分得到速率；
 * - GPU、流量：操作系统都不提供按进程的拆分（macOS 的 ioreg 只有一个整卡数字），
 *   界面上标出来但不假装有数据——藏掉反而让人以为是漏做了。
 */
import type { ProcLeader } from "./types";
import { bytes, rate } from "./format";
import type { Key } from "../i18n";

export type DimKey = "cpu" | "mem" | "io";
export type ColKey = "mean" | "peak" | "active" | "growth";

const MB = 1_048_576;

export const DIMS: DimKey[] = ["cpu", "mem", "io"];

export const DIM_LABEL: Record<DimKey, Key> = {
  cpu: "hist.dimCpu",
  mem: "hist.dimMem",
  io: "hist.dimDisk",
};

export const COL_LABEL: Record<ColKey, Key> = {
  mean: "hist.colMean",
  peak: "hist.colPeak",
  active: "hist.colActive",
  growth: "hist.colGrowth",
};

/**
 * 每个维度看哪三列。
 *
 * CPU / 磁盘用「活跃占比」当第三列：它回答「是不是经常在干活」，
 * 跟均值互补——均值会被长时间待机摊薄，活跃占比不会。
 * 内存没有「活跃」这个概念（占着就是占着），换成窗口内的增长量，
 * 慢慢泄漏的程序在均值上看不出来，在增长上一眼就看得到。
 */
export const DIM_COLS: Record<DimKey, ColKey[]> = {
  cpu: ["mean", "peak", "active"],
  mem: ["mean", "peak", "growth"],
  io: ["mean", "peak", "active"],
};

export function colValue(r: ProcLeader, dim: DimKey, col: ColKey): number {
  if (dim === "mem") {
    if (col === "growth") return r.mem.lastMb - r.mem.firstMb;
    if (col === "peak") return r.mem.peakMb;
    return r.mem.meanMb;
  }
  const s = dim === "cpu" ? r.cpu : r.io;
  if (col === "peak") return s.peak;
  if (col === "active") return s.active;
  return s.mean;
}

/** 条形图的满格基准：取所有行的峰值，这样均值和峰值两个量级都能落在条里 */
export function barScale(rows: ProcLeader[], dim: DimKey): number {
  let m = 0;
  for (const r of rows) m = Math.max(m, colValue(r, dim, "peak"));
  return m || 1;
}

/** 数值 → 展示文本。内存内部存的是 MB，磁盘存的是 KB/s。 */
export function colFmt(dim: DimKey, col: ColKey, v: number): string {
  if (dim === "mem") {
    if (col === "growth") return `${v >= 0 ? "+" : "−"}${bytes(Math.abs(v) * MB, 0)}`;
    return bytes(v * MB, 0);
  }
  if (col === "active") return `${v.toFixed(0)}%`;
  if (dim === "io") return rate(v * 1024);
  return `${v.toFixed(1)}%`;
}

/** 峰值时刻：内存和 CPU 各记各的，取当前维度对应的那个 */
export function peakTs(r: ProcLeader, dim: DimKey): number {
  if (dim === "mem") return r.mem.peakTs;
  return dim === "cpu" ? r.cpu.peakTs : r.io.peakTs;
}

/**
 * 排序。`name` 兜底，不然同值的行每次重排都换位置，看着像在跳。
 */
export function sortRows(
  rows: ProcLeader[],
  dim: DimKey,
  col: ColKey,
  dir: "asc" | "desc",
): ProcLeader[] {
  const sign = dir === "desc" ? -1 : 1;
  return [...rows].sort((a, b) => {
    const d = colValue(a, dim, col) - colValue(b, dim, col);
    if (d !== 0) return d * sign;
    return a.name.localeCompare(b.name);
  });
}
