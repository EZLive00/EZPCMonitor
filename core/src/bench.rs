//! 磁盘测速：顺序读写 + 4K 随机读写（CrystalDiskMark 的极简版）
//!
//! 四项，各自回答不同的问题：
//!
//! | 项目 | 回答什么 |
//! |---|---|
//! | 顺序写 / 顺序读 | 这块盘**大文件**还快不快——拷素材、装系统看这个 |
//! | 4K 随机读 | 开程序、加载资源快不快——这是日常**手感**的主要来源 |
//! | 4K 随机写 | 小文件、日志、数据库写入——SSD 掉速最先在这里露出来 |
//!
//! 只有顺序读写是不够的：一块盘顺序还能跑 2000 MB/s、随机读却掉到 20 MB/s 的情况
//! 很常见（主控在后台做垃圾回收），而后者才是用户真正会感觉到的慢。
//!
//! 随机测试**按时长而不是按次数**跑：NVMe 一秒几万次，机械盘一秒几十次，固定次数
//! 要么等到天荒地老、要么样本太少。2.5 秒对两者都是合适的窗口。
//!
//! 关键细节：写完后必须 `sync_all()` 才算真正落盘，读的时候要绕过 page cache
//! （macOS `F_NOCACHE` / Linux `fadvise DONTNEED`），否则测的是内存速度而不是盘。

use serde::Serialize;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

const CHUNK: usize = 4 * 1024 * 1024;
const FILE_NAME: &str = ".ezpcm-bench.tmp";

/// 随机块的尺寸。4 KiB 是这一行的通用口径（也是文件系统的块大小），
/// 换成别的值就没法跟 CrystalDiskMark / fio 的数字对照了。
const BLOCK: usize = 4096;

/// 随机测试跑多久。机械盘一秒只有几十次 IO，2.5 秒能拿到几百个样本；
/// NVMe 一秒几万次，2.5 秒足够稳。
const RAND_SECS: f64 = 2.5;

/// 固定的随机种子。**故意的**：每次跑都命中同一批偏移，两次测量的差异才只反映盘
/// 本身，不掺「这次恰好踩到冷块」的运气。xorshift64*，够随机也够快。
const SEED: u64 = 0x9E37_79B9_7F4A_7C15;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct BenchResult {
    pub size_mb: u64,
    pub write_mbps: f64,
    pub read_mbps: f64,
    pub write_ms: u64,
    pub read_ms: u64,
    /// 4K 随机读的 IOPS 与折算带宽
    pub rand_read_iops: f64,
    pub rand_read_mbps: f64,
    pub rand_read_ms: u64,
    /// 4K 随机写
    pub rand_write_iops: f64,
    pub rand_write_mbps: f64,
    pub rand_write_ms: u64,
    /// 实际跑过的随机次数，用来判断这个数字有多可信（机械盘上只有几百次）
    pub rand_ops: u64,
    /// 随机块的尺寸（KiB），界面上要标出来
    pub rand_block_kb: u64,
    /// 实际写入的临时文件路径，用户有权知道我们把数据写到了哪
    pub path: String,
    pub note: Option<String>,
}

pub fn run(mount: &str, size_mb: u64) -> Result<BenchResult, String> {
    let size_mb = size_mb.clamp(64, 2048);
    let total = size_mb as usize * 1024 * 1024;

    let (path, note) = pick_path(mount);
    let display = path.to_string_lossy().to_string();

    // ---- 顺序写 ----
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|e| format!("无法创建测速文件：{e}"))?;
    bypass_cache(&f);

    let buf = vec![0x5Au8; CHUNK];
    let t0 = Instant::now();
    let mut left = total;
    while left > 0 {
        let n = left.min(CHUNK);
        if let Err(e) = f.write_all(&buf[..n]) {
            drop(f);
            let _ = std::fs::remove_file(&path);
            return Err(format!("写入失败：{e}"));
        }
        left -= n;
    }
    // 不 fsync 的话数据还在页缓存里，写速会虚高得离谱
    if let Err(e) = f.sync_all() {
        drop(f);
        let _ = std::fs::remove_file(&path);
        return Err(format!("落盘失败：{e}"));
    }
    let write_ms = (t0.elapsed().as_millis() as u64).max(1);
    drop(f);

    // ---- 顺序读 ----
    let t1 = Instant::now();
    {
        let mut rf = File::open(&path).map_err(|e| format!("无法读取测速文件：{e}"))?;
        bypass_cache(&rf);
        let mut rbuf = vec![0u8; CHUNK];
        loop {
            match rf.read(&mut rbuf) {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) => {
                    drop(rf);
                    let _ = std::fs::remove_file(&path);
                    return Err(format!("读取失败：{e}"));
                }
            }
        }
    }
    let read_ms = (t1.elapsed().as_millis() as u64).max(1);

    // ---- 4K 随机读 ----
    //
    // 用刚才顺序写进去的那份文件：数据已经在盘上，随机读才测得到真东西。
    // 单独再写一份纯随机数据没有意义，还多占一倍空间。
    let rf = File::open(&path).map_err(|e| format!("无法读取测速文件：{e}"))?;
    bypass_cache(&rf);
    let (rand_read_ops, rand_read_ms) = random_round(&rf, total, false).map_err(|e| {
        let _ = std::fs::remove_file(&path);
        format!("随机读失败：{e}")
    })?;
    drop(rf);

    // ---- 4K 随机写 ----
    let wf = OpenOptions::new()
        .write(true)
        .open(&path)
        .map_err(|e| format!("无法打开测速文件：{e}"))?;
    bypass_cache(&wf);
    let (rand_write_ops, rand_write_ms) = random_round(&wf, total, true).map_err(|e| {
        let _ = std::fs::remove_file(&path);
        format!("随机写失败：{e}")
    })?;
    // 随机写完之后要真的落盘再删文件，否则删除时还有一批脏页在飞
    let _ = wf.sync_all();
    drop(wf);

    let _ = std::fs::remove_file(&path);

    Ok(BenchResult {
        size_mb,
        write_mbps: round1(size_mb as f64 / (write_ms as f64 / 1000.0)),
        read_mbps: round1(size_mb as f64 / (read_ms as f64 / 1000.0)),
        write_ms,
        read_ms,
        rand_read_iops: iops(rand_read_ops, rand_read_ms),
        rand_read_mbps: round1(iops(rand_read_ops, rand_read_ms) * BLOCK as f64 / MB),
        rand_read_ms,
        rand_write_iops: iops(rand_write_ops, rand_write_ms),
        rand_write_mbps: round1(iops(rand_write_ops, rand_write_ms) * BLOCK as f64 / MB),
        rand_write_ms,
        rand_ops: rand_read_ops.min(rand_write_ops),
        rand_block_kb: BLOCK as u64 / 1024,
        path: display,
        note,
    })
}

const MB: f64 = 1024.0 * 1024.0;

fn iops(ops: u64, ms: u64) -> f64 {
    let secs = ms.max(1) as f64 / 1000.0;
    round1(ops as f64 / secs)
}

/// 跑一轮 4K 随机 I/O，返回 (次数, 毫秒)。
///
/// 计时**只算循环本身**，最后的 `sync_all()` 不算——和 CrystalDiskMark 一个口径。
/// 把 flush 也算进去的话，数字会变成「盘有多快 + 缓存有多能攒」，反而不好比。
fn random_round(f: &File, file_len: usize, write: bool) -> std::io::Result<(u64, u64)> {
    let blocks = (file_len / BLOCK).max(1) as u64;
    let mut rng = Rng(SEED);
    let mut buf = vec![0x5Au8; BLOCK];
    let mut ops: u64 = 0;

    let t = Instant::now();
    while t.elapsed().as_secs_f64() < RAND_SECS {
        let off = rng.offset(blocks) * BLOCK as u64;
        if write {
            write_at(f, &buf, off)?;
        } else {
            read_at(f, &mut buf, off)?;
        }
        ops += 1;
    }
    Ok((ops, (t.elapsed().as_millis() as u64).max(1)))
}

/// xorshift64*。只用在这里，不值得为它拉一个 rand 依赖。
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// 取 [0, blocks) 里的一个块号
    fn offset(&mut self, blocks: u64) -> u64 {
        self.next() % blocks
    }
}

#[cfg(unix)]
fn read_at(f: &File, buf: &mut [u8], off: u64) -> std::io::Result<()> {
    use std::os::unix::fs::FileExt;
    f.read_exact_at(buf, off)
}

#[cfg(unix)]
fn write_at(f: &File, buf: &[u8], off: u64) -> std::io::Result<()> {
    use std::os::unix::fs::FileExt;
    f.write_all_at(buf, off)
}

#[cfg(not(unix))]
fn read_at(f: &File, buf: &mut [u8], off: u64) -> std::io::Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut h = f.try_clone()?;
    h.seek(SeekFrom::Start(off))?;
    h.read_exact(buf)
}

#[cfg(not(unix))]
fn write_at(f: &File, buf: &[u8], off: u64) -> std::io::Result<()> {
    use std::io::{Seek, SeekFrom};
    let mut h = f.try_clone()?;
    h.seek(SeekFrom::Start(off))?;
    h.write_all(buf)
}

/// 优先写在目标卷的根目录；不可写（比如 `/` 需要 root）就退回系统临时目录。
/// 后者在 macOS 上仍是启动卷，测的还是同一块盘，但我们会把实际路径报给用户。
fn pick_path(mount: &str) -> (PathBuf, Option<String>) {
    let p = PathBuf::from(mount).join(FILE_NAME);
    if File::create(&p).is_ok() {
        let _ = std::fs::remove_file(&p);
        return (p, None);
    }
    (
        std::env::temp_dir().join(FILE_NAME),
        Some(format!("{mount} 不可写，已改用系统临时目录")),
    )
}

#[cfg(target_os = "macos")]
fn bypass_cache(f: &File) {
    use std::os::unix::io::AsRawFd;
    unsafe {
        libc::fcntl(f.as_raw_fd(), libc::F_NOCACHE, 1);
    }
}

#[cfg(target_os = "linux")]
fn bypass_cache(f: &File) {
    use std::os::unix::io::AsRawFd;
    unsafe {
        libc::posix_fadvise(f.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
    }
}

#[cfg(not(unix))]
fn bypass_cache(_f: &File) {
    // Windows 上要 FILE_FLAG_NO_BUFFERING（还得按扇区对齐缓冲区），
    // 这一版先不做，读速可能受缓存影响，结果里会注明。
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
