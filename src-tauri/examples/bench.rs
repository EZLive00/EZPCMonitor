//! 采集内核基准：拆到每个子系统，找出真正的性能热点。
//!
//!     cargo run --release --example bench
//!
//! 结论（macOS 15 / Apple Silicon）：温度（IOHIDEventSystemClient）单次 ~40ms，
//! 是唯一的热点；磁盘与网络都在 1ms 量级。所以温度降频到 3s 一次。

use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::{Duration, Instant};

use ezpcm::metrics::Collector;
use sysinfo::{Components, DiskRefreshKind, Disks, Networks, ProcessesToUpdate, System};

fn time_it<F: FnMut()>(n: usize, mut f: F) -> (f64, f64) {
    let mut v = Vec::with_capacity(n);
    for _ in 0..n {
        let t = Instant::now();
        f();
        v.push(t.elapsed().as_secs_f64() * 1000.0);
        std::thread::sleep(Duration::from_millis(120));
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    (v.iter().sum::<f64>() / v.len() as f64, v[v.len() - 1])
}

fn main() {
    let mut sys = System::new();
    sys.refresh_cpu_all();
    sys.refresh_memory();
    let mut disks = Disks::new_with_refreshed_list();
    let mut nets = Networks::new_with_refreshed_list();
    let mut comps = Components::new_with_refreshed_list();

    let (cpu, cpu_max) = time_it(10, || sys.refresh_cpu_usage());
    let (mem, _) = time_it(10, || sys.refresh_memory());
    let (disk, disk_max) = time_it(10, || disks.refresh(true));
    let (d_store, _) = time_it(6, || {
        disks.refresh_specifics(false, DiskRefreshKind::nothing().with_storage());
    });
    let (d_io, _) = time_it(6, || {
        disks.refresh_specifics(false, DiskRefreshKind::nothing().with_io_usage());
    });
    let (net, _) = time_it(10, || nets.refresh(true));
    let (temp, temp_max) = time_it(10, || comps.refresh(false));
    let (proc_, proc_max) = time_it(5, || {
        sys.refresh_processes(ProcessesToUpdate::All, true);
    });

    println!("── 子系统单次耗时 (ms) ──────────────────────────");
    println!("  CPU 使用率     avg {:6.2}   max {:6.2}", cpu, cpu_max);
    println!("  内存           avg {:6.2}", mem);
    println!("  磁盘容量+IO    avg {:6.2}   max {:6.2}", disk, disk_max);
    println!("    ├ 仅容量     avg {:6.2}", d_store);
    println!("    └ 仅 IO      avg {:6.2}", d_io);
    println!("  网络           avg {:6.2}", net);
    println!("  温度传感器     avg {:6.2}   max {:6.2}   <-- 热点", temp, temp_max);
    println!("  进程列表       avg {:6.2}   max {:6.2}", proc_, proc_max);

    let mut c = Collector::new(Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false)));
    for _ in 0..3 {
        c.tick();
        std::thread::sleep(Duration::from_millis(1100));
    }
    let (tick, tick_max) = time_it(12, || {
        c.tick();
    });
    println!("── 合成一帧 ────────────────────────────────────");
    println!("  悬浮窗模式     avg {:6.2}   max {:6.2}   → 1Hz 约占单核 {:.2}%", tick, tick_max, tick / 10.0);

    let mut cp = Collector::new(Arc::new(AtomicBool::new(true)), Arc::new(AtomicBool::new(true)));
    cp.tick();
    let (tickp, _) = time_it(8, || {
        cp.tick();
    });
    println!("  主面板模式     avg {:6.2}                  → 1Hz 约占单核 {:.2}%", tickp, tickp / 10.0);
}
