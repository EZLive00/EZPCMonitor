//! 原生界面文案的多语言。
//!
//! 前端有自己的字典（`src/i18n/`），但**托盘菜单是系统画的**——拿不到 WebView 里的翻译，
//! 所以 Rust 这边得再来一份。两边共用同一套语言标签，`settings.language` 是唯一真值。
//!
//! 只收「原生侧要显示的字符串」：托盘菜单、窗口标题、以及硬盘 SMART 表里那些
//! 由后端拼出来的行名。前端能渲染的一律不进这个文件，否则同一句话会有两个出处。
//!
//! 语言标签用 BCP 47 的短形式：`zh-CN` / `zh-TW` / `en` / `ja` / `ko` / `fr` / `es`。
//! 存储时额外允许 `auto`（跟随系统）。

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Lang {
    ZhCn,
    ZhTw,
    En,
    Ja,
    Ko,
    Fr,
    Es,
}

/// 可选语言（不含 `auto`）。顺序即设置界面里的展示顺序。
pub const LANGS: [&str; 7] = ["zh-CN", "zh-TW", "en", "ja", "ko", "fr", "es"];

impl Lang {
    pub fn tag(self) -> &'static str {
        match self {
            Lang::ZhCn => "zh-CN",
            Lang::ZhTw => "zh-TW",
            Lang::En => "en",
            Lang::Ja => "ja",
            Lang::Ko => "ko",
            Lang::Fr => "fr",
            Lang::Es => "es",
        }
    }

    /// 系统语言标签 → 支持的七种之一。
    ///
    /// 只看前缀和繁简标记：`zh-Hans-CN` / `zh_CN` / `zh` 都归简体，
    /// `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` 归繁体，其余不认识的一律英文。
    pub fn from_tag(tag: &str) -> Lang {
        let t = tag.trim().to_ascii_lowercase().replace('_', "-");
        if t.starts_with("zh") {
            let traditional = t.contains("hant")
                || t.contains("-tw")
                || t.contains("-hk")
                || t.contains("-mo");
            return if traditional { Lang::ZhTw } else { Lang::ZhCn };
        }
        if t.starts_with("ja") {
            Lang::Ja
        } else if t.starts_with("ko") {
            Lang::Ko
        } else if t.starts_with("fr") {
            Lang::Fr
        } else if t.starts_with("es") {
            Lang::Es
        } else {
            Lang::En
        }
    }

    /// 中文（含繁体）走中文文案，其余一律英文——SMART 属性名这类技术术语
    /// 在行业工具（smartctl / CrystalDiskInfo）里本来就是英文，硬翻反而看不懂。
    pub fn is_chinese(self) -> bool {
        matches!(self, Lang::ZhCn | Lang::ZhTw)
    }
}

/// 取系统语言。
///
/// `EZPCM_LANG` 优先——截图和回归测试要能不改系统设置就切语言。
pub fn detect() -> Lang {
    if let Ok(v) = std::env::var("EZPCM_LANG") {
        if !v.is_empty() && v != "auto" {
            return Lang::from_tag(&v);
        }
    }
    sys_locale::get_locale()
        .map(|s| Lang::from_tag(&s))
        .unwrap_or(Lang::En)
}

/// `auto` 解析成具体语言，非法值退回系统语言。
pub fn resolve(choice: &str) -> Lang {
    match choice {
        "auto" => detect(),
        other => {
            if LANGS.contains(&other) {
                Lang::from_tag(other)
            } else {
                detect()
            }
        }
    }
}

/// 中文/日文用全角括号，其余用半角——托盘里 `高（1 秒）` vs `High (1 s)`。
pub fn paren(lang: Lang, inner: &str) -> String {
    match lang {
        Lang::ZhCn | Lang::ZhTw | Lang::Ja => format!("（{inner}）"),
        _ => format!("({inner})"),
    }
}

/// 原生侧文案。找不到的键原样返回，方便发现漏翻而不是显示空白。
pub fn t(lang: Lang, key: &str) -> &'static str {
    let table: &'static [(&'static str, &'static str)] = match lang {
        Lang::ZhCn => ZH_CN,
        Lang::ZhTw => ZH_TW,
        Lang::En => EN,
        Lang::Ja => JA,
        Lang::Ko => KO,
        Lang::Fr => FR,
        Lang::Es => ES,
    };
    table
        .iter()
        .find(|(k, _)| *k == key)
        .map(|(_, v)| *v)
        .unwrap_or_else(|| {
            // 漏翻时退回英文，再不行把键名显出来（比空白好排查）
            EN.iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| *v)
                .unwrap_or("?")
        })
}

// key                      zh-CN            zh-TW              en
static ZH_CN: &[(&str, &str)] = &[
    ("dashboard", "打开主面板"),
    ("hide", "隐藏悬浮窗"),
    ("show", "显示悬浮窗"),
    ("mode", "悬浮窗形态"),
    ("mode.card", "卡片"),
    ("mode.bar", "紧凑条（单行）"),
    ("opacity", "悬浮窗不透明度"),
    ("click", "鼠标穿透"),
    ("freq", "监控频率"),
    ("tier.high", "高"),
    ("tier.mid", "中"),
    ("tier.low", "低"),
    ("more", "更多设置…"),
    ("settings", "设置…"),
    ("quit", "退出 EZPcMonitor"),
    ("window.dash", "主面板"),
    ("unit.sec", "秒"),
];

static ZH_TW: &[(&str, &str)] = &[
    ("dashboard", "開啟主面板"),
    ("hide", "隱藏懸浮窗"),
    ("show", "顯示懸浮窗"),
    ("mode", "懸浮窗形態"),
    ("mode.card", "卡片"),
    ("mode.bar", "精簡條（單行）"),
    ("opacity", "懸浮窗不透明度"),
    ("click", "滑鼠穿透"),
    ("freq", "監控頻率"),
    ("tier.high", "高"),
    ("tier.mid", "中"),
    ("tier.low", "低"),
    ("more", "更多設定…"),
    ("settings", "設定…"),
    ("quit", "結束 EZPcMonitor"),
    ("window.dash", "主面板"),
    ("unit.sec", "秒"),
];

static EN: &[(&str, &str)] = &[
    ("dashboard", "Open Dashboard"),
    ("hide", "Hide Widget"),
    ("show", "Show Widget"),
    ("mode", "Widget Style"),
    ("mode.card", "Card"),
    ("mode.bar", "Compact Bar (single row)"),
    ("opacity", "Widget Opacity"),
    ("click", "Click-through"),
    ("freq", "Refresh Interval"),
    ("tier.high", "High"),
    ("tier.mid", "Medium"),
    ("tier.low", "Low"),
    ("more", "More Settings…"),
    ("settings", "Settings…"),
    ("quit", "Quit EZPcMonitor"),
    ("window.dash", "Dashboard"),
    ("unit.sec", "s"),
];

static JA: &[(&str, &str)] = &[
    ("dashboard", "メインパネルを開く"),
    ("hide", "ウィジェットを隠す"),
    ("show", "ウィジェットを表示"),
    ("mode", "ウィジェット表示形式"),
    ("mode.card", "カード"),
    ("mode.bar", "コンパクトバー（1 行）"),
    ("opacity", "ウィジェットの不透明度"),
    ("click", "マウス透過"),
    ("freq", "更新間隔"),
    ("tier.high", "高"),
    ("tier.mid", "中"),
    ("tier.low", "低"),
    ("more", "その他の設定…"),
    ("settings", "設定…"),
    ("quit", "EZPcMonitor を終了"),
    ("window.dash", "メインパネル"),
    ("unit.sec", "秒"),
];

static KO: &[(&str, &str)] = &[
    ("dashboard", "메인 패널 열기"),
    ("hide", "위젯 숨기기"),
    ("show", "위젯 표시"),
    ("mode", "위젯 형태"),
    ("mode.card", "카드"),
    ("mode.bar", "컴팩트 바(한 줄)"),
    ("opacity", "위젯 불투명도"),
    ("click", "마우스 통과"),
    ("freq", "수집 주기"),
    ("tier.high", "높음"),
    ("tier.mid", "보통"),
    ("tier.low", "낮음"),
    ("more", "추가 설정…"),
    ("settings", "설정…"),
    ("quit", "EZPcMonitor 종료"),
    ("window.dash", "메인 패널"),
    ("unit.sec", "초"),
];

static FR: &[(&str, &str)] = &[
    ("dashboard", "Ouvrir le panneau"),
    ("hide", "Masquer le widget"),
    ("show", "Afficher le widget"),
    ("mode", "Forme du widget"),
    ("mode.card", "Carte"),
    ("mode.bar", "Barre compacte (une ligne)"),
    ("opacity", "Opacité du widget"),
    ("click", "Clic à travers"),
    ("freq", "Fréquence de collecte"),
    ("tier.high", "Élevée"),
    ("tier.mid", "Moyenne"),
    ("tier.low", "Faible"),
    ("more", "Plus d'options…"),
    ("settings", "Réglages…"),
    ("quit", "Quitter EZPcMonitor"),
    ("window.dash", "Panneau principal"),
    ("unit.sec", "s"),
];

static ES: &[(&str, &str)] = &[
    ("dashboard", "Abrir el panel"),
    ("hide", "Ocultar el widget"),
    ("show", "Mostrar el widget"),
    ("mode", "Forma del widget"),
    ("mode.card", "Tarjeta"),
    ("mode.bar", "Barra compacta (una línea)"),
    ("opacity", "Opacidad del widget"),
    ("click", "Clic a través"),
    ("freq", "Frecuencia de captura"),
    ("tier.high", "Alta"),
    ("tier.mid", "Media"),
    ("tier.low", "Baja"),
    ("more", "Más ajustes…"),
    ("settings", "Ajustes…"),
    ("quit", "Salir de EZPcMonitor"),
    ("window.dash", "Panel principal"),
    ("unit.sec", "s"),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_locale_tags() {
        assert_eq!(Lang::from_tag("zh-Hans-CN"), Lang::ZhCn);
        assert_eq!(Lang::from_tag("zh_CN"), Lang::ZhCn);
        assert_eq!(Lang::from_tag("zh"), Lang::ZhCn);
        assert_eq!(Lang::from_tag("zh-Hant-TW"), Lang::ZhTw);
        assert_eq!(Lang::from_tag("zh-HK"), Lang::ZhTw);
        assert_eq!(Lang::from_tag("ja-JP"), Lang::Ja);
        assert_eq!(Lang::from_tag("ko-KR"), Lang::Ko);
        assert_eq!(Lang::from_tag("fr-FR"), Lang::Fr);
        assert_eq!(Lang::from_tag("es-419"), Lang::Es);
        // 没支持的语言退回英文，而不是显示空白
        assert_eq!(Lang::from_tag("de-DE"), Lang::En);
        assert_eq!(Lang::from_tag(""), Lang::En);
    }

    /// 七种语言的托盘文案都必须齐全，漏一条就会在界面上出现 "?"
    #[test]
    fn every_locale_covers_every_key() {
        let keys: Vec<&str> = EN.iter().map(|(k, _)| *k).collect();
        for lang in [Lang::ZhCn, Lang::ZhTw, Lang::En, Lang::Ja, Lang::Ko, Lang::Fr, Lang::Es] {
            for k in &keys {
                assert_ne!(t(lang, k), "?", "{} 缺少 {}", lang.tag(), k);
            }
        }
    }

    #[test]
    fn tag_round_trips() {
        for tag in LANGS {
            assert_eq!(Lang::from_tag(tag).tag(), tag);
        }
    }
}
