//! 指标采集内核
//!
//! 设计要点：
//! 1. 单线程串行采集，避免多线程争抢 /proc、IOKit、WMI 带来的抖动；
//! 2. 分级刷新（tiered refresh）——高频指标 1s，磁盘 2s，温度/进程 3s；
//! 3. 所有平台差异收敛在 sysinfo 的 Components 实现里，本层只做归一化与平滑。

use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use sysinfo::{Components, DiskRefreshKind, Disks, Networks, ProcessesToUpdate, System};

use crate::gpu;

/// 300 个点：1s 一拍约 5 分钟，10s 一拍就是 50 分钟。
/// 按点数而不是按时长截断——采集间隔是可调的，按时长算每次改频率都得重算容量。
pub const HISTORY_CAP: usize = 300;

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct CpuInfo {
    pub usage: f32,
    pub per_core: Vec<f32>,
    pub brand: String,
    pub cores: usize,
    pub physical: usize,
    pub freq_mhz: u64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemInfo {
    pub total: u64,
    pub used: u64,
    pub available: u64,
    pub swap_total: u64,
    pub swap_used: u64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct DiskInfo {
    pub name: String,
    pub mount: String,
    pub fs: String,
    pub kind: String,
    pub total: u64,
    pub free: u64,
    pub used: u64,
    pub read_bps: f64,
    pub write_bps: f64,
    pub removable: bool,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct NetInfo {
    pub rx_bps: f64,
    pub tx_bps: f64,
    pub total_rx: u64,
    pub total_tx: u64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct TempInfo {
    pub label: String,
    pub value: f32,
    pub max: Option<f32>,
    pub critical: Option<f32>,
    pub primary: bool,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct ProcInfo {
    pub pid: u32,
    pub name: String,
    pub cpu: f32,
    pub mem: u64,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct HostInfo {
    pub name: String,
    pub os: String,
    pub kernel: String,
    pub arch: String,
    pub app_version: String,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub ts: u64,
    pub host: HostInfo,
    pub cpu: CpuInfo,
    pub mem: MemInfo,
    pub disks: Vec<DiskInfo>,
    pub disk_total_read_bps: f64,
    pub disk_total_write_bps: f64,
    pub net: NetInfo,
    pub temps: Vec<TempInfo>,
    pub gpu: Option<gpu::GpuInfo>,
    pub load: Vec<f64>,
    pub uptime: u64,
    pub procs: Vec<ProcInfo>,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct HistoryPoint {
    pub ts: u64,
    pub cpu: f32,
    pub mem: f32,
    pub temp: f32,
    pub rx: f64,
    pub tx: f64,
    pub disk: f64,
}

#[derive(Default)]
pub struct History {
    pub points: VecDeque<HistoryPoint>,
}

impl History {
    pub fn push(&mut self, s: &Snapshot) {
        let temp = s
            .temps
            .iter()
            .find(|t| t.primary)
            .map(|t| t.value)
            .unwrap_or(0.0);
        let p = HistoryPoint {
            ts: s.ts,
            cpu: s.cpu.usage,
            mem: if s.mem.total > 0 {
                s.mem.used as f32 / s.mem.total as f32 * 100.0
            } else {
                0.0
            },
            temp,
            rx: s.net.rx_bps,
            tx: s.net.tx_bps,
            disk: s.disk_total_read_bps + s.disk_total_write_bps,
        };
        if self.points.len() >= HISTORY_CAP {
            self.points.pop_front();
        }
        self.points.push_back(p);
    }

    pub fn tail(&self, n: usize) -> Vec<HistoryPoint> {
        let n = n.min(self.points.len());
        self.points.iter().skip(self.points.len() - n).cloned().collect()
    }
}

pub struct Collector {
    sys: System,
    disks: Disks,
    nets: Networks,
    comps: Components,
    want_procs: Arc<AtomicBool>,
    host: HostInfo,
    last_net: Instant,
    last_io: Instant,
    // 分级刷新改成按「距上次多久」判断，而不是按拍数取模。
    // 基础间隔由用户可调（1s / 5s / 10s / 自定义），取模会在间隔一变时全部错位。
    last_storage: Instant,
    last_temps: Instant,
    last_procs: Instant,
    gpu_rx: Option<std::sync::mpsc::Receiver<gpu::GpuInfo>>,
    gpu_last: Option<gpu::GpuInfo>,
}

impl Collector {
    pub fn new(want_procs: Arc<AtomicBool>) -> Self {
        let mut sys = System::new();
        sys.refresh_cpu_all();
        sys.refresh_memory();

        let mut disks = Disks::new_with_refreshed_list();
        disks.refresh(true);

        let nets = Networks::new_with_refreshed_list();
        let comps = Components::new_with_refreshed_list();

        let host = HostInfo {
            name: System::host_name().unwrap_or_else(|| "unknown".into()),
            os: System::long_os_version().unwrap_or_else(|| std::env::consts::OS.into()),
            kernel: System::kernel_version().unwrap_or_default(),
            arch: System::cpu_arch(),
            app_version: env!("CARGO_PKG_VERSION").into(),
        };

        // GPU 采集独立线程：ioreg / NVML 都是「慢查询」，不能拖累主循环
        let gpu_rx = gpu::spawn_probe();

        Self {
            sys,
            disks,
            nets,
            comps,
            want_procs,
            host,
            last_net: Instant::now(),
            last_io: Instant::now(),
            last_storage: Instant::now(),
            last_temps: Instant::now(),
            last_procs: Instant::now(),
            gpu_rx,
            gpu_last: None,
        }
    }

    pub fn tick(&mut self) -> Snapshot {
        let now = Instant::now();
        let net_elapsed = now.duration_since(self.last_net).as_secs_f64().max(0.001);
        self.last_net = now;

        self.sys.refresh_cpu_usage();
        self.sys.refresh_memory();
        self.nets.refresh(true);

        // 磁盘容量枚举（statfs 每个挂载点）单次 ~57ms，不能高频做；
        // 而 IO 统计只要 ~3ms，可以按需高频。两者拆开。
        if now.duration_since(self.last_storage) >= Duration::from_secs(30) {
            self.disks
                .refresh_specifics(true, DiskRefreshKind::nothing().with_storage().with_kind());
            self.last_storage = now;
        }
        let panel_open = self.want_procs.load(Ordering::Relaxed);
        let do_io = panel_open && now.duration_since(self.last_io) >= Duration::from_secs(2);
        if do_io {
            self.disks
                .refresh_specifics(false, DiskRefreshKind::nothing().with_io_usage());
        }
        let io_elapsed = now.duration_since(self.last_io).as_secs_f64().max(0.001);
        if do_io {
            self.last_io = now;
        }

        // 温度：IOHIDEventSystemClient 单次 ~76ms，5s 一次足够（温度是慢变量）
        if now.duration_since(self.last_temps) >= Duration::from_secs(5) {
            self.comps.refresh(false);
            self.last_temps = now;
        }

        if panel_open && now.duration_since(self.last_procs) >= Duration::from_secs(3) {
            self.sys.refresh_processes(ProcessesToUpdate::All, true);
            self.last_procs = now;
        }

        // ---- CPU ----
        let cpus = self.sys.cpus();
        let per_core: Vec<f32> = cpus.iter().map(|c| c.cpu_usage()).collect();
        let usage = if per_core.is_empty() {
            0.0
        } else {
            per_core.iter().sum::<f32>() / per_core.len() as f32
        };
        let cpu = CpuInfo {
            usage: smooth(usage),
            per_core: per_core.iter().map(|v| round1(*v)).collect(),
            brand: cpus
                .first()
                .map(|c| c.brand().trim().to_string())
                .unwrap_or_default(),
            cores: cpus.len(),
            physical: System::physical_core_count().unwrap_or(cpus.len()),
            freq_mhz: cpus.iter().map(|c| c.frequency()).max().unwrap_or(0),
        };

        // ---- 内存 ----
        let total = self.sys.total_memory();
        let used = self.sys.used_memory();
        let mem = MemInfo {
            total,
            used,
            available: self.sys.available_memory(),
            swap_total: self.sys.total_swap(),
            swap_used: self.sys.used_swap(),
        };

        // ---- 磁盘 ----
        let mut disks = Vec::new();
        let mut read_sum = 0.0;
        let mut write_sum = 0.0;
        for d in self.disks.list() {
            let u = d.usage();
            let r = if do_io { u.read_bytes as f64 / io_elapsed } else { 0.0 };
            let w = if do_io { u.written_bytes as f64 / io_elapsed } else { 0.0 };
            read_sum += r;
            write_sum += w;
            let total_space = d.total_space();
            let free = d.available_space();
            disks.push(DiskInfo {
                name: d.name().to_string_lossy().to_string(),
                mount: d.mount_point().to_string_lossy().to_string(),
                fs: d.file_system().to_string_lossy().to_string(),
                kind: format!("{:?}", d.kind()),
                total: total_space,
                free,
                used: total_space.saturating_sub(free),
                read_bps: r,
                write_bps: w,
                removable: d.is_removable(),
            });
        }
        disks.sort_by(|a, b| {
            b.total
                .cmp(&a.total)
                .then(a.mount.len().cmp(&b.mount.len()))
        });
        // APFS 会把同一个卷挂到多个挂载点（/ 与 /System/Volumes/Data），容量和卷名都一样。
        // 按 (卷名, 容量) 去重，保留挂载路径最短的那个（也就是 /）。
        // 不能把 free 也算进 key：两个挂载点报的空闲空间可能差几个字节，那样就漏去重了。
        let mut seen = std::collections::HashSet::new();
        disks.retain(|d| seen.insert((d.name.clone(), d.total)));

        // ---- 网络 ----
        let mut rx = 0u64;
        let mut tx = 0u64;
        let mut total_rx = 0u64;
        let mut total_tx = 0u64;
        for (name, data) in self.nets.list() {
            if name.starts_with("lo") {
                continue;
            }
            rx += data.received();
            tx += data.transmitted();
            total_rx += data.total_received();
            total_tx += data.total_transmitted();
        }
        let net = NetInfo {
            rx_bps: rx as f64 / net_elapsed,
            tx_bps: tx as f64 / net_elapsed,
            total_rx,
            total_tx,
        };

        // ---- 温度 ----
        let temps = self.collect_temps();

        // ---- GPU ----
        if let Some(rx_ch) = &self.gpu_rx {
            while let Ok(g) = rx_ch.try_recv() {
                self.gpu_last = Some(g);
            }
        }

        // ---- 进程 ----
        //
        // 前端要能按 CPU / 内存两种方式排序，所以后端不能只留「CPU 前 N」：
        // 一个吃 2GB 内存但几乎不占 CPU 的进程会直接被筛掉，用户切到内存排序时
        // 榜上全是零。这里取两个维度各前 20 的**并集**（去重后 ≤40 条），
        // 前端按当前排序键再排一次并截断——两边都不做假设。
        const TOP: usize = 20;
        let mut procs = Vec::new();
        if self.want_procs.load(Ordering::Relaxed) {
            let all: Vec<ProcInfo> = self
                .sys
                .processes()
                .iter()
                .map(|(pid, p)| ProcInfo {
                    pid: pid.as_u32(),
                    name: p.name().to_string_lossy().to_string(),
                    cpu: round1(p.cpu_usage()),
                    mem: p.memory(),
                })
                .collect();

            let mut by_cpu: Vec<usize> = (0..all.len()).collect();
            by_cpu.sort_by(|&a, &b| {
                all[b]
                    .cpu
                    .partial_cmp(&all[a].cpu)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let mut by_mem: Vec<usize> = (0..all.len()).collect();
            by_mem.sort_by(|&a, &b| all[b].mem.cmp(&all[a].mem));

            let mut keep = std::collections::HashSet::with_capacity(TOP * 2);
            keep.extend(by_cpu.into_iter().take(TOP));
            keep.extend(by_mem.into_iter().take(TOP));

            procs = all
                .into_iter()
                .enumerate()
                .filter(|(i, _)| keep.contains(i))
                .map(|(_, p)| p)
                .collect();
            // 默认顺序仍按 CPU，前端切换排序时自己再排
            procs.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        }

        let load = System::load_average();

        Snapshot {
            ts: now_ms(),
            host: self.host.clone(),
            cpu,
            mem,
            disks,
            disk_total_read_bps: read_sum,
            disk_total_write_bps: write_sum,
            net,
            temps,
            gpu: self.gpu_last.clone(),
            load: vec![round2(load.one), round2(load.five), round2(load.fifteen)],
            uptime: System::uptime(),
            procs,
        }
    }

    fn collect_temps(&self) -> Vec<TempInfo> {
        let mut raw: Vec<TempInfo> = self
            .comps
            .list()
            .iter()
            .filter_map(|c| {
                let v = c.temperature()?;
                if !(1.0..130.0).contains(&v) {
                    return None;
                }
                let label = c.label().to_string();
                // "PMU tcal" 之类的校准传感器不是真实测温点
                if label.to_lowercase().contains("tcal") {
                    return None;
                }
                Some(TempInfo {
                    label,
                    value: round1(v),
                    max: c.max(),
                    critical: c.critical(),
                    primary: false,
                })
            })
            .collect();

        // 选出「最能代表 CPU/SoC」的那一路传感器
        if let Some(idx) = pick_primary(&raw) {
            raw[idx].primary = true;
        }
        // 去重同名传感器，按温度降序，最多 8 路
        raw.sort_by(|a, b| {
            b.primary
                .cmp(&a.primary)
                .then(b.value.partial_cmp(&a.value).unwrap_or(std::cmp::Ordering::Equal))
        });
        raw.truncate(8);
        raw
    }
}

/// 传感器标签打分：越高越可能是 CPU 主温度
fn score_label(label: &str) -> i32 {
    let l = label.to_lowercase();
    let mut s = 0;
    if l.contains("tdie") {
        s += 120;
    }
    if l.contains("cpu") || l.contains("processor") {
        s += 100;
    }
    if l.contains("package") || l.contains("soc") {
        s += 90;
    }
    if l.contains("core") {
        s += 60;
    }
    if l.contains("die") {
        s += 50;
    }
    // 排除项
    if l.contains("battery") || l.contains("gas gauge") {
        s -= 200;
    }
    if l.contains("gpu") || l.contains("gfx") {
        s -= 80;
    }
    if l.contains("nand") || l.contains("ssd") || l.contains("nvme") {
        s -= 60;
    }
    if l.contains("ambient") || l.contains("board") || l.contains("wifi") {
        s -= 50;
    }
    s
}

fn pick_primary(temps: &[TempInfo]) -> Option<usize> {
    temps
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| {
            score_label(&a.label)
                .cmp(&score_label(&b.label))
                .then(a.value.partial_cmp(&b.value).unwrap_or(std::cmp::Ordering::Equal))
        })
        .and_then(|(i, t)| if score_label(&t.label) > 0 { Some(i) } else { None })
}

// 轻量平滑：显示值不要跟着采样抖动跳舞
fn smooth(v: f32) -> f32 {
    round1(v)
}

fn round1(v: f32) -> f32 {
    (v * 10.0).round() / 10.0
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// 采集主循环。间隔由调用方每次现取——用户随时可能把 10s 改成 1s，
/// 所以睡眠切成 250ms 的小片，一旦发现间隔变了立刻重新开始计时，
/// 不用等完当前这一整段（否则从 10s 调到 1s 后要卡 10 秒才生效）。
pub fn run_loop<F, G>(mut collect: F, interval: G)
where
    F: FnMut(),
    G: Fn() -> Duration,
{
    loop {
        collect();
        let target = interval();
        let start = Instant::now();
        while start.elapsed() < target {
            let left = target.saturating_sub(start.elapsed());
            std::thread::sleep(left.min(Duration::from_millis(250)));
            if interval() != target {
                break;
            }
        }
    }
}
