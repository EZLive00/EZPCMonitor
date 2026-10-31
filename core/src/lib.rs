//! EZPcMonitor 采集内核。
//!
//! 这个 crate 不认识任何 UI 框架：Tauri、SwiftUI 都只是宿主。宿主通过下面这组
//! C ABI 拿到 JSON，自己决定怎么画。
//!
//! 为什么是 JSON 而不是给每个结构体生成绑定：数据形状本来就已经是 JSON 了
//! （历史文件就是 JSONL），一次快照不到 2KB，一秒一次的序列化开销可以忽略；
//! 而换来的是「加字段不用动 ABI」——界面上加个指标，core 里加个字段就行，
//! Swift 那边 `Decodable` 少写一个 key 也能正常解。
//!
//! 线程安全：`EzpcmEngine` 内部全是锁，可以从任意线程调用；
//! 只有 `ezpcm_engine_new` / `ezpcm_engine_free` 必须成对、且不能并发。

pub mod bench;
pub mod diskhealth;
pub mod engine;
pub mod gpu;
pub mod history;
pub mod i18n;
pub mod metrics;
pub mod procstats;
pub mod settings;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;

pub use engine::{Engine, SettingsPatch};

/// 不透明句柄。Swift 侧只需要一个 `OpaquePointer`。
pub struct EzpcmEngine {
    inner: Engine,
}

fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // 非 UTF-8 的路径不该让程序崩，用有损转换兜住
    Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn into_c(s: String) -> *mut c_char {
    // 字符串里有 NUL 时 CString 会失败——JSON 里不该出现，兜底成空对象
    CString::new(s)
        .unwrap_or_else(|_| CString::new("{}").unwrap())
        .into_raw()
}

/// 建引擎并起采集线程。三个路径都可以传 NULL（测试用）。
///
/// `bundled_smartctl` 是应用包里的 smartctl 路径；不存在就回落系统安装的。
#[unsafe(no_mangle)]
pub extern "C" fn ezpcm_engine_new(
    data_dir: *const c_char,
    config_dir: *const c_char,
    bundled_smartctl: *const c_char,
) -> *mut EzpcmEngine {
    let data = cstr(data_dir).unwrap_or_else(|| ".".into());
    let conf = cstr(config_dir).unwrap_or_else(|| data.clone());
    let bundled = cstr(bundled_smartctl).map(PathBuf::from);
    let engine = Engine::new(
        std::path::Path::new(&data),
        std::path::Path::new(&conf),
        bundled,
    );
    Box::into_raw(Box::new(EzpcmEngine { inner: engine }))
}

#[unsafe(no_mangle)]
pub extern "C" fn ezpcm_engine_free(engine: *mut EzpcmEngine) {
    if engine.is_null() {
        return;
    }
    // 采集线程是游离的，进程退出时跟着走；这里只回收句柄本身
    drop(unsafe { Box::from_raw(engine) });
}

/// 释放 `ezpcm_call` 返回的字符串。**每次调用都必须配一次**，否则泄漏。
#[unsafe(no_mangle)]
pub extern "C" fn ezpcm_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    drop(unsafe { CString::from_raw(s) });
}

/// 唯一的调用入口。返回 JSON（UTF-8，调用方负责 free）。
///
/// `args` 可以是 NULL，也可以是不带参数的 `{}`。
#[unsafe(no_mangle)]
pub extern "C" fn ezpcm_call(
    engine: *mut EzpcmEngine,
    method: *const c_char,
    args: *const c_char,
) -> *mut c_char {
    if engine.is_null() {
        return into_c(r#"{"error":"null engine"}"#.into());
    }
    let method = cstr(method).unwrap_or_default();
    let raw = cstr(args).unwrap_or_else(|| "{}".into());
    let args: serde_json::Value = serde_json::from_str(&raw).unwrap_or(serde_json::Value::Null);

    // panic 穿过 FFI 边界是 UB。任何一拍出问题都只让这一次调用失败，
    // 采集线程和宿主都还得活着。
    let e = unsafe { &*engine };
    let out = catch_unwind(AssertUnwindSafe(|| dispatch(&e.inner, &method, &args)))
        .unwrap_or_else(|_| r#"{"error":"panic"}"#.into());
    into_c(out)
}

fn dispatch(engine: &Engine, method: &str, args: &serde_json::Value) -> String {
    let from = args.get("from").and_then(|v| v.as_u64());
    match method {
        "snapshot" => engine.snapshot_json(),
        "recent" => engine.recent_json(),
        "history" => engine.history_json(from),
        "leaders" => engine.leaders_json(from),
        "stats" => engine.stats_json(),
        "settings" => engine.settings_json(),
        "locale" => serde_json::Value::String(engine.locale()).to_string(),
        "seq" => engine.seq().to_string(),
        "patch" => match serde_json::from_value::<SettingsPatch>(args.clone()) {
            Ok(p) => engine.patch_settings(p),
            Err(e) => serde_json::json!({ "error": e.to_string() }).to_string(),
        },
        "wantProcs" => {
            engine.set_want_procs(args.get("on").and_then(|v| v.as_bool()).unwrap_or(false));
            "{}".into()
        }
        "clearHistory" => {
            engine.clear_history();
            "{}".into()
        }
        "health" => engine.health_json(
            args.get("force")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
        ),
        "bench" => engine.bench_json(
            args.get("mount").and_then(|v| v.as_str()).unwrap_or(""),
            args.get("sizeMb").and_then(|v| v.as_u64()).unwrap_or(512),
        ),
        "benchLast" => engine.bench_last_json(
            args.get("mount").and_then(|v| v.as_str()).unwrap_or(""),
        ),
        "version" => serde_json::Value::String(env!("CARGO_PKG_VERSION").into()).to_string(),
        other => serde_json::json!({ "error": format!("unknown method: {other}") }).to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn engine() -> Engine {
        // 临时目录：跑完不清理也无所谓，系统会回收
        let dir = std::env::temp_dir().join(format!("ezpcm-test-{}", std::process::id()));
        Engine::new(&dir, &dir, None)
    }

    #[test]
    fn unknown_method_reports_error() {
        let e = engine();
        let out = dispatch(&e, "nope", &serde_json::Value::Null);
        assert!(out.contains("unknown method"));
    }

    #[test]
    fn snapshot_wraps_seq_and_payload() {
        let e = engine();
        let out = dispatch(&e, "snapshot", &serde_json::Value::Null);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert!(v.get("seq").is_some());
        assert!(v.get("snapshot").is_some());
    }

    #[test]
    fn patch_clamps_and_persists() {
        let e = engine();
        let args = serde_json::json!({ "intervalMs": 999_999, "theme": "solarized" });
        let out = dispatch(&e, "patch", &args);
        let v: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["intervalMs"], settings::MAX_MS);
        assert_eq!(v["theme"], settings::DEFAULT_THEME);
        // 再问一次，读到的应该是存下去的值
        let again: serde_json::Value =
            serde_json::from_str(&dispatch(&e, "settings", &serde_json::Value::Null)).unwrap();
        assert_eq!(again["intervalMs"], settings::MAX_MS);
    }

    #[test]
    fn call_survives_bad_args() {
        let e = engine();
        // 传个数字进去，反序列化失败也不能崩
        let out = dispatch(&e, "patch", &serde_json::json!(42));
        assert!(out.contains("error"));
    }

    #[test]
    fn c_abi_round_trip() {
        let data = CString::new(std::env::temp_dir().to_string_lossy().to_string()).unwrap();
        let h = ezpcm_engine_new(data.as_ptr(), data.as_ptr(), std::ptr::null());
        assert!(!h.is_null());
        let m = CString::new("version").unwrap();
        let p = ezpcm_call(h, m.as_ptr(), std::ptr::null());
        assert!(!p.is_null());
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().to_string();
        assert!(s.contains('.'), "version should look like x.y.z, got {s}");
        ezpcm_string_free(p);
        ezpcm_engine_free(h);
    }
}
