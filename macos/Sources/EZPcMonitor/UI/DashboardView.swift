import AppKit
import SwiftUI

// MARK: - 窗口

final class DashboardWindow: NSWindow {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 标题栏透明、标题文字不画（大标题在内容里）。
        // 注意别开 `titlebarAppearsTransparent`：它会把 `.fullSizeContentView`
        // 塞进 styleMask，内容顶到窗口最上面，红绿灯被盖住——窗口就关不掉了。
        titleVisibility = .hidden
        title = "EZPcMonitor"
        minSize = NSSize(width: 880, height: 660)
        contentView = NSHostingView(rootView: AnyView(content))
        center()
        setFrameAutosaveName("ezpcm.dashboard")
    }
}

@MainActor
final class DashboardController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: DashboardWindow?

    /// 从主面板点开的两个二级窗口由 AppDelegate 统一持有，
    /// 这里只负责转达——面板关掉时它们不该跟着消失（用户可能正在看历史）。
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let view = DashboardView(
                model: model,
                onOpenHistory: { [weak self] in self?.onOpenHistory() },
                onOpenSettings: { [weak self] in self?.onOpenSettings() }
            )
            .environmentObject(L10n.shared)
            let w = DashboardWindow(content: view)
            w.delegate = self
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 主面板开着才需要进程列表；关掉就停采，省一次全表遍历
        model.engine.setWantProcs(true)
        model.refreshNow()
        model.startHealthPolling()
    }

    /// 关窗就把窗口整个放掉，顺便停掉进程采集。
    ///
    /// 不缓存窗口是有意的：面板一关，`NSHostingView` 里的表格、进度条全都不该
    /// 继续占内存——这个分支的全部意义就是「不常驻」。
    func windowWillClose(_ notification: Notification) {
        model.engine.setWantProcs(false)
        model.stopHealthPolling()
        window = nil
    }
}

// MARK: - 主面板

private enum ProcSort: String {
    case cpu, mem
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    @State private var detail: Disk?
    @State private var procSort: ProcSort = .cpu

    private var snap: Snapshot? { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let snap {
                row1(snap)
                row2(snap)
                procCard(snap)
            } else {
                Spacer()
                Text(i18n.t("dash.connecting"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(minWidth: 880, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detail) { d in
            DiskDetailView(
                disk: d,
                health: model.healthRow(for: d.mount),
                series: model.samples,
                refreshing: model.healthLoading,
                engine: model.engine,
                onRefresh: { model.refreshHealth(force: true) }
            )
            .environmentObject(i18n)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snap?.host.name ?? "EZPcMonitor")
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let snap {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snap.cpu.brand.isEmpty ? i18n.t("dash.cpuUnknown") : snap.cpu.brand)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(cpuDetail(snap))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Text(i18n.t("dash.load", ["v": snap.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")]))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                MiniButton(title: i18n.t("dash.history"), action: onOpenHistory)
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )
                }
                .buttonStyle(.plain)
                .help(i18n.t("dash.settings"))
            }
            .padding(.top, 2)
        }
        .frame(height: 44)
    }

    private var subtitle: String {
        guard let snap else { return i18n.t("dash.connecting") }
        return "\(snap.host.os) · \(snap.host.arch) · "
            + i18n.t("dash.uptime", ["v": i18n.duration(snap.uptime)])
    }

    private func cpuDetail(_ snap: Snapshot) -> String {
        var s = i18n.t("dash.cores", [
            "p": i18n.num(Double(snap.cpu.physical)),
            "t": i18n.num(Double(snap.cpu.cores)),
        ])
        if snap.cpu.freqMhz > 0 {
            s += " · " + String(format: "%.2f GHz", Double(snap.cpu.freqMhz) / 1000)
        }
        return s
    }

    // MARK: 两行卡片
    //
    // 宽度按 5:3:4 / 3:5:4 分，跟 WebView 版的 12 栏栅格一一对应。
    // 用 GeometryReader 显式算而不是 `.frame(maxWidth:)`：后者只能均分，
    // CPU 卡要放每核柱状图、磁盘卡要放三行明细，均分两边都不够用。

    private func row1(_ snap: Snapshot) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 12
            let w = geo.size.width - gap * 2
            HStack(spacing: gap) {
                cpuCard(snap).frame(width: w * 5 / 12)
                memCard(snap).frame(width: w * 3 / 12)
                tempCard(snap).frame(width: w * 4 / 12)
            }
        }
        .frame(height: 178)
    }

    private func row2(_ snap: Snapshot) -> some View {
        GeometryReader { geo in
            let gap: CGFloat = 12
            let w = geo.size.width - gap * 2
            HStack(spacing: gap) {
                gpuCard(snap).frame(width: w * 3 / 12)
                diskCard(snap).frame(width: w * 5 / 12)
                netCard(snap).frame(width: w * 4 / 12)
            }
        }
        .frame(height: 178)
    }

    // MARK: CPU

    private func cpuCard(_ snap: Snapshot) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("CPU") {
                    Tag(text: i18n.t("dash.live"), color: Palette.cpu)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.1f", snap.cpu.usage))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Palette.cpu)
                    Text("%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Sparkline(values: model.series, color: Palette.cpu)
                    .frame(height: 26)
                    .padding(.top, 4)

                Spacer(minLength: 4)

                CoreBars(values: snap.cpu.perCore, height: 30)
            }
        }
    }

    // MARK: 内存

    private func memCard(_ snap: Snapshot) -> some View {
        let swapPct = snap.mem.swapTotal > 0
            ? Double(snap.mem.swapUsed) / Double(snap.mem.swapTotal) * 100
            : 0

        return CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(i18n.t("card.mem")) {
                    Tag(text: Fmt.bytes(Double(snap.mem.total), digits: 0))
                }

                HStack(spacing: 12) {
                    RingGauge(
                        value: model.memPercent,
                        label: i18n.t("dash.used").uppercased(),
                        from: Palette.mem,
                        to: Palette.memDeep,
                        size: 76,
                        lineWidth: 7
                    )
                    VStack(spacing: 4) {
                        KVRow(key: i18n.t("dash.used"), value: Fmt.bytes(Double(snap.mem.used)))
                        KVRow(key: i18n.t("dash.avail"), value: Fmt.bytes(Double(snap.mem.available)))
                    }
                }
                .padding(.top, 8)

                Spacer(minLength: 6)

                VStack(spacing: 5) {
                    KVRow(
                        key: i18n.t("dash.swap"),
                        value: "\(Fmt.bytes(Double(snap.mem.swapUsed))) / \(Fmt.bytes(Double(snap.mem.swapTotal), digits: 0))"
                    )
                    Meter(value: swapPct, height: 5, from: Palette.memDeep, to: Palette.mem)
                }
            }
        }
    }

    // MARK: 温度

    private func tempCard(_ snap: Snapshot) -> some View {
        let primary = snap.temps.first(where: { $0.primary }) ?? snap.temps.first

        return CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(i18n.t("card.temp")) {
                    Tag(text: i18n.tn("p.sensors", Double(snap.temps.count)))
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(primary.map { "\(Int($0.value.rounded()))" } ?? "--")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primary.map { Fmt.tempColor($0.value) } ?? Color.secondary)
                    Text("°C")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Spacer(minLength: 4)

                VStack(spacing: 5) {
                    ForEach(snap.temps.prefix(4)) { t in
                        HStack(spacing: 8) {
                            Text(t.label)
                                .font(.system(size: 10))
                                .foregroundStyle(t.primary ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 104, alignment: .leading)
                            // 按临界温度归一：拿 100 归一的话，正常 45°C 的盘永远只有半格
                            Meter(
                                value: t.value / (t.critical ?? 105) * 100,
                                height: 4,
                                to: Fmt.tempColor(t.value),
                                flat: true
                            )
                            Text("\(Int(t.value.rounded()))°")
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                    if snap.temps.isEmpty {
                        Text(i18n.t("dash.noTemp"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    // MARK: GPU

    private func gpuCard(_ snap: Snapshot) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader("GPU") {
                    Tag(text: snap.gpu?.name ?? "—")
                }

                if let gpu = snap.gpu, let util = gpu.utilization {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(util.rounded()))")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.gpu)
                        Text("%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Sparkline(values: model.gpuSeries, color: Palette.gpu)
                        .frame(height: 26)
                        .padding(.top, 4)

                    Spacer(minLength: 6)

                    VStack(spacing: 4) {
                        KVRow(
                            key: i18n.t("dash.vramUsed"),
                            value: gpu.memUsed.map { Fmt.bytes(Double($0), digits: 0) } ?? "—"
                        )
                        KVRow(
                            key: i18n.t("dash.vramTotal"),
                            value: gpu.memTotal.map { Fmt.bytes(Double($0), digits: 0) } ?? i18n.t("dash.unified")
                        )
                    }
                } else {
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(i18n.t("dash.gpuNone"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(i18n.t("dash.gpuPlan"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 磁盘

    private func diskCard(_ snap: Snapshot) -> some View {
        CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(i18n.t("card.disk")) {
                    HStack(spacing: 5) {
                        Circle().fill(Palette.rx).frame(width: 5, height: 5)
                        Text(i18n.t("dash.read", ["v": Fmt.rate(snap.diskTotalReadBps)]))
                        Circle().fill(Palette.tx).frame(width: 5, height: 5).padding(.leading, 4)
                        Text(i18n.t("dash.write", ["v": Fmt.rate(snap.diskTotalWriteBps)]))
                    }
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(snap.disks) { d in
                            diskRow(d)
                        }
                    }
                    .padding(.top, 8)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func diskRow(_ d: Disk) -> some View {
        Button { detail = d } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(d.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Text(d.mount)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("R \(Fmt.rate(d.readBps)) · W \(Fmt.rate(d.writeBps))")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Meter(
                        value: d.percent,
                        height: 5,
                        from: Palette.cpuDeep,
                        to: d.percent > 90 ? Palette.danger : Palette.cpu,
                        flat: d.percent > 90
                    )
                    Text("\(Fmt.bytes(Double(d.used))) / \(Fmt.bytes(Double(d.total), digits: 0))")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 112, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    if let h = model.healthRow(for: d.mount) {
                        DiskStatusChip(health: h)
                    } else {
                        Text(model.healthLoading ? i18n.t("dash.diskLoading") : i18n.t("dash.diskNoHealth"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    Text(i18n.t("dash.diskMore"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.028))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(i18n.t("dash.diskOpen"))
    }

    // MARK: 网络

    private func netCard(_ snap: Snapshot) -> some View {
        let rx = Fmt.splitRate(snap.net.rxBps)
        let tx = Fmt.splitRate(snap.net.txBps)

        return CardBox {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(i18n.t("card.net"))

                HStack(alignment: .top, spacing: 16) {
                    rateBlock("DOWN", rx, Palette.rx)
                    rateBlock("UP", tx, Palette.tx)
                }
                .padding(.top, 8)

                Sparkline(values: model.rxSeries, color: Palette.rx, floor: 64 * 1024)
                    .frame(height: 28)
                    .padding(.top, 6)

                Spacer(minLength: 6)

                VStack(spacing: 4) {
                    KVRow(key: i18n.t("dash.totalRx"), value: Fmt.bytes(Double(snap.net.totalRx)))
                    KVRow(key: i18n.t("dash.totalTx"), value: Fmt.bytes(Double(snap.net.totalTx)))
                }
            }
        }
    }

    private func rateBlock(_ label: String, _ v: (value: String, unit: String), _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(v.unit.isEmpty ? "/s" : "\(v.unit)/s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 进程

    private func procCard(_ snap: Snapshot) -> some View {
        let rows = sortedProcs(snap)

        return CardBox(padding: 12) {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(i18n.t("card.proc")) {
                    HStack(spacing: 8) {
                        SegmentedTabs(
                            titles: [i18n.t("dash.byCpu"), i18n.t("dash.byMem")],
                            index: procSort == .cpu ? 0 : 1
                        ) { idx in
                            procSort = idx == 0 ? .cpu : .mem
                        }
                        Tag(text: i18n.t("dash.topN", ["n": "20"]))
                    }
                }

                // 表头固定，行可滚。20 行按 22pt 是 440pt，主面板留不出这么多，
                // 所以滚动是必需的——但表头必须留在上面，否则滚到底就不知道
                // 哪一列是 CPU 哪一列是内存了。
                HStack(spacing: 8) {
                    Text(i18n.t("dash.pid"))
                        .frame(width: 54, alignment: .leading)
                    Text(i18n.t("dash.procName"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("CPU")
                        .frame(width: 68, alignment: .trailing)
                    Text(i18n.t("dash.memCol"))
                        .frame(width: 84, alignment: .trailing)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.horizontal, 4)

                Hairline().padding(.top, 4)

                if rows.isEmpty {
                    Text(i18n.t("dash.collecting"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { p in
                                procRow(p)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            }
        }
    }

    private func sortedProcs(_ snap: Snapshot) -> [Proc] {
        let sorted = snap.procs.sorted {
            procSort == .cpu ? $0.cpu > $1.cpu : $0.mem > $1.mem
        }
        return Array(sorted.prefix(20))
    }

    private func procRow(_ p: Proc) -> some View {
        HStack(spacing: 8) {
            Text("\(p.pid)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(p.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", p.cpu))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Fmt.loadColor(p.cpu))
                .frame(width: 68, alignment: .trailing)
            Text(Fmt.bytes(Double(p.mem), digits: 0))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: 21)
    }
}
