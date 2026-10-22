import { useCallback, useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { DiskHealth, HistoryPoint, Snapshot } from "./types";

/**
 * 订阅 Rust 采集线程的推送。
 * 事件驱动而非轮询：后端 1s 一拍，前端只负责渲染，空闲时 CPU 占用接近 0。
 */
export function useMetrics(maxPoints = 72) {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [series, setSeries] = useState<HistoryPoint[]>([]);
  const [alive, setAlive] = useState(true);
  const buf = useRef<HistoryPoint[]>([]);

  useEffect(() => {
    let unlisten: UnlistenFn | undefined;
    let cancelled = false;

    const push = (s: Snapshot) => {
      setSnap(s);
      const memPct = s.mem.total > 0 ? (s.mem.used / s.mem.total) * 100 : 0;
      const primary = s.temps.find((t) => t.primary);
      const p: HistoryPoint = {
        ts: s.ts,
        cpu: s.cpu.usage,
        mem: memPct,
        temp: primary?.value ?? 0,
        rx: s.net.rxBps,
        tx: s.net.txBps,
        disk: s.diskTotalReadBps + s.diskTotalWriteBps,
        diskRead: s.diskTotalReadBps,
        diskWrite: s.diskTotalWriteBps,
        gpu: s.gpu?.utilization ?? 0,
      };
      buf.current = [...buf.current, p].slice(-maxPoints);
      setSeries(buf.current);
    };

    (async () => {
      try {
        const s = await invoke<Snapshot>("get_snapshot");
        if (!cancelled && s && s.ts > 0) push(s);
        unlisten = await listen<Snapshot>("metrics:tick", (e) => push(e.payload));
      } catch {
        setAlive(false);
      }
    })();

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [maxPoints]);

  return { snap, series, alive };
}

/**
 * 硬盘健康 / 寿命。
 * 只有主面板会用到，而且 diskutil + smartctl 要 fork 进程，
 * 所以跟 1s 的心跳解耦：进面板拉一次，之后 5 分钟拉一次。
 */
export function useDiskHealth() {
  const [health, setHealth] = useState<DiskHealth[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async (force = false) => {
    setLoading(true);
    try {
      const list = await invoke<DiskHealth[]>("disk_health", { force });
      setHealth(list);
      return list;
    } catch {
      setHealth([]);
      return [];
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    let dead = false;
    let retry: ReturnType<typeof setTimeout> | undefined;

    // 冷启动时第一次 smartctl 探测可能刚好超时，后端会给回空表。
    // 别让用户盯着「正在读取…」等五分钟：空结果就短间隔补几次。
    const run = async (attempt = 0) => {
      const list = await load();
      if (dead) return;
      if (list.length === 0 && attempt < 3) {
        retry = setTimeout(() => run(attempt + 1), 4000);
      }
    };

    run();
    const t = setInterval(() => load(), 5 * 60 * 1000);
    return () => {
      dead = true;
      clearTimeout(retry);
      clearInterval(t);
    };
  }, [load]);

  return { health, loading, refresh: () => load(true) };
}
