import AppKit
import Charts
import SwiftUI

// MARK: - 窗口

final class DashboardWindow: NSWindow {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 标题栏透明、标题文字不画（大标题在内容里）。
        // 注意别开 `titlebarAppearsTransparent`：它会把 `.fullSizeContentView`
        // 塞进 styleMask，内容顶到窗口最上面，红绿灯被盖住——窗口就关不掉了。
        titleVisibility = .hidden
        title = "EZPcMonitor"
        minSize = NSSize(width: 820, height: 620)
        contentView = NSHostingView(rootView: AnyView(content))
        center()
        setFrameAutosaveName("ezpcm.dashboard")
    }
}

@MainActor
final class DashboardController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: DashboardWindow?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(settings: Bool) {
        if window == nil {
            let w = DashboardWindow(
                content: DashboardView(model: model)
                    .environmentObject(L10n.shared)
            )
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 主面板开着才需要进程列表；关掉就停采，省一次全表遍历
        model.engine.setWantProcs(true)
    }

    /// 关窗就把窗口整个放掉，顺便停掉进程采集。
    ///
    /// 不缓存窗口是有意的：面板一关，`NSHostingView` 里的图表、表格全都不该
    /// 继续占内存——这个分支的全部意义就是「不常驻」。
    func windowWillClose(_ notification: Notification) {
        model.engine.setWantProcs(false)
        window = nil
    }
}

// MARK: - 主面板

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    @State private var history: [HistoryPoint] = []
    @State private var range: UInt64 = 3600
    @State private var loadedRange: UInt64 = 0

    private let ranges: [(secs: UInt64, n: Int, unit: String)] = [
        (3600, 1, "set.unitHour"),
        (21_600, 6, "set.unitHour"),
        (86_400, 24, "set.unitHour"),
        (604_800, 7, "set.unitDay"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            cards
            chartPanel
            diskPanel
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(minWidth: 820, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await reload() }
        .onChange(of: range) { _ in Task { await reload() } }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EZPcMonitor")
                    .font(.system(size: 19, weight: .semibold))
                Text(model.snapshot.map { "\($0.host.name) · \($0.host.os)" } ?? i18n.t("dash.connecting"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let snap = model.snapshot {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snap.cpu.brand)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(i18n.t("dash.uptime", ["v": Fmt.uptime(snap.uptime)]))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 指标卡

    private var cards: some View {
        HStack(spacing: 12) {
            MetricCard(
                title: "CPU",
                value: "\(Int(model.cpuPercent.rounded()))",
                unit: "%",
                tint: Palette.cpu,
                series: model.series,
                detail: model.snapshot.map { "\($0.cpu.cores) 核 · \(String(format: "%.2f", $0.load.first ?? 0))" }
            )
            MetricCard(
                title: i18n.t("card.mem"),
                value: "\(Int(model.memPercent.rounded()))",
                unit: "%",
                tint: Palette.mem,
                series: model.memSeries,
                detail: model.snapshot.map {
                    "\(Fmt.bytes(Double($0.mem.used))) / \(Fmt.bytes(Double($0.mem.total)))"
                }
            )
            MetricCard(
                title: i18n.t("card.temp"),
                value: model.primaryTemp.map { "\(Int($0.rounded()))" } ?? "--",
                unit: "°C",
                tint: model.primaryTemp.map(Fmt.tempColor) ?? Palette.temp,
                series: [],
                detail: model.snapshot?.temps.first(where: { $0.primary })?.label
            )
            MetricCard(
                title: i18n.t("card.net"),
                value: Fmt.compact(model.snapshot?.net.rxBps ?? 0),
                unit: "/s",
                tint: Palette.rx,
                series: [],
                detail: "↑ \(Fmt.rate(model.snapshot?.net.txBps ?? 0))"
            )
        }
    }

    // MARK: 曲线

    private var chartPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(i18n.t("dash.history"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("", selection: $range) {
                    ForEach(ranges, id: \.secs) { r in
                        Text("\(r.n) \(i18n.t(r.unit))").tag(r.secs)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }

            if history.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                    Text(loadedRange == 0 ? i18n.t("common.reading") : i18n.t("dash.noHistory"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 190)
            } else {
                Chart(history) { p in
                    LineMark(
                        x: .value("t", p.date),
                        y: .value("v", p.cpu),
                        series: .value("k", "cpu")
                    )
                    .foregroundStyle(Palette.cpu)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))

                    LineMark(
                        x: .value("t", p.date),
                        y: .value("v", p.mem),
                        series: .value("k", "mem")
                    )
                    .foregroundStyle(Palette.mem)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.07))
                        AxisValueLabel().font(.system(size: 9))
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 190)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: 磁盘

    private var diskPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(i18n.t("card.disk"))
                .font(.system(size: 13, weight: .semibold))
            ForEach(model.snapshot?.disks ?? []) { d in
                HStack(spacing: 10) {
                    Text(d.name)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 130, alignment: .leading)
                        .lineLimit(1)
                    Text(d.mount)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .frame(width: 70, alignment: .leading)
                        .lineLimit(1)
                    ProgressView(value: d.percent / 100)
                        .progressViewStyle(.linear)
                        .tint(d.percent > 90 ? Palette.danger : Palette.disk)
                    Text("\(Fmt.bytes(Double(d.used))) / \(Fmt.bytes(Double(d.total)))")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .trailing)
                    Text("R \(Fmt.compact(d.readBps))/s  W \(Fmt.compact(d.writeBps))/s")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 150, alignment: .trailing)
                }
                .frame(height: 22)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    // MARK: 取数

    private func reload() async {
        let from = UInt64(Date().timeIntervalSince1970) - range
        let rows = await Task.detached(priority: .userInitiated) { [engine = model.engine] in
            engine.history(from: from)
        }.value
        history = rows
        loadedRange = range
    }
}

// MARK: - 指标卡

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String
    let tint: Color
    let series: [Double]
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if series.count > 1 {
                Sparkline(values: series, color: tint, floor: 20)
                    .frame(height: 22)
            } else {
                Spacer().frame(height: 22)
            }

            Text(detail ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}
