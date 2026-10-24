//! 历史记录：把指标按固定节奏落盘，让「刚才那一下卡顿是什么时候」可以被回溯。
//!
//! 三个刻意的取舍：
//!
//! 1. **落盘节奏固定 10 秒**，跟用户设的采集间隔解耦。采集可以 1 秒，也可以 10 秒，
//!    写文件永远是 10 秒一条——回溯看的是趋势，1 秒粒度只会把文件撑大十倍。
//!    （间隔比 10 秒还慢时，实际就是「每拍写一条」。）
//! 2. **默认关闭**。这个程序原本的卖点是「零落盘」，悄悄开始写文件不能算特性，
//!    得用户自己点头（见 ADR-011）。
//! 3. **JSON Lines + 整文件重写**。追加只写一行，修剪时把保留窗口内的行搬到临时文件
//!    再 rename 覆盖——rename 是原子的，掉电也不会留下半截文件。

use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

/// 落盘节奏（秒）。见文件头注释。
pub const SAMPLE_SECS: u64 = 10;

/// 保留时长档位：1 小时 / 6 小时 / 24 小时 / 7 天 / 30 天。
/// 界面上的「预计占用」就是用这些值算出来的。
pub const RETENTION_PRESETS: [u64; 5] = [3600, 21_600, 86_400, 604_800, 2_592_000];

pub const MIN_RETENTION: u64 = 600; // 10 分钟
pub const MAX_RETENTION: u64 = 90 * 86_400; // 90 天

/// 没有历史数据时用来估大小的经验值（字节/条）。
/// 实际值会在 `Stats::bytes_per_record` 里按真实文件反算，这个只是兜底。
pub const NOMINAL_BYTES: u64 = 88;

/// 文件里的一行。键名压到一个字母：一条记录省 20 字节，30 天就是 5 MB。
#[derive(Serialize, Deserialize, Clone, Copy, Debug)]
pub struct Row {
    #[serde(rename = "t")]
    pub t: u64,
    #[serde(rename = "c")]
    pub cpu: f32,
    #[serde(rename = "m")]
    pub mem: f32,
    #[serde(rename = "p")]
    pub temp: f32,
    #[serde(rename = "r")]
    pub rx: u64,
    #[serde(rename = "w")]
    pub tx: u64,
    #[serde(rename = "d")]
    pub disk: u64,
    #[serde(rename = "g")]
    pub gpu: f32,
}

/// 交给前端的形状：字段名可读，短键只活在文件里。
#[derive(Serialize, Clone, Copy, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Point {
    pub t: u64,
    pub cpu: f32,
    pub mem: f32,
    pub temp: f32,
    pub rx: u64,
    pub tx: u64,
    pub disk: u64,
    pub gpu: f32,
}

impl From<Row> for Point {
    fn from(r: Row) -> Self {
        Self {
            t: r.t,
            cpu: r.cpu,
            mem: r.mem,
            temp: r.temp,
            rx: r.rx,
            tx: r.tx,
            disk: r.disk,
            gpu: r.gpu,
        }
    }
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub count: u64,
    pub bytes: u64,
    /// 实测的每条字节数（文件为空时退回 `NOMINAL_BYTES`）
    pub bytes_per_record: u64,
    /// 最早 / 最晚一条的时间戳（秒），空文件为 0
    pub oldest: u64,
    pub newest: u64,
}

pub fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

pub fn clamp_retention(secs: u64) -> u64 {
    secs.clamp(MIN_RETENTION, MAX_RETENTION)
}

/// 文件大小上限：留 30% 余量再修剪，避免每写一条就重写一次整个文件。
fn cap_bytes(retention_secs: u64) -> u64 {
    (retention_secs / SAMPLE_SECS).max(1) * NOMINAL_BYTES * 13 / 10
}

pub struct Recorder {
    path: PathBuf,
    file: Option<File>,
    /// 启动时不数文件，等第一次要看统计再数（20 MB 文件扫一遍约 10 ms，
    /// 但没必要挡在启动路径上）
    count: Option<u64>,
}

impl Recorder {
    pub fn new(dir: &Path) -> Self {
        let _ = std::fs::create_dir_all(dir);
        Self {
            path: dir.join("history.jsonl"),
            file: None,
            count: None,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn size(&self) -> u64 {
        std::fs::metadata(&self.path).map(|m| m.len()).unwrap_or(0)
    }

    /// 追加一条。写失败只吞掉并关掉句柄——历史记录坏了不该影响实时监控。
    pub fn append(&mut self, row: &Row) {
        if self.file.is_none() {
            match OpenOptions::new().create(true).append(true).open(&self.path) {
                Ok(f) => self.file = Some(f),
                Err(_) => return,
            }
        }
        let Ok(mut line) = serde_json::to_string(row) else {
            return;
        };
        line.push('\n');
        if let Some(f) = self.file.as_mut() {
            if f.write_all(line.as_bytes()).is_err() {
                self.file = None;
                self.count = None;
                return;
            }
        }
        if let Some(c) = self.count.as_mut() {
            *c += 1;
        }
    }

    /// 超出上限就按保留时长修剪。返回删掉的条数（0 表示没动）。
    pub fn trim_if_needed(&mut self, retention_secs: u64) -> u64 {
        if self.size() <= cap_bytes(retention_secs) {
            return 0;
        }
        self.trim(retention_secs)
    }

    pub fn trim(&mut self, retention_secs: u64) -> u64 {
        let cutoff = now_secs().saturating_sub(clamp_retention(retention_secs));
        // 先松手，Windows 上文件被占用时 rename 会失败
        self.file = None;
        let Ok(text) = std::fs::read_to_string(&self.path) else {
            self.count = Some(0);
            return 0;
        };

        let mut kept = String::with_capacity(text.len());
        let mut kept_n = 0u64;
        let mut dropped = 0u64;
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Row>(line) {
                // 坏行（写一半掉电等）直接丢，别让它一直占着位置
                Ok(r) if r.t >= cutoff => {
                    kept.push_str(line);
                    kept.push('\n');
                    kept_n += 1;
                }
                _ => dropped += 1,
            }
        }

        if dropped == 0 {
            self.count = Some(kept_n);
            return 0;
        }

        let tmp = self.path.with_extension("jsonl.tmp");
        if std::fs::write(&tmp, &kept).is_err() || std::fs::rename(&tmp, &self.path).is_err() {
            let _ = std::fs::remove_file(&tmp);
            return 0;
        }
        self.count = Some(kept_n);
        dropped
    }

    /// 读时间戳 >= `from` 的记录。文件最多几十 MB，一次读完过滤比随机寻道简单可靠。
    pub fn read_since(&self, from: u64) -> Vec<Point> {
        let Ok(f) = File::open(&self.path) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for line in BufReader::new(f).lines().map_while(Result::ok) {
            if line.is_empty() {
                continue;
            }
            if let Ok(r) = serde_json::from_str::<Row>(&line) {
                if r.t >= from {
                    out.push(r.into());
                }
            }
        }
        out
    }

    pub fn clear(&mut self) {
        self.file = None;
        let _ = std::fs::remove_file(&self.path);
        self.count = Some(0);
    }

    pub fn stats(&mut self) -> Stats {
        let bytes = self.size();
        if self.count.is_none() {
            self.count = Some(self.scan());
        }
        let count = self.count.unwrap_or(0);
        let (oldest, newest) = self.span();
        Stats {
            count,
            bytes,
            bytes_per_record: if count > 0 && bytes > 0 {
                bytes / count
            } else {
                NOMINAL_BYTES
            },
            oldest,
            newest,
        }
    }

    fn scan(&self) -> u64 {
        let Ok(f) = File::open(&self.path) else {
            return 0;
        };
        BufReader::new(f)
            .lines()
            .map_while(Result::ok)
            .filter(|l| !l.trim().is_empty())
            .count() as u64
    }

    /// 首尾两条的时间戳：只需要读第一行和最后一行。
    fn span(&self) -> (u64, u64) {
        let Ok(text) = std::fs::read_to_string(&self.path) else {
            return (0, 0);
        };
        let mut lines = text.lines().filter(|l| !l.trim().is_empty());
        let first = lines
            .next()
            .and_then(|l| serde_json::from_str::<Row>(l).ok())
            .map(|r| r.t)
            .unwrap_or(0);
        let last = text
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .and_then(|l| serde_json::from_str::<Row>(l).ok())
            .map(|r| r.t)
            .unwrap_or(0);
        (first, last)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("ezpcm-hist-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn row(t: u64, cpu: f32) -> Row {
        Row {
            t,
            cpu,
            mem: 40.0,
            temp: 50.0,
            rx: 1,
            tx: 2,
            disk: 3,
            gpu: 4.0,
        }
    }

    #[test]
    fn appends_and_reads_back() {
        let dir = tmpdir("append");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        for i in 0..5 {
            r.append(&row(now - 50 + i * 10, i as f32));
        }
        let pts = r.read_since(0);
        assert_eq!(pts.len(), 5);
        assert_eq!(pts[4].cpu, 4.0);

        // 只取后两条
        let pts = r.read_since(now - 20);
        assert_eq!(pts.len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn trim_drops_old_rows_and_keeps_order() {
        let dir = tmpdir("trim");
        let mut r = Recorder::new(&dir);
        let now = now_secs();
        // 三条老数据（2 小时前）+ 三条新数据
        for i in 0..3 {
            r.append(&row(now - 7200 + i, 1.0));
        }
        for i in 0..3 {
            r.append(&row(now - 20 + i, 9.0));
        }
        let dropped = r.trim(3600);
        assert_eq!(dropped, 3);

        let pts = r.read_since(0);
        assert_eq!(pts.len(), 3);
        assert!(pts.iter().all(|p| p.cpu == 9.0));
        assert_eq!(r.stats().count, 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bad_lines_are_discarded_not_fatal() {
        let dir = tmpdir("bad");
        let mut r = Recorder::new(&dir);
        r.append(&row(now_secs(), 1.0));
        // 模拟写一半掉电留下的半行
        let mut f = OpenOptions::new().append(true).open(r.path()).unwrap();
        f.write_all(b"{\"t\":123,\"c\":").unwrap();
        drop(f);

        assert_eq!(r.read_since(0).len(), 1);
        r.trim(86_400);
        assert_eq!(r.read_since(0).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stats_report_measured_record_size() {
        let dir = tmpdir("stats");
        let mut r = Recorder::new(&dir);
        assert_eq!(r.stats().bytes_per_record, NOMINAL_BYTES); // 空文件退回经验值
        for i in 0..10 {
            r.append(&row(now_secs() - i, 12.5));
        }
        let s = r.stats();
        assert_eq!(s.count, 10);
        assert!(s.bytes_per_record > 40 && s.bytes_per_record < 200, "{s:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn retention_is_clamped() {
        assert_eq!(clamp_retention(1), MIN_RETENTION);
        assert_eq!(clamp_retention(u64::MAX), MAX_RETENTION);
        assert_eq!(clamp_retention(86_400), 86_400);
    }
}
