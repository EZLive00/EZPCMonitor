use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::menu::{CheckMenuItem, IsMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager, WebviewWindow};

pub mod bench;
pub mod diskhealth;
pub mod gpu;
pub mod history;
pub mod i18n;
pub mod metrics;
pub mod procstats;
pub mod settings;

use metrics::{Collector, History, Snapshot};

/// 悬浮窗不透明度可选档位（百分比）。整窗 alpha 会连文字一起变淡，
/// 所以下限只放到 60%——再低就不是「透明」而是「看不清」了。
pub const OPACITY_STEPS: [u32; 5] = [100, 90, 80, 70, 60];

pub struct AppState {
    pub snapshot: Arc<Mutex<Snapshot>>,
    pub history: Arc<Mutex<History>>,
    pub want_procs: Arc<AtomicBool>,
    pub click_through: Arc<AtomicBool>,
    /// 悬浮窗形态："card" | "bar"，托盘菜单据此打勾
    pub widget_mode: Mutex<String>,
    /// 悬浮窗不透明度 0.3 ~ 1.0，由前端套到 CSS opacity 上
    pub widget_opacity: Mutex<f64>,
    /// 打开主面板时是不是「我们」把悬浮窗收起来的——关面板时才需要还原。
    /// 用户自己从托盘隐藏的，关面板后不该自作主张给他弹回来。
    pub widget_hidden_by_dashboard: AtomicBool,
    /// 采集间隔（毫秒）。采集线程每轮现取，改了立刻生效。
    pub interval_ms: Arc<AtomicU64>,
    /// 是否记录历史 + 保留多久（秒）。采集线程每拍判断，改了立刻生效。
    pub history_enabled: Arc<AtomicBool>,
    pub history_retention: Arc<AtomicU64>,
    /// 历史文件写入器。采集线程写，命令读/清空，所以套一层锁。
    pub recorder: Arc<Mutex<Option<history::Recorder>>>,
    /// 高占用程序榜的写入器（按小时分片的目录）。跟曲线共用开关和保留时长。
    pub proc_recorder: Arc<Mutex<Option<procstats::Recorder>>>,
    /// 界面语言：`auto` 或 `i18n::LANGS` 里的一项（用户的选择，不是解析结果）。
    /// 托盘菜单要按它重画，前端拿它挑字典。
    pub language: Mutex<String>,
    /// 配色主题：`auto` / `dark` / `light`。后端只存不改，解析在前端做
    /// （`prefers-color-scheme` 是 WebView 的能力，Rust 侧看不到它的变化）。
    pub theme: Mutex<String>,
    /// 托盘里点了「设置…」但主面板是刚拉起来的——这时前端还没挂上监听，
    /// 事件会丢。留个标记，等前端启动时主动来取一次。
    pub open_settings: AtomicBool,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            snapshot: Arc::new(Mutex::new(Snapshot::default())),
            history: Arc::new(Mutex::new(History::default())),
            want_procs: Arc::new(AtomicBool::new(false)),
            click_through: Arc::new(AtomicBool::new(false)),
            widget_mode: Mutex::new("card".into()),
            widget_opacity: Mutex::new(1.0),
            widget_hidden_by_dashboard: AtomicBool::new(false),
            interval_ms: Arc::new(AtomicU64::new(settings::DEFAULT_MS)),
            history_enabled: Arc::new(AtomicBool::new(settings::DEFAULT_HISTORY_ON)),
            history_retention: Arc::new(AtomicU64::new(settings::DEFAULT_RETENTION)),
            recorder: Arc::new(Mutex::new(None)),
            proc_recorder: Arc::new(Mutex::new(None)),
            language: Mutex::new(settings::DEFAULT_LANG.to_string()),
            theme: Mutex::new(settings::DEFAULT_THEME.to_string()),
            open_settings: AtomicBool::new(false),
        }
    }
}

/// 当前生效的语言。用户选 `auto` 时才去问系统。
fn lang_of(state: &AppState) -> i18n::Lang {
    i18n::resolve(&state.language.lock().unwrap())
}

fn widget_dims(mode: &str) -> (f64, f64) {
    match mode {
        "bar" => (300.0, 46.0),
        _ => (272.0, 204.0),
    }
}

#[tauri::command]
fn get_snapshot(state: tauri::State<'_, AppState>) -> Snapshot {
    state.snapshot.lock().unwrap().clone()
}

#[tauri::command]
fn get_history(state: tauri::State<'_, AppState>, seconds: Option<usize>) -> Vec<metrics::HistoryPoint> {
    let n = seconds.unwrap_or(60).min(metrics::HISTORY_CAP);
    state.history.lock().unwrap().tail(n)
}

/// 只有主面板可见时才采集进程列表——悬浮窗不需要，省掉一次全表遍历
#[tauri::command]
fn set_want_procs(state: tauri::State<'_, AppState>, on: bool) {
    state.want_procs.store(on, Ordering::Relaxed);
}

/// 一次设置变更。全部字段可选：只传要改的那一项，其余保持不变。
#[derive(serde::Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct SettingsPatch {
    interval_ms: Option<u64>,
    history_enabled: Option<bool>,
    history_retention_secs: Option<u64>,
    language: Option<String>,
    theme: Option<String>,
}

fn current_settings(state: &AppState) -> settings::Settings {
    settings::Settings {
        interval_ms: state.interval_ms.load(Ordering::Relaxed),
        history_enabled: state.history_enabled.load(Ordering::Relaxed),
        history_retention_secs: state.history_retention.load(Ordering::Relaxed),
        language: state.language.lock().unwrap().clone(),
        theme: state.theme.lock().unwrap().clone(),
    }
}

#[tauri::command]
fn get_settings(state: tauri::State<'_, AppState>) -> settings::Settings {
    current_settings(&state)
}

/// 系统语言。前端只用来显示「跟随系统（简体中文）」里的那个括号，
/// 真正的解析结果以后端为准——避免两边各算一次算出不同答案。
#[tauri::command]
fn get_locale() -> String {
    i18n::detect().tag().to_string()
}

/// 改设置。夹到合法区间 → 存内存 → 落盘 → 广播 `settings:changed` → 刷新托盘。
///
/// 所有入口（托盘、设置弹窗）都走这一个函数，所以不存在「两个地方各改一半」的状态。
#[tauri::command]
fn update_settings(app: tauri::AppHandle, patch: SettingsPatch) -> settings::Settings {
    let (next, lang_changed) = {
        let state = app.state::<AppState>();
        let cur = current_settings(&state);
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
        state.interval_ms.store(next.interval_ms, Ordering::Relaxed);
        state
            .history_enabled
            .store(next.history_enabled, Ordering::Relaxed);
        state
            .history_retention
            .store(next.history_retention_secs, Ordering::Relaxed);
        *state.language.lock().unwrap() = next.language.clone();
        *state.theme.lock().unwrap() = next.theme.clone();
        let changed = next.language != cur.language;
        (next, changed)
    };
    // SMART 属性表在 Rust 侧就格式化好了，缓存里是上一门语言的字符串
    if lang_changed {
        diskhealth::clear_cache();
    }
    settings::save(&app, &next);
    let _ = app.emit("settings:changed", &next);
    refresh_tray(&app);
    sync_window_titles(&app);
    apply_native_theme(&app, &next.theme);
    next
}

/// 原生标题栏也要跟着主题走。
///
/// 界面配色是 CSS 画的，标题栏却是 macOS 画的——不告诉它，浅色界面上就会顶
/// 一条深色标题栏。`None` 表示交还给系统，`auto` 时用它。
fn apply_native_theme(app: &tauri::AppHandle, choice: &str) {
    let theme = match choice {
        "dark" => Some(tauri::Theme::Dark),
        "light" => Some(tauri::Theme::Light),
        _ => None,
    };
    app.set_theme(theme);
}

/// 主面板标题栏里的「主面板」也要跟着语言变——它露在最显眼的地方。
fn sync_window_titles(app: &tauri::AppHandle) {
    let lang = lang_of(&app.state::<AppState>());
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.set_title(&format!("EZPcMonitor · {}", i18n::t(lang, "window.dash")));
    }
}

/// 历史记录的现状：条数、占用、实测每条大小、时间跨度。
///
/// `bytesPerRecord` 是拿真实文件反算的，前端据此估算各档保留时长的占用——
/// 比在两边各写一个魔法常量靠谱。
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryStats {
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
    /// 高占用程序榜那部分：节奏、实测占用、空目录时的经验值
    proc_sample_secs: u64,
    proc_bytes: u64,
    proc_bytes_per_sample: u64,
}

#[tauri::command]
fn history_stats(state: tauri::State<'_, AppState>) -> HistoryStats {
    let (count, bytes, bpr, oldest, newest) = {
        let mut guard = state.recorder.lock().unwrap();
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
    let proc_bytes = state
        .proc_recorder
        .lock()
        .unwrap()
        .as_ref()
        .map(|r| r.bytes())
        .unwrap_or(0);
    HistoryStats {
        enabled: state.history_enabled.load(Ordering::Relaxed),
        retention_secs: state.history_retention.load(Ordering::Relaxed),
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
    }
}

/// 取历史点。`from` 缺省时按当前保留时长取。
#[tauri::command]
fn history_range(state: tauri::State<'_, AppState>, from: Option<u64>) -> Vec<history::Point> {
    let from = from.unwrap_or_else(|| {
        history::now_secs().saturating_sub(state.history_retention.load(Ordering::Relaxed))
    });
    let guard = state.recorder.lock().unwrap();
    guard
        .as_ref()
        .map(|r| r.read_since(from))
        .unwrap_or_default()
}

/// 高占用程序榜。
///
/// 一次扫完 CPU / 内存 / 磁盘三个维度，前端切维度、改排序都不用再回来读文件。
/// 读几十 MB 要几十毫秒，所以走 async——同步命令会跑在主线程上，界面会顿一下。
#[tauri::command(async)]
fn proc_leaders(state: tauri::State<'_, AppState>, from: Option<u64>) -> procstats::Leaders {
    let from = from.unwrap_or_else(|| {
        history::now_secs().saturating_sub(state.history_retention.load(Ordering::Relaxed))
    });
    state
        .proc_recorder
        .lock()
        .unwrap()
        .as_ref()
        .map(|r| r.leaders(from))
        .unwrap_or_default()
}

#[tauri::command]
fn clear_history(state: tauri::State<'_, AppState>) {
    if let Some(r) = state.recorder.lock().unwrap().as_mut() {
        r.clear();
    }
    if let Some(r) = state.proc_recorder.lock().unwrap().as_mut() {
        r.clear();
    }
}

/// 报告图的落地文件名：只留最后一段路径，挡住 `../` 之类跑出目录的写法；
/// 空名、点开头、超长名一律退回默认名。重名自动加 `-2`、`-3`，不覆盖旧图。
fn report_path(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    let mut base = name.rsplit(['/', '\\']).next().unwrap_or("").to_string();
    if base.is_empty() || base.starts_with('.') || base.len() > 120 {
        base = "EZPcMonitor-report.png".into();
    }

    let stem = std::path::Path::new(&base)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("EZPcMonitor-report")
        .to_string();
    let mut path = dir.join(&base);
    for n in 2..1000 {
        if !path.exists() {
            break;
        }
        path = dir.join(format!("{stem}-{n}.png"));
    }
    path
}

/// 保存报告图。
///
/// 默认落在下载目录而不是弹保存对话框：点「报告」的人就是想拿到一个文件，
/// 多一步选目录只是拦路。重名自动加序号，不覆盖已有的图。
#[tauri::command]
fn save_report(app: tauri::AppHandle, png: Vec<u8>, name: String) -> Result<String, String> {
    let dir = app
        .path()
        .download_dir()
        .or_else(|_| app.path().app_data_dir())
        .map_err(|e| e.to_string())?;
    let _ = std::fs::create_dir_all(&dir);

    let path = report_path(&dir, &name);
    std::fs::write(&path, &png).map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().to_string())
}

/// 把已保存的 PNG 放进系统剪贴板。
///
/// WebView 里的 `navigator.clipboard.write` 在 WKWebView 上时灵时不灵
/// （还要求处在用户手势的同步栈里，而我们生成图片是异步的），所以走系统通道。
/// macOS 用 osascript 读文件塞进剪贴板，其它平台返回 unsupported，
/// 前端会退回「复制文件路径」。
#[tauri::command]
fn copy_image(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let quoted = path.replace('\\', "\\\\").replace('"', "\\\"");
        let script =
            format!("set the clipboard to (read (POSIX file \"{quoted}\") as «class PNGf»)");
        let out = std::process::Command::new("osascript")
            .arg("-e")
            .arg(&script)
            .output()
            .map_err(|e| e.to_string())?;
        if out.status.success() {
            Ok(())
        } else {
            Err(String::from_utf8_lossy(&out.stderr).to_string())
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        Err("unsupported".into())
    }
}

/// 主面板启动时问一句：「是不是有人让我打开设置？」取完即清，只生效一次。
#[tauri::command]
fn take_open_settings(state: tauri::State<'_, AppState>) -> bool {
    state.open_settings.swap(false, Ordering::Relaxed)
}

/// 托盘里的「设置…」：把主面板叫起来并让设置弹窗自动展开。
///
/// 主面板可能刚被创建，前端还没注册监听，事件会丢——所以两条路都留：
/// 发事件（面板已开着时生效）+ 打标记（前端启动时来取一次）。
fn open_settings_window(app: &tauri::AppHandle) {
    app.state::<AppState>()
        .open_settings
        .store(true, Ordering::Relaxed);
    open_dashboard(app.clone(), app.state::<AppState>());
    let _ = app.emit_to("main", "settings:open", ());
}

/// 顺序读写测速。必须 async：同步命令跑在主线程上，几秒的 IO 会把界面卡住。
#[tauri::command(async)]
fn disk_bench(mount: String, size_mb: Option<u64>) -> Result<bench::BenchResult, String> {
    bench::run(&mount, size_mb.unwrap_or(512))
}

/// 硬盘健康 / 寿命。
///
/// 只对主面板开放（悬浮窗不显示健康数据），内部带 60s 缓存 + 3s 超时，
/// 不会因为某块外置盘掉线把界面卡住。
#[tauri::command(async)]
fn disk_health(
    state: tauri::State<'_, AppState>,
    force: Option<bool>,
) -> Vec<diskhealth::DiskHealth> {
    let mounts: Vec<String> = {
        let s = state.snapshot.lock().unwrap();
        s.disks.iter().map(|d| d.mount.clone()).collect()
    };
    let lang = lang_of(&state);
    diskhealth::query(&mounts, force.unwrap_or(false), lang)
}

#[tauri::command]
fn set_widget_mode(window: WebviewWindow, mode: String) {
    let mode = if mode == "bar" { "bar" } else { "card" };
    let (w, h) = widget_dims(mode);
    let _ = window.set_size(tauri::LogicalSize::new(w, h));
    // 记住形态，托盘菜单的勾选要跟得上
    let app = window.app_handle();
    if let Some(state) = app.try_state::<AppState>() {
        *state.widget_mode.lock().unwrap() = mode.to_string();
    }
    refresh_tray(app);
}

/// 前端启动时把 localStorage 里的偏好同步过来，避免托盘勾选和实际形态对不上
#[tauri::command]
fn sync_widget_prefs(app: tauri::AppHandle, mode: String, opacity: f64) {
    let opacity = opacity.clamp(0.3, 1.0);
    {
        let state = app.state::<AppState>();
        *state.widget_mode.lock().unwrap() = if mode == "bar" { "bar".into() } else { "card".into() };
        *state.widget_opacity.lock().unwrap() = opacity;
    }
    if let Some(w) = app.get_webview_window("widget") {
        set_window_opacity(&w, opacity);
    }
    refresh_tray(&app);
}

/// 托盘里切形态：改状态 + 改窗口尺寸 + 通知前端换布局
fn apply_widget_mode(app: &tauri::AppHandle, mode: &str) {
    let mode = if mode == "bar" { "bar" } else { "card" };
    {
        let state = app.state::<AppState>();
        *state.widget_mode.lock().unwrap() = mode.to_string();
    }
    if let Some(w) = app.get_webview_window("widget") {
        let (width, height) = widget_dims(mode);
        let _ = w.set_size(tauri::LogicalSize::new(width, height));
        let _ = w.show();
        if let Some(state) = app.try_state::<AppState>() {
            state.widget_hidden_by_dashboard.store(false, Ordering::Relaxed);
        }
    }
    let _ = app.emit_to("widget", "widget:mode", mode);
    refresh_tray(app);
}

/// 整窗不透明度。
///
/// macOS 上直接改 `NSWindow.alphaValue`，系统毛玻璃层会跟着一起变透，桌面才真的透得过来；
/// 用 CSS opacity 只能把网页内容淡掉，底下那层 HudWindow 材质仍然是不透明的深色，
/// 看起来就像「蒙了一层灰」。
#[allow(unused_variables)]
fn set_window_opacity(window: &WebviewWindow, opacity: f64) {
    #[cfg(target_os = "macos")]
    {
        use objc2::runtime::AnyObject;
        let alpha = opacity.clamp(0.2, 1.0);
        let w = window.clone();
        let _ = window.run_on_main_thread(move || {
            if let Ok(ptr) = w.ns_window() {
                if !ptr.is_null() {
                    let ns = ptr as *mut AnyObject;
                    unsafe {
                        let _: () = objc2::msg_send![ns, setAlphaValue: alpha];
                    }
                }
            }
        });
    }
}

/// 推给前端的不透明度事件。macOS 上窗口透明度已经由原生改掉了，
/// 前端只需要记下来（css = false）；其它平台没有原生整窗透明度，退回 CSS 蒙层。
#[derive(Clone, serde::Serialize)]
struct OpacityPayload {
    value: f64,
    css: bool,
}

/// 托盘里调不透明度
fn apply_widget_opacity(app: &tauri::AppHandle, opacity: f64) {
    let opacity = opacity.clamp(0.3, 1.0);
    {
        let state = app.state::<AppState>();
        *state.widget_opacity.lock().unwrap() = opacity;
    }
    if let Some(w) = app.get_webview_window("widget") {
        set_window_opacity(&w, opacity);
    }
    let _ = app.emit_to(
        "widget",
        "widget:opacity",
        OpacityPayload {
            value: opacity,
            css: !cfg!(target_os = "macos"),
        },
    );
    refresh_tray(app);
}

#[tauri::command]
fn set_click_through(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    on: bool,
) -> bool {
    if let Some(w) = app.get_webview_window("widget") {
        let _ = w.set_ignore_cursor_events(on);
    }
    state.click_through.store(on, Ordering::Relaxed);
    on
}

/// 系统级半透明：macOS 用 NSVisualEffectView，Windows 用 Acrylic
fn style_widget(w: &WebviewWindow) {
    #[cfg(target_os = "macos")]
    {
        use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};
        let _ = apply_vibrancy(
            w,
            NSVisualEffectMaterial::HudWindow,
            Some(NSVisualEffectState::Active),
            Some(18.0),
        );
    }
    #[cfg(target_os = "windows")]
    {
        use window_vibrancy::apply_acrylic;
        let _ = apply_acrylic(w, Some((16, 18, 26, 170)));
    }
}

/// 取悬浮窗。窗口被系统销毁时（⌘W / 显示器重连等）按同样参数重建，
/// 保证「点图标 → 一定有窗口」这条路径不会落到空指针上。
fn widget_window(app: &tauri::AppHandle) -> Option<WebviewWindow> {
    if let Some(w) = app.get_webview_window("widget") {
        return Some(w);
    }
    let w = tauri::WebviewWindowBuilder::new(
        app,
        "widget",
        tauri::WebviewUrl::App("widget.html".into()),
    )
    .title("EZPcMonitor")
    .inner_size(272.0, 204.0)
    .resizable(false)
    .maximizable(false)
    .minimizable(false)
    .decorations(false)
    .transparent(true)
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .visible(false)
    .focused(false)
    .build()
    .ok()?;
    style_widget(&w);
    // 重建的窗口是新 NSWindow，不透明度得重新贴上去
    let opacity = *app.state::<AppState>().widget_opacity.lock().unwrap();
    set_window_opacity(&w, opacity);
    Some(w)
}

/// 把悬浮窗重新放回桌面（点 Dock / 启动器图标、托盘菜单都走这里）
fn reveal_widget(app: &tauri::AppHandle) {
    if let Some(w) = widget_window(app) {
        let _ = w.show();
        let _ = w.set_always_on_top(true);
    }
}

#[tauri::command]
fn toggle_widget(app: tauri::AppHandle) -> bool {
    if let Some(w) = widget_window(&app) {
        let visible = w.is_visible().unwrap_or(true);
        let _ = if visible { w.hide() } else { w.show() };
        // 用户手动操作过，就别在关面板时再自作主张
        if let Some(state) = app.try_state::<AppState>() {
            state.widget_hidden_by_dashboard.store(false, Ordering::Relaxed);
        }
        refresh_tray(&app);
        return !visible;
    }
    false
}

#[tauri::command]
fn open_dashboard(app: tauri::AppHandle, state: tauri::State<'_, AppState>) {
    state.want_procs.store(true, Ordering::Relaxed);

    // 悬浮窗和主窗口互斥：主面板一出现就把悬浮窗收起来，关掉面板再放回去。
    // 两个窗口同时挂在桌面上既挡视线又浪费一次 1s 的渲染，没有意义。
    if let Some(w) = app.get_webview_window("widget") {
        if w.is_visible().unwrap_or(false) {
            let _ = w.hide();
            state.widget_hidden_by_dashboard.store(true, Ordering::Relaxed);
            refresh_tray(&app);
        }
    }
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    // 按需创建：主面板的 WebView 常驻要多吃 50MB 内存，没打开就不该存在
    let lang = lang_of(&state);
    let _ = tauri::WebviewWindowBuilder::new(
        &app,
        "main",
        tauri::WebviewUrl::App("index.html".into()),
    )
    .title(format!("EZPcMonitor · {}", i18n::t(lang, "window.dash")))
    // 进程榜要放 20 行，680 高的窗口只能露 4 行——加高到 820，能露出 15 行左右，
    // 剩下的滚动。再高就要顶到屏幕边缘了。
    .inner_size(940.0, 820.0)
    .min_inner_size(820.0, 600.0)
    .center()
    .build();
}

#[tauri::command]
fn quit_app(app: tauri::AppHandle) {
    app.exit(0);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = AppState::default();
    let want_procs = state.want_procs.clone();
    let snap = state.snapshot.clone();
    let hist = state.history.clone();

    tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            get_history,
            set_want_procs,
            disk_health,
            disk_bench,
            get_settings,
            update_settings,
            get_locale,
            history_stats,
            history_range,
            proc_leaders,
            clear_history,
            save_report,
            copy_image,
            take_open_settings,
            set_widget_mode,
            sync_widget_prefs,
            set_click_through,
            toggle_widget,
            open_dashboard,
            quit_app
        ])
        .setup(move |app| {
            // 自带 smartctl（ADR-005 阶段 1）：资源目录里的优先，找不到就回落系统安装的。
            // 开发态（cargo run / tauri dev）资源不会被复制到 target/，所以那里走的还是系统版本。
            if let Ok(dir) = app.path().resource_dir() {
                let bin = dir.join("resources/bin/smartctl");
                if bin.is_file() {
                    diskhealth::set_bundled(bin);
                }
            }

            let widget = app.get_webview_window("widget").expect("widget window");
            style_widget(&widget);

            // 先恢复上次的设置，再启动采集线程——否则第一拍会用默认值跑，
            // 用户改过的 5s 会先被覆盖成 1s 一拍。
            let (interval, hist_on, retention, recorder, proc_recorder) = {
                let saved = settings::load(app.handle());
                let state = app.state::<AppState>();
                state.interval_ms.store(saved.interval_ms, Ordering::Relaxed);
                state
                    .history_enabled
                    .store(saved.history_enabled, Ordering::Relaxed);
                state
                    .history_retention
                    .store(saved.history_retention_secs, Ordering::Relaxed);
                *state.language.lock().unwrap() = saved.language.clone();
                *state.theme.lock().unwrap() = saved.theme.clone();
                apply_native_theme(app.handle(), &saved.theme);

                // 历史文件放在数据目录（不是配置目录）：这是数据，不是偏好
                if let Ok(dir) = app.path().app_data_dir() {
                    let mut rec = history::Recorder::new(&dir);
                    // 上次退出后可能已经过了保留期，启动时先剪一次
                    rec.trim(saved.history_retention_secs);
                    *state.recorder.lock().unwrap() = Some(rec);

                    // 程序榜按小时分片，修剪就是删整个文件，启动时顺手清一遍
                    let mut procs = procstats::Recorder::new(&dir.join("procs"));
                    procs.prune(saved.history_retention_secs);
                    *state.proc_recorder.lock().unwrap() = Some(procs);
                }

                (
                    state.interval_ms.clone(),
                    state.history_enabled.clone(),
                    state.history_retention.clone(),
                    state.recorder.clone(),
                    state.proc_recorder.clone(),
                )
            };

            let handle = app.handle().clone();
            let main_active = app.state::<AppState>().want_procs.clone();
            std::thread::spawn(move || {
                let mut collector = Collector::new(want_procs, hist_on.clone());
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

                        if hist_on.load(Ordering::Relaxed)
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
                                rec.trim_if_needed(retention.load(Ordering::Relaxed));
                            }
                        }

                        // 高占用程序榜：30 秒一拍，跟曲线共用开关和保留时长。
                        // 采集线程已经按名字合并好了，这里只管写。
                        if let Some(entries) = collector.take_pending() {
                            let ret = retention.load(Ordering::Relaxed);
                            let mut guard = proc_recorder.lock().unwrap();
                            if let Some(rec) = guard.as_mut() {
                                rec.append(history::now_secs(), &entries);
                                if last_prune.elapsed() >= Duration::from_secs(600) {
                                    last_prune = std::time::Instant::now();
                                    rec.prune(ret);
                                }
                            }
                        }

                        // 主面板隐藏时不推送：省掉一次跨进程序列化 + 一次 React 渲染
                        let _ = handle.emit_to("widget", "metrics:tick", &s);
                        if main_active.load(Ordering::Relaxed) {
                            let _ = handle.emit_to("main", "metrics:tick", &s);
                        }
                    },
                    // 每拍现读一次：托盘/设置面板改了间隔，这一拍之后就按新节奏走
                    move || Duration::from_millis(interval.load(Ordering::Relaxed)),
                );
            });

            build_tray(app.handle())?;

            // 开发便利：EZPCM_SHOW_DASHBOARD=1 时直接打开主面板，方便截图/调试
            #[cfg(debug_assertions)]
            if std::env::var("EZPCM_SHOW_DASHBOARD").is_ok() {
                open_dashboard(app.handle().clone(), app.state::<AppState>());
            }

            Ok(())
        })
        .on_window_event(|window, event| {
            if window.label() == "main" {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    // 面板隐藏后停止进程采集，并销毁 WebView 释放内存（下次打开时重建）
                    if let Some(state) = window.try_state::<AppState>() {
                        state.want_procs.store(false, Ordering::Relaxed);
                    }
                    let w = window.clone();
                    let app = window.app_handle().clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(80));
                        let _ = w.destroy();
                        // 面板关了，把刚才收起来的悬浮窗放回桌面
                        if let Some(state) = app.try_state::<AppState>() {
                            if state.widget_hidden_by_dashboard.swap(false, Ordering::Relaxed) {
                                reveal_widget(&app);
                                refresh_tray(&app);
                            }
                        }
                    });
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            // macOS 上点 Dock / 启动器里的图标只会「激活」应用，不会把窗口放回来
            // （我们的窗口是 hide 而不是销毁，系统认为它们还在，hasVisibleWindows 为 false 时
            //  tao 也把默认的取消隐藏关掉了）。这里手动补上：先取消应用隐藏，再把窗口放回。
            #[cfg(target_os = "macos")]
            match event {
                tauri::RunEvent::Reopen {
                    has_visible_windows,
                    ..
                } => {
                    // 取消「应用被 ⌘H 隐藏」的状态，否则 show() 出来的窗口仍然不可见
                    let _ = app.show();
                    // 一个窗口都没有时，把悬浮窗也放回来；否则只打开主面板，
                    // 尊重用户主动隐藏悬浮窗的选择。
                    if !has_visible_windows {
                        reveal_widget(app);
                    }
                    open_dashboard(app.clone(), app.state::<AppState>());
                }
                _ => {}
            }
            #[cfg(not(target_os = "macos"))]
            {
                let _ = (app, event);
            }
        });
}

fn build_tray(app: &tauri::AppHandle) -> tauri::Result<()> {
    let menu = tray_menu(app)?;

    let mut builder = TrayIconBuilder::with_id("main")
        .tooltip("EZPcMonitor")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| {
            let id = event.id.as_ref();
            match id {
                "toggle" => {
                    let _ = toggle_widget(app.clone());
                }
                "dashboard" => open_dashboard(app.clone(), app.state::<AppState>()),
                "settings" => open_settings_window(app),
                "click_through" => {
                    let state = app.state::<AppState>();
                    let next = !state.click_through.load(Ordering::Relaxed);
                    let _ = set_click_through(app.clone(), state, next);
                    refresh_tray(app);
                }
                "quit" => app.exit(0),
                _ => {
                    if let Some(mode) = id.strip_prefix("mode:") {
                        apply_widget_mode(app, mode);
                    } else if let Some(pct) = id.strip_prefix("opacity:") {
                        if let Ok(v) = pct.parse::<f64>() {
                            apply_widget_opacity(app, v / 100.0);
                        }
                    } else if let Some(v) = id.strip_prefix("freq:") {
                        if v == "custom" {
                            open_settings_window(app);
                        } else if let Ok(ms) = v.parse::<u64>() {
                            let _ = update_settings(
                                app.clone(),
                                SettingsPatch {
                                    interval_ms: Some(ms),
                                    ..Default::default()
                                },
                            );
                        }
                    }
                }
            }
        });

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    builder.build(app)?;
    Ok(())
}

/// 按当前状态生成托盘菜单：勾选项跟着 AppState 走
fn tray_menu(app: &tauri::AppHandle) -> tauri::Result<Menu<tauri::Wry>> {
    let (mode, opacity, through) = {
        let state = app.state::<AppState>();
        (
            state.widget_mode.lock().unwrap().clone(),
            *state.widget_opacity.lock().unwrap(),
            state.click_through.load(Ordering::Relaxed),
        )
    };
    let visible = app
        .get_webview_window("widget")
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(true);
    let lang = lang_of(&app.state::<AppState>());
    let tr = |k: &str| i18n::t(lang, k);

    let dash = MenuItem::with_id(app, "dashboard", tr("dashboard"), true, None::<&str>)?;

    // 显示/隐藏也归到「形态」里：本质是同一个东西的三种状态（隐藏 / 卡片 / 条）
    let toggle_label = if visible { tr("hide") } else { tr("show") };
    let toggle = MenuItem::with_id(app, "toggle", toggle_label, true, None::<&str>)?;
    let card = CheckMenuItem::with_id(app, "mode:card", tr("mode.card"), true, mode == "card", None::<&str>)?;
    let bar = CheckMenuItem::with_id(
        app,
        "mode:bar",
        tr("mode.bar"),
        true,
        mode == "bar",
        None::<&str>,
    )?;
    let mode_sep = PredefinedMenuItem::separator(app)?;
    let mode_menu =
        Submenu::with_items(app, tr("mode"), true, &[&toggle, &mode_sep, &card, &bar])?;

    let mut op_items = Vec::new();
    for pct in OPACITY_STEPS {
        let checked = (opacity * 100.0).round() as u32 == pct;
        op_items.push(CheckMenuItem::with_id(
            app,
            format!("opacity:{pct}"),
            format!("{pct}%"),
            true,
            checked,
            None::<&str>,
        )?);
    }
    let op_refs: Vec<&dyn IsMenuItem<tauri::Wry>> = op_items
        .iter()
        .map(|i| i as &dyn IsMenuItem<tauri::Wry>)
        .collect();
    let opacity_menu = Submenu::with_items(app, tr("opacity"), true, &op_refs)?;

    let click = CheckMenuItem::with_id(
        app,
        "click_through",
        tr("click"),
        true,
        through,
        None::<&str>,
    )?;

    // 监控频率：三档预设 + 自定义。标题里带上当前值——自定义档位（比如 2.5s）
    // 不在三个预设里，三个都不打勾，只有标题能说清现在是几秒。
    let interval = app.state::<AppState>().interval_ms.load(Ordering::Relaxed);
    let mut freq_items = Vec::new();
    for (i, preset) in settings::PRESETS.iter().enumerate() {
        let tier = tr(["tier.high", "tier.mid", "tier.low"][i]);
        freq_items.push(CheckMenuItem::with_id(
            app,
            format!("freq:{preset}"),
            format!(
                "{} {}",
                tier,
                i18n::paren(lang, &settings::label(*preset, lang))
            ),
            true,
            interval == *preset,
            None::<&str>,
        )?);
    }
    let freq_sep = PredefinedMenuItem::separator(app)?;
    let freq_custom = MenuItem::with_id(app, "freq:custom", tr("more"), true, None::<&str>)?;
    let mut freq_refs: Vec<&dyn IsMenuItem<tauri::Wry>> = freq_items
        .iter()
        .map(|i| i as &dyn IsMenuItem<tauri::Wry>)
        .collect();
    freq_refs.push(&freq_sep);
    freq_refs.push(&freq_custom);
    let freq_menu = Submenu::with_items(
        app,
        format!("{} · {}", tr("freq"), settings::label(interval, lang)),
        true,
        &freq_refs,
    )?;

    let sep = PredefinedMenuItem::separator(app)?;
    let settings_item = MenuItem::with_id(app, "settings", tr("settings"), true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", tr("quit"), true, None::<&str>)?;

    Menu::with_items(
        app,
        &[
            &dash,
            &mode_menu,
            &opacity_menu,
            &freq_menu,
            &click,
            &sep,
            &settings_item,
            &quit,
        ],
    )
}

/// 状态变了就重建菜单（只有几项，代价可以忽略；勾选状态因此永远和真实状态一致）
fn refresh_tray(app: &tauri::AppHandle) {
    if let Ok(menu) = tray_menu(app) {
        if let Some(tray) = app.tray_by_id("main") {
            let _ = tray.set_menu(Some(menu));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::report_path;
    use std::path::Path;

    #[test]
    fn keeps_plain_name() {
        let dir = Path::new("/tmp/ezpc-nonexistent");
        assert_eq!(
            report_path(dir, "EZPcMonitor-report-20261023-1432.png"),
            dir.join("EZPcMonitor-report-20261023-1432.png")
        );
    }

    #[test]
    fn strips_directories_from_name() {
        let dir = Path::new("/tmp/ezpc-nonexistent");
        assert_eq!(
            report_path(dir, "../../etc/passwd.png"),
            dir.join("passwd.png")
        );
        assert_eq!(
            report_path(dir, "C:\\Users\\x\\shot.png"),
            dir.join("shot.png")
        );
    }

    #[test]
    fn falls_back_for_bad_names() {
        let dir = Path::new("/tmp/ezpc-nonexistent");
        for bad in ["", ".", "..", ".hidden.png", &"x".repeat(200)] {
            assert_eq!(
                report_path(dir, bad),
                dir.join("EZPcMonitor-report.png"),
                "input {bad:?} should fall back"
            );
        }
    }

    #[test]
    fn numbers_collisions_instead_of_overwriting() {
        let dir = std::env::temp_dir().join(format!("ezpc-report-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();

        let first = report_path(&dir, "r.png");
        assert_eq!(first, dir.join("r.png"));
        std::fs::write(&first, b"1").unwrap();

        let second = report_path(&dir, "r.png");
        assert_eq!(second, dir.join("r-2.png"));
        std::fs::write(&second, b"2").unwrap();

        let third = report_path(&dir, "r.png");
        assert_eq!(third, dir.join("r-3.png"));

        std::fs::remove_dir_all(&dir).ok();
    }
}
