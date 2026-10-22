//! 硬盘健康（SMART）采集
//!
//! 分三层，能拿到多少报多少，拿不到就明说，绝不用估算值冒充实测：
//!
//! 1. `diskutil info`（macOS 自带、无需权限）—— 只能给出 `SMART Status: Verified /
//!    Failing / Not Supported`，没有寿命、写入量这些真正有用的数字；
//! 2. `smartctl -j`（smartmontools，可选安装）—— 能给出 NVMe 的 `percentage_used`、
//!    `data_units_written`、`power_on_hours` 等；没装就老实说「未安装」；
//! 3. 其它平台 —— Linux 走 `findmnt` + smartctl，Windows 暂未接入（如实标注 N/A）。
//!
//! 采集成本：diskutil ~40ms，smartctl ~30ms。都只在主面板打开时按需触发，
//! 结果缓存 60s，且整个探测有 3s 硬超时，不会因为某个坏掉的外置盘卡住界面。

use serde::Serialize;
use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const CACHE_TTL: Duration = Duration::from_secs(60);
const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
/// 同时探测的挂载点上限（去重后一般只有 1~2 个）
const MAX_PROBES: usize = 4;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct DiskHealth {
    /// 对应的挂载点，前端靠它和 DiskInfo 配对
    pub mount: String,
    /// 物理盘标识（disk0 / nvme0n1 …），空字符串表示没解析出来
    pub device: String,
    pub model: String,
    pub serial: String,
    pub firmware: String,
    /// good | warning | bad | unknown
    pub status: String,
    /// 原始 SMART 文案，例如 "Verified"
    pub smart_status: String,
    /// 剩余寿命百分比 0~100
    pub life_left: Option<f64>,
    /// 已消耗寿命百分比 0~100
    pub life_used: Option<f64>,
    pub spare: Option<f64>,
    pub temperature: Option<f64>,
    pub power_on_hours: Option<u64>,
    pub power_cycles: Option<u64>,
    pub written_bytes: Option<u64>,
    pub read_bytes: Option<u64>,
    pub media_errors: Option<u64>,
    pub unsafe_shutdowns: Option<u64>,
    pub solid_state: Option<bool>,
    pub bus: String,
    /// 完整属性表：NVMe 是健康日志的每一项，ATA 是属性表的每一行
    pub attrs: Vec<SmartAttr>,
    /// 数据来源，前端要如实展示（"diskutil" / "smartctl 7.3"）
    pub source: String,
    /// 缺失说明，例如「未安装 smartmontools，仅能读取系统级健康状态」
    pub note: Option<String>,
}

/// 一行 SMART 属性。数值在 Rust 侧就格式化好，前端只负责排版——
/// 单位换算（NVMe 的 data unit、小时→天）放在这里，前后端不用各写一遍。
#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct SmartAttr {
    pub name: String,
    pub value: String,
    pub extra: String,
    /// 需要留意（低于阈值 / 关键计数非零）
    pub critical: bool,
}

static CACHE: Mutex<Option<(Instant, Vec<DiskHealth>)>> = Mutex::new(None);

/// 带缓存查询。`force = true` 忽略缓存（用户手动点「重新检测」）。
pub fn query(mounts: &[String], force: bool) -> Vec<DiskHealth> {
    // 采集线程刚起来时快照还是空的，这时候不能把「空结果」缓存 60s，
    // 否则用户刚好在这 1 秒内打开面板，就会一直看不到健康数据。
    if mounts.is_empty() {
        return Vec::new();
    }
    if !force {
        if let Ok(guard) = CACHE.lock() {
            if let Some((at, list)) = guard.as_ref() {
                if at.elapsed() < CACHE_TTL {
                    return list.clone();
                }
            }
        }
    }

    let list = probe_all(mounts.to_vec()).unwrap_or_else(|| {
        // 超时：把上一次的结果还回去，总比空列表强
        CACHE
            .lock()
            .ok()
            .and_then(|g| g.as_ref().map(|(_, l)| l.clone()))
            .unwrap_or_default()
    });

    if let Ok(mut guard) = CACHE.lock() {
        *guard = Some((Instant::now(), list.clone()));
    }
    list
}

/// 探测放到子线程，主线程只等最多 3s——外置盘掉线时 smartctl 可能挂很久
fn probe_all(mounts: Vec<String>) -> Option<Vec<DiskHealth>> {
    if mounts.is_empty() {
        return Some(Vec::new());
    }
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut out = Vec::new();
        let mut seen = std::collections::HashSet::new();
        for m in mounts.iter().take(MAX_PROBES) {
            let h = probe(m);
            // 同一块物理盘挂多个挂载点（APFS 的 / 与 /System/Volumes/Data）只报一次
            let key = if h.device.is_empty() {
                h.mount.clone()
            } else {
                h.device.clone()
            };
            if !seen.insert(key) {
                continue;
            }
            out.push(h);
        }
        let _ = tx.send(out);
    });
    rx.recv_timeout(PROBE_TIMEOUT).ok()
}

pub fn probe(mount: &str) -> DiskHealth {
    let mut h = DiskHealth {
        mount: mount.to_string(),
        status: "unknown".into(),
        ..Default::default()
    };

    #[cfg(target_os = "macos")]
    probe_macos(mount, &mut h);
    #[cfg(target_os = "linux")]
    probe_linux(mount, &mut h);
    #[cfg(target_os = "windows")]
    {
        let _ = mount;
        h.note = Some("Windows 端尚未接入 SMART 读取".into());
    }

    h
}

// ---------------------------------------------------------------- macOS

#[cfg(target_os = "macos")]
fn probe_macos(mount: &str, h: &mut DiskHealth) {
    // diskutil 一次就能同时给出 SMART 文案、是否固态、总线类型和物理盘归属
    let Some(info) = sh("diskutil", &["info", mount]) else {
        h.note = Some("无法读取磁盘信息（diskutil 调用失败）".into());
        return;
    };

    h.smart_status = field(&info, "SMART Status").unwrap_or("未知").to_string();
    h.bus = field(&info, "Protocol").unwrap_or("").to_string();
    h.solid_state = field(&info, "Solid State").map(|v| v.eq_ignore_ascii_case("yes"));
    h.source = "diskutil".into();
    if h.model.is_empty() {
        if let Some(name) = field(&info, "Media Name").or_else(|| field(&info, "Volume Name")) {
            h.model = name.to_string();
        }
    }

    match h.smart_status.as_str() {
        "Verified" => h.status = "good".into(),
        "Failing" => h.status = "bad".into(),
        _ => h.status = "unknown".into(),
    }

    // 物理盘：APFS 的挂载点指向的是合成卷（disk3s1s1），SMART 得问底下的 disk0
    if let Some(dev) = physical_disk(&info) {
        h.device = dev;
    }

    let Some(smartctl) = find_smartctl() else {
        h.note = Some("未安装 smartmontools，只能读到系统级健康状态；\n\
                       `brew install smartmontools` 后可显示寿命、写入量等详细数据"
            .into());
        return;
    };
    if h.device.is_empty() {
        h.note = Some("未能定位到物理磁盘，无法读取 SMART 详细数据".into());
        return;
    }

    let dev_path = format!("/dev/{}", h.device);
    match smartctl_json(&smartctl, &dev_path) {
        Ok(v) => {
            apply_smart(&v, h);
            h.source = format!("smartctl {}", smartctl_version(&smartctl));
            h.note = None;
        }
        Err(e) => {
            // 外置 USB 硬盘盒常常不支持直通 SMART，这里不是错误，是硬件限制
            h.note = Some(format!("smartctl 读取失败：{e}"));
        }
    }
}

#[cfg(target_os = "macos")]
fn physical_disk(info: &str) -> Option<String> {
    // 合成卷会直接给出「APFS Physical Store: disk0s2」
    if let Some(store) = field(info, "APFS Physical Store") {
        let d = strip_partition(store);
        if !d.is_empty() {
            return Some(d);
        }
    }
    let whole = field(info, "Whole")
        .map(|v| v.eq_ignore_ascii_case("yes"))
        .unwrap_or(false);
    if whole {
        return field(info, "Device Identifier").map(str::to_string);
    }
    field(info, "Part of Whole")
        .filter(|v| *v != "?" && !v.is_empty())
        .map(strip_partition)
}

// ---------------------------------------------------------------- Linux

#[cfg(target_os = "linux")]
fn probe_linux(mount: &str, h: &mut DiskHealth) {
    let Some(src) = sh("findmnt", &["-n", "-o", "SOURCE", "--target", mount]) else {
        h.note = Some("无法解析挂载点对应的设备".into());
        return;
    };
    let src = src.trim();
    if src.is_empty() || src.starts_with("tmpfs") || src.starts_with("overlay") {
        h.note = Some("该挂载点不是物理磁盘".into());
        return;
    }
    let dev = strip_linux_partition(src.rsplit('/').next().unwrap_or(src));
    h.device = dev.clone();
    // ROTA=1 表示机械盘
    if let Some(rota) = sh("lsblk", &["-dno", "ROTA", &format!("/dev/{dev}")]) {
        h.solid_state = Some(rota.trim() == "0");
    }

    let Some(smartctl) = find_smartctl() else {
        h.note = Some("未安装 smartmontools，Linux 下无法读取 SMART（`apt install smartmontools`）".into());
        return;
    };
    match smartctl_json(&smartctl, &format!("/dev/{dev}")) {
        Ok(v) => {
            apply_smart(&v, h);
            h.source = format!("smartctl {}", smartctl_version(&smartctl));
        }
        Err(e) => h.note = Some(format!("smartctl 读取失败：{e}")),
    }
}

// ---------------------------------------------------------------- 通用

/// 解析 smartctl -x -j 输出，把能用的字段全部填进去
fn apply_smart(v: &serde_json::Value, h: &mut DiskHealth) {
    if h.model.is_empty() {
        if let Some(m) = v["model_name"].as_str().or_else(|| v["device"]["model"].as_str()) {
            h.model = m.trim().to_string();
        }
    }
    h.serial = v["serial_number"].as_str().unwrap_or("").trim().to_string();
    h.firmware = v["firmware_version"].as_str().unwrap_or("").trim().to_string();
    if let Some(p) = v["smart_status"]["passed"].as_bool() {
        h.smart_status = if p { "Verified" } else { "Failing" }.into();
        h.status = if p { "good".into() } else { "bad".into() };
    }

    let log = &v["nvme_smart_health_information_log"];
    if log.is_object() {
        if let Some(pu) = log["percentage_used"].as_f64() {
            h.life_used = Some(pu.clamp(0.0, 100.0));
            h.life_left = Some((100.0 - pu).clamp(0.0, 100.0));
        }
        h.spare = log["available_spare"].as_f64();
        h.media_errors = log["media_errors"].as_u64();
        h.unsafe_shutdowns = log["unsafe_shutdowns"].as_u64();
        h.power_on_hours = log["power_on_hours"].as_u64();
        h.power_cycles = log["power_cycles"].as_u64();
        // NVMe 的一个 data unit = 1000 × 512 字节
        h.written_bytes = log["data_units_written"].as_u64().map(|u| u * 1000 * 512);
        h.read_bytes = log["data_units_read"].as_u64().map(|u| u * 1000 * 512);
        if let Some(cw) = log["critical_warning"].as_u64() {
            if cw != 0 {
                h.status = "warning".into();
            }
        }
        h.attrs = nvme_rows(log);
    } else if let Some(attrs) = v["ata_smart_attributes"]["table"].as_array() {
        h.attrs = ata_rows(attrs);
        // SATA 盘：只能从属性表里挑几个通用的
        for a in attrs {
            let id = a["id"].as_u64().unwrap_or(0);
            let raw = a["raw"]["value"].as_u64();
            match id {
                // 231/177/233 都是各家厂商的「剩余寿命」写法
                231 | 177 | 233 => {
                    if let Some(r) = raw {
                        h.life_left = Some((r as f64).min(100.0));
                        h.life_used = Some(100.0 - (r as f64).min(100.0));
                    }
                }
                9 => h.power_on_hours = raw,
                12 => h.power_cycles = raw,
                194 | 190 => {
                    if let Some(r) = raw {
                        h.temperature = Some(r as f64);
                    }
                }
                5 | 197 | 198 => {
                    if let Some(r) = raw {
                        if r > 0 {
                            h.media_errors = Some(h.media_errors.unwrap_or(0) + r);
                        }
                    }
                }
                _ => {}
            }
        }
    }

    if h.temperature.is_none() {
        h.temperature = v["temperature"]["current"].as_f64();
    }
    if h.power_on_hours.is_none() {
        h.power_on_hours = v["power_on_time"]["hours"].as_u64();
    }
    if h.power_cycles.is_none() {
        h.power_cycles = v["power_cycle_count"].as_u64();
    }

    // 判定优先级：明确失败 > 临界告警 > 寿命见底 > 有介质错误
    if h.status != "bad" {
        let low_life = h.life_left.map(|l| l < 10.0).unwrap_or(false);
        let errors = h.media_errors.unwrap_or(0) > 0;
        if low_life || errors {
            h.status = "warning".into();
        }
    }
}

/// NVMe 健康日志 → 属性表。顺序按「先看要紧的」排，和 CrystalDiskInfo 一致。
fn nvme_rows(log: &serde_json::Value) -> Vec<SmartAttr> {
    let mut out = Vec::new();
    let mut row = |name: &str, value: String, extra: String, critical: bool| {
        out.push(SmartAttr {
            name: name.to_string(),
            value,
            extra,
            critical,
        });
    };

    if let Some(cw) = log["critical_warning"].as_u64() {
        let bits = critical_warning_text(cw);
        row(
            "严重警告",
            if cw == 0 { "0（正常）".into() } else { format!("{cw}（{bits}）") },
            String::new(),
            cw != 0,
        );
    }
    if let Some(pu) = log["percentage_used"].as_f64() {
        row(
            "已用寿命",
            format!("{}%", trim_num(pu)),
            format!("剩余 {}%", trim_num((100.0 - pu).clamp(0.0, 100.0))),
            pu >= 90.0,
        );
    }
    if let Some(s) = log["available_spare"].as_f64() {
        let thresh = log["available_spare_threshold"].as_f64();
        row(
            "可用备用块",
            format!("{}%", trim_num(s)),
            thresh.map(|t| format!("阈值 {}%", trim_num(t))).unwrap_or_default(),
            thresh.map(|t| s < t).unwrap_or(false),
        );
    }
    if let Some(t) = log["temperature"].as_f64().or_else(|| log["temperature"].as_u64().map(|v| v as f64)) {
        row("温度", format!("{} °C", trim_num(t)), String::new(), t >= 70.0);
    }
    if let Some(m) = log["controller_busy_time"].as_u64() {
        row("控制器忙时", format!("{m} 分钟"), String::new(), false);
    }
    if let Some(c) = log["power_cycles"].as_u64() {
        row("通电次数", format!("{c} 次"), String::new(), false);
    }
    if let Some(hours) = log["power_on_hours"].as_u64() {
        row(
            "通电时间",
            format!("{hours} 小时"),
            format!("{} 天", hours / 24),
            false,
        );
    }
    if let Some(s) = log["unsafe_shutdowns"].as_u64() {
        row("异常掉电", format!("{s} 次"), String::new(), false);
    }
    if let Some(e) = log["media_errors"].as_u64() {
        row("介质错误", e.to_string(), String::new(), e > 0);
    }
    if let Some(e) = log["num_err_log_entries"].as_u64() {
        row("错误日志条目", e.to_string(), String::new(), e > 0);
    }
    if let Some(r) = log["host_reads"].as_u64() {
        row("主机读命令", format!("{} 次", thousands(r)), String::new(), false);
    }
    if let Some(w) = log["host_writes"].as_u64() {
        row("主机写命令", format!("{} 次", thousands(w)), String::new(), false);
    }
    if let Some(u) = log["data_units_read"].as_u64() {
        row(
            "累计读取",
            human_bytes(u * 1000 * 512),
            format!("{} 单元", thousands(u)),
            false,
        );
    }
    if let Some(u) = log["data_units_written"].as_u64() {
        row(
            "累计写入",
            human_bytes(u * 1000 * 512),
            format!("{} 单元", thousands(u)),
            false,
        );
    }
    out
}

/// ATA 属性表 → 统一的属性行（保留 id、归一化值、最差值、阈值、原始值）
fn ata_rows(table: &[serde_json::Value]) -> Vec<SmartAttr> {
    let mut out = Vec::new();
    for a in table {
        let id = a["id"].as_u64().unwrap_or(0);
        let name = a["name"].as_str().unwrap_or("").trim().to_string();
        let value = a["value"].as_i64();
        let worst = a["worst"].as_i64();
        let thresh = a["thresh"].as_i64();
        let raw = a["raw"]["string"]
            .as_str()
            .map(str::to_string)
            .or_else(|| a["raw"]["value"].as_u64().map(|v| v.to_string()))
            .unwrap_or_default();
        // 归一化值跌到阈值（含）以下，就是「该换盘」的信号
        let critical = match (value, thresh) {
            (Some(v), Some(t)) if t > 0 => v <= t,
            _ => false,
        };
        let mut extra = String::new();
        if let Some(w) = worst {
            extra.push_str(&format!("最差 {w}"));
        }
        if let Some(t) = thresh {
            if !extra.is_empty() {
                extra.push_str(" · ");
            }
            extra.push_str(&format!("阈值 {t}"));
        }
        if !raw.is_empty() {
            if !extra.is_empty() {
                extra.push_str(" · ");
            }
            extra.push_str(&format!("原始 {raw}"));
        }
        out.push(SmartAttr {
            name: if name.is_empty() { format!("属性 {id}") } else { format!("{id} {name}") },
            value: value.map(|v| v.to_string()).unwrap_or_default(),
            extra,
            critical,
        });
    }
    out
}

fn critical_warning_text(bits: u64) -> String {
    const NAMES: [(u64, &str); 5] = [
        (1, "备用块耗尽"),
        (2, "温度越界"),
        (4, "可靠性降级"),
        (8, "介质只读"),
        (16, "备份失败"),
    ];
    let hit: Vec<&str> = NAMES
        .iter()
        .filter(|(b, _)| bits & b != 0)
        .map(|(_, n)| *n)
        .collect();
    if hit.is_empty() {
        "未知".into()
    } else {
        hit.join("、")
    }
}

/// 十进制容量：和厂商标称 TBW、smartctl 打印的 [15.7 TB] 对齐
fn human_bytes(n: u64) -> String {
    const UNITS: [&str; 6] = ["B", "KB", "MB", "GB", "TB", "PB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1000.0 && i < UNITS.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", UNITS[i])
    }
}

fn thousands(n: u64) -> String {
    let s = n.to_string();
    let mut out = String::with_capacity(s.len() + s.len() / 3);
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

/// 0.0 → "0"，12.0 → "12"，12.5 → "12.5"
fn trim_num(v: f64) -> String {
    if (v - v.round()).abs() < f64::EPSILON {
        format!("{}", v.round() as i64)
    } else {
        format!("{v:.1}")
    }
}

fn smartctl_json(bin: &PathBuf, dev: &str) -> Result<serde_json::Value, String> {
    let out = Command::new(bin)
        .args(["-x", "-j", dev])
        .output()
        .map_err(|e| e.to_string())?;
    // smartctl 的退出码是位掩码：非 0 也可能带着完整 JSON（比如历史错误记录），
    // 所以只看能不能解析出 JSON，不看退出码。
    let text = String::from_utf8_lossy(&out.stdout);
    let text = text.trim();
    if text.is_empty() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    serde_json::from_str(text).map_err(|_| "输出不是合法 JSON".to_string())
}

fn smartctl_version(bin: &PathBuf) -> String {
    sh_path(bin, &["--version"])
        .and_then(|s| {
            s.lines()
                .find(|l| l.to_lowercase().contains("smartctl"))
                .and_then(|l| l.split_whitespace().nth(1))
                .map(str::to_string)
        })
        .unwrap_or_else(|| "?".into())
}

/// 随包自带的 smartctl（ADR-005 阶段 1），启动时由 lib.rs 注入
static BUNDLED: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
/// 解析结果只算一次：每次探测都 fork 一个 --version 太浪费
static RESOLVED: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

pub fn set_bundled(path: PathBuf) {
    let _ = BUNDLED.set(path);
}

/// 能不能跑起来——自带的是 arm64 单架构二进制，Intel Mac 上会 exec 失败，
/// 这时候要静默回落到系统安装的版本，而不是让整个磁盘页报错。
fn runnable(p: &PathBuf) -> bool {
    Command::new(p)
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn find_smartctl() -> Option<PathBuf> {
    RESOLVED
        .get_or_init(|| {
            // 1. 自带的优先：用户不需要装任何东西
            if let Some(p) = BUNDLED.get() {
                if runnable(p) {
                    return Some(p.clone());
                }
            }
            // 2. 系统已装的（brew / apt / 官方安装包）
            for c in CANDIDATES {
                let p = PathBuf::from(c);
                if p.is_file() && runnable(&p) {
                    return Some(p);
                }
            }
            // 3. PATH 里再找一遍（用户自己编译安装的情况）
            std::env::var_os("PATH").and_then(|path| {
                std::env::split_paths(&path)
                    .map(|d| d.join("smartctl"))
                    .find(|p| p.is_file() && runnable(p))
            })
        })
        .clone()
}

/// GUI 应用继承不到 shell 的 PATH，常见的安装位置直接列出来
const CANDIDATES: [&str; 7] = [
    "/opt/homebrew/bin/smartctl",
    "/usr/local/bin/smartctl",
    "/usr/bin/smartctl",
    "/usr/sbin/smartctl",
    "/sbin/smartctl",
    "/opt/local/bin/smartctl",
    r"C:\Program Files\smartmontools\bin\smartctl.exe",
];

fn sh(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() && out.stdout.is_empty() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

fn sh_path(bin: &PathBuf, args: &[&str]) -> Option<String> {
    let out = Command::new(bin).args(args).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).to_string())
}

/// 解析 `Key:   value` 形式的文本（diskutil / lsblk 输出都是这个套路）
fn field<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().find_map(|line| {
        let (k, v) = line.split_once(':')?;
        if k.trim().eq_ignore_ascii_case(key) {
            let v = v.trim();
            if v.is_empty() { None } else { Some(v) }
        } else {
            None
        }
    })
}

/// disk3s1s1 → disk0 的那一步只做「去掉分区后缀」：
/// 从尾部反复砍掉 `s<数字>`，直到砍不动为止。
fn strip_partition(dev: &str) -> String {
    let mut s = dev.trim();
    loop {
        match s.rfind('s') {
            Some(i) if i > 0 && s[i + 1..].chars().all(|c| c.is_ascii_digit()) && i + 1 < s.len() => {
                s = &s[..i];
            }
            _ => break,
        }
    }
    s.to_string()
}

/// Linux 的分区后缀还有 `p1` 这种写法（nvme0n1p2 → nvme0n1）
#[cfg(target_os = "linux")]
fn strip_linux_partition(dev: &str) -> String {
    let s = strip_partition(dev);
    match s.rfind('p') {
        Some(i) if i > 0 && s[i + 1..].chars().all(|c| c.is_ascii_digit()) && i + 1 < s.len() => {
            s[..i].to_string()
        }
        _ => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_partition_suffix() {
        assert_eq!(strip_partition("disk0s2"), "disk0");
        assert_eq!(strip_partition("disk3s1s1"), "disk3");
        assert_eq!(strip_partition("disk0"), "disk0");
        assert_eq!(strip_partition("sda1"), "sda1");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_diskutil_fields() {
        let t = "   Device Identifier:         disk3s1s1\n\
                 \x20  Whole:                     No\n\
                 \x20  Part of Whole:             disk3\n\
                 \x20  SMART Status:              Verified\n\
                 \x20  APFS Physical Store:       disk0s2\n";
        assert_eq!(field(t, "SMART Status"), Some("Verified"));
        assert_eq!(physical_disk(t), Some("disk0".into()));
    }

    #[test]
    fn parses_nvme_json() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"smart_status":{"passed":true},
                "nvme_smart_health_information_log":{"critical_warning":0,"temperature":34,
                "available_spare":100,"percentage_used":12,"data_units_written":30703765,
                "power_on_hours":847,"power_cycles":178,"media_errors":0,
                "unsafe_shutdowns":13}}"#,
        )
        .unwrap();
        let mut h = DiskHealth::default();
        apply_smart(&v, &mut h);
        assert_eq!(h.status, "good");
        assert_eq!(h.life_left, Some(88.0));
        assert_eq!(h.power_on_hours, Some(847));
        assert_eq!(h.written_bytes, Some(30703765u64 * 512000));
    }
}
