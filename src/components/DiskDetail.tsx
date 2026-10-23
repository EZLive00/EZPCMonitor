import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Sparkline } from "./Charts";
import type { BenchResult, DiskHealth, DiskInfo, HistoryPoint } from "../lib/types";
import { bytes, rate } from "../lib/format";
import { useI18n } from "../i18n";

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
  const i = useI18n();
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
        health.solidState == null ? "" : health.solidState ? i.t("dd.solid") : i.t("dd.hdd"),
        health.serial ? `SN ${health.serial}` : "",
        health.firmware ? i.t("dd.firmware", { v: health.firmware }) : "",
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
              {disk.mount} · {disk.fs || i.t("common.unknownFs")} · {bytes(disk.total, 0)}
            </div>
          </div>
          <div className="modal-actions">
            <button className="mini" onClick={onRefresh} disabled={refreshing}>
              {refreshing ? i.t("common.detecting") : i.t("common.redetect")}
            </button>
            <button className="modal-close" onClick={onClose} title={i.t("common.closeEsc")}>
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
                  <div className="stat-k">{i.t("dd.wear")}</div>
                  <div className="stat-v">
                    {health.lifeUsed != null ? `${health.lifeUsed.toFixed(0)}%` : "—"}
                  </div>
                  <div className="stat-n">
                    {health.lifeLeft != null
                      ? i.t("dd.left", { v: health.lifeLeft.toFixed(0) })
                      : i.t("dd.wearNote")}
                  </div>
                </div>
                <div className="stat">
                  <div className="stat-k">{i.t("dd.temp")}</div>
                  <div className="stat-v">
                    {health.temperature != null ? `${health.temperature.toFixed(0)}°` : "—"}
                  </div>
                  <div className="stat-n">{i.t("dd.tempNote")}</div>
                </div>
                <div className="stat">
                  <div className="stat-k">{i.t("dd.usage")}</div>
                  <div className="stat-v">{Math.round(capacityPct)}%</div>
                  <div className="stat-n">{i.t("dd.usedNote", { v: bytes(disk.used, 1) })}</div>
                </div>
                <div className="stat">
                  <div className="stat-k">{i.t("dd.media")}</div>
                  <div className="stat-v" style={{ color: health.mediaErrors ? "var(--warn)" : undefined }}>
                    {health.mediaErrors ?? "—"}
                  </div>
                  <div className="stat-n">{i.t("dd.mediaNote")}</div>
                </div>
              </div>

              <div className="sec-h">
                {i.t("dd.io")}
                <span className="sec-tag">
                  {i.t("dash.read", { v: rate(disk.readBps) })} ·{" "}
                  {i.t("dash.write", { v: rate(disk.writeBps) })}
                </span>
              </div>
              <div className="io-sparks">
                <Sparkline data={ioRead} max={ioMax} id="modal-dr" height={44} color="var(--c-io-r)" />
                <Sparkline
                  data={ioWrite}
                  max={ioMax}
                  id="modal-dw"
                  height={44}
                  color="var(--c-io-w)"
                  showFill={false}
                />
              </div>
            </>
          ) : (
            <div className="dh-note">{i.t("dd.smartLoading")}</div>
          )}

          <div className="sec-h">{i.t("dd.bench")}</div>
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
                {benching ? i.t("common.testing") : i.t("common.startBench")}
              </button>
            </div>
            {!enoughSpace && (
              <div className="dh-note">{i.t("dd.benchNeed", { v: bytes(needBytes, 0) })}</div>
            )}
            {err && <div className="dh-note" style={{ color: "var(--warn)" }}>{err}</div>}
            {bench && (
              <div className="bench-result">
                <div className="stat">
                  <div className="stat-k">{i.t("dd.seqWrite")}</div>
                  <div className="stat-v" style={{ color: "var(--c-io-w)" }}>
                    {bench.writeMbps.toFixed(0)}
                    <span className="stat-u">MB/s</span>
                  </div>
                  <div className="stat-n">{bench.sizeMb} MB / {(bench.writeMs / 1000).toFixed(2)} s</div>
                </div>
                <div className="stat">
                  <div className="stat-k">{i.t("dd.seqRead")}</div>
                  <div className="stat-v" style={{ color: "var(--c-io-r)" }}>
                    {bench.readMbps.toFixed(0)}
                    <span className="stat-u">MB/s</span>
                  </div>
                  <div className="stat-n">{bench.sizeMb} MB / {(bench.readMs / 1000).toFixed(2)} s</div>
                </div>
                <div className="bench-path">
                  {i.t("dd.benchFile", { v: bench.path })}
                  {bench.note ? ` · ${bench.note}` : ""}
                </div>
              </div>
            )}
          </div>

          {health && (
            <>
              <div className="sec-h">
                {i.t("dd.smart")}
                <span className="sec-tag">{i.tn("p.attrs", health.attrs.length)}</span>
              </div>
              <table className="dh-table">
                <thead>
                  <tr>
                    <th>{i.t("dd.colAttr")}</th>
                    <th>{i.t("dd.colValue")}</th>
                    <th>{i.t("dd.colNote")}</th>
                  </tr>
                </thead>
                <tbody>
                  {health.attrs.map((a, idx) => (
                    <tr key={`${a.name}-${idx}`} className={a.critical ? "bad" : undefined}>
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
          {i.t("dd.footSource", { v: health?.source || "—" })} · {i.t("dd.footWarnLead")}
          <b>{i.t("dd.footWarnBold")}</b>
          {i.t("dd.footWarn")}
        </div>
      </div>
    </div>
  );
}
