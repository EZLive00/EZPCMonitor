import AppKit
import SwiftUI

// MARK: - 输入

struct ReportInput {
    let host: String
    let os: String
    let rangeLabel: String
    let points: [HistoryPoint]
    let procs: [Leader]
    let now: UInt64
    let withDate: Bool
}

// MARK: - 配色

/// 报告图不跟随 `NSApp.appearance` 的默认语义色，而是按渲染那一刻的外观
/// 取一组**字面色**。
///
/// 原因很实在：`ImageRenderer` 把一个视图画进位图时，`Color.primary` 这类
/// 动态色要靠环境里的 appearance 解析，而位图没有 appearance——解析错了
/// 就会出现「浅色底上画白字」这种一张全白的图。写死字面值最省心，
/// 顺便也让导出的图跟屏幕上看到的配色一致。
private struct ReportTheme {
    let bg: Color
    let text: Color
    let muted: Color
    let dim: Color
    let line: Color
    let fill: Color
    let accent: Color

    static func current() -> ReportTheme {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark
            ? ReportTheme(
                bg: Color(hex: 0x0d1117),
                text: Color(hex: 0xe6edf3),
                muted: Color(hex: 0x9aa7b4),
                dim: Color(hex: 0x6b7785),
                line: Color.white.opacity(0.09),
                fill: Color.white.opacity(0.045),
                accent: Color(hex: 0x22d3ee)
            )
            : ReportTheme(
                bg: Color(hex: 0xffffff),
                text: Color(hex: 0x11161c),
                muted: Color(hex: 0x5b6672),
                dim: Color(hex: 0x8a949e),
                line: Color.black.opacity(0.09),
                fill: Color.black.opacity(0.035),
                accent: Color(hex: 0x0891b2)
            )
    }

    /// 指标色跟界面里的 `Palette` 同源，只是同样要落成字面值。
    func color(_ m: Metric) -> Color {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch m {
        case .cpu: return Color(hex: dark ? 0x22d3ee : 0x0891b2)
        case .mem: return Color(hex: dark ? 0xa78bfa : 0x7c3aed)
        case .temp: return Color(hex: dark ? 0xfbbf24 : 0xd97706)
        case .rx: return Color(hex: dark ? 0x38bdf8 : 0x0284c7)
        case .tx: return Color(hex: dark ? 0xa78bfa : 0x7c3aed)
        case .disk: return Color(hex: dark ? 0x34d399 : 0x059669)
        case .gpu: return Color(hex: dark ? 0xc084fc : 0x9333ea)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}

// MARK: - 页面

private struct ReportPage: View {
    let input: ReportInput
    let theme: ReportTheme
    let i18n: L10n

    private let w: CGFloat = 1080
    private let pad: CGFloat = 56
    private var content: CGFloat { w - pad * 2 }

    private var cpuBuckets: [Bucket] { SeriesLogic.buckets(input.points, .cpu, count: 400) }
    private var cpuPeak: Double { cpuBuckets.map(\.max).max() ?? 0 }

    private var peakPoint: HistoryPoint? {
        input.points.max { $0.cpu < $1.cpu }
    }

    private var topProc: Leader? {
        input.procs.max { $0.cpu.mean < $1.cpu.mean }
    }

    private var top5: [Leader] {
        Array(input.procs.sorted { $0.cpu.mean > $1.cpu.mean }.prefix(5))
    }

    /// GPU 一条线都没采到就不画——一条贴着底边的直线比没有图更让人困惑。
    private var metrics: [Metric] {
        let all = Metric.charted.filter { m in
            m != .gpu || input.points.contains { $0.gpu > 0 }
        }
        // 两列排布，奇数个会留一个空格，干脆去掉最后一个
        return all.count % 2 == 1 ? Array(all.dropLast()) : all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            strip.padding(.top, 22)
            grid.padding(.top, 30)
            procsSection.padding(.top, 26)
            footer.padding(.top, 26)
        }
        .padding(pad)
        .frame(width: w, alignment: .leading)
        .background(theme.bg)
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(i18n.t("rep.title"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text(input.rangeLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            Text("\(input.host) · \(input.os)")
                .font(.system(size: 14))
                .foregroundStyle(theme.dim)
        }
    }

    // MARK: 结论条

    private var strip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(i18n.t("rep.peak"))
                    .foregroundStyle(theme.text)
                Text(i18n.t("hist.mCpu"))
                    .foregroundStyle(theme.text)
                Text("\(Int(cpuPeak.rounded()))%")
                    .foregroundStyle(theme.text)
                if let p = peakPoint {
                    Text("· \(i18n.clock(p.t, withDate: input.withDate))")
                        .foregroundStyle(theme.muted)
                }
            }
            .font(.system(size: 18, weight: .bold))

            if let top = topProc {
                Text("\(clip(top.name, 34)) · \(i18n.t("hist.colMean")) \(LeadersLogic.format(.cpu, .mean, top.cpu.mean)) · \(i18n.t("hist.colPeak")) \(LeadersLogic.format(.cpu, .peak, top.cpu.peak))")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.muted)
            } else {
                Text(i18n.t("rep.noProc"))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.muted)
            }
        }
        .padding(22)
        .frame(width: content, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.fill)
        )
    }

    // MARK: 曲线

    private var grid: some View {
        let gap: CGFloat = 24
        let cw = (content - gap) / 2
        let rows = stride(from: 0, to: metrics.count, by: 2).map { i in
            Array(metrics[i..<min(i + 2, metrics.count)])
        }
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, pair in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(pair) { m in
                        chartCard(m, width: cw)
                    }
                    if pair.count == 1 {
                        Color.clear.frame(width: cw, height: 1)
                    }
                }
            }
        }
    }

    private func chartCard(_ m: Metric, width: CGFloat) -> some View {
        let buckets = SeriesLogic.buckets(input.points, m, count: 160)
        let peak = buckets.map(\.max).max() ?? 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(i18n.t(m.titleKey))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.muted)
                Spacer()
                Text("\(i18n.t("rep.peak")) \(m.format(peak))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.dim)
            }
            ReportSpark(values: buckets.map(\.max), color: theme.color(m), line: theme.line, height: 150)
                .padding(.top, 8)
        }
        .frame(width: width, alignment: .leading)
    }

    // MARK: 程序

    private var procsSection: some View {
        let barMax = max(1, top5.map(\.cpu.peak).max() ?? 0)

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(i18n.t("rep.top"))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.muted)
                Spacer()
                Text(i18n.t("rep.topHint"))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.dim)
            }

            if top5.isEmpty {
                Text(i18n.t("rep.noProc"))
                    .font(.system(size: 14))
                    .foregroundStyle(theme.dim)
                    .padding(.top, 18)
            }

            ForEach(Array(top5.enumerated()), id: \.element.id) { _, r in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(clip(r.name, 44))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Spacer()
                        Text(LeadersLogic.format(.cpu, .mean, r.cpu.mean))
                            .font(.system(size: 17, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(theme.text)
                    }

                    bar(
                        mean: r.cpu.mean / barMax,
                        peak: (r.cpu.peak - r.cpu.mean) / barMax,
                        color: theme.color(.cpu)
                    )
                    .padding(.top, 7)

                    Text("\(i18n.t("hist.colPeak")) \(LeadersLogic.format(.cpu, .peak, r.cpu.peak)) · \(i18n.t("hist.colActive")) \(Int(r.cpu.active.rounded()))% · \(i18n.t("hist.colGrowth")) \(LeadersLogic.format(.mem, .growth, r.mem.lastMb - r.mem.firstMb))")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.dim)
                        .padding(.top, 6)
                }
                .padding(.top, 20)
            }
        }
    }

    private func bar(mean: Double, peak: Double, color: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.line)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(color)
                    .frame(width: content * CGFloat(min(1, max(0, mean))))
                Rectangle()
                    .fill(color.opacity(0.3))
                    .frame(width: content * CGFloat(min(1, max(0, peak))))
            }
            .clipShape(Capsule())
        }
        .frame(width: content, height: 7)
    }

    // MARK: 脚注

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(theme.line).frame(width: content, height: 1)
            HStack {
                Text("\(i18n.t("rep.generated", ["v": i18n.clock(input.now, withDate: true)])) · \(i18n.t("rep.samples", ["n": i18n.num(Double(input.points.count))]))")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.dim)
                Spacer()
                Text("EZPcMonitor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.dim)
            }
            .padding(.top, 24)
        }
    }

    /// 按「半个字宽」估长度截断：图里的文本不会自动换行，
    /// 名字太长会顶到右边的数字上。
    private func clip(_ s: String, _ units: Int) -> String {
        var width = 0
        var out = ""
        for ch in s {
            let wide = ch.unicodeScalars.contains { $0.value >= 0x1100 }
            width += wide ? 2 : 1
            if width > units { return out + "…" }
            out.append(ch)
        }
        return out
    }
}

/// 报告里的折线：面积 + 线 + 峰值虚线 + 峰值圆点。
private struct ReportSpark: View {
    let values: [Double]
    let color: Color
    let line: Color
    var height: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let hi = max(1, (values.max() ?? 0))
                let step = geo.size.width / CGFloat(values.count - 1)
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * step,
                            y: geo.size.height - min(v, hi) / hi * geo.size.height)
                }
                let peakIdx = values.firstIndex(of: values.max() ?? 0) ?? 0
                let px = pts[peakIdx].x
                let py = pts[peakIdx].y

                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.22), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    Path { p in
                        p.move(to: CGPoint(x: px, y: py))
                        p.addLine(to: CGPoint(x: px, y: geo.size.height))
                    }
                    .stroke(color.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                    Circle()
                        .fill(color)
                        .frame(width: 6.4, height: 6.4)
                        .position(x: px, y: py)

                    Rectangle()
                        .fill(line)
                        .frame(height: 1)
                        .position(x: geo.size.width / 2, y: geo.size.height)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - 生成 / 保存 / 复制

enum ReportMaker {
    /// 1080 宽、2 倍导出。Retina 上不糊，文件也不至于几十兆。
    static let width: CGFloat = 1080
    static let scale: CGFloat = 2

    @MainActor
    static func image(_ input: ReportInput) -> NSImage? {
        let page = ReportPage(input: input, theme: .current(), i18n: L10n.shared)
        let renderer = ImageRenderer(content: page)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.nsImage
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// `EZPcMonitor-report-20261023-1432.png`
    static func name(_ now: UInt64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return "EZPcMonitor-report-\(f.string(from: Date(timeIntervalSince1970: TimeInterval(now)))).png"
    }

    /// 存到「下载」。同名不覆盖，改成 `-2`、`-3`——
    /// 同一分钟内连按两次导出是很常见的操作，第二次把第一次顶掉会很恼人。
    static func save(_ data: Data, name: String) -> URL? {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
            if n > 999 { break }
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    static func copy(_ image: NSImage) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.writeObjects([image])
    }
}
