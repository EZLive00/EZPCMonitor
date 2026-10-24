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

    var onOpenDashboard: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    init(model: AppModel, widget: WidgetController) {
        self.model = model
        self.widget = widget
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "gauge", accessibilityDescription: "EZPcMonitor")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "EZPcMonitor"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
    }

    private var i18n: L10n { L10n.shared }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(action(i18n.t("w.openDash"), #selector(openDashboard), key: "d"))
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
    @objc private func openHistory() { onOpenHistory() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func toggleWidget() { widget.toggle() }
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
