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
    /// 背景层的不透明度。**1.0 就是 1.0**：整层完全不透明，桌面彻底盖住。
    /// 只作用在背景层：卡片是半透明的磨砂（见 `CardFrost`），但**文字永远是实心的**——
    /// 字跟着一起透就没法看了。
    var opacity: Double = 0.94

    /// 滑杆的下限。**别再往下压**：0.1 已经是「几乎全透明」，后面透上来的就是清晰的
    /// 桌面内容（磨砂只占 alpha 那部分），再低窗口就只剩一层纱了。
    /// 这一档也是可读性的下限：纯白窗口垫底时，白 72% 的副标题实测 4.85:1，再往下
    /// 就压线（见 `veil`）。
    static let opacityRange: ClosedRange<Double> = 0.1...1

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

    /// 整层背景的不透明度，**直接就是滑杆的值**。
    ///
    /// 这是「不透明度」最直白的读法，也是唯一能让「桌面透过来」真正可见的做法：
    /// `NSVisualEffectView(.behindWindow)` 的透光率实测只有 ~17%（白窗垫在底下，
    /// 窗口底色只亮了 14/255），单靠它，滑杆拉到哪里都还是一块实色——用户反馈的
    /// 「还是完全不透明，看不到后面内容」就是这个。
    ///
    /// 系统材质那一档没有滑杆（材质的不透明度由系统控制），恒为 1。
    private var alpha: Double { backdrop.kind == .material ? 1 : backdrop.opacity }

    /// 层内的玻璃：满强度的材质 + 满强度的染色（或照片）。
    ///
    /// **浓度不跟滑杆走**——滑杆调的是「有多透」，不是「颜色有多浓」。这样不管拉到
    /// 哪里，窗口都还是同一个色相，只是后面露出多少不同。早先让染色 alpha 跟着滑杆
    /// 走，结果是「拉低变灰、拉高变艳」，跟用户对不透明度的预期完全是两回事。
    private var glass: some View {
        ZStack {
            switch backdrop.kind {
            case .material:
                MaterialView()
            case .solid:
                MaterialView()
                backdrop.preset.color
                sheen
            case .image:
                if let image {
                    MaterialView()
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                    // 磨砂已经烘在文件里了，这层材质只负责 macOS 的「活力」观感：
                    // 压暗、降饱和、加一点系统调的噪点。去掉它照片会艳得卡片都看不见，
                    // 单靠纱补不回来——纱只能整体压黑，压不出那种去饱和的灰。
                    // 它只占 1MB 左右（真正贵的是图本身，见 importImage 的注释）。
                    MaterialView(material: .hudWindow, blending: .withinWindow)
                    sheen
                } else {
                    // 图片文件被删了/格式不认：退回材质，总比一片黑好
                    MaterialView()
                }
            }
        }
    }

    /// 压在**整层背景之上**的纱，注意它在 `.opacity()` 外面。
    ///
    /// 位置是这件事的关键：滑杆把整层降到 35% 时，如果纱在层内，它也会被一起降到
    /// 35%，等于什么都没兜住。放在层外，它挡的是「最终到达眼睛的画面」——不管后面
    /// 是壁纸、别的窗口还是一张照片，亮度都有上限。
    ///
    /// 强度跟着滑杆反向走：越透明，后面越不可控，越需要纱。深色主题纯色那档
    /// 从 0.38（10%）降到 0.10（100%）——上限按最坏情况定：纯白窗口垫底、
    /// 滑杆拉到 10%，白 72% 的副标题实测仍有 4.85:1，主标题 5.50:1。
    ///
    /// 100% 留 0.10 而不是归零：预设色比「玻璃 + 纱」亮，归零后那一档反而更亮，
    /// 实测表头会从 3.9:1 掉到 3.5:1。浅色不留——浅色主题的问题是太暗，白纱帮倒忙。
    private var veil: Color {
        // 滑杆归一化：0 = 最透明那档，1 = 完全不透明
        let lo = Backdrop.opacityRange.lowerBound
        let t = min(1, max(0, (alpha - lo) / (1 - lo)))

        var dark = 0.26
        var light = 0.18
        switch backdrop.kind {
        case .material:
            break
        case .solid:
            dark = 0.38 - 0.28 * t
            light = 0.30 - 0.30 * t
        case .image:
            // 照片的内容不可控，一张雪景铺满也照样白字白底，纱必须一直在
            dark = 0.40
            light = 0.38
        }

        let preset = backdrop.preset
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            if isDark {
                return NSColor.black.withAlphaComponent(dark)
            }
            // 浅色主题的纯色背景，纱用**预设色自己**而不是白：白纱盖在浅色染色上
            // 会把色相洗没（选了 ocean 得到一片白，和「系统材质」没区别）。预设色
            // 本身就是浅色，同样能把底色抬到黑字读得清的范围，还顺带保住色相。
            if backdrop.kind == .solid {
                return NSColor(hex: preset.light).withAlphaComponent(light)
            }
            return NSColor.white.withAlphaComponent(light)
        })
    }

    /// 玻璃上的一层高光，从左上到右下淡出。纯色背景全靠它「有玻璃感」，
    /// 不然就只是一块染了色的板子。
    ///
    /// 压到 0.07：它盖在**最上面**，抬的是最终底色，留多了直接把次要文字往下拽
    /// （0.10 时实测副标题从 5.9:1 掉到 5.0:1）。它跟着 `glass` 一起被滑杆稀释，
    /// 所以越透明越弱，正好。
    private var sheen: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.07), Color.white.opacity(0.0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            // 滑杆作用在**整层**上：这一降，桌面就从下面直接透上来。
            // 桌面是清晰的——磨砂材质只占 `alpha` 那部分，这也是「真透明」的代价。
            glass.opacity(alpha)
            veil
        }
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
