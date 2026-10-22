//! 本地设置。
//!
//! 三项目前：采集间隔、是否记录历史、历史保留多久。留成结构体是为了以后加开机自启、
//! 主题之类的直接往里塞，不用再动存储层。
//!
//! 文件很小（几十字节），放在系统的应用配置目录里。**不上传、不含任何标识信息**，
//! 只是让用户下次打开还是上次的偏好。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

pub const MIN_MS: u64 = 500;
pub const MAX_MS: u64 = 60_000;
pub const DEFAULT_MS: u64 = 1000;
/// 托盘菜单里的三档预设
pub const PRESETS: [u64; 3] = [1000, 5000, 10_000];
/// 历史记录默认关闭：这个程序原本的卖点之一是「零落盘」，
/// 开始写文件得用户自己点头（ADR-011）。
pub const DEFAULT_HISTORY_ON: bool = false;
pub const DEFAULT_RETENTION: u64 = 86_400;

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub interval_ms: u64,
    pub history_enabled: bool,
    /// 保留时长（秒）
    pub history_retention_secs: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            interval_ms: DEFAULT_MS,
            history_enabled: DEFAULT_HISTORY_ON,
            history_retention_secs: DEFAULT_RETENTION,
        }
    }
}

/// 500ms 是下限：再快没有意义，sysinfo 的 CPU 采样本身就有平滑；
/// 60s 是上限：再慢就不像监控了。
pub fn clamp(ms: u64) -> u64 {
    ms.clamp(MIN_MS, MAX_MS)
}

/// 托盘/界面共用的显示文案：1000 → "1 秒"，2500 → "2.5 秒"
pub fn label(ms: u64) -> String {
    if ms % 1000 == 0 {
        format!("{} 秒", ms / 1000)
    } else {
        format!("{:.1} 秒", ms as f64 / 1000.0)
    }
}

fn path(app: &AppHandle) -> Option<PathBuf> {
    app.path()
        .app_config_dir()
        .ok()
        .map(|d| d.join("settings.json"))
}

pub fn load(app: &AppHandle) -> Settings {
    let Some(p) = path(app) else {
        return Settings::default();
    };
    let Ok(text) = std::fs::read_to_string(&p) else {
        return Settings::default();
    };
    let mut s: Settings = serde_json::from_str(&text).unwrap_or_default();
    s.interval_ms = clamp(s.interval_ms);
    s
}

pub fn save(app: &AppHandle, s: &Settings) {
    let Some(p) = path(app) else { return };
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(s) {
        let _ = std::fs::write(&p, text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clamps_to_range() {
        assert_eq!(clamp(100), MIN_MS);
        assert_eq!(clamp(120_000), MAX_MS);
        assert_eq!(clamp(2500), 2500);
    }

    #[test]
    fn labels_whole_and_fractional_seconds() {
        assert_eq!(label(1000), "1 秒");
        assert_eq!(label(10_000), "10 秒");
        assert_eq!(label(2500), "2.5 秒");
    }

    /// 老版本写下的 / 手改坏的 settings.json 都不能让程序起不来：
    /// 缺字段走默认值，越界的值被夹回来。
    #[test]
    fn tolerates_partial_or_bad_json() {
        let empty: Settings = serde_json::from_str("{}").unwrap();
        assert_eq!(empty.interval_ms, DEFAULT_MS);

        let mut bad: Settings = serde_json::from_str(r#"{"intervalMs": 999999}"#).unwrap();
        bad.interval_ms = clamp(bad.interval_ms);
        assert_eq!(bad.interval_ms, MAX_MS);
    }
}
