import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Sparkline } from "./Charts";
import type { BenchResult, DiskHealth, DiskInfo, HistoryPoint } from "../lib/types";
import { bytes, rate } from "../lib/format";

interface Props {
  disk: DiskInfo;
  health?: DiskHealth;
  series: HistoryPoint[];
  onClose: () => void;
  onRefresh: () => void;
  refreshing: boolean;
}

const SIZES = [256, 512, 1024];

/**
 * 磁盘详情（二级页面）。
 *
 * 一级页面只留容量、实时读写和一行状态，所有「复杂」的东西都收在这里：
 * 身份信息、磨损与异常计数、完整 SMART 属性表、实时读写曲线、顺序读写测速。
 *
 * 做成应用内弹窗而不是独立窗口，是因为多一个 WebView 要多约 50MB 常驻内存
 * （见 ADR-006），代价是不能拖到第二块屏，暂时接受。
 */
export function DiskDetail({ disk, health, series, onClose, onRefresh, refreshing }: Props) {
  const [size, setSize] = useState(512);
  const [bench, setBench] = useState<BenchResult | null>(null);
  const [benching, setBenching] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const ioRead = series.map((p) => p.diskRead ?? 0);
  const ioWrite = series.map((p) => p.diskWrite ?? 0);
  const ioMax = Math.max(64 * 1024, ...ioRead, ...ioWrite) * 1.18;

  // 测速要写 size*2 出去（含文件系统开销），空间不够就别让用户点了
  const needBytes = size * 1024 * 1024 * 2 + 200 * 1024 * 1024;
  const enoughSpace = disk.free > needBytes;

  const startBench = async () => {
    setBenching(true);
    setErr(null);
    try {
      const r = await invoke<BenchResult>("disk_bench", { mount: disk.mount, sizeMb: size });
      setBench(r);
    } catch (e) {
      setErr(typeof e === "string" ? e : String(e));
    } finally {
      setBenching(false);
    }
  };

  const meta = health
    ? [
        health.device,
        health.bus,
        health.solidState == null ? "" : health.solidState ? "固态" : "机械",
        health.serial ? `SN ${health.serial}` : "",
        health.firmware ? `固件 ${health.firmware}` : "",
      ].filter(Boolean)
    : [];

  const capacityPct = disk.total > 0 ? (disk.used / disk.total) * 100 : 0;

  return (
    <div className="modal-backdrop" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-head">
          <div>
            <div className="modal-title">{disk.name}</div>
            <div className="modal-sub">
              {disk.mount} · {disk.fs || "未知文件系统"} · {bytes(disk.total, 0)}
            </div>
          </div>
          <div className="modal-actions">
            <button className="mini" onClick={onRefresh} disabled={refreshing}>
              {refreshing ? "检测中" : "重新检测"}
            </button>
            <button className="modal-close" onClick={onClose} title="关闭（Esc）">
              ×
            </button>
          </div>
        </div>

        <div className="modal-body">
          {health ? (
            <>
              {meta.length > 0 && <div className="modal-meta">{meta.join(" · ")}</div>}

              <div className="stat-row">
                <div className="stat">
                  <div className="stat-k">磨损</div>
                  <div className="stat-v">
                    {health.lifeUsed != null ? `${health.lifeUsed.toFixed(0)}%` : "—"}
                  </div>
                  <div className="stat-n">
                    {health.lifeLeft != null ? `剩余 ${health.lifeLeft.toFixed(0)}%` : "厂商标称耐久度估算"}
                  </div>
                </div>
                <div className="stat">
                  <div className="stat-k">温度</div>
                  <div className="stat-v">
                    {health.temperature != null ? `${health.temperature.toFixed(0)}°` : "—"}
                  </div>
                  <div className="stat-n">控制器上报</div>
                </div>
                <div className="stat">
                  <div className="stat-k">已用 / 容量</div>
                  <div className="stat-v">{Math.round(capacityPct)}%</div>
                  <div className="stat-n">{bytes(disk.used, 1)} 已用</div>
                </div>
                <div className="stat">
                  <div className="stat-k">介质错误</div>
                  <div className="stat-v" style={{ color: health.mediaErrors ? "var(--warn)" : undefined }}>
                    {health.mediaErrors ?? "—"}
                  </div>
                  <div className="stat-n">非零即需备份</div>
                </div>
              </div>

              <div className="sec-h">
                实时读写
                <span className="sec-tag">
                  读 {rate(disk.readBps)} · 写 {rate(disk.writeBps)}
                </span>
              </div>
              <div className="io-sparks">
                <Sparkline data={ioRead} max={ioMax} id="modal-dr" height={44} color="#22d3ee" />
                <Sparkline
                  data={ioWrite}
                  max={ioMax}
                  id="modal-dw"
                  height={44}
                  color="#a78bfa"
                  showFill={false}
                />
              </div>
            </>
          ) : (
            <div className="dh-note">
              正在读取 SMART 数据…如果一直没有结果，说明这块盘不提供健康信息。
            </div>
          )}

          <div className="sec-h">测速（顺序读写）</div>
          <div className="bench">
            <div className="bench-opts">
              {SIZES.map((s) => (
                <button
                  key={s}
                  className={`chip${size === s ? " on" : ""}`}
                  onClick={() => setSize(s)}
                  disabled={benching}
                >
                  {s} MB
                </button>
              ))}
              <button className="btn-primary" onClick={startBench} disabled={benching || !enoughSpace}>
                {benching ? "测速中…" : "开始测速"}
              </button>
            </div>
            {!enoughSpace && (
              <div className="dh-note">可用空间不足（需要约 {bytes(needBytes, 0)}），换个容量再试。</div>
            )}
            {err && <div className="dh-note" style={{ color: "var(--warn)" }}>{err}</div>}
            {bench && (
              <div className="bench-result">
                <div className="stat">
                  <div className="stat-k">顺序写</div>
                  <div className="stat-v" style={{ color: "#a78bfa" }}>
                    {bench.writeMbps.toFixed(0)}
                    <span className="stat-u">MB/s</span>
                  </div>
                  <div className="stat-n">{bench.sizeMb} MB / {(bench.writeMs / 1000).toFixed(2)} s</div>
                </div>
                <div className="stat">
                  <div className="stat-k">顺序读</div>
                  <div className="stat-v" style={{ color: "#22d3ee" }}>
                    {bench.readMbps.toFixed(0)}
                    <span className="stat-u">MB/s</span>
                  </div>
                  <div className="stat-n">{bench.sizeMb} MB / {(bench.readMs / 1000).toFixed(2)} s</div>
                </div>
                <div className="bench-path">
                  测试文件 {bench.path}（已删除）
                  {bench.note ? ` · ${bench.note}` : ""}
                </div>
              </div>
            )}
          </div>

          {health && (
            <>
              <div className="sec-h">
                SMART 属性
                <span className="sec-tag">{health.attrs.length} 项</span>
              </div>
              <table className="dh-table">
                <thead>
                  <tr>
                    <th>属性</th>
                    <th>值</th>
                    <th>备注</th>
                  </tr>
                </thead>
                <tbody>
                  {health.attrs.map((a, i) => (
                    <tr key={`${a.name}-${i}`} className={a.critical ? "bad" : undefined}>
                      <td className="name">{a.name}</td>
                      <td className="val">{a.value || "—"}</td>
                      <td className="extra">{a.extra}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {health.note && <div className="dh-note">{health.note}</div>}
            </>
          )}
        </div>

        <div className="modal-foot">
          数据来源 {health?.source || "—"} · 磨损是厂商标称耐久度的估算，
          <b>不代表故障预测</b>；介质错误、备用块这类「已经发生」的计数更值得关注。
        </div>
      </div>
    </div>
  );
}
