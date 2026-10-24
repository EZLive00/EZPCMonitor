import AppKit
import SwiftUI

/// 悬浮窗。
///
/// 用 `NSPanel` 而不是 `NSWindow`：面板可以 `nonactivatingPanel`，
/// 点它不会把当前正在用的 App 挤到后台——一个监控小挂件抢焦点是最讨人厌的行为。
final class WidgetPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        // 跟着用户切 Space、盖在全屏应用上，但不参与 ⌘` 循环
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 让「按住卡片空白处拖动」生效。
///
/// `isMovableByWindowBackground` 只对**没有被内容接住**的点击有效，而 SwiftUI 的
/// 文字和图形虽然不处理 mouseDown，事件仍然落在 NSHostingView 上。所以把毛玻璃
/// 这层换成子类，明确告诉 AppKit「这块背景可以拖窗口」——它是卡片上面积最大、
/// 又确实不响应点击的一层。
final class DraggableEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor
final class WidgetController {
    private let model: AppModel
    private let panel: WidgetPanel
    private var observer: NSObjectProtocol?

    var onOpenDashboard: (() -> Void)?

    private static let originKey = "ezpcm.widgetOrigin"

    init(model: AppModel) {
        self.model = model
        panel = WidgetPanel(size: WidgetSize.of(model.mode))

        rebuildContent()
        restorePosition()

        // 用户拖完记住位置。didMove 在拖拽过程中会疯狂回调，
        // 这里只在结束时写一次——窗口移动的收尾没有专门通知，用防抖最简单。
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // 通知虽然投递到 main queue，但闭包本身不带隔离标注，
            // 显式跳一次 main actor 才不会在 Swift 6 语言模式下报错
            Task { @MainActor in self?.schedulePositionSave() }
        }

        model.onModeChanged = { [weak self] in self?.applyMode() }
        model.onOpacityChanged = { [weak self] in self?.applyOpacity() }
        model.onPinnedChanged = { [weak self] in self?.applyPinned() }
        model.onClickThroughChanged = { [weak self] in self?.applyClickThrough() }

        applyOpacity()
        applyPinned()
        applyClickThrough()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - 显示

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        // 内容改了之后窗口阴影要重算，否则圆角外面会留一圈方的
        panel.invalidateShadow()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() { isVisible ? hide() : show() }

    /// 主面板与悬浮窗互斥：面板一开就把挂件收起来，关掉再放回来。
    /// 桌面上同时挂两个窗口既占地方，显示的还是同一份数据。
    ///
    /// **单向**：关掉悬浮窗不会把主面板拉起来。用户点挂件上的 ✕ 是想让它消失，
    /// 不是想换一个更大的窗口看同一份数据。
    func setDashboardOpen(_ open: Bool) {
        if open { panel.orderOut(nil) } else { show() }
    }

    // MARK: - 外观

    private func rebuildContent() {
        let root: AnyView
        if model.mode == .card {
            root = AnyView(
                CardWidget(
                    model: model,
                    onHide: { [weak self] in self?.hide() },
                    onOpenDashboard: { [weak self] in self?.onOpenDashboard?() },
                    onQuit: { NSApp.terminate(nil) }
                )
            )
        } else {
            root = AnyView(
                BarWidget(
                    model: model,
                    onOpenDashboard: { [weak self] in self?.onOpenDashboard?() },
                    onQuit: { NSApp.terminate(nil) }
                )
            )
        }

        let host = NSHostingView(rootView: root.environmentObject(L10n.shared))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.frame = NSRect(origin: .zero, size: WidgetSize.of(model.mode))
        panel.contentView = host
    }

    private func applyMode() {
        rebuildContent()
        resize(to: WidgetSize.of(model.mode))
        panel.invalidateShadow()
    }

    /// 改尺寸时锚住左上角。用户把卡片摆在屏幕右上角，切到紧凑条以后
    /// 应该还贴着右上角，而不是以左下角为原点往外长。
    private func resize(to size: CGSize) {
        let f = panel.frame
        let origin = NSPoint(x: f.origin.x, y: f.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private func applyOpacity() {
        panel.alphaValue = model.opacity
    }

    private func applyPinned() {
        panel.level = model.pinned ? .floating : .normal
    }

    private func applyClickThrough() {
        panel.ignoresMouseEvents = model.clickThrough
    }

    // MARK: - 位置

    private func restorePosition() {
        let size = WidgetSize.of(model.mode)
        if let raw = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(raw)
            // 上次那块屏幕拔掉了就别硬放，退回主屏右上角
            if NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) }) {
                panel.setFrameTopLeftPoint(p)
                return
            }
        }
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - size.width - 24, y: v.maxY - 24))
    }

    private var saveTask: DispatchWorkItem?

    private func schedulePositionSave() {
        saveTask?.cancel()
        let p = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY)
        let task = DispatchWorkItem {
            UserDefaults.standard.set(NSStringFromPoint(p), forKey: Self.originKey)
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }
}
