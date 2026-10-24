import AppKit
import SwiftUI
import SystemConfiguration

// MARK: - 窗口

final class HistoryWindow: NSWindow {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "History"
        useUnifiedChrome()
        minSize = NSSize(width: 820, height: 560)
        contentView = NSHostingView(rootView: AnyView(content))
        center()
        setFrameAutosaveName("ezpcm.history")
    }

    /// Esc 关窗。窗口里没有自绘的关闭按钮了，键盘总得留个出口。
    override func cancelOperation(_ sender: Any?) {
        performClose(nil)
    }
}

@MainActor
final class HistoryController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: HistoryWindow?

    var onOpenSettings: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let view = HistoryView(
                model: model,
                onOpenSettings: { [weak self] in self?.onOpenSettings() }
            )
            .environmentObject(L10n.shared)
            let w = HistoryWindow(content: view)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 和历史窗口一起关掉，省得一直占着几十万个点。
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 视图

/// 历史回溯。两种看法，同一份数据：
///
/// - **曲线**：整机各指标的走势，回答「什么时候卡的」；
/// - **程序**：按进程名合并后的高占用榜，回答「是谁卡的」。
///
/// 时间窗只列「保留时长以内」的档位，程序榜跟曲线共用同一个窗口——
/// 它本来就是从同一段历史里算出来的，再给一套时间选择只会让人怀疑两边对不上。
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onOpenSettings: () -> Void = {}

    @State private var rows: [HistoryPoint] = []
    @State private var leaders: Leaders?
    @State private var stats: HistoryStats?
    @State private var range: UInt64?
    @State private var view = 0
    @State private var loading = true
    @State private var busy: String?
    @State private var flash = ""

    /// 默认停在「保留时长以内最大的那一档」，而不是「全部」：
    /// 保留 30 天的人一进来就画三十万个点，图糊成一片，还得自己往回缩。
    init(model: AppModel, onOpenSettings: @escaping () -> Void = {}) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        let opts = SeriesLogic.ranges.filter { $0 <= model.settings.historyRetentionSecs }
        _range = State(initialValue: opts.last)
    }

    private var retention: UInt64 { model.settings.historyRetentionSecs }
    private var enabled: Bool { model.settings.historyEnabled }

    /// 可选档位只到保留时长为止，末尾再补一个「全部」。
    private var options: [UInt64] {
        SeriesLogic.ranges.filter { $0 <= retention }
    }

    /// 24 小时档也要标日期：首尾正好差一天，中间那个「09:32」属于昨天还是今天
    /// 光看时间分不出来。
    private var withDate: Bool { (range ?? retention) >= 86_400 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.top, 10)

            if !enabled && rows.isEmpty && !loading {
                EmptyState(
                    i18n.t("hist.off"),
                    hint: i18n.t("hist.offHint", ["n": "\(stats?.sampleSecs ?? 10)"])
                ) {
                    PrimaryButton(title: i18n.t("hist.enable"), action: onOpenSettings)
                }
                .frame(maxHeight: .infinity)
            } else {
                rangeBar.padding(.top, 10)

                ScrollView {
                    content.padding(.vertical, 12)
                }
                .scrollIndicators(.automatic)
            }

            Hairline()
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: range) {
            await load()
            // 开发钩子：`--report` 一进来就出一张图存到「下载」，
            // 用来回归报告版面和 ImageRenderer 的导出，省得每次都手点。
            if CommandLine.arguments.contains("--report") { await makeReport(copy: false) }
        }
        .task { stats = await fetchStats() }
    }

    // MARK: 头部

    private var header: some View {
        SheetHeader(i18n.t("hist.title"), subtitle: subtitle) {
            Text(flash)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Palette.ok)
                .opacity(flash.isEmpty ? 0 : 1)

            SegmentedTabs(titles: [i18n.t("hist.viewCurve"), i18n.t("hist.viewProc")], index: view) { view = $0 }

            MiniButton(
                title: busy == "report" ? i18n.t("hist.reporting") : i18n.t("hist.report"),
                enabled: busy == nil && !rows.isEmpty
            ) { Task { await makeReport(copy: false) } }

            MiniButton(title: i18n.t("hist.copy"), enabled: busy == nil && !rows.isEmpty) {
                Task { await makeReport(copy: true) }
            }

            // 自绘的 ✕ 去掉了：窗口左上角已经有红绿灯，两个关闭按钮并排只会让人犹豫。
            // 键盘党按 Esc 一样能关（HistoryWindow.cancelOperation）。
        }
    }

    private var subtitle: String {
        guard let stats else { return i18n.t("common.reading") }
        return i18n.t("hist.sub", [
            "count": i18n.tn("p.records", Double(stats.count)),
            "size": Fmt.bytes(Double(stats.bytes + stats.procBytes)),
            "ret": i18n.retention(retention),
        ])
    }

    // MARK: 时间窗

    private var rangeBar: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { r in
                Chip(title: i18n.retention(r), on: range == r) { range = r }
            }
            Chip(title: i18n.t("hist.all"), on: range == nil) { range = nil }

            Spacer(minLength: 8)

            if view == 0 {
                Text(loading ? i18n.t("common.reading") : i18n.tn("p.points", Double(rows.count)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if view == 0 {
            if rows.isEmpty {
                if loading {
                    Text(i18n.t("common.reading"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    EmptyState(
                        i18n.t("hist.empty"),
                        hint: i18n.t("hist.emptyHint", ["n": "\(stats?.sampleSecs ?? 10)"])
                    )
                }
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    ForEach(charted) { m in
                        metricCard(m)
                    }
                }
            }
        } else {
            ProcLeadersView(data: leaders ?? .empty, loading: leaders == nil, withDate: withDate)
                .frame(minHeight: 320)
        }
    }

    /// GPU 一条线都没采到就不画——一条贴着底边的直线比没有图更让人困惑。
    private var charted: [Metric] {
        Metric.charted.filter { m in
            m != .gpu || SeriesLogic.stats(rows, .gpu).max > 0
        }
    }

    private func metricCard(_ m: Metric) -> some View {
        let s = SeriesLogic.stats(rows, m)

        return CardBox(padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(i18n.t(m.titleKey))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(i18n.t("hist.peak")) \(m.format(s.max))")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("· \(i18n.t("hist.avg")) \(m.format(s.avg))")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                TrendChart(
                    buckets: SeriesLogic.buckets(rows, m),
                    color: m.color,
                    times: timeLabels,
                    height: 88
                )
            }
        }
    }

    /// 时间轴三档：起点 / 中点 / 终点。
    private var timeLabels: [String] {
        guard rows.count > 1, let first = rows.first, let last = rows.last else { return [] }
        let mid = (first.t + last.t) / 2
        return [first.t, mid, last.t].map { i18n.clock($0, withDate: withDate) }
    }

    private var footer: some View {
        HStack {
            Text(view == 0
                 ? i18n.t("hist.foot", ["n": "\(stats?.sampleSecs ?? 10)"])
                 : i18n.t("hist.procFoot", ["n": "\(stats?.procSampleSecs ?? 30)"]))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: 取数

    @MainActor
    private func load() async {
        loading = true
        let from = range.map { UInt64(Date().timeIntervalSince1970) - $0 }
        let engine = model.engine
        // 一次拿回曲线和程序榜：程序榜那次目录扫描比曲线贵得多，
        // 两个都读同一批分片，串行做反而比并发两次扫描快。
        let (r, l) = await Task.detached(priority: .userInitiated) { () -> ([HistoryPoint], Leaders) in
            (engine.history(from: from), engine.leaders(from: from))
        }.value
        rows = r
        leaders = l
        loading = false
    }

    @MainActor
    private func fetchStats() async -> HistoryStats? {
        let engine = model.engine
        return await Task.detached(priority: .utility) { engine.stats() }.value
    }

    // MARK: 出图

    /// 两个按钮走同一条路：先落盘，再决定要不要放进剪贴板。
    /// 复制也得有文件——用户很可能既想粘到聊天里，也想留一份。
    @MainActor
    private func makeReport(copy: Bool) async {
        guard busy == nil, !rows.isEmpty else { return }
        busy = copy ? "copy" : "report"

        // 历史窗口可以比主面板先打开，那时候模型里还没有第一拍快照。
        // 不补这一下，报告抬头就会写成「Mac ·」——中间那个点后面什么都没有。
        model.refreshNow()
        let snap = model.snapshot
        let host = snap?.host.name ?? Self.computerName()
        let os = snap?.host.os ?? ""

        let input = ReportInput(
            host: host,
            os: os,
            rangeLabel: i18n.retention(range ?? retention),
            points: rows,
            procs: leaders?.rows ?? [],
            now: UInt64(Date().timeIntervalSince1970),
            withDate: withDate
        )

        guard let image = ReportMaker.image(input),
              let png = ReportMaker.png(image),
              let url = ReportMaker.save(png, name: ReportMaker.name(input.now))
        else {
            busy = nil
            show(i18n.t("hist.copyFail"))
            return
        }

        if copy {
            _ = ReportMaker.copy(image)
            show(i18n.t("hist.copied"))
        } else {
            show(i18n.t("hist.reportSaved"))
            // 顺手在访达里选中，省得用户去翻下载目录
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        busy = nil
    }

    /// 报告抬头要写用户在「系统设置」里看到的那台机器名，而不是 DNS 主机名——
    /// 后者常是 `wargondebijibendiannao.local` 这种拼音串，放进报告里很难看。
    private static func computerName() -> String {
        if let n = SCDynamicStoreCopyComputerName(nil, nil) as String?, !n.isEmpty {
            return n
        }
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }

    @MainActor
    private func show(_ text: String) {
        flash = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if flash == text { flash = "" }
        }
    }
}
