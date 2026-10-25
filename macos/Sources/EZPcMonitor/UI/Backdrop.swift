import AppKit
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 模型

enum BackdropKind: String, Codable {
    /// 系统材质：`NSVisualEffectView` 的毛玻璃，跟着桌面内容实时变。
    case material
    /// 纯色（带一点透明度，桌面从底下透出来）。
    case solid
    /// 用户自选的图片。落盘时压到 1400px 并磨好，存成 `backdrop.jpg`。
    case image
}

struct BackdropColor: Identifiable {
    let id: String
    let dark: UInt32
    let light: UInt32

    var color: Color { Palette.dyn(dark, light) }
}

/// 主面板的背景。**存在 UserDefaults 而不是 core 的 settings.json**：
/// 它只影响一个窗口怎么画，内核不需要知道；放进 settings.json 就得动 Rust 那边的
/// schema 和 JSON 契约，为了一个纯视觉偏好不值得。
struct Backdrop: Codable, Equatable {
    var kind: BackdropKind = .material
    var color: String = Backdrop.colors[0].id
    /// 图片文件名（存在应用数据目录里，不是用户选的那个原始路径）
    var image: String?
    /// 背景层的浓度。**1.0 就是 1.0**：染色/照片的 alpha 直接等于它，
    /// 100% 时桌面完全盖住，35% 时桌面明显透过来。
    /// 只作用在背景层，正文和卡片永远不透明——文字半透明就没法看了。
    var opacity: Double = 0.94

    /// 滑杆的下限。**不要再压**：再低就轮到玻璃上那层纱兜不住了，
    /// 深色主题 + 纯白壁纸时白字会掉到 4.5:1 以下（见 `BackdropLayer.tintScrim`）。
    static let opacityRange: ClosedRange<Double> = 0.35...1

    var preset: BackdropColor {
        Self.colors.first { $0.id == color } ?? Self.colors[0]
    }

    /// 深色取偏深的一档、浅色取偏浅的一档，和 `Palette` 里那套语义色同一套规则：
    /// 同一个色相在两个外观下各出一个值，而不是把深色调亮。
    ///
    /// 深色那档不能压得太黑：纯色是「玻璃 + 染色」，颜色本身太暗的话，
    /// 盖在本来就暗的材质上会看不出色相，只剩一块黑。
    static let colors: [BackdropColor] = [
        .init(id: "graphite", dark: 0x3D4453, light: 0xE9EDF3),
        .init(id: "ocean", dark: 0x1D4E70, light: 0xDBEDFB),
        .init(id: "teal", dark: 0x17564F, light: 0xD8F2EE),
        .init(id: "violet", dark: 0x3E3063, light: 0xEAE4FA),
        .init(id: "sand", dark: 0x4E4231, light: 0xF6EEDC),
        .init(id: "rose", dark: 0x4E2F3E, light: 0xFAE3EC),
    ]
}

// MARK: - 图片的落盘与解码

enum BackdropStore {
    /// 用户选的图不会原地引用：原文件被移走或删掉，背景就没了。
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.ezpc.monitor", isDirectory: true)
    }

    static func url(for name: String) -> URL { dir.appendingPathComponent(name) }

    /// 落盘尺寸。**磨过的图不需要大**：模糊之后 15px 以上就没有细节了，再大的像素
    /// 只是把同一片渐变换个分辨率存一遍。实测 1400px 让主面板 footprint 从 31MB 涨到
    /// 47MB，400px 是 31MB——开销基本和像素数成正比，跟磨砂没关系。
    ///
    /// 720px 铺满 1000×768pt 的窗口（2 倍屏 2000px 宽）大约放大 2.8 倍。放大一片
    /// 已经模糊的渐变，看不出区别。
    static let maxPixel = 720

    /// 磨砂半径按落盘尺寸给：半径 × (窗口像素 / 落盘像素) 才是屏幕上看到的模糊量。
    /// 0.02 这个系数让任何一档落盘尺寸的观感一致（720 → 14.4，1400 → 28）。
    static let blurRatio = 0.02

    /// 导入时就把图磨好，落盘的是**磨过**的 720px JPEG，不是原图。
    ///
    /// 为什么不在合成时磨：照片是静止的，磨出来的像素每次都一样，实时的
    /// `.withinWindow` 材质等于每帧重算一遍同样的结果。不过实测那层材质只占 1MB，
    /// 真正贵的是图本身——所以真正省下来的不是这层材质，是落盘尺寸。
    ///
    /// 为什么落盘而不是每次启动磨：磨一次要几十毫秒、峰值几十 MB，放在启动路径
    /// 上不划算；写进文件之后启动就是一次缩略图解码。磁盘代价 100KB 上下。
    @discardableResult
    static func importImage(from src: URL) -> String? {
        guard let cg = thumbnail(src, maxPixel: maxPixel) else { return nil }
        let blurred = blur(cg, radius: Double(maxPixel) * blurRatio) ?? cg
        let name = "backdrop.jpg"
        let dst = url(for: name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 先删旧的所有 backdrop.*，避免换格式之后留下一堆孤儿文件
            if let olds = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in olds where f.hasPrefix("backdrop.") {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
            guard let dest = CGImageDestinationCreateWithURL(
                dst as CFURL, UTType.jpeg.identifier as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(
                dest, blurred,
                [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
            )
            guard CGImageDestinationFinalize(dest) else { return nil }
            return name
        } catch {
            return nil
        }
    }

    /// 清空：连文件一起删。只把 `Backdrop.image` 置空的话，那张几百 KB 到几 MB 的
    /// 图会一直躺在应用数据目录里，用户点「清空」之后它就不该再占地方。
    static func removeAll() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for f in names where f.hasPrefix("backdrop.") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// 读图。
    ///
    /// 用 `CGImageSourceCreateThumbnailAtIndex` 而不是 `NSImage(contentsOf:)`：
    /// 后者按原始尺寸整张解码，一张 6000×4000 的照片就是 96MB；缩略图接口只解出
    /// 目标尺寸。文件本身已经是 `maxPixel` 这一档了，这里的上限只是兜底——
    /// 万一有人把一张大图直接塞进应用数据目录。
    static func load(_ name: String, maxPixel: Int = BackdropStore.maxPixel) -> NSImage? {
        guard let cg = thumbnail(url(for: name), maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// 只解出目标尺寸，不解原图。导入和读取共用这一条路径。
    static func thumbnail(_ src: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    /// 高斯模糊。只在导入时跑一次，所以用不着 CIContext 的缓存和复用。
    ///
    /// `clampedToExtent()` 不能省：高斯模糊会把采样窗口伸出图像边界，不先夹住的话
    /// 结果会比原图小一圈，四周留白边。
    ///
    /// 色彩空间必须显式指定 sRGB。CIContext 默认用线性空间做运算，进出各转一次，
    /// 回来之后饱和度会明显偏高——同一张照片烘完再显示，比直接显示艳一截，
    /// 卡片直接糊在背景里。原图的 ICC 也会在这一步丢掉，所以写 JPEG 时要带上。
    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CIContext(options: [
            .workingColorSpace: space,
            .outputColorSpace: space,
        ])
        return context.createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: space)
    }
}

// MARK: - 背景层

/// 铺在窗口最底下的那一层。放在 SwiftUI 的 `.background` 里，永远不参与命中测试。
///
/// 三种背景都是**毛玻璃**，只是磨的东西不一样：
/// - 材质：`behindWindow`，磨的是窗口背后的桌面，跟着桌面内容实时变；
/// - 纯色：同一层 `behindWindow` 材质打底，再盖一层带透明度的色 —— 就是 macOS 的
///   「着色玻璃」，颜色是染上去的，底下的桌面依然被磨过；
/// - 图片：照片在**导入时**就已经磨好了（见 `BackdropStore.importImage`），这里只
///   负责铺上去、加一层纱。照片是静止的，合成时再磨一遍同样的像素纯属浪费——
///   实测那层 `.withinWindow` 材质让主面板 footprint 从 31MB 涨到 48MB。
struct BackdropLayer: View {
    let backdrop: Backdrop
    let image: NSImage?

    /// 照片上的压暗/提亮层。文字颜色跟着主题走，所以压的方向也得跟着走：
    /// 深色主题压黑，浅色主题提白，否则「深色主题 + 亮色照片」就是白字白底。
    /// 强度按「最花的照片也能读」定：0.5 左右，卡片那层 5.5% 的白才重新看得出来。
    ///
    /// 浅色那档比深色低一截：白纱盖在照片上会把整张图洗成一片灰白，色相全丢，
    /// 看上去和「系统材质」没区别——用户选了图却看不出选了图。
    ///
    /// **照片这层不跟滑杆走**（和纯色的 `tintScrim` 不一样）：纯色的颜色是我们自己
    /// 定的，铺满时它自己就能保证可读；照片的内容不可控，一张雪景铺满也照样白字白底，
    /// 所以纱必须一直在。
    private var scrim: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor.black.withAlphaComponent(0.52)
                : NSColor.white.withAlphaComponent(0.50)
        })
    }

    /// 玻璃上的一层高光，从左上到右下淡出。纯色背景全靠它「有玻璃感」，
    /// 不然就只是一块染了色的板子。
    ///
    /// 强度跟着**玻璃的可见程度**走：染色铺满时这就是一块实色漆，没有玻璃，
    /// 也就不该有高光。留着它还有实际代价——0.10 的白盖在纯色上把底色抬了
    /// 二十几级，实测次要文字从 5.3:1 掉到 4.4:1，正好卡在 WCAG 的线下面。
    private var sheen: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 染色/照片的浓度，**直接就是滑杆的值**。
    ///
    /// 这里以前是 `0.40 + 0.45 * opacity`：滑杆 0.6~1 只能把它从 0.67 推到 0.85。
    /// 而深色的预设色和「磨砂桌面 + 纱」的亮度本来就撞在一起，0.18 的 alpha 差值
    /// 落到屏幕上只剩 2.4/255——整根滑杆拉到底，画面几乎没动，用户反馈的
    /// 「只能改变一点点亮度」就是这个。现在的映射是 1:1，滑杆走 35%→100%，
    /// 染色就从「35% 的色 + 65% 的桌面」一路铺到「纯色、桌面完全盖住」。
    private var tint: Double { backdrop.opacity }

    /// 「玻璃还剩多少可见」：滑杆到底就是 0，最淡那档是 1。
    /// 高光和纱都按它走——它们是玻璃的属性，染色铺满时玻璃已经不存在了。
    private var glass: Double {
        let lo = Backdrop.opacityRange.lowerBound
        return 1 - min(1, max(0, (tint - lo) / (1 - lo)))
    }

    /// 压在染色上的纱，**跟着玻璃的可见程度反向走**。
    ///
    /// 染色越薄，桌面越是直接进眼睛，越需要它把可读性兜住；染色铺满时桌面根本
    /// 透不过来，纱就只剩「把颜色压暗」了。所以它一路降到很薄，但**不归零**。
    ///
    /// 深色留 0.10 的底是有账的：预设色本身比「玻璃 + 纱」亮（teal 的相对亮度
    /// 0.075，原来那档玻璃是 0.066），一点不留的话 100% 那档反而更亮，实测
    /// 表头从 3.9:1 掉到 3.5:1——修滑杆把可读性修回去了，不能这么收场。
    /// 浅色不留：浅色主题的问题是太暗，白纱只会帮倒忙。
    ///
    /// 上限按最坏情况定：深色主题 + 纯白壁纸 + 滑杆拉到 35%，白字仍要 4.5:1。
    private var tintScrim: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let lo = dark ? 0.10 : 0.0
            let hi = dark ? 0.42 : 0.30
            let a = lo + (hi - lo) * glass
            return dark
                ? NSColor.black.withAlphaComponent(a)
                : NSColor.white.withAlphaComponent(a)
        })
    }

    /// 系统材质上的压暗层，**保证可读性的兜底**。
    ///
    /// 背景走的是 `.behindWindow`，透的是桌面——壁纸亮一点，整个窗口就跟着发白，
    /// 白 55% 的次要文字直接掉到 3:1 以下（这台机器上实测 3.14:1，WCAG 对小字要求
    /// 4.5:1）。压一档把底色拉到可预期的范围：桌面照样透得过来，只是不再由壁纸的
    /// 明暗决定可读性。
    ///
    /// 这一层是**定值**，不跟滑杆走：系统材质那一档滑杆本来就是灰的（材质的不透明度
    /// 由系统控制，没得调），固定住才能拿它当「其余各档的亮度基准」。
    private var glassScrim: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark
                ? NSColor.black.withAlphaComponent(0.26)
                : NSColor.white.withAlphaComponent(0.18)
        })
    }

    var body: some View {
        ZStack {
            switch backdrop.kind {
            case .material:
                MaterialView()
                glassScrim
            case .solid:
                MaterialView()
                // 玻璃打底 + 染色，浓度由滑杆给
                backdrop.preset.color.opacity(tint)
                tintScrim
                sheen.opacity(glass)
            case .image:
                if let image {
                    // 照片下面**必须垫一层磨砂**：照片一旦不到满浓度，桌面就从
                    // 它下面直接透上来，而且是没磨过、没压过的生像素——和
                    // 「整层降透明度」是同一个错误，只是换了个入口。
                    MaterialView()
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        // 照片的浓度也直接跟滑杆走：压下去是「照片淡进毛玻璃里」。
                        .opacity(tint)
                    // 磨砂已经烘在文件里了，这层材质只负责 macOS 的「活力」观感：
                    // 压暗、降饱和、加一点系统调的噪点。去掉它照片会艳得卡片都看不见，
                    // 单靠纱补不回来——纱只能整体压黑，压不出那种去饱和的灰。
                    // 它只占 1MB 左右（真正贵的是图本身，见 importImage 的注释）。
                    MaterialView(material: .hudWindow, blending: .withinWindow)
                    scrim.opacity(0.75)
                    sheen.opacity(glass)
                } else {
                    // 图片文件被删了/格式不认：退回材质，总比一片黑好
                    MaterialView()
                    glassScrim
                }
            }
        }
        // 这里**不乘** `backdrop.opacity`。窗口是 isOpaque = false，整层降透明度
        // 会让窗口本身变成「半透明塑料膜」，底下透出来的是没磨过、没压过的桌面——
        // 滑杆拉到 70% 就等于给整窗垫了 30% 的生壁纸，白字压上去只有 3:1 出头。
        // 「桌面透过来」这件事由材质本身负责（它磨的就是桌面），滑杆只管染色浓淡。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// 只做一件事：铺一块系统材质。跟悬浮窗那个 `WidgetBackground` 的区别是不带拖动、
/// 不带圆角——主窗口的圆角由窗口自己裁。
///
/// `blending` 决定磨谁：`.behindWindow` 磨窗口背后的桌面，`.withinWindow` 磨窗口
/// 内部下层的内容。现在三个背景都只用到 `.behindWindow`——图片那条路试过
/// `.withinWindow`，效果一样但按窗口像素开了十几 MB 的离屏缓冲，换成了导入时
/// 烘一次。留着这个参数是因为以后真要磨窗内的动态内容（比如视频）还得用它。
struct MaterialView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}
