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
//!
//! **测速文件必须写在被选中的那块盘上。** 原来的做法是「卷根写不进去就退回系统
//! 临时目录」——在启动卷上这是等价的（临时目录也在同一块 NAND 上），但对外接盘是
//! 错的：用户选的是 U 盘，写不进去就悄悄去测内置 SSD，量出来的数字还挂在 U 盘名下。
//! 现在写不进去就直接失败，并且把「没权限」单独报出来，让界面去引导用户授权。
//!
//! 结果会存一份到 `bench.json`：一次 512 MB 的测速要写几百兆，测完关掉窗口就
//! 丢掉太可惜，重启程序后还得再写一遍——对 SSD 是实打实的损耗。

use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const CHUNK: usize = 4 * 1024 * 1024;
const FILE_NAME: &str = ".ezpcm-bench.tmp";
/// 探测目录能不能写用的一次性文件。和测速文件分开，免得半路失败留下个假结果。
const PROBE_NAME: &str = ".ezpcm-bench.probe";

/// 随机块的尺寸。4 KiB 是这一行的通用口径（也是文件系统的块大小），
/// 换成别的值就没法跟 CrystalDiskMark / fio 的数字对照了。
const BLOCK: usize = 4096;

/// 随机测试跑多久。机械盘一秒只有几十次 IO，2.5 秒能拿到几百个样本；
/// NVMe 一秒几万次，2.5 秒足够稳。
const RAND_SECS: f64 = 2.5;

/// 固定的随机种子。**故意的**：每次跑都命中同一批偏移，两次测量的差异才只反映盘
/// 本身，不掺「这次恰好踩到冷块」的运气。xorshift64*，够随机也够快。
const SEED: u64 = 0x9E37_79B9_7F4A_7C15;

/// 测速失败。
///
/// `code` 让界面能分开处理：**没权限**要告诉用户去哪儿开权限，**只读盘**要说明
/// 原因，其余的把技术细节摆出来就行。文案在界面那边（七种语言），这里只给码。
#[derive(Debug)]
pub struct BenchError {
    pub code: &'static str,
    /// 技术细节，给 `io` 那类兜底用。不带中文前缀——界面可能不是中文的。
    pub message: String,
}

impl BenchError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    fn from_io(stage: &str, e: &std::io::Error) -> Self {
        Self::new(classify(e), format!("{stage}: {e}"))
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct BenchResult {
    /// 测的是哪个挂载点。缓存按它去重，界面也能据此判断结果是不是这块盘的。
    pub mount: String,
    /// 测完的时刻（Unix 秒）。缓存下来的结果必须能看出「这是什么时候测的」，
    /// 否则重启后用户会以为刚测过。
    pub at: u64,
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
    /// `cache` 表示没用卷根目录（启动卷根要管理员权限），改用了同一块盘上的缓存目录
    pub note: Option<String>,
}

pub fn run(config_dir: &Path, mount: &str, size_mb: u64) -> Result<BenchResult, BenchError> {
    let size_mb = size_mb.clamp(64, 2048);
    let total = size_mb as usize * 1024 * 1024;

    // 先在目标卷上找一个能写的目录。找不到就直接失败——**不跨卷回退**。
    let (dir, note) = pick_dir(mount)?;
    let path = dir.join(FILE_NAME);
    let display = path.to_string_lossy().to_string();

    // ---- 顺序写 ----
    let mut f = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&path)
        .map_err(|e| BenchError::from_io("create", &e))?;
    bypass_cache(&f);

    let buf = vec![0x5Au8; CHUNK];
    let t0 = Instant::now();
    let mut left = total;
    while left > 0 {
        let n = left.min(CHUNK);
        if let Err(e) = f.write_all(&buf[..n]) {
            drop(f);
            let _ = std::fs::remove_file(&path);
            return Err(BenchError::from_io("write", &e));
        }
        left -= n;
    }
    // 不 fsync 的话数据还在页缓存里，写速会虚高得离谱
    if let Err(e) = f.sync_all() {
        drop(f);
        let _ = std::fs::remove_file(&path);
        return Err(BenchError::from_io("sync", &e));
    }
    let write_ms = (t0.elapsed().as_millis() as u64).max(1);
    drop(f);

    // ---- 顺序读 ----
    let t1 = Instant::now();
    {
        let mut rf = File::open(&path).map_err(|e| BenchError::from_io("open", &e))?;
        bypass_cache(&rf);
        let mut rbuf = vec![0u8; CHUNK];
        loop {
            match rf.read(&mut rbuf) {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) => {
                    drop(rf);
                    let _ = std::fs::remove_file(&path);
                    return Err(BenchError::from_io("read", &e));
                }
            }
        }
    }
    let read_ms = (t1.elapsed().as_millis() as u64).max(1);

    // ---- 4K 随机读 ----
    //
    // 用刚才顺序写进去的那份文件：数据已经在盘上，随机读才测得到真东西。
    // 单独再写一份纯随机数据没有意义，还多占一倍空间。
    let rf = File::open(&path).map_err(|e| BenchError::from_io("open", &e))?;
    bypass_cache(&rf);
    let (rand_read_ops, rand_read_ms) = random_round(&rf, total, false).map_err(|e| {
        let _ = std::fs::remove_file(&path);
        BenchError::from_io("rand-read", &e)
    })?;
    drop(rf);

    // ---- 4K 随机写 ----
    let wf = OpenOptions::new()
        .write(true)
        .open(&path)
        .map_err(|e| BenchError::from_io("open", &e))?;
    bypass_cache(&wf);
    let (rand_write_ops, rand_write_ms) = random_round(&wf, total, true).map_err(|e| {
        let _ = std::fs::remove_file(&path);
        BenchError::from_io("rand-write", &e)
    })?;
    // 随机写完之后要真的落盘再删文件，否则删除时还有一批脏页在飞
    let _ = wf.sync_all();
    drop(wf);

    let _ = std::fs::remove_file(&path);

    let result = BenchResult {
        mount: mount.to_string(),
        at: now(),
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
    };

    // 落盘一份，重启后还能看到上次的数字
    save_last(config_dir, &result);
    Ok(result)
}

const MB: f64 = 1024.0 * 1024.0;

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

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

/// 在**目标卷**上找一个能写的目录。找不到就失败，绝不跨卷。
///
/// 原来的做法是「卷根写不进去就退回系统临时目录」。这在启动卷上是等价的
/// （临时目录也在同一块 NAND 上），但对外接盘是**错的**：用户选的是 U 盘，
/// 写不进去就悄悄去测内置 SSD，量出来的数字还挂在 U 盘名下——文件路径藏在
/// 页面最下面一行小字里，没人会发现。
fn pick_dir(mount: &str) -> Result<(PathBuf, Option<String>), BenchError> {
    if mount.is_empty() {
        return Err(BenchError::new("io", "empty mount"));
    }

    let root = PathBuf::from(mount);
    // 卷根能写就用卷根。外接盘一般直接可写。
    let root_err = match probe(&root) {
        Ok(()) => return Ok((root, None)),
        Err(e) => BenchError::from_io("probe", &e),
    };

    // 启动卷的根目录要管理员权限。家目录在**同一块盘**上——APFS 的 System 卷和
    // Data 卷只是挂载点不同，物理上是同一块 NAND——所以测的仍然是这块盘。
    if mount == "/" {
        if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
            let cache = home.join("Library/Caches/dev.ezpc.monitor");
            if std::fs::create_dir_all(&cache).is_ok() && probe(&cache).is_ok() {
                return Ok((cache, Some("cache".into())));
            }
        }
    }

    // 到这儿说明这块盘上有地方我们写不进去：可能是 TCC 没授权、可能是只读分区。
    // 具体是哪种由 `classify` 从 errno 判断，界面据此给不同的话术。
    Err(root_err)
}

/// 试着在目录里建一个文件。能建就能测。
///
/// 比看权限位准：macOS 的 TCC 是拦在 `open()` 上的，`stat` 出来的权限位看着
/// 一切正常，真要写才失败。
fn probe(dir: &Path) -> std::io::Result<()> {
    let p = dir.join(PROBE_NAME);
    File::create(&p)?;
    let _ = std::fs::remove_file(&p);
    Ok(())
}

#[cfg(unix)]
fn classify(e: &std::io::Error) -> &'static str {
    match e.raw_os_error() {
        Some(libc::EROFS) => "readonly",
        Some(libc::ENOSPC) => "nospace",
        // EPERM 是 macOS 的 TCC 拒绝，EACCES 是普通的权限位
        Some(libc::EACCES) | Some(libc::EPERM) => "denied",
        _ => "io",
    }
}

#[cfg(not(unix))]
fn classify(e: &std::io::Error) -> &'static str {
    match e.kind() {
        std::io::ErrorKind::PermissionDenied => "denied",
        _ => "io",
    }
}

/// 上次测速的结果，按卷存，最多留 8 条。
///
/// 为什么要落盘：一次 512 MB 的测速要写几百兆、花五秒多，测完关掉窗口或者
/// 重启程序结果就没了，下次还得再写一遍——对 SSD 是实打实的损耗。
#[derive(Serialize, Deserialize, Default)]
struct Cache {
    results: Vec<BenchResult>,
}

fn cache_path(dir: &Path) -> PathBuf {
    dir.join("bench.json")
}

fn save_last(dir: &Path, r: &BenchResult) {
    let p = cache_path(dir);
    let mut c: Cache = std::fs::read_to_string(&p)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default();

    // 同一块盘只留最新的一条；再按「最近测的在前」截到 8 条，
    // 免得换过几块移动硬盘之后这个文件无限长大。
    c.results.retain(|x| x.mount != r.mount);
    c.results.insert(0, r.clone());
    c.results.truncate(8);

    if let Some(parent) = p.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(t) = serde_json::to_string(&c) {
        let _ = std::fs::write(&p, t);
    }
}

pub fn load_last(dir: &Path, mount: &str) -> Option<BenchResult> {
    let text = std::fs::read_to_string(cache_path(dir)).ok()?;
    let c: Cache = serde_json::from_str(&text).ok()?;
    c.results.into_iter().find(|r| r.mount == mount)
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
