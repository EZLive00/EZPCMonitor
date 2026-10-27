import SwiftUI

// MARK: - 容器

/// 主面板和弹窗共用的卡片底。
///
/// 卡片要不要磨砂，由 `cardFrost` 这个环境值决定。
///
/// 主面板的背景现在是**真透明**的（能看到后面的窗口），卡片如果还只是 5.5% 的白，
/// 整块窗口就是一张平的通透玻璃，看不出哪里是卡片。磨砂把卡片和背景分成两层材质：
/// 背景是「透」的，卡片是「糊」的。
///
/// 用环境值而不是构造参数：主面板里 7 处 `CardBox`，历史窗口 1 处，逐处传等于把
/// 同一个开关抄 8 遍，还容易漏。历史窗口是**不透明**窗口，磨砂在那儿只会白花内存。
private struct CardFrostKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardFrost: Bool {
        get { self[CardFrostKey.self] }
        set { self[CardFrostKey.self] = newValue }
    }
}

/// 卡片自己那层玻璃。
///
/// **不用 SwiftUI 的 `.thinMaterial`**：实测它铺在纯色背景上，卡片内部和旁边的
/// 缝隙只差 1~2 级亮度（同一张截图采样：缝隙 (34,51,69)，卡片 (33,53,67)），
/// 等于没画——用户的原话就是「区块和背景一种透明效果」。它到底取了哪一层没法控制，
/// 索性自己搭一层能算清楚的。
///
/// 两层：
/// 1. `NSVisualEffectView`（`.withinWindow`）—— 糊的是**窗口里**的背景（染色或照片），
///    不是桌面。所以纯色下它就是去饱和 + 加噪点，图片下能把照片糊开，视觉上都是「毛玻璃」。
/// 2. 一层提亮。深色 12%、浅色 42%：这才是「卡片浮在背景上」的那点亮度差，
///    也是滑杆拉到 10% 时唯一还能把区块和缝隙分开的东西（实测差 20 级）。
struct CardFrost: View {
    var body: some View {
        ZStack {
            MaterialView(material: .popover, blending: .withinWindow)
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                // 浅色主题要的是「比背景白」，所以给得多；深色主题只要「比背景亮一点」，
                // 给多了会变成一块灰板，压掉背景的色相。
                return NSColor.white.withAlphaComponent(isDark ? 0.12 : 0.42)
            })
        }
    }
}

struct CardBox<Content: View>: View {
    var padding: CGFloat = 14
    let content: Content

    @Environment(\.cardFrost) private var frost

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if frost {
                    CardFrost()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(frost ? 0.14 : 0.09), lineWidth: 1)
            )
    }
}

/// 卡片标题行：左边标题，右边可以挂标签或小控件。
struct CardHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 4)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// 小灰标签：`10 核`、`3 个传感器`、`TOP 20`。
struct Tag: View {
    let text: String
    var color: Color = Ink.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

/// 键值行：左灰右黑，用于内存 / GPU / 网络卡的底部明细。
struct KVRow: View {
    let key: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}

// MARK: - 进度条

/// 细进度条。`value` 是 0–100。
struct Meter: View {
    let value: Double
    var height: CGFloat = 5
    var from: Color = Palette.cpuDeep
    var to: Color = Palette.cpu
    /// 单色（温度、告警这类不该有渐变的地方）
    var flat = false

    private var ratio: Double { min(1, max(0, value / 100)) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(flat
                          ? AnyShapeStyle(to)
                          : AnyShapeStyle(LinearGradient(
                                colors: [from, to],
                                startPoint: .leading, endPoint: .trailing)))
                    .frame(width: geo.size.width * ratio)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 按钮

/// 圆角小胶囊按钮。`on` 表示当前选中。
struct Chip: View {
    let title: String
    var on = false
    var enabled = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : (enabled ? Color.primary : Color.secondary.opacity(0.5)))
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    Capsule().fill(on ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Color.primary.opacity(0.06)))
                )
                .overlay(
                    Capsule().strokeBorder(
                        on ? Color.clear : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help ?? "")
    }
}

/// 次要按钮（描边）。
struct MiniButton: View {
    let title: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(enabled ? 0.07 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 主按钮（实心强调色）。
struct PrimaryButton: View {
    let title: String
    var enabled = true
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: small ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, small ? 10 : 14)
                .padding(.vertical, small ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.accent.opacity(enabled ? 1 : 0.4))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 分段切换（曲线 / 程序）。
struct SegmentedTabs: View {
    let titles: [String]
    let index: Int
    let action: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, title in
                Button { action(i) } label: {
                    Text(title)
                        .font(.system(size: 11, weight: i == index ? .semibold : .regular))
                        .foregroundStyle(i == index ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(i == index ? Color.primary.opacity(0.10) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

// MARK: - 图表

/// 历史曲线。
///
/// 两条线叠在一起：实线是**每桶峰值**（尖峰不会被平均掉），面积是**每桶均值**
/// （看得出常态）。只画一条的话，要么看不到抖动，要么把「一直很忙」和
/// 「偶尔飙一下」画成同一个形状。
struct TrendChart: View {
    let buckets: [Bucket]
    let color: Color
    /// 底部时间轴，最多三个：左 / 中 / 右
    var times: [String] = []
    var height: CGFloat = 96

    private var hi: Double {
        max(1, (buckets.map(\.max).max() ?? 0)) * 1.12
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                if buckets.count > 1 {
                    let line = points(in: geo.size, peak: true)
                    let area = points(in: geo.size, peak: false)
                    ZStack {
                        Path { p in
                            p.move(to: CGPoint(x: area[0].x, y: geo.size.height))
                            for pt in area { p.addLine(to: pt) }
                            p.addLine(to: CGPoint(x: area[area.count - 1].x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.30), color.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                        Path { p in
                            p.move(to: line[0])
                            for pt in line.dropFirst() { p.addLine(to: pt) }
                        }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: height)

            if !times.isEmpty {
                HStack {
                    ForEach(Array(times.enumerated()), id: \.offset) { i, t in
                        Text(t)
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                        if i < times.count - 1 { Spacer() }
                    }
                }
            }
        }
    }

    private func points(in size: CGSize, peak: Bool) -> [CGPoint] {
        let step = size.width / CGFloat(max(1, buckets.count - 1))
        let usable = max(1, size.height - 2)
        return buckets.enumerated().map { i, b in
            let v = min(max(0, peak ? b.max : b.avg), hi)
            return CGPoint(x: CGFloat(i) * step, y: size.height - CGFloat(v / hi) * usable - 1)
        }
    }
}

/// 每核占用柱状图。
///
/// 宽度按容器等分而不是固定 6pt：8 核的机器上固定宽度会缩在左上角一小撮，
/// 16 核的机器上又会顶出卡片。等分之后两边的观感一致。
struct CoreBars: View {
    let values: [Double]
    var height: CGFloat = 30
    var showNumbers = true

    var body: some View {
        GeometryReader { geo in
            let n = max(1, values.count)
            let gap: CGFloat = 3
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    VStack(spacing: 3) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Fmt.loadColor(v))
                                .frame(height: max(2, height * min(100, max(0, v)) / 100))
                        }
                        .frame(height: height)

                        if showNumbers {
                            Text("\(Int(v.rounded()))")
                                .font(.system(size: 7.5))
                                .monospacedDigit()
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    .frame(width: w)
                }
            }
        }
        .frame(height: showNumbers ? height + 12 : height)
    }
}

// MARK: - 硬盘状态

/// 一级页面只放这一行状态摘要——具体属性、曲线、测速都在详情里。
///
/// 措辞刻意克制：`SMART Status: Verified` 只意味着「没有属性越过阈值」，
/// 不等于「盘是好的」，所以写「正常」而不是「健康良好」；`percentage_used`
/// 是磨损记账而不是倒计时，所以写「磨损」而不是「剩余寿命」。
struct DiskStatusChip: View {
    let health: DiskHealth
    @EnvironmentObject private var i18n: L10n

    private var color: Color {
        switch health.status {
        case "good": return Palette.ok
        case "warning": return Palette.warn
        case "bad": return Palette.danger
        default: return Color.secondary
        }
    }

    private var label: String {
        switch health.status {
        case "good": return i18n.t("ds.good")
        case "warning": return i18n.t("ds.warning")
        case "bad": return i18n.t("ds.bad")
        default: return i18n.t("ds.unknown")
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).foregroundStyle(color)
            if let used = health.lifeUsed {
                Text("·").foregroundStyle(Ink.tertiary)
                Text(i18n.t("ds.wear", ["v": "\(Int(used.rounded()))"]))
            }
            if let t = health.temperature {
                Text("·").foregroundStyle(Ink.tertiary)
                Text("\(Int(t.rounded()))°C")
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
    }
}

/// 详情页顶部的四个数字块。
struct StatTile: View {
    let key: String
    let value: String
    let note: String
    var valueColor: Color = .primary
    var unit: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            Text(note)
                .font(.system(size: 9.5))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - 弹窗外壳

/// 弹窗顶部：标题 + 副标题 + 右侧操作。
struct SheetHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let actions: Actions

    init(_ title: String, subtitle: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { actions }
        }
    }
}

extension SheetHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// 一条 1px 分隔线，比 `Divider()` 更淡，卡片里用不抢视线。
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 1)
    }
}

/// 空状态：一行粗体结论 + 一行解释，可选一个按钮。
struct EmptyState<Action: View>: View {
    let title: String
    let hint: String
    let action: Action

    init(_ title: String, hint: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.hint = hint
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

extension EmptyState where Action == EmptyView {
    init(_ title: String, hint: String) {
        self.init(title, hint: hint) { EmptyView() }
    }
}
