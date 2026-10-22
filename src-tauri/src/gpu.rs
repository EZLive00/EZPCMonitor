//! GPU 采集（尽力而为，失败即降级为 None，绝不影响主循环）
//!
//! - macOS：解析 `ioreg -c IOAccelerator` 的 PerformanceStatistics（Apple Silicon 可用）
//! - Linux：读 `/sys/class/drm/card*/device/gpu_busy_percent`（amd/i915 可用）
//! - Windows：MVP 暂缺，路线图中通过 NVML / D3DKMT 补齐

use serde::Serialize;
use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct GpuInfo {
    pub name: String,
    pub utilization: Option<f32>,
    pub mem_used: Option<u64>,
    pub mem_total: Option<u64>,
}

pub fn spawn_probe() -> Option<Receiver<GpuInfo>> {
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1500));
            loop {
                if let Some(info) = probe_once() {
                    if tx.send(info).is_err() {
                        break;
                    }
                }
                std::thread::sleep(Duration::from_secs(5));
            }
        });
        Some(rx)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
fn probe_once() -> Option<GpuInfo> {
    let out = std::process::Command::new("ioreg")
        .args(["-r", "-d", "1", "-c", "IOAccelerator"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let util = extract_int(&text, "\"Device Utilization %\"=").map(|v| v as f32);
    let mem = extract_int(&text, "\"In use system memory\"=");
    let name = if cfg!(target_arch = "aarch64") {
        "Apple GPU".to_string()
    } else {
        "GPU".to_string()
    };
    if util.is_none() && mem.is_none() {
        return None;
    }
    Some(GpuInfo {
        name,
        utilization: util,
        mem_used: mem,
        mem_total: None,
    })
}

#[cfg(target_os = "macos")]
fn extract_int(text: &str, key: &str) -> Option<u64> {
    let idx = text.find(key)? + key.len();
    let rest = &text[idx..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

#[cfg(target_os = "linux")]
fn probe_once() -> Option<GpuInfo> {
    use std::fs;
    let entries = fs::read_dir("/sys/class/drm").ok()?;
    for e in entries.flatten() {
        let p = e.path().join("device/gpu_busy_percent");
        if let Ok(s) = fs::read_to_string(&p) {
            if let Ok(v) = s.trim().parse::<f32>() {
                return Some(GpuInfo {
                    name: e.file_name().to_string_lossy().to_string(),
                    utilization: Some(v),
                    mem_used: None,
                    mem_total: None,
                });
            }
        }
    }
    None
}
