import AppKit
import SwiftUI

// MARK: - 窗口

final class SettingsWindow: NSWindow {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Settings"
        useUnifiedChrome()
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: AnyView(content))
        center()
        setFrameAutosaveName("ezpcm.settings")
    }

    /// Esc 关窗。窗口里没有自绘的关闭按钮了，键盘总得留个出口。
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: SettingsWindow?

    var onOpenHistory: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let view = SettingsView(model: model, onOpenHistory: { [weak self] in self?.onOpenHistory() })
                .environmentObject(L10n.shared)
            let w = SettingsWindow(content: view)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 视图

/// 设置。
///
/// 所有改动都走 `patchSettings` 一个入口——夹取、落盘都在 core 里做一次，
/// 界面不重复实现规则。所以这里没有「保存」按钮：点一下就是最终结果，
/// 输入框只在数字非法时禁用「应用」。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onOpenHistory: () -> Void = {}

    @State private var draftMs = ""
    @State private var amount = ""
    @State private var unit = 3600
    @State private var stats: HistoryStats?
    @State private var version = ""

    private static let minMs: UInt64 = 500
    private static let maxMs: UInt64 = 60_000

    private struct FreqPreset: Identifiable {
        let ms: UInt64
        let tier: String
        let hint: String
        var id: UInt64 { ms }
    }

    private struct ThemeOption: Identifiable {
        let tag: String
        let key: String
        var id: String { tag }
    }

    private struct UnitOption: Identifiable {
        let secs: UInt64
        let key: String
        var id: UInt64 { secs }
    }

    private static let presets: [FreqPreset] = [
        FreqPreset(ms: 1000, tier: "set.tierHigh", hint: "set.freqMost"),
        FreqPreset(ms: 5000, tier: "set.tierMid", hint: "set.freqBalanced"),
        FreqPreset(ms: 10_000, tier: "set.tierLow", hint: "set.freqSaver"),
    ]
    private static let themes: [ThemeOption] = [
        ThemeOption(tag: "auto", key: "set.themeAuto"),
        ThemeOption(tag: "dark", key: "set.themeDark"),
        ThemeOption(tag: "light", key: "set.themeLight"),
    ]
    private static let units: [UnitOption] = [
        UnitOption(secs: 60, key: "set.unitMin"),
        UnitOption(secs: 3600, key: "set.unitHour"),
        UnitOption(secs: 86_400, key: "set.unitDay"),
    ]

    private var settings: Settings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 不再画自绘的 ✕：窗口左上角已经有红绿灯了，两个关闭按钮并排只会让人犹豫。
            // 键盘党按 Esc 一样能关（下面的 onExitCommand）。
            SheetHeader(i18n.t("set.title"), subtitle: i18n.t("set.sub"))

            Hairline().padding(.top, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    monitorGroup
                    generalGroup
                    historyGroup
                    aboutGroup
                }
                .padding(.vertical, 14)
            }
            .scrollIndicators(.automatic)

            Hairline()
            Text(i18n.t("set.foot"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(width: 620, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            syncDrafts()
            version = model.engine.version()
            stats = await fetchStats()
        }
        .onChange(of: settings) { _ in syncDrafts() }
    }

    // MARK: 监控

    private var monitorGroup: some View {
        group(i18n.t("set.group.monitor")) {
            row(i18n.t("set.freq"), hint: i18n.t("set.freqHint")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(Self.presets) { p in
                            presetTile(
                                i18n.t(p.tier),
                                i18n.interval(p.ms),
                                on: settings.intervalMs == p.ms,
                                help: "\(i18n.interval(p.ms)) · \(i18n.t(p.hint))"
                            ) {
                                model.patchSettings(["intervalMs": p.ms])
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text(i18n.t("common.custom"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", text: $draftMs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 62)
                            .font(.system(size: 11, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(msValid ? Color.clear : Palette.warn, lineWidth: 1)
                            )
                        Text(i18n.t("set.unitSec"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        PrimaryButton(title: i18n.t("common.apply"), enabled: msValid, small: true) {
                            model.patchSettings(["intervalMs": UInt64((Double(draftMs) ?? 0) * 1000)])
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var msValid: Bool {
        guard let v = Double(draftMs), v.isFinite else { return false }
        let ms = v * 1000
        return ms >= Double(Self.minMs) && ms <= Double(Self.maxMs)
    }

    // MARK: 通用

    private var generalGroup: some View {
        group(i18n.t("set.group.general")) {
            row(i18n.t("set.theme"), hint: i18n.t("set.themeHint")) {
                HStack(spacing: 6) {
                    ForEach(Self.themes) { t in
                        themeTile(t.tag, i18n.t(t.key), on: settings.theme == t.tag) {
                            model.patchSettings(["theme": t.tag])
                        }
                    }
                    Spacer()
                }
            }

            row(i18n.t("set.language"), hint: i18n.t("set.languageHint")) {
                FlowRow(spacing: 6) {
                    Chip(title: i18n.t("set.langAuto"), on: settings.language == "auto") {
                        model.patchSettings(["language": "auto"])
                    }
                    ForEach(L10n.choices) { l in
                        Chip(title: l.name, on: settings.language == l.tag) {
                            model.patchSettings(["language": l.tag])
                        }
                    }
                }
            }
        }
    }

    private func themeTile(_ tag: String, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        // 色块写死成「这个主题长什么样」，不跟当前主题走——它是预览，不是装饰
        let bg: Color = tag == "light" ? Color(white: 0.96)
            : tag == "dark" ? Color(white: 0.16)
            : Color(white: 0.5)
        return Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        tag == "auto"
                            ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.16)],
                                                           startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(bg)
                    )
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                Text(title)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(on ? Palette.accent.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func presetTile(_ title: String, _ sub: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                Text(sub)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 74)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(on ? Palette.accent.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: 历史

    private var historyGroup: some View {
        group(i18n.t("set.group.history"), trailing: {
            Button(action: onOpenHistory) {
                Text(i18n.t("set.viewHistory"))
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
            }
            .buttonStyle(.plain)
        }) {
            row(i18n.t("set.record"), hint: i18n.t("set.recordHint", ["n": "\(sampleSecs)"])) {
                HStack {
                    Toggle("", isOn: Binding(
                        get: { settings.historyEnabled },
                        set: { model.patchSettings(["historyEnabled": $0]) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    Spacer()
                }
            }

            row(i18n.t("set.retention"), hint: i18n.t("set.retentionHint")) {
                VStack(alignment: .leading, spacing: 8) {
                    FlowRow(spacing: 6) {
                        ForEach(presets, id: \.self) { p in
                            retentionTile(p, on: settings.historyRetentionSecs == p) {
                                model.patchSettings(["historyRetentionSecs": p])
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text(i18n.t("common.custom"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        TextField("", text: $amount)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .font(.system(size: 11, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(retentionValid ? Color.clear : Palette.warn, lineWidth: 1)
                            )
                        ForEach(Self.units) { u in
                            Chip(title: i18n.t(u.key), on: unit == Int(u.secs)) { unit = Int(u.secs) }
                        }
                        PrimaryButton(title: i18n.t("common.apply"), enabled: retentionValid, small: true) {
                            model.patchSettings(["historyRetentionSecs": retentionSecs])
                        }
                        Spacer()
                    }

                    if !retentionValid {
                        Text(i18n.t("set.range", [
                            "min": i18n.retention(minRetention),
                            "max": i18n.retention(maxRetention),
                        ]))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.warn)
                    }
                }
            }

            row(i18n.t("set.usage"), hint: stats.map {
                i18n.t("set.usageHint", [
                    "count": i18n.tn("p.records", Double($0.count)),
                    "b": "\($0.bytesPerRecord)",
                ])
            } ?? i18n.t("common.reading")) {
                HStack(spacing: 8) {
                    Spacer()
                    Text(stats.map { Fmt.bytes(Double($0.bytes + $0.procBytes)) } ?? "—")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    MiniButton(
                        title: i18n.t("set.clear"),
                        enabled: canClear
                    ) {
                        model.engine.clearHistory()
                        Task { stats = await fetchStats() }
                    }
                }
            }

            if settings.historyEnabled {
                Text(i18n.t("set.estimate", [
                    "ret": i18n.retention(settings.historyRetentionSecs),
                    "size": estimate(settings.historyRetentionSecs),
                    "n": "\(sampleSecs)",
                ]))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var canClear: Bool {
        guard let s = stats else { return false }
        return s.count > 0 || s.procBytes > 0
    }

    private func retentionTile(_ secs: UInt64, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(i18n.retention(secs))
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                Text(estimate(secs))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(on ? Palette.accent.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(on ? Palette.accent.opacity(0.55) : Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 关于

    private var aboutGroup: some View {
        group(i18n.t("set.group.about")) {
            row("EZPcMonitor", hint: i18n.t("set.aboutHint")) {
                HStack {
                    Spacer()
                    Text("v\(version)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 数据

    private var sampleSecs: UInt64 { stats?.sampleSecs ?? 10 }
    private var procSampleSecs: UInt64 { stats?.procSampleSecs ?? 30 }
    private var bpr: UInt64 { stats?.bytesPerRecord ?? 88 }
    private var procBps: UInt64 { stats?.procBytesPerSample ?? 300 }
    private var presets: [UInt64] { stats?.presets ?? SeriesLogic.ranges }
    private var minRetention: UInt64 { stats?.minRetentionSecs ?? 600 }
    private var maxRetention: UInt64 { stats?.maxRetentionSecs ?? 7_776_000 }

    /// 某档保留时长的预计占用 = 曲线 + 程序榜。
    ///
    /// 曲线那条是拿实测的每条字节数算的，很准；程序榜那条只能用经验值——
    /// 每条要记几个进程，取决于当时开了多少程序，没法用一个固定值概括。
    private func estimate(_ secs: UInt64) -> String {
        let curve = Double(secs) / Double(max(1, sampleSecs)) * Double(bpr)
        let procs = Double(secs) / Double(max(1, procSampleSecs)) * Double(procBps)
        return Fmt.bytes(curve + procs, digits: 0)
    }

    private var unitSecs: UInt64 { UInt64(unit) }

    private var retentionSecs: UInt64 {
        UInt64((Double(amount) ?? 0) * Double(unitSecs))
    }

    private var retentionValid: Bool {
        retentionSecs >= minRetention && retentionSecs <= maxRetention
    }

    private func fetchStats() async -> HistoryStats? {
        let engine = model.engine
        return await Task.detached(priority: .utility) { engine.stats() }.value
    }

    /// 外部（菜单栏）改了值，输入框要跟着对齐。
    private func syncDrafts() {
        let ms = settings.intervalMs
        draftMs = ms % 1000 == 0 ? "\(ms / 1000)" : String(format: "%.1f", Double(ms) / 1000)

        let secs = settings.historyRetentionSecs
        let u: UInt64 = secs % 86_400 == 0 ? 86_400 : (secs % 3600 == 0 ? 3600 : 60)
        unit = Int(u)
        amount = "\(secs / u)"
    }

    // MARK: 排版

    private func group<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        group(title, trailing: { EmptyView() }, content: content)
    }

    private func group<T: View, Content: View>(
        _ title: String,
        @ViewBuilder trailing: () -> T,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                trailing()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
        }
    }

    private func row<Content: View>(
        _ label: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5))
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 168, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 自动换行

/// 一行放不下就换行。语言选项有 8 个、保留档位有 5 个，固定宽度里必然要折。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}
