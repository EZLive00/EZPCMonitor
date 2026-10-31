//! 引擎：把「采集 + 落盘 + 查询」收成一个对象，供宿主通过 C ABI 调用。
//!
//! 以前这套状态散在 Tauri 的 `AppState` 里，命令函数从 `tauri::State` 上取。
//! 现在宿主是 Swift，没有 `tauri::State` 了，所以把状态收进一个 `Engine`，
//! 由 `lib.rs` 的 C ABI 用裸指针持有。
//!
//! 线程模型没变：一个采集线程跑 `metrics::run_loop`，其余都是读锁。
//! 宿主每秒来问一次「最新快照」，靠 `seq` 判断是不是新的一拍——
//! 采集节奏由设置里的 `intervalMs` 决定，跟宿主的刷新节奏解耦，
//! 所以两边不同频时不会重复渲染同一个数。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;

use crate::metrics::{self, Collector, Snapshot};
use crate::{bench, diskhealth, history, i18n, procstats, settings};

/// 设置变更：全部字段可选，只传要改的那一项。
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct SettingsPatch {
    interval_ms: Option<u64>,
    history_enabled: Option<bool>,
    history_retention_secs: Option<u64>,
    language: Option<String>,
    theme: Option<String>,
}

/// 历史记录的现状：条数、占用、实测每条大小、时间跨度。
///
/// `bytes_per_record` 是拿真实文件反算的，界面据此估算各档保留时长的占用——
/// 比在两边各写一个魔法常量靠谱。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryStats {
    enabled: bool,
    retention_secs: u64,
    sample_secs: u64,
    min_retention_secs: u64,
    max_retention_secs: u64,
    presets: Vec<u64>,
    count: u64,
    bytes: u64,
    bytes_per_record: u64,
    oldest: u64,
    newest: u64,
    proc_sample_secs: u64,
    proc_bytes: u64,
    proc_bytes_per_sample: u64,
}

pub struct Engine {
    config_dir: PathBuf,
    snapshot: Arc<Mutex<Snapshot>>,
    history: Arc<Mutex<metrics::History>>,
    /// 每采一拍加一。宿主拿它判断「这次问到的和上次是不是同一拍」。
    seq: Arc<AtomicU64>,
    want_procs: Arc<AtomicBool>,
    interval_ms: Arc<AtomicU64>,
    history_enabled: Arc<AtomicBool>,
    history_retention: Arc<AtomicU64>,
    recorder: Arc<Mutex<Option<history::Recorder>>>,
    proc_recorder: Arc<Mutex<Option<procstats::Recorder>>>,
    settings: Mutex<settings::Settings>,
}

impl Engine {
    /// `data_dir` 放历史数据（`history.jsonl`、`procs/`），
    /// `config_dir` 放偏好（`settings.json`）——两者分开是有意的：
    /// 清缓存不该顺手把用户设置删掉，备份设置也不该拖走几百兆历史。
    pub fn new(data_dir: &Path, config_dir: &Path, bundled_smartctl: Option<PathBuf>) -> Engine {
        let _ = std::fs::create_dir_all(data_dir);
        let _ = std::fs::create_dir_all(config_dir);

        // 自带的 smartctl 优先，找不到就回落系统安装的
        if let Some(bin) = bundled_smartctl {
            if bin.is_file() {
                diskhealth::set_bundled(bin);
            }
        }

        let saved = settings::load(config_dir);

        // 上次退出后可能已经过了保留期，启动时先剪一次
        let mut rec = history::Recorder::new(data_dir);
        rec.trim(saved.history_retention_secs);
        let mut procs = procstats::Recorder::new(&data_dir.join("procs"));
        procs.prune(saved.history_retention_secs);

        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let hist = Arc::new(Mutex::new(metrics::History::default()));
        let seq = Arc::new(AtomicU64::new(0));
        let want_procs = Arc::new(AtomicBool::new(false));
        let interval_ms = Arc::new(AtomicU64::new(saved.interval_ms));
        let history_enabled = Arc::new(AtomicBool::new(saved.history_enabled));
        let history_retention = Arc::new(AtomicU64::new(saved.history_retention_secs));
        let recorder = Arc::new(Mutex::new(Some(rec)));
        let proc_recorder = Arc::new(Mutex::new(Some(procs)));

        {
            let snap = snapshot.clone();
            let hist = hist.clone();
            let seq = seq.clone();
            let want = want_procs.clone();
            let interval = interval_ms.clone();
            let hist_on = history_enabled.clone();
            let retention = history_retention.clone();
            let rec = recorder.clone();
            let prec = proc_recorder.clone();
            std::thread::Builder::new()
                .name("ezpcm-collect".into())
                .spawn(move || {
                    collect_forever(snap, hist, seq, want, interval, hist_on, retention, rec, prec)
                })
                .expect("spawn collector");
        }

        Engine {
            config_dir: config_dir.to_path_buf(),
            snapshot,
            history: hist,
            seq,
            want_procs,
            interval_ms,
            history_enabled,
            history_retention,
            recorder,
            proc_recorder,
            settings: Mutex::new(saved),
        }
    }

    pub fn seq(&self) -> u64 {
        self.seq.load(Ordering::Relaxed)
    }

    /// 最新快照。外面包一层 `seq`，宿主据此判断要不要重绘。
    pub fn snapshot_json(&self) -> String {
        #[derive(Serialize)]
        struct Tick<'a> {
            seq: u64,
            snapshot: &'a Snapshot,
        }
        let snap = self.snapshot.lock().unwrap();
        serde_json::to_string(&Tick {
            seq: self.seq.load(Ordering::Relaxed),
            snapshot: &snap,
        })
        .unwrap_or_else(|_| "{}".into())
    }

    /// 内存里最近 300 个点，给悬浮窗的迷你折线用。主面板要长历史走 `history_json`。
    pub fn recent_json(&self) -> String {
        let h = self.history.lock().unwrap();
        serde_json::to_string(&h.points).unwrap_or_else(|_| "[]".into())
    }

    pub fn history_json(&self, from: Option<u64>) -> String {
        let from = from.unwrap_or_else(|| {
            history::now_secs().saturating_sub(self.history_retention.load(Ordering::Relaxed))
        });
        let guard = self.recorder.lock().unwrap();
        let rows = guard
            .as_ref()
            .map(|r| r.read_since(from))
            .unwrap_or_default();
        serde_json::to_string(&rows).unwrap_or_else(|_| "[]".into())
    }

    pub fn leaders_json(&self, from: Option<u64>) -> String {
        let from = from.unwrap_or_else(|| {
            history::now_secs().saturating_sub(self.history_retention.load(Ordering::Relaxed))
        });
        let out = self
            .proc_recorder
            .lock()
            .unwrap()
            .as_ref()
            .map(|r| r.leaders(from))
            .unwrap_or_default();
        serde_json::to_string(&out).unwrap_or_else(|_| "{}".into())
    }

    pub fn stats_json(&self) -> String {
        let (count, bytes, bpr, oldest, newest) = {
            let mut guard = self.recorder.lock().unwrap();
            match guard.as_mut() {
                Some(r) => {
                    let s = r.stats();
                    (
                        s.count,
                        s.bytes,
                        s.bytes_per_record,
                        s.oldest,
                        s.newest,
                    )
                }
                None => (0, 0, history::NOMINAL_BYTES, 0, 0),
            }
        };
        let proc_bytes = self
            .proc_recorder
            .lock()
            .unwrap()
            .as_ref()
            .map(|r| r.bytes())
            .unwrap_or(0);
        let s = HistoryStats {
            enabled: self.history_enabled.load(Ordering::Relaxed),
            retention_secs: self.history_retention.load(Ordering::Relaxed),
            sample_secs: history::SAMPLE_SECS,
            min_retention_secs: history::MIN_RETENTION,
            max_retention_secs: history::MAX_RETENTION,
            presets: history::RETENTION_PRESETS.to_vec(),
            count,
            bytes,
            bytes_per_record: bpr,
            oldest,
            newest,
            proc_sample_secs: procstats::SAMPLE_SECS,
            proc_bytes,
            proc_bytes_per_sample: procstats::NOMINAL_BYTES_PER_SAMPLE,
        };
        serde_json::to_string(&s).unwrap_or_else(|_| "{}".into())
    }

    pub fn settings_json(&self) -> String {
        let s = self.settings.lock().unwrap();
        serde_json::to_string(&*s).unwrap_or_else(|_| "{}".into())
    }

    /// 系统语言标签（已解析成受支持的七种之一）。界面只用来显示
    /// 「跟随系统（简体中文）」里的那个括号——真正用哪种以 `settings.language` 为准。
    pub fn locale(&self) -> String {
        i18n::detect().tag().to_string()
    }

    /// 改设置：夹到合法区间 → 存内存 → 落盘 → 返回新值。
    ///
    /// 宿主那边所有入口（托盘、设置窗）都走这一个函数，
    /// 所以不存在「两个地方各改一半」的状态。
    pub fn patch_settings(&self, patch: SettingsPatch) -> String {
        let (next, lang_changed) = {
            let mut guard = self.settings.lock().unwrap();
            let cur = guard.clone();
            let next = settings::Settings {
                interval_ms: settings::clamp(patch.interval_ms.unwrap_or(cur.interval_ms)),
                history_enabled: patch.history_enabled.unwrap_or(cur.history_enabled),
                history_retention_secs: history::clamp_retention(
                    patch
                        .history_retention_secs
                        .unwrap_or(cur.history_retention_secs),
                ),
                language: settings::clamp_lang(patch.language.as_deref().unwrap_or(&cur.language)),
                theme: settings::clamp_theme(patch.theme.as_deref().unwrap_or(&cur.theme)),
            };
            let lang_changed = next.language != cur.language;
            *guard = next.clone();
            self.interval_ms.store(next.interval_ms, Ordering::Relaxed);
            self.history_enabled
                .store(next.history_enabled, Ordering::Relaxed);
            self.history_retention
                .store(next.history_retention_secs, Ordering::Relaxed);
            (next, lang_changed)
        };
        // SMART 属性表在 Rust 侧就格式化好了，缓存里是上一门语言的字符串
        if lang_changed {
            diskhealth::clear_cache();
        }
        settings::save(&self.config_dir, &next);
        serde_json::to_string(&next).unwrap_or_else(|_| "{}".into())
    }

    pub fn set_want_procs(&self, on: bool) {
        self.want_procs.store(on, Ordering::Relaxed);
    }

    pub fn clear_history(&self) {
        if let Some(r) = self.recorder.lock().unwrap().as_mut() {
            r.clear();
        }
        if let Some(r) = self.proc_recorder.lock().unwrap().as_mut() {
            r.clear();
        }
    }

    pub fn health_json(&self, force: bool) -> String {
        let mounts: Vec<String> = {
            let s = self.snapshot.lock().unwrap();
            s.disks.iter().map(|d| d.mount.clone()).collect()
        };
        let lang = i18n::Lang::from_tag(&self.settings.lock().unwrap().language.clone());
        let list = diskhealth::query(&mounts, force, lang);
        serde_json::to_string(&list).unwrap_or_else(|_| "[]".into())
    }

    pub fn bench_json(&self, mount: &str, size_mb: u64) -> String {
        match bench::run(&self.config_dir, mount, size_mb) {
            Ok(r) => serde_json::to_string(&r).unwrap_or_else(|_| "{}".into()),
            // `code` 让界面分开处理：没权限要引导用户去系统设置，只读盘要说明原因。
            // 文案在界面那边，这里只给码和技术细节。
            Err(e) => serde_json::json!({ "error": e.message, "code": e.code }).to_string(),
        }
    }

    /// 上次测速的结果（重启后还在）。没有就返回 `null`。
    pub fn bench_last_json(&self, mount: &str) -> String {
        match bench::load_last(&self.config_dir, mount) {
            Some(r) => serde_json::to_string(&r).unwrap_or_else(|_| "null".into()),
            None => "null".into(),
        }
    }
}

/// 采集主循环。原来是 Tauri 的 `setup` 里内联的一段闭包，逻辑一字未改，
/// 只是把「发事件给 WebView」换成了「更新共享状态 + 加序号」。
#[allow(clippy::too_many_arguments)]
fn collect_forever(
    snap: Arc<Mutex<Snapshot>>,
    hist: Arc<Mutex<metrics::History>>,
    seq: Arc<AtomicU64>,
    want_procs: Arc<AtomicBool>,
    interval_ms: Arc<AtomicU64>,
    history_enabled: Arc<AtomicBool>,
    history_retention: Arc<AtomicU64>,
    recorder: Arc<Mutex<Option<history::Recorder>>>,
    proc_recorder: Arc<Mutex<Option<procstats::Recorder>>>,
) {
    let mut collector = Collector::new(want_procs, history_enabled.clone());
    let mut first = true;
    // 落盘节奏和采集节奏解耦：采集 1s 也好 10s 也好，写文件固定 10s 一条
    let mut last_record = std::time::Instant::now()
        .checked_sub(Duration::from_secs(history::SAMPLE_SECS))
        .unwrap_or_else(std::time::Instant::now);
    // 过期分片不必每拍都扫目录，10 分钟一次足够（最短保留期是 10 分钟）
    let mut last_prune = std::time::Instant::now();

    metrics::run_loop(
        move || {
            // 首帧 CPU 需要两次采样才有意义，先让 sysinfo 稳定一拍
            if first {
                first = false;
                std::thread::sleep(Duration::from_millis(400));
            }
            let s = collector.tick();
            {
                let mut guard = snap.lock().unwrap();
                *guard = s.clone();
            }
            hist.lock().unwrap().push(&s);
            seq.fetch_add(1, Ordering::Relaxed);

            if history_enabled.load(Ordering::Relaxed)
                && last_record.elapsed() >= Duration::from_secs(history::SAMPLE_SECS)
            {
                last_record = std::time::Instant::now();
                let primary = s
                    .temps
                    .iter()
                    .find(|t| t.primary)
                    .map(|t| t.value)
                    .unwrap_or(0.0);
                let mem = if s.mem.total > 0 {
                    s.mem.used as f32 / s.mem.total as f32 * 100.0
                } else {
                    0.0
                };
                let row = history::Row {
                    t: history::now_secs(),
                    // 一位小数够了：多存两位，30 天多好几 MB
                    cpu: (s.cpu.usage * 10.0).round() / 10.0,
                    mem: (mem * 10.0).round() / 10.0,
                    temp: (primary * 10.0).round() / 10.0,
                    rx: s.net.rx_bps as u64,
                    tx: s.net.tx_bps as u64,
                    disk: (s.disk_total_read_bps + s.disk_total_write_bps) as u64,
                    gpu: s
                        .gpu
                        .as_ref()
                        .and_then(|g| g.utilization)
                        .map(|v| (v * 10.0).round() / 10.0)
                        .unwrap_or(0.0),
                };
                let mut guard = recorder.lock().unwrap();
                if let Some(rec) = guard.as_mut() {
                    rec.append(&row);
                    rec.trim_if_needed(history_retention.load(Ordering::Relaxed));
                }
            }

            // 高占用程序榜：30 秒一拍，跟曲线共用开关和保留时长。
            // 采集线程已经按名字合并好了，这里只管写。
            if let Some(entries) = collector.take_pending() {
                let ret = history_retention.load(Ordering::Relaxed);
                let mut guard = proc_recorder.lock().unwrap();
                if let Some(rec) = guard.as_mut() {
                    rec.append(history::now_secs(), &entries);
                    if last_prune.elapsed() >= Duration::from_secs(600) {
                        last_prune = std::time::Instant::now();
                        rec.prune(ret);
                    }
                }
            }
        },
        // 每拍现读一次：设置里改了间隔，这一拍之后就按新节奏走
        move || Duration::from_millis(interval_ms.load(Ordering::Relaxed)),
    );
}
