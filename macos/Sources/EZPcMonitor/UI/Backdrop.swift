import AppKit
import SwiftUI

// MARK: - 模型

enum BackdropKind: String, Codable {
    /// 系统材质：`NSVisualEffectView` 的毛玻璃，跟着桌面内容实时变。
    case material
    /// 纯色（带一点透明度，桌面从底下透出来）。
    case solid
    /// 用户自选的图片，落盘时压到 1400px，磨砂交给合成时的 `.withinWindow` 材质。
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
    /// 背景层的透明度。1.0 = 不透明，0.6 = 桌面透得比较明显。
    /// 只作用在背景层，正文和卡片永远不透明——文字半透明就没法看了。
    var opacity: Double = 0.94

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
    /// 拷一份到应用数据目录，固定叫 `backdrop.<ext>`，换图时把旧的删掉。
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.ezpc.monitor", isDirectory: true)
    }

    static func url(for name: String) -> URL { dir.appendingPathComponent(name) }

    @discardableResult
    static func importImage(from src: URL) -> String? {
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased()
        let name = "backdrop.\(ext)"
        let dst = url(for: name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 先删旧的所有 backdrop.*，避免换格式之后留下一堆孤儿文件
            if let olds = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for f in olds where f.hasPrefix("backdrop.") {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
                }
            }
            try FileManager.default.copyItem(at: src, to: dst)
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

    /// 读图并缩到 1400px。
    ///
    /// 用 `CGImageSourceCreateThumbnailAtIndex` 而不是 `NSImage(contentsOf:)`：
    /// 后者按原始尺寸整张解码，一张 6000×4000 的照片就是 96MB；缩略图接口只解出
    /// 目标尺寸，1400px 这一档约 5MB。
    ///
    /// 模糊不在这里做：磨砂交给 `BackdropLayer` 里那层 `.withinWindow` 材质，
    /// 由窗口服务器合成，比预先磨一遍更像系统原生，也不用把 CoreImage 拖进来。
    static func load(_ name: String, maxPixel: Int = 1400) -> NSImage? {
        let src = url(for: name)
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: .zero)
    }
}

// MARK: - 背景层

/// 铺在窗口最底下的那一层。放在 SwiftUI 的 `.background` 里，永远不参与命中测试。
///
/// 三种背景都是**真毛玻璃**，只是磨的东西不一样：
/// - 材质：`behindWindow`，磨的是窗口背后的桌面；
/// - 纯色：先铺一层 `behindWindow` 材质，再盖一层带透明度的色 —— 就是 macOS 的
///   「着色玻璃」，颜色是染上去的，底下的桌面依然被磨过；
/// - 图片：`withinWindow`，磨的是窗口**内部**那张图。这是唯一能把用户自己的照片
///   变成毛玻璃的办法——`behindWindow` 只采样窗口外面，对窗内内容无效。
struct BackdropLayer: View {
    let backdrop: Backdrop
    let image: NSImage?

    /// 图片上的压暗/提亮层。文字颜色跟着主题走，所以压的方向也得跟着走：
    /// 深色主题压黑，浅色主题提白，否则「深色主题 + 亮色照片」就是白字白底。
    /// 强度按「最花的照片也能读」定：0.5 左右，卡片那层 3.5% 的白才重新看得出来。
    ///
    /// 浅色那档比深色低一截：白纱盖在照片上会把整张图洗成一片灰白，色相全丢，
    /// 看上去和「系统材质」没区别——用户选了图却看不出选了图。
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
    private var sheen: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.10), Color.white.opacity(0.0)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            switch backdrop.kind {
            case .material:
                MaterialView()
            case .solid:
                MaterialView()
                // 玻璃打底 + 染色。0.40~0.85 之间跟着滑杆走：最低那档还能看清
                // 桌面在动，最高那档基本就是一块带磨砂的实色。
                backdrop.preset.color.opacity(0.40 + 0.45 * backdrop.opacity)
                sheen
            case .image:
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                    MaterialView(material: .hudWindow, blending: .withinWindow)
                    scrim.opacity(0.75)
                    sheen
                } else {
                    // 图片文件被删了/格式不认：退回材质，总比一片黑好
                    MaterialView()
                }
            }
        }
        .opacity(backdrop.kind == .material ? 1 : backdrop.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// 只做一件事：铺一块系统材质。跟悬浮窗那个 `WidgetBackground` 的区别是不带拖动、
/// 不带圆角——主窗口的圆角由窗口自己裁。
///
/// `blending` 决定磨谁：`.behindWindow` 磨窗口背后的桌面，`.withinWindow` 磨
/// 窗口内部下层的内容（用来把用户选的图片磨成毛玻璃）。
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
