const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

export function bytes(n: number, digits = 1): string {
  if (!n || n < 1) return "0 B";
  let i = 0;
  let v = n;
  while (v >= 1024 && i < UNITS.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v.toFixed(i === 0 ? 0 : digits)} ${UNITS[i]}`;
}

export function rate(bps: number): string {
  return `${bytes(bps, 1)}/s`;
}

const SI_UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

/**
 * 十进制（1000 进位）的容量格式。
 * 厂商标 TBW、smartctl 报「Data Units Written」用的都是这个口径，
 * 硬盘寿命页如果按 1024 算，数字会和官方标称对不上。
 */
export function bytesSI(n: number, digits = 1): string {
  if (!n || n < 1) return "0 B";
  let i = 0;
  let v = n;
  while (v >= 1000 && i < SI_UNITS.length - 1) {
    v /= 1000;
    i += 1;
  }
  return `${v.toFixed(i === 0 ? 0 : digits)} ${SI_UNITS[i]}`;
}

/** 大数值拆成数字 + 单位，方便排版时数字更大、单位更小 */
export function splitRate(bps: number): { value: string; unit: string } {
  const s = rate(bps);
  const [v, ...rest] = s.split(" ");
  return { value: v, unit: rest.join(" ") };
}

export function pct(n: number): number {
  return Math.max(0, Math.min(100, n));
}

export function pctStr(n: number): string {
  return `${Math.round(pct(n))}%`;
}

export function uptime(sec: number): string {
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d > 0) return `${d} 天 ${h} 小时`;
  if (h > 0) return `${h} 小时 ${m} 分`;
  return `${m} 分钟`;
}

export function tempColor(t: number): string {
  if (t >= 85) return "var(--danger)";
  if (t >= 70) return "var(--warn)";
  return "var(--ok)";
}

export function loadColor(v: number): string {
  if (v >= 85) return "var(--danger)";
  if (v >= 65) return "var(--warn)";
  return "var(--accent)";
}
