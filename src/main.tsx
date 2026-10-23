import { useState } from "react";
import { createRoot } from "react-dom/client";
import { Meter, Ring, Sparkline } from "./components/Charts";
import { DiskDetail } from "./components/DiskDetail";
import { DiskStatusChip } from "./components/DiskStatus";
import { HistoryModal } from "./components/HistoryModal";
import { SettingsModal } from "./components/SettingsModal";
import { useDiskHealth, useMetrics } from "./lib/useMetrics";
import { useSettings } from "./lib/useSettings";
import { initLocale, useI18n } from "./i18n";
import { initTheme } from "./lib/theme";
import { bytes, rate, tempColor } from "./lib/format";
import type { DiskInfo } from "./lib/types";
import "./styles.css";

initLocale();
initTheme();

export default function Dashboard() {
  const { snap, series, alive } = useMetrics(120);
  const { health, loading, refresh } = useDiskHealth();
  const { settings, update, open: settingsOpen, setOpen: setSettingsOpen } = useSettings();
  const i = useI18n();
  // 点开的是哪块盘；详情页自己按 mount 去 health 里取最新数据
  const [detail, setDetail] = useState<DiskInfo | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);
  // 进程榜按 CPU 还是按内存排。后端已经保证两个维度的前 20 都在数据里，
  // 这里只负责按当前键重排 + 截断。
  const [procSort, setProcSort] = useState<"cpu" | "mem">("cpu");

  if (!snap) {
    return (
      <div className="dash" style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ color: "var(--muted)", fontSize: 13 }}>
          {alive ? i.t("dash.connecting") : i.t("dash.disconnected")}
        </div>
      </div>
    );
  }

  const memPct = snap.mem.total > 0 ? (snap.mem.used / snap.mem.total) * 100 : 0;
  const swapPct = snap.mem.swapTotal > 0 ? (snap.mem.swapUsed / snap.mem.swapTotal) * 100 : 0;
  const primary = snap.temps.find((t) => t.primary);

  return (
    <div className="dash">
      <div className="dash-head">
        <div>
          <div className="dash-title">{snap.host.name}</div>
          <div className="dash-sub">
            {snap.host.os} · {snap.host.arch} ·{" "}
            {i.t("dash.uptime", { v: i.duration(snap.uptime) })}
          </div>
        </div>
        <div className="dash-meta">
          <div>{snap.cpu.brand || i.t("dash.cpuUnknown")}</div>
          <div>
            {i.t("dash.cores", { p: snap.cpu.physical, t: snap.cpu.cores })}
            {snap.cpu.freqMhz > 0 ? ` · ${(snap.cpu.freqMhz / 1000).toFixed(2)} GHz` : ""}
          </div>
          <div>{i.t("dash.load", { v: snap.load.map((l) => l.toFixed(2)).join("  ") })}</div>
        </div>
        <div className="dash-tools">
          <button className="tool-btn" onClick={() => setHistoryOpen(true)} title={i.t("hist.title")}>
            {i.t("dash.history")}
          </button>
          <button
            className={`gear${settingsOpen ? " on" : ""}`}
            onClick={() => setSettingsOpen(!settingsOpen)}
            title={i.t("dash.settings")}
            aria-label={i.t("dash.settings")}
          >
            <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
              <path
                d="M2 4.5h5M11 4.5h3M2 11.5h3M9 11.5h5"
                stroke="currentColor"
                strokeWidth="1.4"
                strokeLinecap="round"
              />
              <circle cx="9" cy="4.5" r="1.9" stroke="currentColor" strokeWidth="1.4" />
              <circle cx="7" cy="11.5" r="1.9" stroke="currentColor" strokeWidth="1.4" />
            </svg>
          </button>
        </div>
      </div>

      <div className="grid">
        {/* ---------------- CPU ---------------- */}
        <div className="card" style={{ gridColumn: "span 5" }}>
          <div className="card-h">
            CPU
            <span className="tag">{i.t("dash.live")}</span>
          </div>
          <div className="big">
            <span className="num" style={{ color: "var(--c-cpu)" }}>
              {snap.cpu.usage.toFixed(1)}
            </span>
            <span className="unit">%</span>
          </div>
          <div style={{ marginTop: 6, height: 42 }}>
            <Sparkline
              data={series.map((p) => p.cpu)}
              id="dash-cpu"
              height={42}
              minMax={25}
              color="var(--c-cpu)"
            />
          </div>
          <div className="cores">
            {snap.cpu.perCore.map((v, i2) => (
              <div className="core" key={i2}>
                <div className="track">
                  <div className="fill" style={{ height: `${Math.max(4, v)}%` }} />
                </div>
                <span>{Math.round(v)}</span>
              </div>
            ))}
          </div>
        </div>

        {/* ---------------- 内存 ---------------- */}
        <div className="card" style={{ gridColumn: "span 3" }}>
          <div className="card-h">
            {i.t("card.mem")}
            <span className="tag">{bytes(snap.mem.total, 0)}</span>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 14, marginTop: 10 }}>
            <Ring
              id="dash-mem"
              value={memPct}
              size={86}
              stroke={7}
              label={i.t("dash.used").toUpperCase()}
              from="var(--c-mem)"
              to="var(--c-mem-2)"
            />
            <div style={{ flex: 1, minWidth: 0 }}>
              <div className="kv">
                <span>{i.t("dash.used")}</span>
                <b>{bytes(snap.mem.used, 1)}</b>
              </div>
              <div className="kv">
                <span>{i.t("dash.avail")}</span>
                <b>{bytes(snap.mem.available, 1)}</b>
              </div>
            </div>
          </div>
          <div style={{ marginTop: "auto", paddingTop: 12 }}>
            <div className="kv">
              <span>{i.t("dash.swap")}</span>
              <b>
                {bytes(snap.mem.swapUsed, 1)} / {bytes(snap.mem.swapTotal, 0)}
              </b>
            </div>
            <Meter value={swapPct} height={5} color="linear-gradient(90deg,var(--c-mem-2),var(--c-mem))" />
          </div>
        </div>

        {/* ---------------- 温度 ---------------- */}
        <div className="card" style={{ gridColumn: "span 4" }}>
          <div className="card-h">
            {i.t("card.temp")}
            <span className="tag">{i.tn("p.sensors", snap.temps.length)}</span>
          </div>
          <div className="big">
            <span className="num" style={{ color: primary ? tempColor(primary.value) : "var(--muted)" }}>
              {primary ? Math.round(primary.value) : "--"}
            </span>
            <span className="unit">°C</span>
          </div>
          <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 5 }}>
            {snap.temps.slice(0, 4).map((t) => (
              <div key={t.label} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span
                  style={{
                    fontSize: 10.5,
                    color: t.primary ? "var(--text)" : "var(--muted)",
                    width: 108,
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                    whiteSpace: "nowrap",
                  }}
                >
                  {t.label}
                </span>
                <div style={{ flex: 1 }}>
                  <Meter
                    value={(t.value / (t.critical ?? 105)) * 100}
                    height={4}
                    color={tempColor(t.value)}
                  />
                </div>
                <span style={{ fontSize: 10.5, color: "var(--muted)", width: 32, textAlign: "right" }}>
                  {t.value.toFixed(0)}°
                </span>
              </div>
            ))}
            {snap.temps.length === 0 && (
              <div style={{ fontSize: 11, color: "var(--dim)" }}>{i.t("dash.noTemp")}</div>
            )}
          </div>
        </div>

        {/* ---------------- GPU ---------------- */}
        <div className="card" style={{ gridColumn: "span 3" }}>
          <div className="card-h">
            GPU
            <span className="tag">{snap.gpu?.name || "—"}</span>
          </div>
          {snap.gpu?.utilization != null ? (
            <>
              <div className="big">
                <span className="num" style={{ color: "var(--c-mem)" }}>
                  {snap.gpu.utilization.toFixed(0)}
                </span>
                <span className="unit">%</span>
              </div>
              <div style={{ marginTop: 6, height: 34 }}>
                <Sparkline
                  data={series.map((p) => p.gpu ?? 0)}
                  id="dash-gpu"
                  height={34}
                  minMax={25}
                  color="var(--c-mem)"
                />
              </div>
              <div style={{ marginTop: "auto", paddingTop: 10 }}>
                <div className="kv">
                  <span>{i.t("dash.vramUsed")}</span>
                  <b>{snap.gpu.memUsed != null ? bytes(snap.gpu.memUsed, 0) : "—"}</b>
                </div>
                <div className="kv">
                  <span>{i.t("dash.vramTotal")}</span>
                  <b>{snap.gpu.memTotal != null ? bytes(snap.gpu.memTotal, 0) : i.t("dash.unified")}</b>
                </div>
              </div>
            </>
          ) : (
            <div className="card-empty">
              {i.t("dash.gpuNone")}
              <span>{i.t("dash.gpuPlan")}</span>
            </div>
          )}
        </div>

        {/* ---------------- 磁盘 ---------------- */}
        <div className="card" style={{ gridColumn: "span 5" }}>
          <div className="card-h">
            {i.t("card.disk")}
            <span className="tag">
              <i style={{ background: "var(--c-cpu)" }} />
              {i.t("dash.read", { v: rate(snap.diskTotalReadBps) })}
              <i style={{ background: "var(--c-mem)", marginLeft: 10 }} />
              {i.t("dash.write", { v: rate(snap.diskTotalWriteBps) })}
            </span>
          </div>
          <div style={{ overflow: "auto", marginTop: 4, flex: 1, minHeight: 0 }}>
            {snap.disks.map((d) => {
              const p = d.total > 0 ? (d.used / d.total) * 100 : 0;
              // 健康数据按挂载点配对；对不上时（例如 APFS 合并了挂载点）退回同序号
              const h = health.find((x) => x.mount === d.mount);
              return (
                <div
                  className="disk-row clickable"
                  key={d.mount + d.name}
                  onClick={() => setDetail(d)}
                  title={i.t("dash.diskOpen")}
                >
                  <div className="disk-top">
                    <span className="disk-name">{d.name}</span>
                    <span className="disk-mount">{d.mount}</span>
                    <span className="disk-io">
                      R {rate(d.readBps)} · W {rate(d.writeBps)}
                    </span>
                  </div>
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <Meter
                      value={p}
                      height={5}
                      color={
                        p > 90
                          ? "var(--danger)"
                          : "linear-gradient(90deg,var(--c-cpu-2),var(--c-cpu))"
                      }
                    />
                    <span
                      style={{
                        fontSize: 10,
                        color: "var(--muted)",
                        whiteSpace: "nowrap",
                        width: 116,
                        textAlign: "right",
                      }}
                    >
                      {bytes(d.used, 1)} / {bytes(d.total, 0)}
                    </span>
                  </div>
                  <div className="disk-foot">
                    {h ? (
                      <DiskStatusChip h={h} />
                    ) : (
                      <span className="disk-status dim">
                        {loading ? i.t("dash.diskLoading") : i.t("dash.diskNoHealth")}
                      </span>
                    )}
                    <span className="disk-more">{i.t("dash.diskMore")}</span>
                  </div>
                </div>
              );
            })}
          </div>
        </div>

        {/* ---------------- 网络 ---------------- */}
        <div className="card" style={{ gridColumn: "span 4" }}>
          <div className="card-h">{i.t("card.net")}</div>
          <div style={{ display: "flex", gap: 20, marginTop: 10 }}>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 10, color: "var(--dim)", letterSpacing: "0.1em" }}>DOWN</div>
              <div className="big" style={{ marginTop: 2 }}>
                <span className="num" style={{ fontSize: 24, color: "var(--c-cpu)" }}>
                  {bytes(snap.net.rxBps, 1).split(" ")[0]}
                </span>
                <span className="unit">{bytes(snap.net.rxBps, 1).split(" ")[1]}/s</span>
              </div>
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 10, color: "var(--dim)", letterSpacing: "0.1em" }}>UP</div>
              <div className="big" style={{ marginTop: 2 }}>
                <span className="num" style={{ fontSize: 24, color: "var(--c-mem)" }}>
                  {bytes(snap.net.txBps, 1).split(" ")[0]}
                </span>
                <span className="unit">{bytes(snap.net.txBps, 1).split(" ")[1]}/s</span>
              </div>
            </div>
          </div>
          <div style={{ height: 30, marginTop: 6 }}>
            <Sparkline
              data={series.map((p) => p.rx)}
              id="dash-net"
              height={30}
              minMax={64 * 1024}
              color="var(--c-cpu)"
            />
          </div>
          <div style={{ marginTop: "auto" }}>
            <div className="kv">
              <span>{i.t("dash.totalRx")}</span>
              <b>{bytes(snap.net.totalRx, 1)}</b>
            </div>
            <div className="kv">
              <span>{i.t("dash.totalTx")}</span>
              <b>{bytes(snap.net.totalTx, 1)}</b>
            </div>
          </div>
        </div>

        {/* ---------------- 进程 ---------------- */}
        <div className="card" style={{ gridColumn: "span 12", minHeight: 0 }}>
          <div className="card-h">
            {i.t("card.proc")}
            <span className="sort-tabs">
              <button
                className={procSort === "cpu" ? "on" : undefined}
                onClick={() => setProcSort("cpu")}
              >
                {i.t("dash.byCpu")}
              </button>
              <button
                className={procSort === "mem" ? "on" : undefined}
                onClick={() => setProcSort("mem")}
              >
                {i.t("dash.byMem")}
              </button>
            </span>
            <span className="tag">{i.t("dash.topN", { n: 20 })}</span>
          </div>
          <div style={{ overflow: "auto", marginTop: 4 }}>
            <table className="proc-table">
              <thead>
                <tr>
                  <th style={{ width: 60 }}>{i.t("dash.pid")}</th>
                  <th>{i.t("dash.procName")}</th>
                  <th style={{ width: 80, textAlign: "right" }}>CPU</th>
                  <th style={{ width: 100, textAlign: "right" }}>{i.t("dash.memCol")}</th>
                </tr>
              </thead>
              <tbody>
                {[...snap.procs]
                  .sort((a, b) => (procSort === "cpu" ? b.cpu - a.cpu : b.mem - a.mem))
                  .slice(0, 20)
                  .map((p) => (
                    <tr key={p.pid}>
                      <td className="mono">{p.pid}</td>
                      <td className="name">{p.name}</td>
                      <td className="mono" style={{ textAlign: "right" }}>
                        {p.cpu.toFixed(1)}%
                      </td>
                      <td className="mono" style={{ textAlign: "right" }}>
                        {bytes(p.mem, 0)}
                      </td>
                    </tr>
                  ))}
                {snap.procs.length === 0 && (
                  <tr>
                    <td colSpan={4} style={{ color: "var(--dim)", paddingTop: 10 }}>
                      {i.t("dash.collecting")}
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {detail && (
        <DiskDetail
          disk={detail}
          health={health.find((x) => x.mount === detail.mount)}
          series={series}
          onClose={() => setDetail(null)}
          onRefresh={refresh}
          refreshing={loading}
        />
      )}

      {settingsOpen && (
        <SettingsModal
          settings={settings}
          update={update}
          onClose={() => setSettingsOpen(false)}
          onOpenHistory={() => {
            setSettingsOpen(false);
            setHistoryOpen(true);
          }}
        />
      )}

      {historyOpen && (
        <HistoryModal
          retentionSecs={settings.historyRetentionSecs}
          enabled={settings.historyEnabled}
          onClose={() => setHistoryOpen(false)}
          onOpenSettings={() => {
            setHistoryOpen(false);
            setSettingsOpen(true);
          }}
        />
      )}
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Dashboard />);
