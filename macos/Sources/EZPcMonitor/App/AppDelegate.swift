import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var widget: WidgetController!
    private var status: StatusItemController!
    private var dashboard: DashboardController?
    private var history: HistoryController?
    private var settings: SettingsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let engine = makeEngine() else {
            let alert = NSAlert()
            alert.messageText = "EZPcMonitor"
            alert.informativeText = "采集内核初始化失败，无法继续。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        model = AppModel(engine: engine)
        widget = WidgetController(model: model)
        status = StatusItemController(model: model, widget: widget)

        status.onOpenDashboard = { [weak self] in self?.openDashboard() }
        status.onCloseDashboard = { [weak self] in self?.dashboard?.close() }
        status.isDashboardVisible = { [weak self] in self?.dashboard?.isVisible ?? false }
        status.onOpenHistory = { [weak self] in self?.openHistory() }
        status.onOpenSettings = { [weak self] in self?.openSettings() }
        widget.onOpenDashboard = { [weak self] in self?.openDashboard() }

        widget.show()

        // 开发便利：直接拉某个窗口，省得每次去点菜单栏图标（截图/回归都靠它）。
        // 环境变量和命令行参数都认：`open --args --dashboard` 比 setenv 好使，
        // 因为 launchctl 的 domain 环境需要 root。
        if devFlag("EZPCM_SHOW_DASHBOARD", arg: "--dashboard") {
            openDashboard()
        }
        if devFlag("EZPCM_SHOW_HISTORY", arg: "--history") {
            openHistory()
        }
        if devFlag("EZPCM_SHOW_SETTINGS", arg: "--settings") {
            openSettings()
        }
    }

    private func devFlag(_ env: String, arg: String) -> Bool {
        ProcessInfo.processInfo.environment[env] != nil
            || CommandLine.arguments.contains(arg)
    }

    /// 关掉主面板不该退出程序——这是个常驻的菜单栏工具。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - 路径

    private func makeEngine() -> CoreEngine? {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.ezpc.monitor", isDirectory: true)
        // 打包时 build.sh 把 smartctl 放进 Contents/Resources/bin/
        let smartctl = Bundle.main.resourceURL?.appendingPathComponent("bin/smartctl")
        return CoreEngine(dataDir: support, configDir: support, smartctl: smartctl)
    }

    // MARK: - 窗口

    private func openDashboard() {
        if dashboard == nil {
            dashboard = DashboardController(model: model)
            dashboard?.onOpenHistory = { [weak self] in self?.openHistory() }
            dashboard?.onOpenSettings = { [weak self] in self?.openSettings() }
            // 互斥：面板一开收起悬浮窗，关掉再放回来（见 WidgetController.setDashboardOpen）
            dashboard?.onVisibilityChanged = { [weak self] open in
                self?.widget.setDashboardOpen(open)
            }
        }
        dashboard?.show()
    }

    private func openHistory() {
        if history == nil {
            history = HistoryController(model: model)
        }
        history?.onOpenSettings = { [weak self] in self?.openSettings() }
        history?.show()
    }

    private func openSettings() {
        if settings == nil {
            settings = SettingsController(model: model)
        }
        settings?.onOpenHistory = { [weak self] in self?.openHistory() }
        settings?.show()
    }
}
