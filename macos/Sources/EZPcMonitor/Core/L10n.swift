import Foundation
import SwiftUI

/// 界面文案。
///
/// 字典不在这里手写：`macos/tools/extract-strings.mjs` 把 `src/i18n/*.ts`
/// 导成 `Resources/strings.json`（7 种语言 × 181 键），构建时打进包里。
/// WebView 版攒下来的翻译不该在原生版里重打一遍——重抄必然走样，
/// 而且以后加文案只改一处。
final class L10n: ObservableObject {
    static let shared = L10n()

    /// 当前语言标签，七种之一（不含 `auto`——那是设置里的值，解析在 `AppModel`）
    @Published private(set) var lang: String = "en"

    private var tables: [String: [String: String]] = [:]

    /// 设置界面里的语言列表。每种语言用**自己的文字**写名字——
    /// 找不到自己母语的人才最需要翻译。
    static let choices: [(tag: String, name: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("es", "Español"),
    ]

    private init() {
        load()
    }

    private func load() {
        guard let url = Self.resourceURL() else {
            NSLog("EZPcMonitor: strings.json 没找到，界面会显示键名")
            return
        }
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else {
            NSLog("EZPcMonitor: strings.json 解析失败")
            return
        }
        tables = raw
    }

    private static func resourceURL() -> URL? {
        // 正常路径：打好的 .app 里
        if let u = Bundle.main.url(forResource: "strings", withExtension: "json") {
            return u
        }
        // 开发便利：直接 `swift run` 时没有 bundle 资源，用环境变量指过去
        if let dir = ProcessInfo.processInfo.environment["EZPCM_RESOURCES"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("strings.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func setLanguage(_ tag: String) {
        let resolved = Self.normalize(tag)
        if resolved != lang {
            lang = resolved
        }
    }

    /// 把任意标签（`zh-Hans-CN`、`zh_CN`、`en-US`）归到支持的七种之一。
    static func normalize(_ tag: String) -> String {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if t.hasPrefix("zh") {
            let traditional = t.contains("hant") || t.contains("-tw")
                || t.contains("-hk") || t.contains("-mo")
            return traditional ? "zh-TW" : "zh-CN"
        }
        if t.hasPrefix("ja") { return "ja" }
        if t.hasPrefix("ko") { return "ko" }
        if t.hasPrefix("fr") { return "fr" }
        if t.hasPrefix("es") { return "es" }
        return "en"
    }

    /// 取文案。找不到就退回英文，再找不到把键名显示出来——
    /// 空白比错字更难查。
    func t(_ key: String) -> String {
        tables[lang]?[key] ?? tables["en"]?[key] ?? key
    }

    /// 带插值：`{n}` / `{v}` 这类占位符。
    func t(_ key: String, _ vars: [String: String]) -> String {
        var s = t(key)
        for (k, v) in vars {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return s
    }
}

/// 视图里这样取：`@EnvironmentObject private var i18n: L10n`
///
/// 用 `@EnvironmentObject` 而不是「直接取单例」：语言是 `@Published` 的，
/// 只有走过环境对象，切换语言时视图才会重绘。单例只在 `AppDelegate` 里建一次。

