import AppKit

/// 三个窗口共用的外观：内容延伸到标题栏底下，标题栏只剩三个红绿灯。
///
/// 现在 macOS 上的新应用基本都这么做（系统设置、Music、Notes，以及绝大多数
/// 第三方工具）。传统的 `.titled` 窗口会在标题栏和正文之间画一条 1px 分隔线，
/// 标题栏自己还带一层材质——那是最"像 2010 年"的地方。
///
/// 三件事必须一起做，少一件都不到位：
/// 1. `.fullSizeContentView`：内容视图占满整个窗口，能画到标题栏底下；
/// 2. `titlebarAppearsTransparent`：去掉标题栏那层材质，否则会在内容上盖一条灰带；
/// 3. `titlebarSeparatorStyle = .none`：去掉那条分隔线（macOS 11+ 的 API）。
///    只做 1+2 的话，线还在。
///
/// 红绿灯不会被内容盖住：`.fullSizeContentView` 会把标题栏高度写进
/// `contentView.safeAreaInsets.top`，SwiftUI 的根视图默认遵守安全区，
/// 所以正文自动从红绿灯下方开始。真要让内容顶上去，得显式 `.ignoresSafeArea()`。
///
/// 曾经踩过的坑：只开 `titlebarAppearsTransparent` 而没同时把内容让出安全区，
/// 内容会盖住红绿灯，窗口就点不掉了。现在靠安全区解决，不需要手写 padding。
extension NSWindow {
    func useUnifiedChrome() {
        styleMask.insert(.fullSizeContentView)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        // 标题栏只剩 28pt，光靠那一条拖窗口太窄；让整块背景都能拖。
        isMovableByWindowBackground = true
        backgroundColor = .windowBackgroundColor
    }
}
