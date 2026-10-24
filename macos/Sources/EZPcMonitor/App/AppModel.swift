import AppKit
import Combine
import SwiftUI

/// 界面唯一的状态源。
///
/// 数据从 `CoreEngine` 轮询而来——不是 core 反过来回调 Swift。轮询的好处是
/// 没有跨语言回调的生命周期问题（Rust 线程拿着 Swift 闭包，谁先死都说不清），
/// 代价是每 200ms~1s 一次 1.4KB 的 JSON 编解码，实测可以忽略。
/// 靠 `seq` 判断「是不是新的一拍」，所以刷新快于采集节奏也不会重复重绘。
@MainActor
final class AppModel: ObservableObject {
    let engine: CoreEngine

    @Published private(set) var snapshot: Snapshot?
    /// 迷你折线用的滑动窗口，最多 72 点
    @Published private(set) var series: [Double] = []
    /// 内存的滑动窗口。主面板的内存卡也要一条线，不能拿 CPU 的糊弄。
    @Published private(set) var memSeries: [Double] = []
    @Published private(set) var settings: Settings = .fallback
    @Published private(set) var systemLocale: String = "en"

    // 悬浮窗偏好。这些是**纯界面状态**，不像设置那样进 core 的 settings.json——
    // 换个窗口位置不该触发一次「设置已保存」。
    @Published var mode: WidgetMode {
        didSet {
            guard oldValue != mode else { return }
            defaults.set(mode.rawValue, forKey: Keys.mode)
            onModeChanged?()
        }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity); onOpacityChanged?() }
    }
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: Keys.pinned); onPinnedChanged?() }
    }
    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: Keys.clickThrough); onClickThroughChanged?() }
    }

    // 由 AppDelegate 挂上的副作用。放在这里是为了让「改一个值」和
    // 「窗口跟着变」在同一处发生，而不是散在几个视图的 onChange 里。
    var onModeChanged: (() -> Void)?
    var onOpacityChanged: (() -> Void)?
    var onPinnedChanged: (() -> Void)?
    var onClickThroughChanged: (() -> Void)?
    var onSettingsChanged: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastSeq: UInt64 = 0

    private enum Keys {
        static let mode = "ezpcm.mode"
        static let opacity = "ezpcm.opacity"
        static let pinned = "ezpcm.pinned"
        static let clickThrough = "ezpcm.clickThrough"
    }

    init(engine: CoreEngine) {
        self.engine = engine
        let savedMode = WidgetMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .card
        let savedOpacity = defaults.object(forKey: Keys.opacity) as? Double ?? 1.0
        mode = savedMode
        // 下限 0.6：再低就不是「半透明」而是「看不清」了
        opacity = min(1.0, max(0.6, savedOpacity))
        pinned = defaults.object(forKey: Keys.pinned) as? Bool ?? true
        clickThrough = defaults.object(forKey: Keys.clickThrough) as? Bool ?? false

        systemLocale = engine.locale()
        settings = engine.settings()
        L10n.shared.setLanguage(settings.resolvedLanguage(systemLocale: systemLocale))

        // 折线从历史里种一批，否则刚启动是一片空白，得等一分钟才有形状
        let seed = engine.recent().suffix(72)
        if seed.count > 1 {
            series = seed.map(\.cpu)
            memSeries = seed.map(\.mem)
        }

        applyAppearance()
        restartTimer()
    }

    // MARK: - 轮询

    private func restartTimer() {
        timer?.invalidate()
        // 刷新快于采集：采集 10s 一拍时也要在 1s 内看到变化。
        // 反过来（刷新比采集慢）会漏掉中间那些拍，曲线会跳。
        let secs = min(1.0, max(0.2, Double(settings.intervalMs) / 1000))
        let t = Timer(timeInterval: secs, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // .common：菜单打开、窗口拖动时定时器也得继续跑，否则松手前数字是冻住的
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard let tick = engine.tick() else { return }
        guard tick.seq != lastSeq else { return }
        lastSeq = tick.seq
        snapshot = tick.snapshot
        series.append(tick.snapshot.cpu.usage)
        if series.count > 72 {
            series.removeFirst(series.count - 72)
        }
        memSeries.append(tick.snapshot.mem.percent)
        if memSeries.count > 72 {
            memSeries.removeFirst(memSeries.count - 72)
        }
    }

    /// 面板一打开就先要一拍，别让用户对着空白等一个刷新周期。
    func refreshNow() {
        if let tick = engine.tick(), tick.seq != lastSeq {
            lastSeq = tick.seq
            snapshot = tick.snapshot
        }
    }

    // MARK: - 设置

    func patchSettings(_ patch: [String: Any]) {
        guard let next = engine.patch(patch) else { return }
        let languageChanged = next.language != settings.language
        settings = next
        if languageChanged {
            systemLocale = engine.locale()
            L10n.shared.setLanguage(next.resolvedLanguage(systemLocale: systemLocale))
        }
        applyAppearance()
        restartTimer()
        onSettingsChanged?()
    }

    /// 主题：`auto` 交还给系统，`dark` / `light` 硬指定。
    /// 用 `NSApp.appearance` 而不是在 SwiftUI 里包一层 `.preferredColorScheme`，
    /// 因为毛玻璃（`NSVisualEffectView`）读的是 NSAppearance，只改 SwiftUI 那一层
    /// 会出现「卡片变浅了、背后的模糊还是深的」。
    private func applyAppearance() {
        switch settings.theme {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - 给视图用的派生值

    var cpuPercent: Double { snapshot?.cpu.usage ?? 0 }
    var memPercent: Double { snapshot?.mem.percent ?? 0 }
    var primaryTemp: Double? { snapshot?.primaryTemp }
    var mainDiskPercent: Double { snapshot?.disks.first?.percent ?? 0 }

    var resolvedLanguage: String {
        settings.resolvedLanguage(systemLocale: systemLocale)
    }
}
