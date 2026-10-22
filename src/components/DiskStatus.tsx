import type { DiskHealth } from "../lib/types";

const LABEL: Record<string, string> = {
  good: "正常",
  warning: "留意",
  bad: "告警",
  unknown: "未知",
};

const COLOR: Record<string, string> = {
  good: "var(--ok)",
  warning: "var(--warn)",
  bad: "var(--danger)",
  unknown: "var(--dim)",
};

/**
 * 一级页面只放这一行状态摘要——具体属性、曲线、测速都在详情弹窗里。
 *
 * 措辞刻意克制：`SMART Status: Verified` 只意味着「没有属性越过阈值」，
 * 不等于「盘是好的」，所以这里写「正常」而不是「健康良好」；
 * `percentage_used` 是磨损记账而不是倒计时，所以写「磨损」而不是「剩余寿命」。
 */
export function DiskStatusChip({ h }: { h: DiskHealth }) {
  const color = COLOR[h.status] ?? "var(--dim)";
  return (
    <span className="disk-status">
      <span className="dot" style={{ background: color }} />
      <span style={{ color }}>{LABEL[h.status] ?? LABEL.unknown}</span>
      {h.lifeUsed != null && (
        <>
          <span className="sep">·</span>
          <span>磨损 {h.lifeUsed.toFixed(0)}%</span>
        </>
      )}
      {h.temperature != null && (
        <>
          <span className="sep">·</span>
          <span>{h.temperature.toFixed(0)}°C</span>
        </>
      )}
    </span>
  );
}
