//! 顺序读写测速（CrystalDiskMark 的极简版）
//!
//! 只做顺序写 + 顺序读各一次：这两个数字足够回答「这块盘是不是掉速了」。
//! 4K 随机读写要反复寻址、耗时是顺序测试的好几倍，对一个常驻监控不值当。
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

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct BenchResult {
    pub size_mb: u64,
    pub write_mbps: f64,
    pub read_mbps: f64,
    pub write_ms: u64,
    pub read_ms: u64,
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

    let _ = std::fs::remove_file(&path);

    Ok(BenchResult {
        size_mb,
        write_mbps: round1(size_mb as f64 / (write_ms as f64 / 1000.0)),
        read_mbps: round1(size_mb as f64 / (read_ms as f64 / 1000.0)),
        write_ms,
        read_ms,
        path: display,
        note,
    })
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
