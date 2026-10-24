import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var widget: WidgetController!
    private var status: StatusItemController!
    private var dashboard: DashboardController?

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
        status.onOpenSettings = { [weak self] in self?.openDashboard(settings: true) }
        widget.onOpenDashboard = { [weak self] in self?.openDashboard() }

        widget.show()

        // 开发便利：直接拉主面板，省得每次去点菜单栏图标（截图/回归都靠它）
        if ProcessInfo.processInfo.environment["EZPCM_SHOW_DASHBOARD"] != nil {
            openDashboard()
        }
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

    // MARK: - 主面板

    private func openDashboard(settings: Bool = false) {
        if dashboard == nil {
            dashboard = DashboardController(model: model)
        }
        dashboard?.show(settings: settings)
        // 主面板开着才需要进程列表；关掉就停采，省一次全表遍历
        model.engine.setWantProcs(true)
    }
}
