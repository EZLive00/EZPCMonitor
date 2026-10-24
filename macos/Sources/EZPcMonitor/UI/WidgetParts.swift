import SwiftUI

/// 环形进度。
///
/// 没用 `Gauge`：系统那个是给「设置」用的细环，字号和线宽都调不动，
/// 塞进 62pt 的格子里会显得又细又飘。自己画三行就够，还能控制渐变方向。
struct RingGauge: View {
    let value: Double
    let label: String
    let from: Color
    let to: Color
    var size: CGFloat = 62
    var lineWidth: CGFloat = 6

    private var clamped: Double { min(100, max(0, value)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clamped / 100)
                .stroke(
                    LinearGradient(colors: [from, to], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // 0.35s 够平滑又不拖沓；再长，快速起伏时会一直追不上
                .animation(.easeOut(duration: 0.35), value: clamped)

            VStack(spacing: -2) {
                Text("\(Int(clamped.rounded()))")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(label)
                    .font(.system(size: 7.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 迷你折线。
///
/// 上界取 `max(floor, 实际最大值)` 而不是固定 0–100：桌面待机时 CPU 在 3% 上下，
/// 按 100 画就是一条贴着底边的直线，看不出任何形状。地板值（默认 20）挡住
/// 「把 1% 的抖动放大成满屏波浪」这种过度反应。
///
/// 横轴按**固定容量**算，点不够时从右边开始长。刚启动只有七八个点时，
/// 如果按「铺满宽度」画，会得到一条横跨整张卡片的大斜线——看起来像有五分钟历史，
/// 其实只有八秒。
struct Sparkline: View {
    let values: [Double]
    let color: Color
    var floor: Double = 20
    var capacity: Int = 72

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.18), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )

                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let hi = max(floor, values.max() ?? 0)
        let cap = max(capacity, values.count)
        let step = size.width / CGFloat(cap - 1)
        // 上下各留 2pt，线宽 1.4 才不会在顶/底被裁掉一半
        let usable = max(1, size.height - 4)
        let offset = CGFloat(cap - values.count)
        return values.enumerated().map { i, v in
            let x = (offset + CGFloat(i)) * step
            let y = 2 + usable * (1 - CGFloat(min(1, max(0, v / hi))))
            return CGPoint(x: x, y: y)
        }
    }
}

/// 悬浮窗右下角的「读/写」那一小截。
struct RateLabel: View {
    let arrow: String
    let arrowColor: Color
    let value: String
    let unit: String

    var body: some View {
        HStack(spacing: 3) {
            Text(arrow).foregroundStyle(arrowColor)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(unit).foregroundStyle(.secondary)
        }
        .font(.system(size: 10.5))
    }
}
