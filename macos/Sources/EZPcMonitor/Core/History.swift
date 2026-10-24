import SwiftUI

/// 分桶后的一段曲线。
///
/// 直接画原始点是不行的：7 天档有六万个点，铺到 300pt 宽的图里每个点不到
/// 0.005pt，画出来既慢又是一团糊。压成 ~180 个桶之后点数和像素数大致对得上。
///
/// 每桶同时保留均值和峰值：只用均值会把尖峰抹平（CPU 飙到 100% 的那十秒
/// 会被平均成 20%），只用峰值又看不出常态。
struct Bucket: Identifiable {
    let t: UInt64
    /// 桶内均值——代表「常态」
    let avg: Double
    /// 桶内峰值——代表「最坏的那一下」
    let max: Double

    var id: UInt64 { t }
}

/// 历史里能画的指标。
///
/// 用枚举而不是 `KeyPath`：`HistoryPoint` 里 cpu/mem 是 `Double`、rx/disk 是
/// `UInt64`，拿一个泛型键去取会一路和类型转换纠缠；而且每个指标还要配标题、
/// 颜色、格式化方式，本来就是一个东西的四个面。
enum Metric: String, CaseIterable, Identifiable {
    case cpu, mem, temp, rx, tx, disk, gpu

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .cpu: return "hist.mCpu"
        case .mem: return "hist.mMem"
        case .temp: return "hist.mTemp"
        case .rx: return "hist.mRx"
        case .tx: return "hist.mRx"
        case .disk: return "hist.mDisk"
        case .gpu: return "hist.mGpu"
        }
    }

    var color: Color {
        switch self {
        case .cpu: return Palette.cpu
        case .mem: return Palette.mem
        case .temp: return Palette.temp
        case .rx: return Palette.rx
        case .tx: return Palette.tx
        case .disk: return Palette.disk
        case .gpu: return Palette.gpu
        }
    }

    func value(_ p: HistoryPoint) -> Double {
        switch self {
        case .cpu: return p.cpu
        case .mem: return p.mem
        case .temp: return p.temp
        case .rx: return Double(p.rx)
        case .tx: return Double(p.tx)
        case .disk: return Double(p.disk)
        case .gpu: return p.gpu
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .cpu, .mem, .gpu: return "\(Int(v.rounded()))%"
        case .temp: return "\(Int(v.rounded()))°C"
        case .rx, .tx, .disk: return Fmt.rate(v)
        }
    }

    /// 历史弹窗里画哪六个。
    ///
    /// 不含 `tx`：它和 `rx` 同源同量级，两张图并排只会让人反复对照，
    /// 真要看上传量在首页的网络卡里就够了。
    static let charted: [Metric] = [.cpu, .mem, .temp, .rx, .disk, .gpu]
}

enum SeriesLogic {
    /// 历史弹窗的可选时间窗。只列「保留时长以内」的档位——
    /// 保留 24 小时的人点「7 天」只会看到一条直线，不如干脆不给这个选项。
    static let ranges: [UInt64] = [3600, 21_600, 86_400, 604_800, 2_592_000]

    /// 把几万个点压成 ~180 个桶。点本来就不够时原样返回（一桶一点）。
    static func buckets(_ rows: [HistoryPoint], _ m: Metric, count: Int = 180) -> [Bucket] {
        guard !rows.isEmpty else { return [] }
        if rows.count <= count {
            return rows.map { Bucket(t: $0.t, avg: m.value($0), max: m.value($0)) }
        }
        var out: [Bucket] = []
        out.reserveCapacity(count)
        let step = Double(rows.count) / Double(count)
        for i in 0..<count {
            let start = Int(Double(i) * step)
            let end = max(start + 1, Int(Double(i + 1) * step))
            var sum = 0.0
            var peak = -Double.infinity
            for j in start..<min(end, rows.count) {
                let v = m.value(rows[j])
                sum += v
                if v > peak { peak = v }
            }
            let n = Double(max(1, min(end, rows.count) - start))
            out.append(Bucket(t: rows[start].t, avg: sum / n, max: peak == -.infinity ? 0 : peak))
        }
        return out
    }

    /// 整段区间的均值与峰值。用原始点算，不经过分桶——分桶后的峰值会略低于真实峰值。
    static func stats(_ rows: [HistoryPoint], _ m: Metric) -> (avg: Double, max: Double) {
        guard !rows.isEmpty else { return (0, 0) }
        var sum = 0.0
        var peak = 0.0
        for r in rows {
            let v = m.value(r)
            sum += v
            if v > peak { peak = v }
        }
        return (sum / Double(rows.count), peak)
    }
}
