import AppKit

/// 菜单栏图标。
///
/// 菜单在每次要弹出时重建（`menuNeedsUpdate`），而不是监听一堆状态去改勾。
/// 一个监控工具的菜单总共十几项，重建的成本远低于「改一个值忘了同步某一项勾」
/// 带来的 bug——这类不同步在托盘菜单里特别容易发生，因为入口有四五个。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let widget: WidgetController
    private let item: NSStatusItem
    private let menu = NSMenu()

    var onOpenDashboard: () -> Void = {}
    var onCloseDashboard: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// 菜单要按主面板当前开没开决定那一行写「打开」还是「关闭」。
    var isDashboardVisible: () -> Bool = { false }

    init(model: AppModel, widget: WidgetController) {
        self.model = model
        self.widget = widget
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            button.image = Self.trayImage()
            button.toolTip = "EZPcMonitor"
            // 左键开主面板，右键才弹菜单。
            //
            // 这里**不能**给 `item.menu` 赋值：一旦设了 menu，点击会被菜单接管，
            // button 的 action 永远收不到，「点图标开主面板」就无从谈起。菜单改成
            // 右键时手动 popUp。
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        menu.autoenablesItems = false
        menu.delegate = self
    }

    private var i18n: L10n { L10n.shared }

    /// 菜单栏图标：App 图标里那条心电折线，抠成模板图。
    ///
    /// 模板图（`isTemplate = true`）AppKit 只看 alpha，按菜单栏当前颜色重新着色，
    /// 所以深色栏上是白的、浅色栏上是黑的，不用备两套图。图由
    /// `scripts/gen_tray_icon.py` 生成，1x/2x/3x 三档由 `NSImage(named:)` 自己挑。
    ///
    /// 回落用 `gauge` 符号：资源没打进包时（比如只跑单文件调试）至少还有个图标，
    /// 不至于在菜单栏里留下一个看不见但能点的空白区。
    static func trayImage() -> NSImage? {
        if let image = NSImage(named: "tray-template") {
            image.isTemplate = true
            return image
        }
        let fallback = NSImage(systemSymbolName: "gauge", accessibilityDescription: "EZPcMonitor")
        fallback?.isTemplate = true
        return fallback
    }

    /// 这一次点击算不算「次要点击」（右键 / Control-点）。
    ///
    /// 单独拎出来是因为它只有一行判断，却决定了整个交互模型——左键开面板、
    /// 右键弹菜单。而 `NSApp.currentEvent` 在自动化测试里造不出来，做成纯函数
    /// 才能把两条分支都验一遍。
    static func isSecondaryClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseUp || event.modifierFlags.contains(.control)
    }

    /// 左键：开主面板（已经开着就提到前面来）。右键 / Control-点：弹菜单。
    @objc private func statusButtonClicked() {
        guard let button = item.button else { return onOpenDashboard() }
        guard Self.isSecondaryClick(NSApp.currentEvent) else { return onOpenDashboard() }

        // popUp 不一定会走 menuNeedsUpdate（取决于这次 runloop 的时机），
        // 手动刷一次，菜单里的标题和勾才是当下的状态。
        menuNeedsUpdate(menu)

        // 锚点放在按钮的**下沿**，菜单从菜单栏下面往下展开。
        //
        // 以前写的是 `y: bounds.height + 4`（按钮上沿再往上 4pt）。这个值在应用
        // 是前台时看着没问题——AppKit 会把菜单往下挪；但应用**不在前台**时它按
        // 原样摆，菜单顶部跑到屏幕外，于是第一项被吃掉、顶上多出一个向上滚动的
        // 箭头（鼠标划过去菜单往上滚一下，箭头才消失）。用户报的就是这个。
        // 菜单栏在屏幕最顶上，锚点只要高过按钮上沿就一定有这一截跑到屏幕外。
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 主面板这一行是「开关」，标题跟着当前状态走
        let dashOpen = isDashboardVisible()
        menu.addItem(
            dashOpen
                ? action(i18n.t("w.closeDash"), #selector(closeDashboard), key: "d")
                : action(i18n.t("w.openDash"), #selector(openDashboard), key: "d")
        )
        menu.addItem(action(i18n.t("hist.title"), #selector(openHistory), key: "r"))

        let toggleTitle = widget.isVisible ? i18n.t("w.hide") : i18n.t("w.show")
        menu.addItem(action(toggleTitle, #selector(toggleWidget), key: "h"))

        menu.addItem(.separator())

        // 形态
        let modeItem = NSMenuItem(title: i18n.t("w.compact"), action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        modeMenu.addItem(check(i18n.t("w.card"), #selector(setCard), on: model.mode == .card))
        modeMenu.addItem(check(i18n.t("w.bar"), #selector(setBar), on: model.mode == .bar))
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 不透明度
        let opItem = NSMenuItem(title: i18n.t("w.opacity"), action: nil, keyEquivalent: "")
        let opMenu = NSMenu()
        opMenu.autoenablesItems = false
        for step in [100, 90, 80, 70, 60] {
            let v = Double(step) / 100
            let mi = check("\(step)%", #selector(setOpacity(_:)), on: abs(model.opacity - v) < 0.001)
            mi.representedObject = v
            opMenu.addItem(mi)
        }
        opItem.submenu = opMenu
        menu.addItem(opItem)

        menu.addItem(check(i18n.t("w.clickThrough"), #selector(toggleClickThrough), on: model.clickThrough))

        menu.addItem(.separator())

        // 采集频率
        let freqItem = NSMenuItem(title: i18n.t("set.freq"), action: nil, keyEquivalent: "")
        let freqMenu = NSMenu()
        freqMenu.autoenablesItems = false
        for (ms, key) in [(1000 as UInt64, "set.freqMost"), (5000, "set.freqBalanced"), (10_000, "set.freqSaver")] {
            let title = "\(ms / 1000) \(i18n.t("unit.sec"))"
            let mi = check("\(title)  ·  \(i18n.t(key))", #selector(setInterval(_:)), on: model.settings.intervalMs == ms)
            mi.representedObject = ms
            freqMenu.addItem(mi)
        }
        freqMenu.addItem(.separator())
        let more = NSMenuItem(title: i18n.t("set.title"), action: #selector(openSettings), keyEquivalent: "")
        more.target = self
        freqMenu.addItem(more)
        freqItem.submenu = freqMenu
        menu.addItem(freqItem)

        menu.addItem(.separator())
        menu.addItem(action(i18n.t("w.quit"), #selector(quit), key: "q"))
    }

    // MARK: - 构造小工具

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    private func check(_ title: String, _ sel: Selector, on: Bool) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    // MARK: - 动作

    @objc private func openDashboard() { onOpenDashboard() }
    @objc private func closeDashboard() { onCloseDashboard() }
    @objc private func openHistory() { onOpenHistory() }
    @objc private func openSettings() { onOpenSettings() }

    /// 互斥是双向的：要让挂件出来，就得先收起主面板——否则桌面上会同时挂着
    /// 两个显示同一份数据的窗口。关主面板本身也会把挂件放回来（`windowWillClose`），
    /// 这里的 `show()` 是给「主面板根本没开」那条路兜底的，重复调用无副作用。
    @objc private func toggleWidget() {
        guard widget.isVisible else {
            if isDashboardVisible() { onCloseDashboard() }
            widget.show()
            return
        }
        widget.hide()
    }
    @objc private func setCard() { model.mode = .card }
    @objc private func setBar() { model.mode = .bar }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        model.opacity = v
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let ms = sender.representedObject as? UInt64 else { return }
        model.patchSettings(["intervalMs": ms])
    }

    @objc private func toggleClickThrough() {
        model.clickThrough.toggle()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
