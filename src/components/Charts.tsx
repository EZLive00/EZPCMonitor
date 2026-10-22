interface RingProps {
  value: number;
  size?: number;
  stroke?: number;
  from: string;
  to: string;
  label: string;
  id: string;
}

export function Ring({ value, size = 72, stroke = 5.5, from, to, label, id }: RingProps) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(100, value));
  const dash = (v / 100) * c;

  return (
    <div className="ring" style={{ width: size, height: size }}>
      <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`}>
        <defs>
          <linearGradient id={id} x1="0" y1="0" x2="1" y2="1">
            <stop offset="0%" stopColor={from} />
            <stop offset="100%" stopColor={to} />
          </linearGradient>
        </defs>
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke="rgba(255,255,255,0.075)"
          strokeWidth={stroke}
        />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          fill="none"
          stroke={`url(#${id})`}
          strokeWidth={stroke}
          strokeLinecap="round"
          strokeDasharray={`${dash} ${c}`}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
          style={{ transition: "stroke-dasharray .55s cubic-bezier(.22,1,.36,1)" }}
        />
      </svg>
      <div className="ring-center">
        <div className="ring-num">
          {Math.round(v)}
          <span>%</span>
        </div>
        <div className="ring-label">{label}</div>
      </div>
    </div>
  );
}

interface SparkProps {
  data: number[];
  /** 固定上限；不传则按峰值自动缩放，避免低负载时曲线贴底 */
  max?: number;
  minMax?: number;
  height?: number;
  color?: string;
  id?: string;
  showFill?: boolean;
}

export function Sparkline({
  data,
  max,
  minMax = 10,
  height = 36,
  color = "#22d3ee",
  id = "spark",
  showFill = true,
}: SparkProps) {
  const W = 240;
  const H = height;
  const pts = data.length ? data : [0];
  const n = pts.length;
  const step = n > 1 ? W / (n - 1) : W;

  const peak = pts.reduce((a, b) => Math.max(a, b), 0);
  const hi = max ?? Math.max(minMax, peak * 1.18);

  const coords = pts.map((v, i) => {
    const clamped = Math.max(0, Math.min(hi, v));
    const x = i * step;
    const y = H - (clamped / hi) * (H - 3) - 1.5;
    return [x, y] as const;
  });

  const line = coords.map(([x, y], i) => `${i === 0 ? "M" : "L"}${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  const area = `${line} L${W},${H} L0,${H} Z`;

  return (
    <svg className="spark" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" height={height}>
      <defs>
        <linearGradient id={`${id}-fill`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={color} stopOpacity="0.34" />
          <stop offset="100%" stopColor={color} stopOpacity="0" />
        </linearGradient>
      </defs>
      {showFill && <path d={area} fill={`url(#${id}-fill)`} />}
      <path
        d={line}
        fill="none"
        stroke={color}
        strokeWidth="1.6"
        strokeLinejoin="round"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  );
}

interface MeterProps {
  value: number;
  color?: string;
  height?: number;
  track?: string;
}

export function Meter({ value, color = "var(--accent)", height = 6, track }: MeterProps) {
  const v = Math.max(0, Math.min(100, value));
  return (
    <div className="meter" style={{ height, background: track ?? "rgba(255,255,255,0.07)" }}>
      <div
        className="meter-fill"
        style={{ width: `${v}%`, background: color, transition: "width .5s cubic-bezier(.22,1,.36,1)" }}
      />
    </div>
  );
}
