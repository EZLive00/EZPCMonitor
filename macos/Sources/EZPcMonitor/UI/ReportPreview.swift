import AppKit
import SwiftUI

// MARK: - 窗口

/// 报告预览。点「报告」不再直接落盘，而是先把渲染好的那张图摆出来，看清了再决定
/// 存不存。
///
/// 为什么是独立窗口而不是 sheet：报告是 1080×1355 的竖图，窗口得能拉大、能滚，
/// sheet 在这两件事上都不好使。而且这个程序的其它三个窗口（主面板 / 历史 / 设置）
/// 都是独立窗口 + 统一 chrome，多一个 sheet 反而不像一家的。
final class ReportPreviewWindow: NSWindow {
    init(content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Report"
        useUnifiedChrome()
        minSize = NSSize(width: 560, height: 460)
        // 见 DashboardWindow：关窗时 AppKit 默认还会 release 一次，
        // 而 controller 紧接着 `window = nil`，多出来的那次是双重释放
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: AnyView(content))
        center()
    }

    /// Esc 等于「取消」：这个窗口里没有落盘动作，关掉就是什么都不留。
    override func cancelOperation(_ sender: Any?) { performClose(nil) }
}

@MainActor
final class ReportPreviewController: NSObject, NSWindowDelegate {
    private var window: ReportPreviewWindow?

    func show(input: ReportInput, name: String) {
        // 上一张还开着就先关掉，别叠一摞预览窗
        window?.close()
        window = nil

        let view = ReportPreviewView(
            input: input,
            name: name,
            onClose: { [weak self] in self?.window?.performClose(nil) }
        )
        .environmentObject(L10n.shared)

        let w = ReportPreviewWindow(content: view)
        w.delegate = self
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 视图

/// 报告页的自然高度（未缩放）。排版宽度固定 1080，高度由内容决定，
/// 而 `scaleEffect` 不改布局尺寸——所以要量出来，才能给滚动区留对位置。
private struct PageHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ReportPreviewView: View {
    let input: ReportInput
    let name: String
    var onClose: () -> Void = {}

    @EnvironmentObject private var i18n: L10n

    /// 状态行：空着就显示提示，动过手就显示结果。
    @State private var note = ""
    @State private var noteOK = true
    /// 已经存过一次的地址。非空表示「保存」已完成，按钮随之禁用。
    @State private var saved: URL?
    @State private var pageHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline().padding(.top, 10)
            canvas
            Hairline()
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(minWidth: 560, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头部

    private var header: some View {
        SheetHeader(i18n.t("rep.title"), subtitle: subtitle) { EmptyView() }
    }

    /// 「2160 × 2734 · EZPcMonitor-report-20261024-2318.png」——
    /// 把**将要保存的文件名**和分辨率摆出来，用户能提前看出重名和尺寸。
    private var subtitle: String {
        var parts: [String] = []
        if pageHeight > 0 {
            let w = Int(ReportMaker.width * ReportMaker.scale)
            let h = Int((pageHeight * ReportMaker.scale).rounded())
            parts.append("\(w) × \(h)")
        }
        parts.append(name)
        return parts.joined(separator: " · ")
    }

    // MARK: 图

    /// 按宽度铺满、纵向滚动。报告是竖图，窗口再高也装不下；缩到整张可见会让
    /// 10.5pt 的说明文字糊成一团，不如保持宽度、让人自己往下滚。
    ///
    /// 里面是活的视图而不是位图（见 `ReportMaker.page`），所以窗口拉大之后文字
    /// 是重新排的，不是把一张图放大。
    private var canvas: some View {
        GeometryReader { geo in
            let w = max(240, geo.size.width - 24)
            let k = w / ReportMaker.width

            ScrollView(.vertical) {
                ReportMaker.page(input)
                    .frame(width: ReportMaker.width)
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: PageHeightKey.self, value: g.size.height)
                        }
                    )
                    .scaleEffect(k, anchor: .topLeading)
                    // scaleEffect 只改画面不改布局，这里按缩放后的尺寸重新占位，
                    // 否则滚动区会多出（1-k）× 高度的一截空白。
                    //
                    // 还没量到高度时传 nil 而不是 0：传 0 的话内容一开始只有 1pt 高，
                    // 量完突然长到一千多点，滚动区会莫名其妙停在半截（实测偏了整整
                    // (1-k)×高度）。让它先按自然高度排版，量到之后再收回缩放后的高度。
                    .frame(width: w, alignment: .topLeading)
                    .frame(height: pageHeight > 0 ? pageHeight * k : nil, alignment: .topLeading)
                    .overlay(
                        Rectangle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.automatic)
            .onPreferenceChange(PageHeightKey.self) { pageHeight = $0 }
        }
        .background(
            // 报告本身自带底色，铺一块比窗口更沉的面，图的边界才看得出来
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.vertical, 10)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 8) {
            statusLine
            Spacer(minLength: 12)

            MiniButton(title: i18n.t("rep.cancel")) { onClose() }
            MiniButton(title: i18n.t("hist.copy")) { copy() }
            PrimaryButton(title: i18n.t("rep.save"), enabled: saved == nil) { save() }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let saved {
            HStack(spacing: 8) {
                Text(i18n.t("rep.savedTo"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Palette.ok)
                MiniButton(title: i18n.t("rep.reveal")) {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                }
            }
        } else if !note.isEmpty {
            Text(note)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(noteOK ? Palette.ok : Palette.warn)
                .lineLimit(1)
        } else {
            Text(i18n.t("rep.hint"))
                .font(.system(size: 10.5))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: 动作

    /// 到这一步才真的渲成 2160 宽的位图——预览期间一直是活的视图。
    private func save() {
        guard saved == nil else { return }
        guard let image = ReportMaker.image(input),
              let png = ReportMaker.png(image),
              let url = ReportMaker.save(png, name: name)
        else {
            note = i18n.t("rep.failed")
            noteOK = false
            return
        }
        saved = url
        note = ""
    }

    private func copy() {
        guard let image = ReportMaker.image(input) else {
            note = i18n.t("hist.copyFail")
            noteOK = false
            return
        }
        if ReportMaker.copy(image) {
            note = i18n.t("hist.copied")
            noteOK = true
        } else {
            note = i18n.t("hist.copyFail")
            noteOK = false
        }
    }
}
