import AppKit
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
    @State private var failure: EngineError?

    private static let sizes: [UInt64] = [256, 512, 1024]

    private var capacityPct: Double {
        disk.total > 0 ? Double(disk.used) / Double(disk.total) * 100 : 0
    }

    /// 测速只写一份 `size` 的文件，顺序读和两项随机测试都复用它
    /// （随机测试不另写数据，见 `core/src/bench.rs`）。留 200 MB 给文件系统开销。
    private var needBytes: UInt64 {
        size * 1024 * 1024 + 200 * 1024 * 1024
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

            // 上面这块钉住：身份行、四个数字块、实时曲线。滚到 SMART 第 30 行时
            // 「磨损 0%」还得在视野里——那是打开这一页唯一必看的东西。
            if let health {
                VStack(alignment: .leading, spacing: 14) {
                    metaLine(health)
                    statRow(health)
                    ioSection
                }
                .padding(.top, 14)

                // 滚动区和上面钉住的部分之间要有一条线：没有它，内容滑到边界上
                // 会像是被硬切掉的。
                Hairline()
            }

            // 测速结果和 SMART 属性表一起滚。
            //
            // 原来是「整页钉死 700、只有属性表内部滚」。测速加上随机读写那一行之后
            // 总高度超了，而且超出的部分**是从顶部裁掉的**：标题和「关闭」按钮
            // 直接看不见。与其每加一项就去抠十几点高度（SMART 表 200→150、
            // 曲线 34→30……抠到最后处处是巧合），不如让下半页自己滚。
            //
            // 顺手把属性表内部的 ScrollView 也去掉了：嵌在页面滚动里的滚动区，
            // 滚轮到底该滚谁全看指针在哪，是比多滚两屏更糟的体验。
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    benchSection

                    if let health {
                        smartSection(health)
                    } else {
                        Text(i18n.t("dd.smartLoading"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)

            Hairline()
            footer
        }
        .padding(18)
        .frame(width: 720, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        // 上次测速的结果是存在盘上的（`bench.json`），打开这一页先捞出来。
        // 一次 512 MB 的测速要写几百兆，关掉窗口就没了太可惜。
        .task {
            if bench == nil {
                bench = engine.benchLast(mount: disk.mount)
            }
        }
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
            sectionTitle(
                i18n.t("dd.bench"),
                tag: bench.map { i18n.t("dd.benchAt", ["v": benchTime($0.at)]) }
            )

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
            if let f = failure {
                // 没权限和别的失败分开说：前者能引导用户去解决，后者只能报细节。
                note(benchMessage(f), color: Palette.warn)
                if f.code == "denied" {
                    MiniButton(title: i18n.t("dd.benchOpenSettings")) {
                        openPrivacySettings()
                    }
                    .padding(.top, 2)
                }
            }

            if let b = bench {
                // 一行四个，不是两行两列。
                //
                // 两行两列读起来确实更清楚（顺序 / 随机各一行），但这一页的高度是
                // 定死的 700：多一行 76 的数字块，SMART 表就得让出 50、页脚还是会
                // 被挤出窗口。而没跑测速时（打开 sheet 最常见的样子）那一行是空的，
                // 整页会空出一大片。
                //
                // 一行的代价只是「顺序和随机看起来并列」，用两件事补回来：
                // 标签里写明 `4K`，随机那两格的副标题是折算带宽（`38.2 MB/s`）
                // 而不是同样的 MB/s 大数字——不会有人把 9,775 和 2,798 直接比大小。
                HStack(spacing: 10) {
                    StatTile(
                        key: i18n.t("dd.seqWrite"),
                        value: String(format: "%.0f", b.writeMbps),
                        note: seqNote(b.sizeMb, b.writeMs),
                        valueColor: Palette.tx,
                        unit: "MB/s"
                    )
                    StatTile(
                        key: i18n.t("dd.seqRead"),
                        value: String(format: "%.0f", b.readMbps),
                        note: seqNote(b.sizeMb, b.readMs),
                        valueColor: Palette.rx,
                        unit: "MB/s"
                    )
                    StatTile(
                        key: i18n.t("dd.randWrite"),
                        value: Fmt.iops(b.randWriteIops),
                        note: randNote(b.randWriteMbps, b.randWriteMs),
                        valueColor: Palette.tx,
                        unit: "IOPS"
                    )
                    StatTile(
                        key: i18n.t("dd.randRead"),
                        value: Fmt.iops(b.randReadIops),
                        note: randNote(b.randReadMbps, b.randReadMs),
                        valueColor: Palette.rx,
                        unit: "IOPS"
                    )
                }
                note(i18n.t("dd.randBlock", ["v": "\(b.randBlockKb)"]))
                note(i18n.t("dd.benchFile", ["v": b.path]) + (b.note.map { " · \(dirNote($0))" } ?? ""))
            }
        }
    }

    private func seqNote(_ mb: UInt64, _ ms: UInt64) -> String {
        "\(mb) MB / \(String(format: "%.2f", Double(ms) / 1000)) s"
    }

    /// 随机那两格的副标题：折算带宽 + 时长。
    ///
    /// 带宽一定要给——「12 116 IOPS」对不熟悉这一行的人是空的，换成
    /// 「47.3 MB/s」立刻就知道这一项能干什么。时长也一定要给，它是这个数字
    /// 有多稳的前提（2.5 秒是我们在 NVMe 和机械盘之间取的折中）。
    private func randNote(_ mbps: Double, _ ms: UInt64) -> String {
        "\(String(format: "%.1f", mbps)) MB/s · \(String(format: "%.1f", Double(ms) / 1000)) s"
    }

    /// 测速文件放在哪的说明。core 只回一个码，文案在这边。
    private func dirNote(_ code: String) -> String {
        code == "cache" ? i18n.t("dd.benchCacheDir") : code
    }

    /// 「上次测于 …」。今天只给时刻，更早的带上日期。
    ///
    /// 走 `L10n.clock` 而不是自己造一个 `DateFormatter`：那个已经按界面语言
    /// 定好了 `HH:mm`，跟历史记录里的时间轴是同一套格式。用系统 locale 的话，
    /// 中文界面会冒出「10:34 PM」。
    private func benchTime(_ secs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        return i18n.clock(secs, withDate: !Calendar.current.isDateInToday(date))
    }

    /// 失败原因：能引导用户解决的（没权限 / 只读）给一句话说清怎么办，
    /// 其余的把 core 给的技术细节原样摆出来——总比只写「失败」强。
    private func benchMessage(_ e: EngineError) -> String {
        switch e.code {
        case "denied": return i18n.t("dd.benchDenied")
        case "readonly": return i18n.t("dd.benchReadonly")
        case "nospace": return i18n.t("dd.benchNoSpace", ["v": Fmt.bytes(Double(size * 1024 * 1024))])
        default: return i18n.t("dd.benchFailed", ["v": e.message])
        }
    }

    /// 打开「隐私与安全性 → 文件与文件夹」。macOS 15 上这个锚点直接落在那一页。
    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }

    private func startBench() {
        guard !benching else { return }
        benching = true
        failure = nil
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
            case .failure(let e): failure = e
            }
        }
    }

    // MARK: SMART

    private func smartSection(_ h: DiskHealth) -> some View {
        // 表格不再自己夹高度：外层页面已经在滚了，属性条数从 8 到 40 都让它自然
        // 撑开，40 条就滚 40 条——而不是像以前那样在一个 200 高的小窗里翻。
        VStack(alignment: .leading, spacing: 6) {
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

                LazyVStack(spacing: 0) {
                    ForEach(h.attrs) { a in
                        attrRow(a)
                    }
                }
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

            glossary(h)
        }
    }

    /// 表下面那几行解释。
    ///
    /// 「可用备用块 100%｜备注：低于 99% 会报警」——普通用户读到这儿还是懵的：
    /// 备用块是什么？阈值是及格线还是剩余量？备注列只有 210pt，塞不下完整句子，
    /// 所以在表下面用整行宽度讲清最容易被误读的三行。
    ///
    /// 只解释**这张表里真的有的行**：机械盘走的是 ATA 属性表，里面没有
    /// 「可用备用块」，给它配一句解释反而添乱。判断靠 `key`，不靠本地化之后的名字。
    ///
    /// 一行都没有就整块不出现——比如磁盘映像这种压根不报 SMART 的卷，
    /// 留着个光秃秃的「怎么读这张表」标题比不放还怪。
    @ViewBuilder
    private func glossary(_ h: DiskHealth) -> some View {
        let keys = Set(h.attrs.map(\.key))
        let entries = [
            ("wear", "dd.glossWearTerm", "dd.glossWear"),
            ("spare", "dd.glossSpareTerm", "dd.glossSpare"),
            ("media", "dd.glossMediaTerm", "dd.glossMedia"),
        ].filter { keys.contains($0.0) }

        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(i18n.t("dd.glossTitle"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.bottom, 1)

                ForEach(entries, id: \.0) { e in
                    // 术语用 semibold、解释用常规字重，靠字重而不是颜色区分——
                    // 颜色一多，这一块就比上面的表还热闹。
                    (Text(i18n.t(e.1)).font(.system(size: 10, weight: .semibold))
                        + Text(" · " + i18n.t(e.2)).font(.system(size: 10)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 10)
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
        // 「介质错误、备用块这类已经发生的计数更值得关注」原来接在这一行后面，
        // 现在表下面有了逐条解释，那句话就只是重复；而且它一长，法语的页脚
        // 会被 `lineLimit(1)` 截掉半句。
        HStack(spacing: 4) {
            Text(i18n.t("dd.footSource", ["v": health?.source ?? "—"]))
            Text("·")
            Text(i18n.t("dd.footWarnLead"))
            Text(i18n.t("dd.footWarnBold"))
                .fontWeight(.semibold)
            Spacer()
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Ink.tertiary)
        .lineLimit(1)
        .padding(.top, 10)
    }
}
