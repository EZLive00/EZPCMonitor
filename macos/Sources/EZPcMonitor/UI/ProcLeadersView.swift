import SwiftUI

/// 高占用程序榜。
///
/// 排序在本地做：core 一次把三个维度全算好了，切维度、点表头都不用再读文件。
/// **默认按峰值排**——按均值排的话，一个平时 2%、偶尔飙到 96% 的备份程序
/// 永远进不了前十，而那恰恰是最需要被看见的那种。
struct ProcLeadersView: View {
    let data: Leaders
    let loading: Bool
    /// 跨天的时间窗要把日期也标上，否则「峰值 08:12」不知道是哪天的
    let withDate: Bool

    @EnvironmentObject private var i18n: L10n

    @State private var dim: DimKey = .cpu
    @State private var col: ColKey = .peak
    @State private var desc = true

    /// 榜上显示几名。10 名之后的基本都是背景进程，多了只是噪音。
    private static let top = 10

    private var rows: [Leader] { data.rows }

    private var sorted: [Leader] {
        Array(LeadersLogic.sort(rows, dim, col, desc: desc).prefix(Self.top))
    }

    private var scale: Double { LeadersLogic.barScale(sorted, dim) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dimBar

            if !loading && rows.isEmpty {
                EmptyState(
                    i18n.t("hist.procEmpty"),
                    hint: i18n.t("hist.procEmptyHint", ["n": "\(data.sampleSecs)"])
                )
                .frame(maxHeight: .infinity)
            } else {
                table
            }
        }
    }

    // MARK: 维度切换

    private var dimBar: some View {
        HStack(spacing: 6) {
            ForEach(DimKey.allCases, id: \.self) { d in
                Chip(title: i18n.t(d.labelKey), on: dim == d) { pick(d) }
            }
            // 系统不提供按进程的 GPU / 流量，标出来但点不动：
            // 藏掉会让人以为漏做了
            Chip(
                title: i18n.t("hist.dimGpu"),
                enabled: false,
                help: i18n.t("hist.dimUnsupported", ["v": i18n.t("hist.dimGpu")])
            ) {}
            Chip(
                title: i18n.t("hist.dimNet"),
                enabled: false,
                help: i18n.t("hist.dimUnsupported", ["v": i18n.t("hist.dimNet")])
            ) {}

            Spacer(minLength: 8)

            Text(loading ? i18n.t("common.reading") : i18n.t("hist.procTotal", ["n": i18n.num(Double(data.total))]))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    /// 切维度。「增长」只在内存维度里有，切到别的维度得退回一个存在的列。
    private func pick(_ d: DimKey) {
        dim = d
        if !LeadersLogic.cols(for: d).contains(col) { col = .peak }
    }

    // MARK: 表格

    private var table: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { idx, r in
                        row(idx + 1, r)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 22, alignment: .leading)
            Text(i18n.t("hist.colProc"))
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(LeadersLogic.cols(for: dim), id: \.self) { c in
                Button { sort(by: c) } label: {
                    HStack(spacing: 3) {
                        Spacer(minLength: 0)
                        Text(i18n.t(c.labelKey))
                        Text(c == col ? (desc ? "▼" : "▲") : "")
                            .font(.system(size: 7))
                            .opacity(c == col ? 1 : 0)
                    }
                    .foregroundStyle(c == col ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: Self.width(c))
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }

    private func sort(by c: ColKey) {
        if c == col {
            desc.toggle()
        } else {
            col = c
            desc = true
        }
    }

    private func row(_ rank: Int, _ r: Leader) -> some View {
        let mean = LeadersLogic.value(r, dim, .mean)
        let peak = LeadersLogic.value(r, dim, .peak)
        let meanPct = min(100, mean / scale * 100)
        let peakPct = min(100 - meanPct, (peak - mean) / scale * 100)

        return HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)

            Text(r.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(LeadersLogic.cols(for: dim), id: \.self) { c in
                cell(r, c, mean: meanPct, peak: peakPct)
                    .frame(width: Self.width(c))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .frame(height: 24)
    }

    @ViewBuilder
    private func cell(_ r: Leader, _ c: ColKey, mean: Double, peak: Double) -> some View {
        let v = LeadersLogic.value(r, dim, c)
        let text = LeadersLogic.format(dim, c, v)

        if c == .mean {
            // 条形放在数字**前面**而不是垫在底下：垫底的话数字压在浅色填充上，
            // 深浅两种背景下的对比度都不稳，而且三个数字列会看起来像三个色块。
            HStack(spacing: 5) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Palette.cpu.opacity(0.8))
                            .frame(width: Self.barWidth * CGFloat(mean / 100))
                        Rectangle()
                            .fill(Palette.cpu.opacity(0.28))
                            .frame(width: Self.barWidth * CGFloat(max(0, peak) / 100))
                    }
                    .clipShape(Capsule())
                }
                .frame(width: Self.barWidth, height: 6)

                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
            }
        } else {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .helpIf(c == .peak,
                        i18n.t("hist.peakAt", [
                            "v": text,
                            "t": i18n.clock(LeadersLogic.peakTs(r, dim), withDate: withDate),
                        ]))
        }
    }

    /// 列宽按内容给：均值那列要放条+数字，峰值/活跃只要数字。
    /// 平均条用 56pt 而不是 36pt——归一化基准是全场峰值，常见的均值只有个位数
    /// 百分比，条太短就成了一根浮着的小短线，反而看不出差异。
    private static func width(_ c: ColKey) -> CGFloat {
        switch c {
        case .mean: return 124
        case .peak: return 100
        default: return 88
        }
    }

    private static let barWidth: CGFloat = 56
}

private extension View {
    /// `.help("")` 在 macOS 上会弹出一个空的提示框，所以空的就干脆不挂。
    @ViewBuilder
    func helpIf(_ on: Bool, _ text: String) -> some View {
        if on { self.help(text) } else { self }
    }
}
