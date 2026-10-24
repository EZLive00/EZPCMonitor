import Foundation
import SwiftUI

/// 界面文案。
///
/// 字典不在这里手写：`macos/tools/extract-strings.mjs` 把 `src/i18n/*.ts`
/// 导成 `Resources/strings.json`（7 种语言 × 185 键 + 8 个单复数键），
/// 构建时打进包里。WebView 版攒下来的翻译不该在原生版里重打一遍——
/// 重抄必然走样，而且以后加文案只改一处。
final class L10n: ObservableObject {
    static let shared = L10n()

    /// 一门语言的完整词表
    private struct Table {
        var strings: [String: String]
        /// 单复数：值是 `[单数, 复数]`，`tn` 按 n 取
        var plurals: [String: [String]]
    }

    @Published private(set) var lang: String = "en"

    private var tables: [String: Table] = [:]
    private var numberFormatters: [String: NumberFormatter] = [:]
    private var clockFormatters: [String: DateFormatter] = [:]

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
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else {
            NSLog("EZPcMonitor: strings.json 解析失败")
            return
        }
        for (tag, dict) in raw {
            let strings = dict["strings"] as? [String: String] ?? [:]
            let plurals = dict["plurals"] as? [String: [String]] ?? [:]
            tables[tag] = Table(strings: strings, plurals: plurals)
        }
    }

    private static func resourceURL() -> URL? {
        // 正常路径：打好的 .app 里
        if let u = Bundle.main.url(forResource: "strings", withExtension: "json") {
            return u
        }
        // 开发便利：直接跑可执行文件时没有 bundle 资源，用环境变量指过去
        if let dir = ProcessInfo.processInfo.environment["EZPCM_RESOURCES"] {
            let u = URL(fileURLWithPath: dir).appendingPathComponent("strings.json")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func setLanguage(_ tag: String) {
        let resolved = Self.normalize(tag)
        if resolved != lang { lang = resolved }
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

    // MARK: - 取词

    /// 找不到就退回英文，再找不到把键名显示出来——空白比错字更难查。
    func t(_ key: String) -> String {
        tables[lang]?.strings[key] ?? tables["en"]?.strings[key] ?? key
    }

    /// 带插值：`{n}` / `{v}` 这类占位符。
    func t(_ key: String, _ vars: [String: String]) -> String {
        var s = t(key)
        for (k, v) in vars {
            s = s.replacingOccurrences(of: "{\(k)}", with: v)
        }
        return s
    }

    /// 单复数短语：`n == 1` 取第 0 项，其余取第 1 项。
    func tn(_ key: String, _ n: Double) -> String {
        let pair = tables[lang]?.plurals[key] ?? tables["en"]?.plurals[key] ?? [key, key]
        let text = pair.count > 1 ? (n == 1 ? pair[0] : pair[1]) : (pair.first ?? key)
        // 小数按需保留一位：2.5 秒，而不是 2.5000001 秒
        let shown = n.rounded() == n ? num(n) : num(n, frac: 1)
        return text.replacingOccurrences(of: "{n}", with: shown)
    }

    // MARK: - 格式化

    /// 按当前语言格式化数字（千分位、小数逗号）。
    func num(_ n: Double, frac: Int = 0) -> String {
        guard n.isFinite else { return "—" }
        let key = "\(lang)-\(frac)"
        let f: NumberFormatter
        if let cached = numberFormatters[key] {
            f = cached
        } else {
            f = NumberFormatter()
            f.locale = Locale(identifier: lang)
            f.numberStyle = .decimal
            f.minimumFractionDigits = frac
            f.maximumFractionDigits = frac
            numberFormatters[key] = f
        }
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 秒 → 「2 天 5 小时」/「3 minutes」
    func duration(_ secs: UInt64) -> String {
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(tn("p.day", Double(d))) \(tn("p.hour", Double(h)))" }
        if h > 0 { return "\(tn("p.hour", Double(h))) \(tn("p.min", Double(m)))" }
        return tn("p.min", Double(m))
    }

    /// 秒 → 「1 天」/「1.5 小时」/「10 分钟」
    func retention(_ secs: UInt64) -> String {
        if secs % 86_400 == 0 { return tn("p.day", Double(secs / 86_400)) }
        if secs % 3600 == 0 { return tn("p.hour", Double(secs / 3600)) }
        if secs % 60 == 0 && secs < 3600 { return tn("p.min", Double(secs / 60)) }
        return tn("p.hour", (Double(secs) / 3600 * 10).rounded() / 10)
    }

    /// 毫秒 → 「1 秒」/「2.5 s」
    func interval(_ ms: UInt64) -> String {
        tn("p.sec", (Double(ms) / 100).rounded() / 10)
    }

    /// unix 秒 → 「14:05」，跨天时「10-22 14:05」
    func clock(_ ts: UInt64, withDate: Bool = false) -> String {
        let key = "\(lang)-\(withDate)"
        let f: DateFormatter
        if let cached = clockFormatters[key] {
            f = cached
        } else {
            f = DateFormatter()
            f.locale = Locale(identifier: lang)
            // h23 而不是默认的 12 小时制：时间轴标签要短，也不想出现 AM/PM
            f.dateFormat = withDate ? "MM-dd HH:mm" : "HH:mm"
            clockFormatters[key] = f
        }
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
