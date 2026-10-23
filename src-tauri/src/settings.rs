//! 本地设置。
//!
//! 五项目前：采集间隔、是否记录历史、历史保留多久、界面语言、配色主题。留成结构体
//! 是为了以后加开机自启之类的直接往里塞，不用再动存储层。
//!
//! 文件很小（一两百字节），放在系统的应用配置目录里。**不上传、不含任何标识信息**，
//! 只是让用户下次打开还是上次的偏好。

use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

use crate::i18n::{self, Lang};

pub const MIN_MS: u64 = 500;
pub const MAX_MS: u64 = 60_000;
pub const DEFAULT_MS: u64 = 1000;
/// 托盘菜单里的三档预设
pub const PRESETS: [u64; 3] = [1000, 5000, 10_000];
/// 历史记录默认关闭：这个程序原本的卖点之一是「零落盘」，
/// 开始写文件得用户自己点头（ADR-011）。
pub const DEFAULT_HISTORY_ON: bool = false;
pub const DEFAULT_RETENTION: u64 = 86_400;
/// 默认跟随系统语言
pub const DEFAULT_LANG: &str = "auto";
/// 默认跟随系统配色
pub const DEFAULT_THEME: &str = "auto";
/// 主题只接受这三种；`auto` 由前端监听 `prefers-color-scheme` 解析
pub const THEMES: [&str; 3] = ["auto", "dark", "light"];

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub interval_ms: u64,
    pub history_enabled: bool,
    /// 保留时长（秒）
    pub history_retention_secs: u64,
    /// `auto` 或 i18n::LANGS 里的一项
    pub language: String,
    /// `auto` / `dark` / `light`
    pub theme: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            interval_ms: DEFAULT_MS,
            history_enabled: DEFAULT_HISTORY_ON,
            history_retention_secs: DEFAULT_RETENTION,
            language: DEFAULT_LANG.to_string(),
            theme: DEFAULT_THEME.to_string(),
        }
    }
}

/// 500ms 是下限：再快没有意义，sysinfo 的 CPU 采样本身就有平滑；
/// 60s 是上限：再慢就不像监控了。
pub fn clamp(ms: u64) -> u64 {
    ms.clamp(MIN_MS, MAX_MS)
}

/// 语言只接受 `auto` 和七种已知标签；手改坏的 settings.json 退回跟随系统。
pub fn clamp_lang(v: &str) -> String {
    if v == DEFAULT_LANG || i18n::LANGS.contains(&v) {
        v.to_string()
    } else {
        DEFAULT_LANG.to_string()
    }
}

/// 主题同理：不认识的写死值退回跟随系统，免得界面变成没有变量的裸样式。
pub fn clamp_theme(v: &str) -> String {
    if THEMES.contains(&v) {
        v.to_string()
    } else {
        DEFAULT_THEME.to_string()
    }
}

/// 托盘菜单里的显示文案：1000 → "1 秒"，2500 → "2.5 秒"；英文则是 "1 s" / "2.5 s"。
///
/// 法语、西班牙语的小数点是逗号，顺手换掉——托盘标题是唯一能看到小数的地方。
pub fn label(ms: u64, lang: Lang) -> String {
    let unit = i18n::t(lang, "unit.sec");
    let n = if ms % 1000 == 0 {
        format!("{}", ms / 1000)
    } else {
        format!("{:.1}", ms as f64 / 1000.0)
    };
    let n = match lang {
        Lang::Fr | Lang::Es => n.replace('.', ","),
        _ => n,
    };
    format!("{n} {unit}")
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
    s.language = clamp_lang(&s.language);
    s.theme = clamp_theme(&s.theme);
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
        assert_eq!(label(1000, Lang::ZhCn), "1 秒");
        assert_eq!(label(10_000, Lang::ZhCn), "10 秒");
        assert_eq!(label(2500, Lang::ZhCn), "2.5 秒");
        assert_eq!(label(2500, Lang::En), "2.5 s");
        // 法语的小数点是逗号
        assert_eq!(label(2500, Lang::Fr), "2,5 s");
    }

    #[test]
    fn rejects_unknown_language() {
        assert_eq!(clamp_lang("auto"), "auto");
        assert_eq!(clamp_lang("ja"), "ja");
        assert_eq!(clamp_lang("de"), "auto");
        assert_eq!(clamp_lang(""), "auto");
    }

    #[test]
    fn rejects_unknown_theme() {
        assert_eq!(clamp_theme("auto"), "auto");
        assert_eq!(clamp_theme("dark"), "dark");
        assert_eq!(clamp_theme("light"), "light");
        assert_eq!(clamp_theme("solarized"), "auto");
        assert_eq!(clamp_theme(""), "auto");
    }

    /// 老版本写下的 / 手改坏的 settings.json 都不能让程序起不来：
    /// 缺字段走默认值，越界的值被夹回来。
    #[test]
    fn tolerates_partial_or_bad_json() {
        let empty: Settings = serde_json::from_str("{}").unwrap();
        assert_eq!(empty.interval_ms, DEFAULT_MS);
        assert_eq!(empty.language, DEFAULT_LANG);
        assert_eq!(empty.theme, DEFAULT_THEME);

        let mut bad: Settings = serde_json::from_str(r#"{"intervalMs": 999999}"#).unwrap();
        bad.interval_ms = clamp(bad.interval_ms);
        assert_eq!(bad.interval_ms, MAX_MS);

        // 不认识的界面语言退回跟随系统，而不是让界面变成空白
        let odd: Settings = serde_json::from_str(r#"{"language": "klingon"}"#).unwrap();
        assert_eq!(clamp_lang(&odd.language), DEFAULT_LANG);
    }
}
