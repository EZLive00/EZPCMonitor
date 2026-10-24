import SwiftUI

enum WidgetSize {
    // 高度不是拍脑袋定的：26（头）+ 6 + 64（环）+ 14 + 32（折线）+ 30（脚）= 172，
    // 再加 6pt 余量。用固定高度而不是让 Spacer 去分，是因为 Spacer 分出来的空白
    // 会随内容多少浮动，窗口高度固定时表现成「折线一会儿贴上一会儿贴下」。
    static let card = CGSize(width: 288, height: 178)
    static let bar = CGSize(width: 320, height: 42)

    static func of(_ mode: WidgetMode) -> CGSize {
        mode == .card ? card : bar
    }
}

/// 毛玻璃底。
///
/// `.hudWindow` 是系统给「悬浮控件」那一档材质：比 `.popover` 更暗更薄，
/// 放在桌面壁纸上能看清字又不像一块实心板。圆角用 `cornerCurve = .continuous`，
/// 也就是苹果那套「超椭圆」，比正圆角看着更软。
struct WidgetBackground: NSViewRepresentable {
    var corner: CGFloat = 14

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = DraggableEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = corner
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - 卡片形态

struct CardWidget: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onHide: () -> Void
    var onOpenDashboard: () -> Void
    var onQuit: () -> Void

    @State private var hovering = false

    private var temp: Double? { model.primaryTemp }
    private var rx: (value: String, unit: String) { Fmt.splitRate(model.snapshot?.net.rxBps ?? 0) }
    private var tx: (value: String, unit: String) { Fmt.splitRate(model.snapshot?.net.txBps ?? 0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            rings.padding(.top, 6)
            Sparkline(values: model.series, color: Palette.cpu)
                .frame(height: 32)
                .padding(.horizontal, 10)
                .padding(.top, 14)
            footer
        }
        .frame(width: WidgetSize.card.width, height: WidgetSize.card.height)
        .background(WidgetBackground())
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu { contextItems }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.accent)
                .frame(width: 6, height: 6)
                .shadow(color: Palette.accent.opacity(0.85), radius: 3)

            Text("EZPcMonitor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer(minLength: 0)

            // 按钮只在鼠标进来时出现：平时让位给数字，别让控件抢视觉重心
            if hovering {
                iconButton("rectangle.compress.vertical", help: i18n.t("w.compact")) {
                    model.mode = .bar
                }
                iconButton("xmark", help: i18n.t("w.hide"), action: onHide)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .frame(height: 26)
    }

    private var rings: some View {
        HStack(alignment: .center, spacing: 14) {
            RingGauge(value: model.cpuPercent, label: "CPU", from: Palette.cpu, to: Palette.cpuDeep, size: 64)
            RingGauge(value: model.memPercent, label: "MEM", from: Palette.mem, to: Palette.memDeep, size: 64)

            Spacer(minLength: 0)

            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(temp.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(temp.map(Fmt.tempColor) ?? Color.secondary)
                    Text("°C")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("TEMP")
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            RateLabel(arrow: "↓", arrowColor: Palette.rx, value: rx.value, unit: rx.unit)
            RateLabel(arrow: "↑", arrowColor: Palette.tx, value: tx.value, unit: tx.unit)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text("DISK")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)
                Text("\(Int(model.mainDiskPercent.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(model.mainDiskPercent > 90 ? Palette.danger : Color.primary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var contextItems: some View {
        Button(i18n.t("w.toBar")) { model.mode = .bar }
        Button(model.pinned ? i18n.t("w.unpin") : i18n.t("w.pin")) {
            model.pinned.toggle()
        }
        Button(i18n.t("w.clickThrough")) { model.clickThrough = true }
        Divider()
        Button(i18n.t("w.openDash"), action: onOpenDashboard)
        Divider()
        Button(i18n.t("w.quit"), action: onQuit)
    }
}

// MARK: - 紧凑条形态

struct BarWidget: View {
    @ObservedObject var model: AppModel
    @EnvironmentObject private var i18n: L10n

    var onOpenDashboard: () -> Void
    var onQuit: () -> Void

    @State private var hovering = false

    private var rx: (value: String, unit: String) { Fmt.splitRate(model.snapshot?.net.rxBps ?? 0) }
    private var tx: (value: String, unit: String) { Fmt.splitRate(model.snapshot?.net.txBps ?? 0) }

    var body: some View {
        HStack(spacing: 0) {
            segment {
                key("CPU")
                number("\(Int(model.cpuPercent.rounded()))", "%")
            }
            divider
            segment {
                key("MEM")
                number("\(Int(model.memPercent.rounded()))", "%")
            }
            divider
            segment {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(model.primaryTemp.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(model.primaryTemp.map(Fmt.tempColor) ?? Color.secondary)
                    Text("°C").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            divider
            segment {
                HStack(spacing: 4) {
                    Text("↓").font(.system(size: 10)).foregroundStyle(Palette.rx)
                    Text(Fmt.compact(model.snapshot?.net.rxBps ?? 0))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Text("↑").font(.system(size: 10)).foregroundStyle(Palette.tx)
                    Text(Fmt.compact(model.snapshot?.net.txBps ?? 0))
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
        }
        .frame(width: WidgetSize.bar.width, height: WidgetSize.bar.height)
        .background(WidgetBackground(corner: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        // 双击展回卡片：条模式是「收起来看个数」，想细看自然要展开
        .onTapGesture(count: 2) { model.mode = .card }
        .contextMenu {
            Button(i18n.t("w.toCard")) { model.mode = .card }
            Button(model.pinned ? i18n.t("w.unpin") : i18n.t("w.pin")) { model.pinned.toggle() }
            Button(i18n.t("w.clickThrough")) { model.clickThrough = true }
            Divider()
            Button(i18n.t("w.openDash"), action: onOpenDashboard)
            Divider()
            Button(i18n.t("w.quit"), action: onQuit)
        }
    }

    private func segment<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(width: 0.8, height: 16)
    }

    private func key(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }

    private func number(_ v: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(v)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(unit).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}
