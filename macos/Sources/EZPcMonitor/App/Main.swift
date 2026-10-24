import AppKit

// 菜单栏应用的标准起手式。
//
// 没有用 SwiftUI 的 `@main struct App`：那个抽象假设「应用有一到几个 WindowGroup」，
// 而我们真正的界面是一个非激活的 NSPanel（悬浮窗）+ 一个按需创建的 NSWindow
// （主面板）。用 AppKit 的 delegate 反而更直白，也不用跟 Scene 的生命周期打架。
//
// 写成 `@main` + `@MainActor static func main()` 而不是顶层的 `main.swift`：
// 顶层代码在 Swift 5 语言模式下是 nonisolated 的，构造 @MainActor 的 AppDelegate
// 会直接报错。给它一个显式的 main-actor 入口最省事。
@main
struct EZPcMonitorApp {
    /// `NSApplication.delegate` 是 **weak** 的。把 delegate 只放在 `main()` 的
    /// 局部变量里，优化器在 `app.run()` 之后就认为它没用了，ARC 直接把它放掉——
    /// 应用活下来但变成一个没有 delegate 的空壳，菜单栏图标和悬浮窗全都不出现。
    /// 必须自己抓一个强引用。
    private static var retained: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retained = delegate
        app.delegate = delegate
        // .accessory：有菜单栏图标，但不进 Dock、不抢 ⌘Tab。
        // 配合 Info.plist 里的 LSUIElement 一起用——单靠其中一样在某些启动路径下会失效。
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
