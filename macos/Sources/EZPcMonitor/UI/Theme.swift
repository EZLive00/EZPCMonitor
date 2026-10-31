import AppKit
import SwiftUI

// MARK: - 颜色

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

/// 配色沿用 WebView 版那一套（`src/styles.css` 里的 `--c-*`）。
///
/// 换到原生不是重画一遍配色，而是把同一组语义色搬过来——用户在两个版本之间
/// 来回看的时候，「青=CPU、紫=内存、绿=磁盘」这套映射不该变。
///
/// 浅色模式单独给一档：`#22d3ee` 这种高明度青在毛玻璃上好看，压到白底上会糊。
/// 用 `NSColor(name:dynamicProvider:)` 让系统自己按外观挑，视图里不用传 colorScheme。
enum Palette {
    static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    static let accent = dyn(0x22d3ee, 0x0891b2)
    static let accent2 = dyn(0xa78bfa, 0x7c3aed)

    static let cpu = dyn(0x22d3ee, 0x0891b2)
    static let cpuDeep = dyn(0x0e7490, 0x155e75)
    static let mem = dyn(0xa78bfa, 0x7c3aed)
    static let memDeep = dyn(0x6d28d9, 0x5b21b6)
    static let temp = dyn(0xfbbf24, 0xd97706)
    static let rx = dyn(0x38bdf8, 0x0284c7)
    static let tx = dyn(0xa78bfa, 0x7c3aed)
    static let disk = dyn(0x34d399, 0x059669)
    static let gpu = dyn(0xc084fc, 0x9333ea)

    static let ok = dyn(0x34d399, 0x059669)
    static let warn = dyn(0xfbbf24, 0xd97706)
    static let danger = dyn(0xf87171, 0xdc2626)
}

// MARK: - 文字色

/// 文字用的透明度阶梯。
///
/// 不用系统的 `.secondary`（深色下是白 55%）：主面板是**半透明**窗口，底色来自
/// 磨砂玻璃后面的桌面，明度不可控。白 55% 压在常见的浅色壁纸上，实测对比度只有
/// **3.1~3.4:1**，10.5pt 的卡片标题和 9.5pt 的表头读起来发虚——WCAG 对小字的要求
/// 是 4.5:1。
///
/// 这里把次要文字抬到 72%，同时把窗口底色压暗一档（见 `BackdropLayer` 的 scrim），
/// 两头一起使劲才够：只提亮文字的话，白字在浅底上还是会糊成一片。
enum Ink {
    static func level(_ dark: Double, _ light: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor.white.withAlphaComponent(dark)
                : NSColor.black.withAlphaComponent(light)
        })
    }

    /// 次要文字：卡片标题、键名、表头、单位。
    static let secondary = level(0.72, 0.62)

    /// 更弱的一档：只用在不需要细读的地方（`DOWN`/`UP` 这类列标签、分隔点）。
    /// 系统 `.tertiary` 是白 25%，压在这种底色上只有 1.5:1——等于没画。
    static let tertiary = level(0.55, 0.46)
}

// MARK: - 格式化
//
// 跟 `src/lib/format.ts` 逐条对齐。这些数字会同时出现在悬浮窗和主面板里，
// 两处算法不一致的话，同一个值会显示成 "1.5 GB" 和 "1.50 GB"，很难看。

enum Fmt {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 二进制进位（1024）。内存、磁盘容量用它。
    static func bytes(_ n: Double, digits: Int = 1) -> String {
        guard n >= 1 else { return "0 B" }
        var v = n
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.\(digits)f %@", v, units[i])
    }

    static func rate(_ bps: Double) -> String { "\(bytes(bps))/s" }

    /// 拆成数字和单位，方便排版时数字大、单位小。
    static func splitRate(_ bps: Double) -> (value: String, unit: String) {
        let s = rate(bps)
        guard let sp = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[s.startIndex..<sp]), String(s[s.index(after: sp)...]))
    }

    /// 十进制进位（1000）。厂商标 TBW、smartctl 报 Data Units Written 用的都是这个口径，
    /// 硬盘寿命页如果按 1024 算，数字会和官方标称对不上。
    static func bytesSI(_ n: Double, digits: Int = 1) -> String {
        guard n >= 1 else { return "0 B" }
        var v = n
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.\(digits)f %@", v, units[i])
    }

    /// 悬浮窗底部那种极简写法：`1.2G`、`840K`。
    static func compact(_ n: Double) -> String {
        guard n >= 1 else { return "0" }
        let u = ["B", "K", "M", "G"]
        var v = n
        var i = 0
        while v >= 1024 && i < u.count - 1 {
            v /= 1024
            i += 1
        }
        return v < 10 ? String(format: "%.1f%@", v, u[i]) : "\(Int(v.rounded()))\(u[i])"
    }

    static func pct(_ n: Double) -> Double { min(100, max(0, n)) }

    /// IOPS 的千位分隔。
    ///
    /// `12116` 和 `12,116` 是同一个数，但前者要数位数才知道是「一万二」还是
    /// 「十二万」——而这正是这一格唯一要传达的信息。用 `NumberFormatter` 而不是
    /// 手写逗号：法语的千位分隔符是窄不换行空格，德语是点号。
    static func iops(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v.rounded())) ?? String(format: "%.0f", v)
    }

    static func tempColor(_ t: Double) -> Color {
        if t >= 85 { return Palette.danger }
        if t >= 70 { return Palette.warn }
        return Palette.ok
    }

    static func loadColor(_ v: Double) -> Color {
        if v >= 85 { return Palette.danger }
        if v >= 65 { return Palette.warn }
        return Palette.accent
    }

    /// 表格里的着色：只有真的高才上色。
    ///
    /// 每个数字都染一遍的话，整列都在喊，反而看不出哪个才是异常的那个——
    /// 而「哪个异常」正是这张表唯一的用处。
    static func loadTint(_ v: Double) -> Color? {
        if v >= 85 { return Palette.danger }
        if v >= 65 { return Palette.warn }
        return nil
    }

    /// 秒 → 「3 天 4 小时」/「2h 15m」这种。跟界面语言无关的缩写，
    /// 因为它在悬浮窗/卡片里只占一行，翻译成完整单词会撑爆。
    static func uptime(_ secs: UInt64) -> String {
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
