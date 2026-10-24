//! 高占用程序的历史榜：回答「过去 24 小时到底是谁在吃 CPU」。
//!
//! 曲线文件（`history.rs`）只存整机 8 个数字，回答不了「谁」。要回答「谁」就得
//! 另起一条采样流。这里记的四个决定：
//!
//! 1. **按进程名合并**。Chrome 会开十几个渲染进程，按 pid 记的话榜单前十全是
//!    `Google Chrome Helper`。合并要在**全量进程表**上做——先按 pid 取前 20 再合并
//!    会把同一个程序漏掉几份，加起来永远偏小。
//! 2. **只记高于门槛的**。桌面程序绝大多数时候在 0%，全记下来 30 天能到几百 MB，
//!    而榜单只关心「高占用」。缺席即视为低于门槛，均值按窗口内总采样数做分母，
//!    不会被漏记的那点零头抬起来。
//! 3. **按 UTC 小时分片**。修剪 = 删掉整个文件，永远不用重写；30 天也就 720 个
//!    小文件，比一个几百 MB 的大文件好伺候得多（掉电最多丢当前这一小时）。
//! 4. **字典行 + 数字行**。进程名在一个小时里只出现一次，之后只写
//!    `[名字编号, CPU, 内存MB, IO KB/s]` 四元组。比逐行带名字省 60% 体积，
//!    同时还是能 `head` 能 `jq` 的 JSONL。
//!
//! **不记中位数。** 中位数要拿到完整分布才能算，而桌面程序是典型的零质量分布
//! ——中位数会趴在 0% 上，前十名全是 0.0%，一点区分度都没有。换成「活跃占比」
//! （有多少比例的采样里它高于阈值），同样能回答「是不是常年高占用」，还能合并。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use crate::history::{clamp_retention, now_secs};

/// 采样节奏。比曲线的 10 秒慢——榜单看的是几小时的趋势，30 秒足够，
/// 而每条记录要带十几个进程，10 秒会把文件撑大三倍。
pub const SAMPLE_SECS: u64 = 30;

/// 进榜门槛：三个维度满足任一即记。低于这个量级的不值得占一行字节。
///
/// 内存那条定在 150MB 是有实测依据的：桌面系统上 RSS 超过 40MB 的进程有几十个，
/// 全记下来一个月能到 60MB；150MB 以上通常只剩十来个，而内存榜的前十本来就
/// 都在这个量级以上——门槛再低只是把「背景噪音」也写进文件。
pub const CPU_FLOOR: f32 = 0.5;
pub const MEM_FLOOR_MB: u32 = 150;
pub const IO_FLOOR_KB: u32 = 256;

/// 「活跃」的判定线：一次采样里 CPU ≥ 5% 或 IO ≥ 1 MB/s 才算活跃。
/// 活跃占比回答的是「它是不是经常在干活」，跟均值互补。
pub const ACTIVE_CPU: f32 = 5.0;
pub const ACTIVE_IO_KB: u32 = 1024;

/// 空目录时的经验值，用来给设置页估体积。
pub const NOMINAL_BYTES_PER_SAMPLE: u64 = 300;

/// 采集侧交过来的一条聚合记录（已经按名字合并好）。
pub struct Entry {
    pub name: String,
    pub cpu: f32,
    pub mem_mb: u32,
    pub io_kb: u32,
}

impl Entry {
    fn above_floor(&self) -> bool {
        self.cpu >= CPU_FLOOR || self.mem_mb >= MEM_FLOOR_MB || self.io_kb >= IO_FLOOR_KB
    }
}

// ---------------------------------------------------------------- 文件格式

/// 字典行：`{"d":["Google Chrome"]}`，从当前编号往后追加。
#[derive(Serialize, Deserialize)]
struct DictLine {
    d: Vec<String>,
}

/// 采样行：`{"t":1761234567,"p":[[3,12.3,524,0],…]}`。
/// 元组序列化成定长数组，比对象省掉 `"n":` `"c":` 这些键名。
#[derive(Serialize, Deserialize)]
struct SampleLine {
    t: u64,
    p: Vec<(u32, f32, u32, u32)>,
}

// ---------------------------------------------------------------- 时间分片

/// 1970-01-01 起的天数 → (年, 月, 日)。Howard Hinnant 的 civil_from_days，
/// 只为给分片文件起个能看懂的名字，不引入 chrono。
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as i64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// 分片名：`2026-10-23T14`。定宽、UTC、字典序即时序——
/// 修剪时直接拿字符串比大小，不用再把名字解析回时间。
pub fn shard_name(secs: u64) -> String {
    let hour = secs / 3600;
    let (y, m, d) = civil_from_days((hour / 24) as i64);
    format!("{y:04}-{m:02}-{d:02}T{:02}", hour % 24)
}

// ---------------------------------------------------------------- 写入

pub struct Recorder {
    dir: PathBuf,
    /// 当前打开的分片（UTC 小时序号）。0 表示还没开过文件。
    hour: u64,
    file: Option<File>,
    /// 当前分片的名字字典：名字 → 编号。换分片时清空。
    dict: HashMap<String, u32>,
}

impl Recorder {
    pub fn new(dir: &Path) -> Self {
        let _ = std::fs::create_dir_all(dir);
        Self {
            dir: dir.to_path_buf(),
            hour: 0,
            file: None,
            dict: HashMap::new(),
        }
    }

    /// 整个目录的字节数。30 天也就 720 个文件，一次遍历几毫秒，设置页才调。
    pub fn bytes(&self) -> u64 {
        let Ok(rd) = std::fs::read_dir(&self.dir) else {
            return 0;
        };
        rd.flatten()
            .filter(|e| e.path().extension().and_then(|s| s.to_str()) == Some("jsonl"))
            .filter_map(|e| e.metadata().ok())
            .map(|m| m.len())
            .sum()
    }

    /// 追加一次采样。`entries` 为空也要写——空行就是「这一拍大家都很闲」，
    /// 少了它，均值和不活跃占比的分母就对不上真实时间跨度。
    pub fn append(&mut self, t: u64, entries: &[Entry]) {
        if !self.open_shard(t / 3600) {
            return;
        }
        let mut line = String::with_capacity(32 + entries.len() * 20);
        let mut fresh = String::new();

        let mut tuples: Vec<(u32, f32, u32, u32)> = Vec::with_capacity(entries.len());
        for e in entries.iter().filter(|e| e.above_floor()) {
            let id = match self.dict.get(&e.name) {
                Some(id) => *id,
                None => {
                    let id = self.dict.len() as u32;
                    self.dict.insert(e.name.clone(), id);
                    // 新名字当场补一行字典。追加式写入，不回头改文件头。
                    if let Ok(s) = serde_json::to_string(&DictLine {
                        d: vec![e.name.clone()],
                    }) {
                        fresh.push_str(&s);
                        fresh.push('\n');
                    }
                    id
                }
            };
            tuples.push((id, e.cpu, e.mem_mb, e.io_kb));
        }

        let Ok(body) = serde_json::to_string(&SampleLine { t, p: tuples }) else {
            return;
        };
        line.push_str(&fresh);
        line.push_str(&body);
        line.push('\n');

        let Some(f) = self.file.as_mut() else { return };
        if f.write_all(line.as_bytes()).is_err() {
            // 写失败就关掉句柄，下一拍重开；历史记录坏了不该影响实时监控
            self.file = None;
            self.hour = 0;
            return;
        }
    }

    /// 换到 `hour` 对应的分片。返回是否可写。
    fn open_shard(&mut self, hour: u64) -> bool {
        if self.file.is_some() && self.hour == hour {
            return true;
        }
        self.file = None;
        let path = self.dir.join(format!("{}.jsonl", shard_name(hour * 3600)));
        match OpenOptions::new().create(true).append(true).open(&path) {
            Ok(f) => {
                // 字典是「每个分片一份」的：编号只在这个文件里有意义
                self.dict.clear();
                self.hour = hour;
                self.file = Some(f);
                true
            }
            Err(_) => false,
        }
    }

    /// 删掉整片早于保留期的分片。返回删掉的文件数。
    pub fn prune(&mut self, retention_secs: u64) -> u64 {
        let cutoff = now_secs().saturating_sub(clamp_retention(retention_secs));
        let floor = shard_name(cutoff);
        let Ok(rd) = std::fs::read_dir(&self.dir) else {
            return 0;
        };
        let mut removed = 0;
        for e in rd.flatten() {
            let path = e.path();
            if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            // 定宽 UTC 文件名，字典序 < 保留起点的那片整片都过期了
            if stem < floor.as_str() && std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        removed
    }

    pub fn clear(&mut self) {
        self.file = None;
        self.hour = 0;
        self.dict.clear();
        let _ = std::fs::remove_dir_all(&self.dir);
        let _ = std::fs::create_dir_all(&self.dir);
    }
}

// ---------------------------------------------------------------- 读取与聚合

/// 一个维度（CPU / 磁盘 IO）的统计：均值、峰值、峰值时刻、活跃占比。
#[derive(Serialize, Clone, Copy, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct DimStat {
    pub mean: f32,
    pub peak: f32,
    /// 峰值出现的 unix 秒
    pub peak_ts: u64,
    /// 活跃采样占全部采样的百分比（0~100）
    pub active: f32,
}

/// 内存是「存量」不是「流量」，所以除了均值和峰值，还要给首尾值——
/// 首尾之差就是这个窗口里涨了多少，能暴露慢慢泄漏的程序。
#[derive(Serialize, Clone, Copy, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemStat {
    pub mean_mb: f32,
    pub peak_mb: f32,
    pub peak_ts: u64,
    pub first_mb: f32,
    pub last_mb: f32,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Leader {
    pub name: String,
    /// 它出现过几次采样（缺席 = 低于门槛）
    pub samples: u32,
    pub cpu: DimStat,
    pub mem: MemStat,
    pub io: DimStat,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Leaders {
    /// 窗口内的总采样次数（含空拍），所有均值和占比都以它为分母
    pub total: u64,
    pub sample_secs: u64,
    pub rows: Vec<Leader>,
}

#[derive(Default, Clone)]
struct Acc {
    samples: u32,
    cpu_sum: f64,
    cpu_peak: f32,
    cpu_peak_t: u64,
    cpu_active: u32,
    mem_sum: f64,
    mem_peak: u32,
    mem_peak_t: u64,
    mem_first: u32,
    mem_last: u32,
    io_sum: f64,
    io_peak: u32,
    io_peak_t: u64,
    io_active: u32,
}

impl Acc {
    fn push(&mut self, t: u64, cpu: f32, mem: u32, io: u32) {
        if self.samples == 0 {
            self.mem_first = mem;
        }
        self.samples += 1;
        self.mem_last = mem;

        self.cpu_sum += cpu as f64;
        if cpu > self.cpu_peak {
            self.cpu_peak = cpu;
            self.cpu_peak_t = t;
        }
        if cpu >= ACTIVE_CPU {
            self.cpu_active += 1;
        }

        self.mem_sum += mem as f64;
        if mem > self.mem_peak {
            self.mem_peak = mem;
            self.mem_peak_t = t;
        }

        self.io_sum += io as f64;
        if io > self.io_peak {
            self.io_peak = io;
            self.io_peak_t = t;
        }
        if io >= ACTIVE_IO_KB {
            self.io_active += 1;
        }
    }
}

fn r1(v: f64) -> f32 {
    (v * 10.0).round() as f32 / 10.0
}

impl Recorder {
    /// 把 `[from, now]` 内的采样聚合成榜单，按 CPU 峰值降序。
    ///
    /// 一次扫完三个维度：调用方（前端）切维度、改排序都不用再回来读一遍文件。
    pub fn leaders(&self, from: u64) -> Leaders {
        let floor = shard_name(from);
        let mut files: Vec<PathBuf> = match std::fs::read_dir(&self.dir) {
            Ok(rd) => rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("jsonl"))
                .filter(|p| {
                    p.file_stem()
                        .and_then(|s| s.to_str())
                        .map(|s| s >= floor.as_str())
                        .unwrap_or(false)
                })
                .collect(),
            Err(_) => Vec::new(),
        };
        // 首/末值要按时间顺序，所以文件名必须排好再读
        files.sort();

        let mut total = 0u64;
        let mut acc: HashMap<String, Acc> = HashMap::new();

        for path in files {
            let Ok(f) = File::open(&path) else { continue };
            let mut dict: Vec<String> = Vec::new();
            for line in BufReader::new(f).lines().map_while(Result::ok) {
                if line.is_empty() {
                    continue;
                }
                if let Ok(d) = serde_json::from_str::<DictLine>(&line) {
                    dict.extend(d.d);
                    continue;
                }
                let Ok(s) = serde_json::from_str::<SampleLine>(&line) else {
                    continue; // 写一半掉电留下的残行
                };
                if s.t < from {
                    continue;
                }
                total += 1;
                for (id, cpu, mem, io) in s.p {
                    let Some(name) = dict.get(id as usize) else {
                        continue;
                    };
                    acc.entry(name.clone()).or_default().push(s.t, cpu, mem, io);
                }
            }
        }

        let denom = total.max(1) as f64;
        let mut rows: Vec<Leader> = acc
            .into_iter()
            .map(|(name, a)| Leader {
                name,
                samples: a.samples,
                cpu: DimStat {
                    mean: r1(a.cpu_sum / denom),
                    peak: a.cpu_peak,
                    peak_ts: a.cpu_peak_t,
                    active: r1(a.cpu_active as f64 / denom * 100.0),
                },
                mem: MemStat {
                    mean_mb: r1(a.mem_sum / denom),
                    peak_mb: a.mem_peak as f32,
                    peak_ts: a.mem_peak_t,
                    first_mb: a.mem_first as f32,
                    last_mb: a.mem_last as f32,
                },
                io: DimStat {
                    mean: r1(a.io_sum / denom),
                    peak: a.io_peak as f32,
                    peak_ts: a.io_peak_t,
                    active: r1(a.io_active as f64 / denom * 100.0),
                },
            })
            .collect();

        // 名字兜底排序：同峰值时不能让行序每刷新一次就跳
        rows.sort_by(|a, b| {
            b.cpu
                .peak
                .partial_cmp(&a.cpu.peak)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.name.cmp(&b.name))
        });

        Leaders {
            total,
            sample_secs: SAMPLE_SECS,
            rows,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ezpcm-proc-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn e(name: &str, cpu: f32, mem: u32, io: u32) -> Entry {
        Entry {
            name: name.into(),
            cpu,
            mem_mb: mem,
            io_kb: io,
        }
    }

    #[test]
    fn shard_names_are_sortable_utc_hours() {
        assert_eq!(shard_name(0), "1970-01-01T00");
        assert_eq!(shard_name(1_700_000_000), "2023-11-14T22");
        // 定宽 → 字典序即时序
        assert!(shard_name(1_700_000_000) < shard_name(1_700_000_000 + 3600));
        // 跨年
        assert_eq!(shard_name(1_704_067_200), "2024-01-01T00");
    }

    #[test]
    fn round_trips_and_merges_by_name() {
        let dir = tmpdir("round");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        r.append(now - 20, &[e("Chrome", 12.0, 500, 0), e("idle", 0.1, 10, 0)]);
        r.append(now - 10, &[e("Chrome", 8.0, 520, 4096), e("Xcode", 30.0, 900, 0)]);
        r.append(now, &[e("Chrome", 4.0, 510, 0)]);

        let l = r.leaders(now - 60);
        assert_eq!(l.total, 3);
        // idle 低于门槛，不该进榜
        assert_eq!(l.rows.len(), 2);

        let chrome = l.rows.iter().find(|x| x.name == "Chrome").unwrap();
        assert_eq!(chrome.samples, 3);
        assert_eq!(chrome.cpu.peak, 12.0);
        assert_eq!(chrome.cpu.peak_ts, now - 20);
        // 均值分母是全部采样（含没出现的），所以是 (12+8+4)/3
        assert!((chrome.cpu.mean - 8.0).abs() < 0.05, "{:?}", chrome.cpu);
        assert_eq!(chrome.mem.first_mb, 500.0);
        assert_eq!(chrome.mem.last_mb, 510.0);
        assert_eq!(chrome.mem.peak_mb, 520.0);
        assert_eq!(chrome.io.peak, 4096.0);
        // 3 拍里只有 1 拍 IO ≥ 1MB/s
        assert!((chrome.io.active - 33.3).abs() < 0.2, "{:?}", chrome.io);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn active_share_uses_total_samples_not_appearances() {
        let dir = tmpdir("active");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        // 10 拍里只有 2 拍在干活，其中 1 拍算活跃
        for i in 0..8 {
            r.append(now - 90 + i * 10, &[]);
        }
        r.append(now - 10, &[e("Backup", 60.0, 100, 0)]);
        r.append(now, &[e("Backup", 1.0, 100, 0)]);

        let l = r.leaders(now - 200);
        assert_eq!(l.total, 10);
        let b = l.rows.iter().find(|x| x.name == "Backup").unwrap();
        assert_eq!(b.samples, 2);
        assert!((b.cpu.active - 10.0).abs() < 0.2, "{:?}", b.cpu);
        assert!((b.cpu.mean - 6.1).abs() < 0.1, "{:?}", b.cpu);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dict_grows_across_samples() {
        let dir = tmpdir("dict");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        r.append(now - 20, &[e("A", 10.0, 0, 0)]);
        r.append(now - 10, &[e("A", 10.0, 0, 0), e("B", 20.0, 0, 0)]);
        r.append(now, &[e("B", 20.0, 0, 0)]);

        let l = r.leaders(0);
        assert_eq!(l.rows.len(), 2);
        let b = l.rows.iter().find(|x| x.name == "B").unwrap();
        assert_eq!(b.samples, 2);
        assert_eq!(b.cpu.peak, 20.0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn window_start_excludes_older_shards_and_samples() {
        let dir = tmpdir("window");
        let mut r = Recorder::new(&dir);
        let base = 1_700_000_000; // 固定时间，避开「正好跨小时」的抖动
        r.append(base, &[e("Old", 99.0, 0, 0)]);
        r.append(base + 7200, &[e("New", 10.0, 0, 0)]);

        let l = r.leaders(base + 3600);
        assert_eq!(l.total, 1);
        assert_eq!(l.rows.len(), 1);
        assert_eq!(l.rows[0].name, "New");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prune_drops_whole_shards() {
        let dir = tmpdir("prune");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        r.append(now - 90 * 86_400, &[e("Ancient", 50.0, 0, 0)]);
        r.append(now, &[e("Fresh", 50.0, 0, 0)]);
        assert_eq!(r.prune(3600), 1);
        // 当前这片不能被误删
        assert!(r.leaders(0).rows.iter().any(|x| x.name == "Fresh"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_lines_are_skipped() {
        let dir = tmpdir("corrupt");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        r.append(now, &[e("A", 10.0, 0, 0)]);
        let path = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .next()
            .unwrap();
        let mut f = OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(b"{\"t\":12,\"p\":[[").unwrap();
        drop(f);

        assert_eq!(r.leaders(0).total, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bytes_counts_only_shards() {
        let dir = tmpdir("bytes");
        let mut r = Recorder::new(&dir);
        assert_eq!(r.bytes(), 0);
        r.append(now_secs(), &[e("A", 10.0, 0, 0)]);
        assert!(r.bytes() > 20, "{}", r.bytes());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
