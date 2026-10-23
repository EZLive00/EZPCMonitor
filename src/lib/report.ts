/**
 * 一键报告图。
 *
 * 走的是 **SVG 字符串 → `<img>` → `<canvas>` → `toBlob`** 这条路，而不是
 * html2canvas 之类的库：报告就一张静态图，用浏览器自己的排版引擎最省事，
 * 也不必为一个功能拖进来 200KB 依赖。
 *
 * 三个必须记住的坑：
 *
 * 1. **SVG 里不能用 CSS 变量**。它被塞进 `<img>` 之后就是一个独立文档，
 *    拿不到页面上的 `:root`。所以颜色必须在这里用 `getComputedStyle`
 *    解析成字面量再写进去——顺便也就跟着当前主题走了。
 * 2. **`--line` / `--grid` 解析不出来**。它们本身是 `rgba(var(--ovl), α)`，
 *    自定义属性的值不会在 `getPropertyValue` 里展开，只能自己拼。
 * 3. **`<img>` 的 src 只能用 `data:`**。CSP 写的是 `img-src 'self' data:`，
 *    用 `blob:` 会被直接拦掉，而且拦得很安静——画出来是一张白图。
 */
import type { Key } from "../i18n";
import type { HistPoint, ProcLeader } from "./types";
import { sampleSeries } from "./useHistory";
import { colFmt } from "./leaders";
import { rate } from "./format";

const W = 1080;
const PAD = 56;
const CONTENT = W - PAD * 2;
/** 导出倍率：2× 在 Retina 上才不糊，1080 宽最终是 2160×N 的 PNG */
const SCALE = 2;

export interface ReportInput {
  host: string;
  os: string;
  rangeLabel: string;
  points: HistPoint[];
  procs: ProcLeader[];
  now: number;
  withDate: boolean;
  t: (key: Key, vars?: Record<string, string | number>) => string;
  num: (n: number, frac?: number) => string;
  clock: (ts: number, withDate?: boolean) => string;
}

function cssVar(name: string): string {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || "#888";
}

function palette() {
  return {
    bg: cssVar("--report-bg"),
    text: cssVar("--text"),
    muted: cssVar("--muted"),
    dim: cssVar("--dim"),
    ovl: cssVar("--ovl"),
    accent: cssVar("--accent"),
    cpu: cssVar("--c-cpu"),
    mem: cssVar("--c-mem"),
    temp: cssVar("--c-temp"),
    disk: cssVar("--c-disk"),
    rx: cssVar("--c-rx"),
    gpu: cssVar("--c-gpu"),
  };
}

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

const r1 = (n: number) => Math.round(n * 10) / 10;

function txt(
  x: number,
  y: number,
  s: string,
  size: number,
  weight: number,
  fill: string,
  anchor: "start" | "middle" | "end" = "start",
): string {
  return `<text x="${r1(x)}" y="${r1(y)}" font-size="${size}" font-weight="${weight}" fill="${fill}" text-anchor="${anchor}">${esc(s)}</text>`;
}

/** 按「半个字宽」估长度截断：SVG 不会自动换行，名字太长会顶到右边的数字上 */
function clip(s: string, units: number): string {
  let w = 0;
  let out = "";
  for (const ch of s) {
    const cw = /[\u1100-\u11ff\u2e80-\ua4cf\ua960-\ua97f\uac00-\ud7ff\uf900-\ufaff\uff00-\uff60]/.test(ch)
      ? 2
      : 1;
    if (w + cw > units) return `${out}…`;
    w += cw;
    out += ch;
  }
  return out;
}

interface Cell {
  x: number;
  y: number;
  w: number;
  h: number;
}

function linePath(vals: number[], c: Cell, max: number): string {
  if (vals.length === 0) return "";
  const step = vals.length > 1 ? c.w / (vals.length - 1) : 0;
  return vals
    .map((v, i) => {
      const x = c.x + i * step;
      const y = c.y + c.h - (Math.min(v, max) / max) * c.h;
      return `${i ? "L" : "M"}${r1(x)} ${r1(y)}`;
    })
    .join(" ");
}

function spark(
  vals: number[],
  c: Cell,
  max: number,
  color: string,
  ovl: string,
): string {
  if (vals.length === 0) return "";
  const path = linePath(vals, c, max);
  const area = `${path} L${r1(c.x + c.w)} ${r1(c.y + c.h)} L${r1(c.x)} ${r1(c.y + c.h)} Z`;
  const peakIdx = vals.reduce((bi, v, i) => (v > vals[bi] ? i : bi), 0);
  const step = vals.length > 1 ? c.w / (vals.length - 1) : 0;
  const px = c.x + peakIdx * step;
  const py = c.y + c.h - (Math.min(vals[peakIdx], max) / max) * c.h;
  return [
    `<path d="${area}" fill="${color}" fill-opacity="0.1"/>`,
    // 峰值位置打一条虚线：报告要能一眼指出「最坏的那一下在哪」
    `<line x1="${r1(px)}" y1="${r1(py)}" x2="${r1(px)}" y2="${r1(c.y + c.h)}" stroke="${color}" stroke-opacity="0.45" stroke-width="1" stroke-dasharray="3 4"/>`,
    `<path d="${path}" fill="none" stroke="${color}" stroke-width="1.8" stroke-linejoin="round" stroke-linecap="round"/>`,
    `<circle cx="${r1(px)}" cy="${r1(py)}" r="3.2" fill="${color}"/>`,
    `<line x1="${r1(c.x)}" y1="${r1(c.y + c.h)}" x2="${r1(c.x + c.w)}" y2="${r1(c.y + c.h)}" stroke="rgba(${ovl}, 0.09)" stroke-width="1"/>`,
  ].join("");
}

/** 生成 SVG 字符串。抽出来是为了能单独调版面，不必每次都跑一遍 canvas。 */
function buildSvg(input: ReportInput): string {
  const { t, num, clock, points, procs, now } = input;
  const p = palette();
  const parts: string[] = [];

  // ---- 头部 ----
  let y = PAD + 22;
  parts.push(txt(PAD, y, t("rep.title"), 30, 700, p.text));
  parts.push(txt(W - PAD, y, input.rangeLabel, 15, 600, p.accent, "end"));
  y += 26;
  parts.push(txt(PAD, y, `${input.host} · ${input.os}`, 14, 400, p.dim));

  // ---- 结论条 ----
  y += 22;
  const stripY = y;
  const stripH = 92;
  parts.push(
    `<rect x="${PAD}" y="${stripY}" width="${CONTENT}" height="${stripH}" rx="16" fill="rgba(${p.ovl}, 0.045)" stroke="rgba(${p.ovl}, 0.08)"/>`,
  );

  const cpuSeries = sampleSeries(points, "cpu", 400);
  const cpuPeak = cpuSeries.reduce((m, b) => Math.max(m, b.max), 0);
  const peakAt = points.length
    ? points.reduce((bi, r, i) => (r.cpu > points[bi].cpu ? i : bi), 0)
    : -1;
  const topProc = procs.length
    ? [...procs].sort((a, b) => b.cpu.mean - a.cpu.mean)[0]
    : null;

  parts.push(
    txt(
      PAD + 22,
      stripY + 38,
      `${t("rep.peak")}  ${t("hist.mCpu")} ${cpuPeak.toFixed(0)}%${
        peakAt >= 0 ? ` · ${clock(points[peakAt].t, input.withDate)}` : ""
      }`,
      18,
      700,
      p.text,
    ),
  );
  parts.push(
    txt(
      PAD + 22,
      stripY + 66,
      topProc
        ? `${clip(topProc.name, 34)} · ${t("hist.colMean")} ${colFmt("cpu", "mean", topProc.cpu.mean)} · ${t("hist.colPeak")} ${colFmt("cpu", "peak", topProc.cpu.peak)}`
        : t("rep.noProc"),
      14,
      400,
      p.muted,
    ),
  );
  y = stripY + stripH + 30;

  // ---- 2×N 曲线 ----
  const metrics = (
    [
      { key: "cpu", label: "hist.mCpu", color: p.cpu, fmt: (v: number) => `${v.toFixed(0)}%` },
      { key: "mem", label: "hist.mMem", color: p.mem, fmt: (v: number) => `${v.toFixed(0)}%` },
      { key: "temp", label: "hist.mTemp", color: p.temp, fmt: (v: number) => `${v.toFixed(0)}°C` },
      { key: "disk", label: "hist.mDisk", color: p.disk, fmt: (v: number) => rate(v) },
      { key: "rx", label: "hist.mRx", color: p.rx, fmt: (v: number) => rate(v) },
      { key: "gpu", label: "hist.mGpu", color: p.gpu, fmt: (v: number) => `${v.toFixed(0)}%` },
    ] as { key: keyof HistPoint; label: Key; color: string; fmt: (v: number) => string }[]
  ).filter((m) => m.key !== "gpu" || points.some((r) => (r.gpu ?? 0) > 0));
  // 两列排布，奇数个会留一个空格，干脆去掉最后一个
  if (metrics.length % 2 === 1) metrics.pop();

  const GAP = 24;
  const CW = (CONTENT - GAP) / 2;
  const CH = 196;

  metrics.forEach((m, idx) => {
    const col = idx % 2;
    const row = Math.floor(idx / 2);
    const x = PAD + col * (CW + GAP);
    const top = y + row * (CH + GAP);
    const buckets = sampleSeries(points, m.key, 160);
    const peak = buckets.reduce((a, b) => Math.max(a, b.max), 0);

    parts.push(txt(x, top + 14, t(m.label), 13, 600, p.muted));
    parts.push(txt(x + CW, top + 14, `${t("rep.peak")} ${m.fmt(peak)}`, 12, 400, p.dim, "end"));
    parts.push(
      spark(
        buckets.map((b) => b.max),
        { x, y: top + 26, w: CW, h: CH - 40 },
        Math.max(peak, 1),
        m.color,
        p.ovl,
      ),
    );
  });
  y += Math.ceil(metrics.length / 2) * (CH + GAP) + 14;

  // ---- 高占用程序 ----
  parts.push(txt(PAD, y, t("rep.top"), 15, 700, p.muted));
  parts.push(txt(W - PAD, y, t("rep.topHint"), 13, 400, p.dim, "end"));
  y += 14;

  const top5 = [...procs].sort((a, b) => b.cpu.mean - a.cpu.mean).slice(0, 5);
  const barMax = top5.reduce((m, r) => Math.max(m, r.cpu.peak), 1);
  const ROW = 74;

  if (top5.length === 0) {
    parts.push(txt(PAD, y + 34, t("rep.noProc"), 14, 400, p.dim));
    y += 56;
  }

  top5.forEach((r, i) => {
    const ry = y + i * ROW + 22;
    const meanW = (r.cpu.mean / barMax) * CONTENT;
    const peakW = Math.max(0, ((r.cpu.peak - r.cpu.mean) / barMax) * CONTENT);
    parts.push(txt(PAD, ry, clip(r.name, 44), 16, 600, p.text));
    parts.push(txt(W - PAD, ry, colFmt("cpu", "mean", r.cpu.mean), 17, 700, p.text, "end"));
    parts.push(
      `<rect x="${PAD}" y="${ry + 12}" width="${CONTENT}" height="7" rx="3.5" fill="rgba(${p.ovl}, 0.07)"/>`,
      `<rect x="${PAD}" y="${ry + 12}" width="${r1(meanW)}" height="7" rx="3.5" fill="${p.cpu}"/>`,
      `<rect x="${r1(PAD + meanW)}" y="${ry + 12}" width="${r1(peakW)}" height="7" rx="3.5" fill="${p.cpu}" fill-opacity="0.3"/>`,
    );
    parts.push(
      txt(
        PAD,
        ry + 34,
        `${t("hist.colPeak")} ${colFmt("cpu", "peak", r.cpu.peak)} · ${t("hist.colActive")} ${r.cpu.active.toFixed(0)}% · ${t("hist.colGrowth")} ${colFmt("mem", "growth", r.mem.lastMb - r.mem.firstMb)}`,
        12,
        400,
        p.dim,
      ),
    );
  });
  if (top5.length) y += top5.length * ROW;

  // ---- 脚注 ----
  y += 26;
  parts.push(
    `<line x1="${PAD}" y1="${y}" x2="${W - PAD}" y2="${y}" stroke="rgba(${p.ovl}, 0.09)" stroke-width="1"/>`,
  );
  y += 24;
  parts.push(
    txt(
      PAD,
      y,
      `${t("rep.generated", { v: clock(now, true) })} · ${t("rep.samples", { n: num(points.length) })}`,
      12,
      400,
      p.dim,
    ),
  );
  parts.push(txt(W - PAD, y, "EZPcMonitor", 12, 600, p.dim, "end"));

  const H = Math.ceil(y + PAD);

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
<style>text{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','PingFang SC','Microsoft YaHei','Segoe UI',system-ui,sans-serif;}</style>
<rect width="${W}" height="${H}" fill="${p.bg}"/>
${parts.join("\n")}
</svg>`;
}

function toDataUrl(svg: string): string {
  const bytes = new TextEncoder().encode(svg);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return `data:image/svg+xml;base64,${btoa(bin)}`;
}

/** 渲染成 PNG。失败时抛错，调用方负责把状态收回去。 */
export async function renderReport(input: ReportInput): Promise<Blob> {
  const svg = buildSvg(input);
  const img = new Image();
  img.decoding = "sync";
  const url = toDataUrl(svg);
  await new Promise<void>((resolve, reject) => {
    img.onload = () => resolve();
    img.onerror = () => reject(new Error("svg decode failed"));
    img.src = url;
  });

  const canvas = document.createElement("canvas");
  canvas.width = Math.round(img.width * SCALE) || W * SCALE;
  canvas.height = Math.round(img.height * SCALE);
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("no 2d context");
  ctx.scale(SCALE, SCALE);
  ctx.drawImage(img, 0, 0, img.width, img.height);

  const blob = await new Promise<Blob | null>((resolve) =>
    canvas.toBlob(resolve, "image/png"),
  );
  if (!blob) throw new Error("png encode failed");
  return blob;
}

/** `EZPcMonitor-report-20261023-1432.png` */
export function reportName(now: number): string {
  const d = new Date(now * 1000);
  const p2 = (n: number) => String(n).padStart(2, "0");
  return `EZPcMonitor-report-${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}.png`;
}
