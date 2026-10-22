import type { Bucket } from "../lib/useHistory";

interface Props {
  id: string;
  buckets: Bucket[];
  color: string;
  height?: number;
  /** 底部时间轴，最多三个，左 / 中 / 右 */
  timeLabels: string[];
}

const W = 300;
const H = 100;

/**
 * 历史曲线。
 *
 * 和首页的 Sparkline 不同，这里要标刻度和时间，所以图本身仍然用
 * `preserveAspectRatio="none"` 拉伸（线宽靠 vectorEffect 保住），
 * 但文字全部放在 HTML 图层上——否则横竖比例不一致时字会被拉扁。
 *
 * 两条线：实线是**每桶峰值**（尖峰不会被平均掉），面积是**每桶均值**（看出常态）。
 */
export function HistoryChart({ id, buckets, color, height = 96, timeLabels }: Props) {
  const n = buckets.length;
  const hi = Math.max(1, ...buckets.map((b) => b.max)) * 1.12;

  const x = (i: number) => (n > 1 ? (i / (n - 1)) * W : 0);
  const y = (v: number) => H - (Math.max(0, Math.min(hi, v)) / hi) * (H - 2) - 1;

  const peakLine = buckets.map((b, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(b.max).toFixed(1)}`).join(" ");
  const avgArea = `${buckets.map((b, i) => `${i === 0 ? "M" : "L"}${x(i).toFixed(1)},${y(b.avg).toFixed(1)}`).join(" ")} L${W},${H} L0,${H} Z`;

  return (
    <div className="hchart" style={{ height }}>
      {n > 1 ? (
        <svg className="spark" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" height={height}>
          <defs>
            <linearGradient id={`${id}-fill`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor={color} stopOpacity="0.3" />
              <stop offset="100%" stopColor={color} stopOpacity="0" />
            </linearGradient>
          </defs>
          <path d={avgArea} fill={`url(#${id}-fill)`} />
          <path
            d={peakLine}
            fill="none"
            stroke={color}
            strokeWidth="1.5"
            strokeLinejoin="round"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
          />
        </svg>
      ) : (
        <div className="hchart-empty">数据点太少</div>
      )}
      <div className="hchart-axis">
        {timeLabels.map((t, i) => (
          <span key={i}>{t}</span>
        ))}
      </div>
    </div>
  );
}
