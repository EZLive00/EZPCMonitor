import SwiftUI

/// 磁盘详情。
///
/// 一级页面只留容量、实时读写和一行状态，所有「复杂」的东西都收在这里：
/// 身份信息、磨损与异常计数、完整 SMART 属性表、实时读写曲线、顺序读写测速。
///
/// 做成主面板上的 sheet 而不是独立窗口：它跟某一块盘强绑定，独立窗口会出现
/// 「盘已经拔了窗口还开着」的状态，sheet 天然跟着父窗口走。
struct DiskDetailView: View {
    let disk: Disk
    let health: DiskHealth?
    let series: [Sample]
    let refreshing: Bool
    let engine: CoreEngine
    var onRefresh: () -> Void = {}

    @EnvironmentObject private var i18n: L10n
    @Environment(\.dismiss) private var dismiss

    @State private var size: UInt64 = 512
    @State private var bench: BenchResult?
    @State private var benching = false
    @State private var error: String?

    private static let sizes: [UInt64] = [256, 512, 1024]

    private var capacityPct: Double {
        disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0
    }

    /// 测速要写 size*2 出去（含文件系统开销），空间不够就别让用户点了。
    private var needBytes: UInt64 {
        size * 1024 * 1024 * 2 + 200 * 1024 * 1024
    }

    private var enoughSpace: Bool { disk.free > needBytes }

    private var ioRead: [Double] { series.map(\.diskRead) }
    private var ioWrite: [Double] { series.map(\.diskWrite) }

    /// 两条曲线共用一个上界，否则「读 200MB/s、写 2MB/s」会被各自归一成
    /// 两条一样高的山，看图的人会以为读写差不多。
    private var ioMax: Double {
        max(64 * 1024, (ioRead + ioWrite).max() ?? 0) * 1.18
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.top, 10)

            // 只有 SMART 属性表滚动，上面的身份行 / 数字块 / 曲线 / 测速固定住。
            // 整页塞进 ScrollView 的话，滚到属性表第 12 行时「磨损 0%」这种
            // 一眼就该看到的结论会滚出视野。
            VStack(alignment: .leading, spacing: 14) {
                if let health {
                    metaLine(health)
                    statRow(health)
                    ioSection
                } else {
                    Text(i18n.t("dd.smartLoading"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                benchSection

                if let health {
                    smartSection(health)
                }
            }
            .padding(.vertical, 14)
            .frame(maxHeight: .infinity, alignment: .top)

            Hairline()
            footer
        }
        .padding(18)
        .frame(width: 720, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头部

    private var header: some View {
        SheetHeader(
            disk.name,
            subtitle: "\(disk.mount) · \(disk.fs.isEmpty ? i18n.t("common.unknownFs") : disk.fs) · \(Fmt.bytes(Double(disk.total), digits: 0))"
        ) {
            MiniButton(title: refreshing ? i18n.t("common.detecting") : i18n.t("common.redetect"), enabled: !refreshing) {
                onRefresh()
            }
            MiniButton(title: i18n.t("common.closeEsc")) { dismiss() }
        }
    }

    // MARK: 身份

    private func metaLine(_ h: DiskHealth) -> some View {
        var bits: [String] = []
        if !h.device.isEmpty { bits.append(h.device) }
        if !h.bus.isEmpty { bits.append(h.bus) }
        if let ssd = h.solidState { bits.append(i18n.t(ssd ? "dd.solid" : "dd.hdd")) }
        if !h.serial.isEmpty { bits.append("SN \(h.serial)") }
        if !h.firmware.isEmpty { bits.append(i18n.t("dd.firmware", ["v": h.firmware])) }

        return Text(bits.joined(separator: " · "))
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    // MARK: 四个数字块

    private func statRow(_ h: DiskHealth) -> some View {
        HStack(spacing: 10) {
            StatTile(
                key: i18n.t("dd.wear"),
                value: h.lifeUsed.map { "\(Int($0.rounded()))%" } ?? "—",
                note: h.lifeLeft.map { i18n.t("dd.left", ["v": "\(Int($0.rounded()))"]) } ?? i18n.t("dd.wearNote"),
                valueColor: h.lifeUsed.map { $0 > 80 ? Palette.danger : ($0 > 60 ? Palette.warn : Color.primary) } ?? .primary
            )
            StatTile(
                key: i18n.t("dd.temp"),
                value: h.temperature.map { "\(Int($0.rounded()))°" } ?? "—",
                note: i18n.t("dd.tempNote"),
                valueColor: h.temperature.map(Fmt.tempColor) ?? .primary
            )
            StatTile(
                key: i18n.t("dd.usage"),
                value: "\(Int(capacityPct.rounded()))%",
                note: i18n.t("dd.usedNote", ["v": Fmt.bytes(Double(disk.used))])
            )
            StatTile(
                key: i18n.t("dd.media"),
                value: h.mediaErrors.map { "\($0)" } ?? "—",
                note: i18n.t("dd.mediaNote"),
                valueColor: (h.mediaErrors ?? 0) > 0 ? Palette.warn : .primary
            )
        }
    }

    // MARK: 实时读写

    private var ioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(
                i18n.t("dd.io"),
                tag: "\(i18n.t("dash.read", ["v": Fmt.rate(disk.readBps)])) · \(i18n.t("dash.write", ["v": Fmt.rate(disk.writeBps)]))"
            )

            // 上下两条而不是叠在一张图里：读写量级经常差两个数量级，
            // 叠在一起小的那条会被压成贴着底边的直线。
            VStack(spacing: 6) {
                ioSpark(ioRead, color: Palette.rx, label: "R")
                ioSpark(ioWrite, color: Palette.tx, label: "W")
            }
        }
    }

    private func ioSpark(_ values: [Double], color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 10)
            Sparkline(values: values, color: color, floor: ioMax, capacity: max(2, values.count))
                .frame(height: 34)
        }
    }

    // MARK: 测速

    private var benchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(i18n.t("dd.bench"))

            HStack(spacing: 6) {
                ForEach(Self.sizes, id: \.self) { s in
                    Chip(
                        title: "\(s) MB",
                        on: size == s,
                        enabled: !benching
                    ) { size = s }
                }
                PrimaryButton(
                    title: benching ? i18n.t("common.testing") : i18n.t("common.startBench"),
                    enabled: !benching && enoughSpace
                ) {
                    startBench()
                }
                .padding(.leading, 6)
            }

            if !enoughSpace {
                note(i18n.t("dd.benchNeed", ["v": Fmt.bytes(Double(needBytes), digits: 0)]))
            }
            if let error {
                note(error, color: Palette.warn)
            }

            if let b = bench {
                HStack(spacing: 10) {
                    StatTile(
                        key: i18n.t("dd.seqWrite"),
                        value: String(format: "%.0f", b.writeMbps),
                        note: "\(b.sizeMb) MB / \(String(format: "%.2f", Double(b.writeMs) / 1000)) s",
                        valueColor: Palette.tx,
                        unit: "MB/s"
                    )
                    StatTile(
                        key: i18n.t("dd.seqRead"),
                        value: String(format: "%.0f", b.readMbps),
                        note: "\(b.sizeMb) MB / \(String(format: "%.2f", Double(b.readMs) / 1000)) s",
                        valueColor: Palette.rx,
                        unit: "MB/s"
                    )
                }
                note(i18n.t("dd.benchFile", ["v": b.path]) + (b.note.map { " · \($0)" } ?? ""))
            }
        }
    }

    private func startBench() {
        guard !benching else { return }
        benching = true
        error = nil
        let mount = disk.mount
        let sizeMb = size
        let engine = self.engine
        Task { @MainActor in
            // 写 1GB 出去，几秒到几十秒都有可能，必须离开主线程
            let r = await Task.detached(priority: .userInitiated) {
                engine.bench(mount: mount, sizeMb: sizeMb)
            }.value
            benching = false
            switch r {
            case .success(let b): bench = b
            case .failure(let e): error = e.message
            }
        }
    }

    // MARK: SMART

    private func smartSection(_ h: DiskHealth) -> some View {
        // 表格高度算出来而不是靠弹性布局：不同盘的属性条数从 8 到 40 都有，
        // 让 ScrollView 自己决定高度会让整张 sheet 的高度跟着盘变，
        // 每次打开都跳一下。这里夹到 240，多出来的部分滚动看。
        let tableHeight = min(200, CGFloat(h.attrs.count) * 21 + 26)

        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle(i18n.t("dd.smart"), tag: i18n.tn("p.attrs", Double(h.attrs.count)))

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(i18n.t("dd.colAttr"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(i18n.t("dd.colValue"))
                        .frame(width: 150, alignment: .leading)
                    Text(i18n.t("dd.colNote"))
                        .frame(width: 210, alignment: .leading)
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .padding(.vertical, 4)

                Hairline()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(h.attrs) { a in
                            attrRow(a)
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: tableHeight)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )

            if let n = h.note, !n.isEmpty {
                note(n)
            }
        }
    }

    private func attrRow(_ a: SmartAttr) -> some View {
        HStack(spacing: 8) {
            Text(a.name)
                .font(.system(size: 10.5))
                .foregroundStyle(a.critical ? Palette.warn : Color.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(a.value.isEmpty ? "—" : a.value)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(a.critical ? Palette.warn : Color.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(a.extra)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 210, alignment: .leading)
        }
        .padding(.vertical, 3.5)
        .background(a.critical ? Palette.warn.opacity(0.07) : Color.clear)
    }

    // MARK: 小工具

    private func sectionTitle(_ title: String, tag: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            if let tag {
                Tag(text: tag)
            }
            Spacer()
        }
    }

    private func note(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(i18n.t("dd.footSource", ["v": health?.source ?? "—"]))
            Text("·")
            Text(i18n.t("dd.footWarnLead"))
            Text(i18n.t("dd.footWarnBold"))
                .fontWeight(.semibold)
            Text(i18n.t("dd.footWarn"))
            Spacer()
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Ink.tertiary)
        .lineLimit(1)
        .padding(.top, 10)
    }
}
