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
        // 标题栏透明、标题文字不画（大标题在内容里），内容延伸到标题栏底下。
        // 具体做了哪三件事见 WindowChrome.swift——光设 titleVisibility 是没用的，
        // 那条分隔线来自标题栏自己，不是标题文字。
        title = "EZPcMonitor"
        useUnifiedChrome()
        // 背景由内容里的 BackdropLayer 画，窗口自己必须是透的，
        // 否则「材质 / 半透明纯色 / 图片」都会被窗口底色盖住。
        isOpaque = false
        backgroundColor = .clear
        minSize = NSSize(width: 880, height: 660)
        // 必须显式关掉。程序化创建的 NSWindow 默认 isReleasedWhenClosed = true，
        // AppKit 会在关窗时自己 release 一次；而 DashboardController 在
        // windowWillClose 里又把 window 置 nil，等于第二次 release。
        // 多出来的那次不会当场炸，而是等当前 runloop 回调的自动释放池排空时，
        // 对着已经释放的对象再发一次消息——EXC_BAD_ACCESS，栈里只有
        // objc_msgSend ← AutoreleasePoolPage::releaseUntil，看不出是谁。
        isReleasedWhenClosed = false
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

    /// 面板开/关时通知外面，用来收起和还原悬浮窗。
    var onVisibilityChanged: (Bool) -> Void = { _ in }

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
        guard let w = window else { return }
        // 托盘菜单点「打开主面板」时窗口可能只是被最小化了，
        // makeKeyAndOrderFront 不会把它从 Dock 里捞出来
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onVisibilityChanged(true)
        // 主面板开着才需要进程列表；关掉就停采，省一次全表遍历
        model.engine.setWantProcs(true)
        model.refreshNow()
        model.startHealthPolling()
    }

    /// 从托盘菜单关掉主面板。走 `performClose` 而不是 `orderOut`：
    /// 只有真的关窗才会触发 `windowWillClose`，那里的收尾（停采、还原悬浮窗）不能跳过。
    func close() {
        window?.performClose(nil)
    }

    /// 关窗就把窗口整个放掉，顺便停掉进程采集。
    ///
    /// 不缓存窗口是有意的：面板一关，`NSHostingView` 里的表格、进度条全都不该
    /// 继续占内存——这个分支的全部意义就是「不常驻」。
    func windowWillClose(_ notification: Notification) {
        model.engine.setWantProcs(false)
        model.stopHealthPolling()
        window = nil
        onVisibilityChanged(false)
    }
}

// MARK: - 主面板

private enum ProcSort: String {
    case cpu, mem
}

/// 磁盘列表内容的底边（global 坐标）。
private struct DiskContentBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 磁盘列表视口的底边（global 坐标）。两者相减就是「下面还剩多少没露出来」。
private struct DiskViewportBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 读出窗口标题栏的高度（内容视图的安全区顶部内边距）。
///
/// 背景要铺满整个窗口（含标题栏那 28pt），这就要求 `.ignoresSafeArea()` 加在
/// **最外层**；可一旦忽略安全区，SwiftUI 里就再也读不到 `safeAreaInsets` 了，
/// 而内容又不能真的顶到红绿灯底下。所以只能绕到 AppKit 那边问一句：
/// `contentView.safeAreaInsets.top` 是窗口自己的属性，不受 SwiftUI 忽略安全区影响。
///
/// 不写死 28 是因为全屏时它会变成 0，写死的话全屏下顶部会多出一条空白。
private struct TitleBarInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { read(v) }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { read(v) }
    }

    private func read(_ v: NSView) {
        let top = v.window?.contentView?.safeAreaInsets.top ?? 0
        // 差值判断是必需的：写回 inset 会再触发一次 updateNSView，
        // 不设阈值就是无限循环。
        if abs(top - inset) > 0.5 { inset = top }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    @State private var detail: Disk?
    @State private var procSort: ProcSort = .cpu

    /// 标题栏高度。初值给标准值，探针量到真实值后会覆盖（见 TitleBarInsetReader）。
    @State private var titleBarInset: CGFloat = 28

    /// 磁盘列表的滚动位置。两个 global 底边相减就知道下面还有没有东西，
    /// 不用具名坐标空间（`coordinateSpace(name:)` 在 macOS 14 已经换了写法）。
    @State private var diskContentBottom: CGFloat = 0
    @State private var diskViewportBottom: CGFloat = 0

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
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(.horizontal, 18)
        // 标题栏那 28pt 由 ignoresSafeArea 交给背景了，内容自己补回来
        .padding(.top, 14 + titleBarInset)
        .padding(.bottom, 16)
        .frame(minWidth: 880, minHeight: 660)
        // 卡片改用磨砂（见 `CardBox`）。背景现在是**真透明**的，卡片如果还是
        // 5.5% 的白，整窗就是一张平的玻璃，看不出哪里是区块。只在主面板开：
        // 历史窗口是 opaque 的，磨砂在那儿只是白花内存。
        .environment(\.cardFrost, true)
        .background {
            BackdropLayer(backdrop: model.backdrop, image: model.backdropImage)
                .background(TitleBarInsetReader(inset: $titleBarInset))
                // 圆角裁在背景自己身上。窗口一旦设成 isOpaque = false，系统就不再
                // 替我们切圆角了（不透明窗口的圆角是窗口自己画的），只能自己裁。
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        // **必须加在最外层**。放进 `.background` 里是没用的——试过
        // `.background { Color.red.ignoresSafeArea() }`，红也一样被截在标题栏
        // 下面：`.background` 的内容拿到的安全区是「内容视图的」，已经扣掉了
        // 标题栏，没有可扩展的空间。加在根上，整个视图（含背景）才真正铺满
        // 整窗，红绿灯那条才不会透出桌面。
        .ignoresSafeArea()
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
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let snap {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snap.cpu.brand.isEmpty ? i18n.t("dash.cpuUnknown") : snap.cpu.brand)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Text(cpuDetail(snap))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                    Text(i18n.t("dash.load", ["v": snap.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")]))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                MiniButton(title: i18n.t("dash.history"), action: onOpenHistory)
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
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
                        .foregroundStyle(Ink.secondary)
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
                        .foregroundStyle(primary.map { Fmt.tempColor($0.value) } ?? Ink.secondary)
                    Text("°C")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                }
                .padding(.top, 4)

                Spacer(minLength: 4)

                VStack(spacing: 5) {
                    ForEach(snap.temps.prefix(4)) { t in
                        HStack(spacing: 8) {
                            Text(t.label)
                                .font(.system(size: 10))
                                .foregroundStyle(t.primary ? Color.primary : Ink.secondary)
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
                                .foregroundStyle(Ink.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                    if snap.temps.isEmpty {
                        Text(i18n.t("dash.noTemp"))
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.tertiary)
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
                            .foregroundStyle(Ink.secondary)
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
                            .foregroundStyle(Ink.secondary)
                        Text(i18n.t("dash.gpuPlan"))
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: 磁盘

    /// 底边渐隐的高度。约等于一行文字，够让人看出「这儿被淡掉了」，
    /// 又不至于把最后一行盖没。
    private static let diskFade: CGFloat = 22

    /// 下面还有没露出来的盘吗——只有「内容比视口高」且「没滚到底」时为真。
    ///
    /// 内容装得下时 `remaining` 是负的，滚到底时也回到 0，两种情况都不该有渐隐。
    private var showsMoreDisks: Bool {
        diskContentBottom - diskViewportBottom > 0.5
    }

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
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                }

                diskList(snap)
            }
        }
    }

    /// 磁盘列表。盘多了在这块 178pt 高的卡里滚。
    ///
    /// 单独拆出来不只是为了好读：整张卡的类型一复杂，编译器就会
    /// 「unable to type-check this expression in reasonable time」。
    private func diskList(_ snap: Snapshot) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(snap.disks) { d in
                    diskRow(d)
                }
            }
            .padding(.top, 8)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: DiskContentBottomKey.self,
                        value: g.frame(in: .global).maxY
                    )
                }
            )
        }
        // 平时不画滚动条，滚的时候才浮出来——一条常驻的滚动条在 178pt
        // 高的卡里比内容还抢眼
        .scrollIndicators(.automatic)
        .background(
            GeometryReader { g in
                Color.clear.preference(
                    key: DiskViewportBottomKey.self,
                    value: g.frame(in: .global).maxY
                )
            }
        )
        .onPreferenceChange(DiskContentBottomKey.self) { diskContentBottom = $0 }
        .onPreferenceChange(DiskViewportBottomKey.self) { diskViewportBottom = $0 }
        // 底边渐隐。用 mask 而不是盖一层渐变：卡片本身是半透明的，
        // 任何实色渐变都会把背后的桌面/照片染脏，只有把内容自己淡出去才对。
        .mask { diskMask }
        .animation(.easeOut(duration: 0.16), value: showsMoreDisks)
    }

    private var diskMask: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: showsMoreDisks ? Self.diskFade : 0)
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
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("R \(Fmt.rate(d.readBps)) · W \(Fmt.rate(d.writeBps))")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundStyle(Ink.secondary)
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
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .frame(width: 112, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    if let h = model.healthRow(for: d.mount) {
                        DiskStatusChip(health: h)
                    } else {
                        Text(model.healthLoading ? i18n.t("dash.diskLoading") : i18n.t("dash.diskNoHealth"))
                            .font(.system(size: 10))
                            .foregroundStyle(Ink.tertiary)
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
                .foregroundStyle(Ink.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(v.value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(v.unit.isEmpty ? "/s" : "\(v.unit)/s")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Ink.secondary)
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
                .foregroundStyle(Ink.tertiary)
                .padding(.top, 8)
                .padding(.horizontal, 4)

                Hairline().padding(.top, 4)

                if rows.isEmpty {
                    Text(i18n.t("dash.collecting"))
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
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
                .foregroundStyle(Ink.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(p.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", p.cpu))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Fmt.loadTint(p.cpu) ?? Color.primary)
                .frame(width: 68, alignment: .trailing)
            Text(Fmt.bytes(Double(p.mem), digits: 0))
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: 21)
    }
}
