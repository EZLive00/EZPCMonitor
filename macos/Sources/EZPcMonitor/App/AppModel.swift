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
    /// 折线用的滑动窗口。一个缓冲区喂所有曲线——CPU、内存、网络、GPU
    /// 各自留一份数组的话，窗口长度迟早会对不齐，图上就会错位。
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var settings: Settings = .fallback
    @Published private(set) var systemLocale: String = "en"

    /// 硬盘健康。查询要跑 smartctl（几百毫秒到几秒），所以只在主面板打开时拉一次，
    /// 之后靠「重新检测」按钮手动刷。
    @Published private(set) var health: [DiskHealth] = []
    @Published private(set) var healthLoading = false

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
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    @Published var pinned: Bool {
        didSet { defaults.set(pinned, forKey: Keys.pinned); onPinnedChanged?() }
    }
    @Published var clickThrough: Bool {
        didSet { defaults.set(clickThrough, forKey: Keys.clickThrough); onClickThroughChanged?() }
    }

    /// 主面板背景。改一次就存一次，下次启动直接恢复。
    @Published var backdrop: Backdrop {
        didSet {
            guard oldValue != backdrop else { return }
            defaults.set(try? JSONEncoder().encode(backdrop), forKey: Keys.backdrop)
            reloadBackdropImage()
        }
    }

    /// 解码后的背景图（已经缩到 1400px）。单独存一份是为了
    /// 别让 `Backdrop` 这个 Codable 结构体拖着 `NSImage` 跑。
    @Published private(set) var backdropImage: NSImage?

    private var cachedImageName: String?

    // 由 AppDelegate 挂上的副作用。放在这里是为了让「改一个值」和
    // 「窗口跟着变」在同一处发生，而不是散在几个视图的 onChange 里。
    var onModeChanged: (() -> Void)?
    var onPinnedChanged: (() -> Void)?
    var onClickThroughChanged: (() -> Void)?
    var onSettingsChanged: (() -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastSeq: UInt64 = 0
    private var healthTimer: Timer?
    private var healthRetryTimer: Timer?
    private var healthRetry = 0

    private enum Keys {
        static let mode = "ezpcm.mode"
        static let opacity = "ezpcm.opacity"
        static let pinned = "ezpcm.pinned"
        static let clickThrough = "ezpcm.clickThrough"
        static let backdrop = "ezpcm.backdrop"
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

        let savedBackdrop = defaults.data(forKey: Keys.backdrop)
            .flatMap { try? JSONDecoder().decode(Backdrop.self, from: $0) }
        backdrop = savedBackdrop ?? Backdrop()
        backdropImage = savedBackdrop?.image.flatMap { BackdropStore.load($0) }

        systemLocale = engine.locale()
        settings = engine.settings()
        L10n.shared.setLanguage(settings.resolvedLanguage(systemLocale: systemLocale))

        // 折线从历史里种一批，否则刚启动是一片空白，得等一分钟才有形状
        let seed = engine.recent().suffix(Self.window)
        samples = seed.map(Sample.init)

        applyAppearance()
        restartTimer()
    }

    // MARK: - 背景

    /// 换图：先把图磨好写进应用数据目录，再一次性改掉 backdrop（只触发一次 didSet）。
    ///
    /// 落盘名固定是 `backdrop.jpg`，所以换图之后 `image` 这个字符串没变——didSet 里
    /// 「名字没变就不重解」的缓存会命中，界面上还是上一张。这里显式作废缓存再解一次。
    /// 同理，用户重选同一张图时 `backdrop` 和旧值完全相等，didSet 直接返回，也得靠这一手。
    @discardableResult
    func setBackdropImage(from url: URL) -> Bool {
        guard let name = BackdropStore.importImage(from: url) else { return false }
        var next = backdrop
        next.image = name
        next.kind = .image
        backdrop = next
        cachedImageName = nil
        reloadBackdropImage()
        return true
    }

    func clearBackdropImage() {
        var next = backdrop
        next.image = nil
        if next.kind == .image { next.kind = .material }
        backdrop = next
        BackdropStore.removeAll()
    }

    /// 只在文件名变了才重新解码：同一次运行里来回切「材质 ↔ 图片」不该反复解图。
    private func reloadBackdropImage() {
        guard let name = backdrop.image else {
            backdropImage = nil
            cachedImageName = nil
            return
        }
        guard cachedImageName != name else { return }
        backdropImage = BackdropStore.load(name)
        cachedImageName = name
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
        samples.append(Sample(tick.snapshot))
        if samples.count > Self.window {
            samples.removeFirst(samples.count - Self.window)
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

    /// 折线窗口长度。72 点按 1 秒一拍是一分多钟，按 10 秒一拍是十二分钟——
    /// 够看出「刚才那一下」的形状，又不至于让卡片里的线密到看不出起伏。
    static let window = 72

    var series: [Double] { samples.map(\.cpu) }
    var memSeries: [Double] { samples.map(\.mem) }
    var rxSeries: [Double] { samples.map(\.rx) }
    var txSeries: [Double] { samples.map(\.tx) }
    var gpuSeries: [Double] { samples.map(\.gpu) }
    var diskSeries: [Double] { samples.map(\.disk) }

    var cpuPercent: Double { snapshot?.cpu.usage ?? 0 }
    var memPercent: Double { snapshot?.mem.percent ?? 0 }
    var primaryTemp: Double? { snapshot?.primaryTemp }
    var mainDiskPercent: Double { snapshot?.disks.first?.percent ?? 0 }

    var resolvedLanguage: String {
        settings.resolvedLanguage(systemLocale: systemLocale)
    }

    // MARK: - 硬盘健康

    /// 拉一次健康数据。查询会起进程读 SMART，绝不能占主线程。
    func refreshHealth(force: Bool = false) {
        guard !healthLoading else { return }
        healthLoading = true
        let engine = self.engine
        Task { @MainActor in
            let rows = await Task.detached(priority: .utility) {
                engine.health(force: force)
            }.value
            self.health = rows
            self.healthLoading = false
            // 冷启动第一次 smartctl 探测可能刚好超时，core 会给回空表。
            // 别让用户盯着「未检测到」等五分钟：空结果就短间隔补几次。
            if rows.isEmpty, !force, self.healthRetry < 3 {
                self.healthRetry += 1
                self.healthRetryTimer?.invalidate()
                self.healthRetryTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.refreshHealth() }
                }
            }
        }
    }

    /// 主面板打开时开始轮询，关掉就停——smartctl 是 fork 进程，没必要常驻跑。
    func startHealthPolling() {
        healthRetry = 0
        refreshHealth()
        healthTimer?.invalidate()
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHealth() }
        }
        RunLoop.main.add(t, forMode: .common)
        healthTimer = t
    }

    func stopHealthPolling() {
        healthTimer?.invalidate()
        healthTimer = nil
        healthRetryTimer?.invalidate()
        healthRetryTimer = nil
    }

    /// 按挂载点配对。对不上时（例如 APFS 把多个卷合并成一个物理盘）
    /// 返回 nil，界面显示「未检测到」，而不是拿另一块盘的数字顶上去。
    func healthRow(for mount: String) -> DiskHealth? {
        health.first { $0.mount == mount }
    }
}
