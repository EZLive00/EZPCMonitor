import Foundation

/// 程序榜的维度 / 列 / 排序 —— 表格和报告图共用一套定义。
///
/// 三个维度里只有两个半是真能按进程拿到的：
/// - CPU、内存：sysinfo 直接给；
/// - 磁盘：sysinfo 给的是「自启动以来的累计读写」，core 里自己做差分得到速率；
/// - GPU、流量：操作系统都不提供按进程的拆分（macOS 的 ioreg 只有一个整卡数字），
///   界面上标出来但不假装有数据——藏掉反而让人以为是漏做了。
enum DimKey: String, CaseIterable {
    case cpu, mem, io

    var labelKey: String {
        switch self {
        case .cpu: return "hist.dimCpu"
        case .mem: return "hist.dimMem"
        case .io: return "hist.dimDisk"
        }
    }
}

enum ColKey: String, CaseIterable {
    case mean, peak, active, growth

    var labelKey: String {
        switch self {
        case .mean: return "hist.colMean"
        case .peak: return "hist.colPeak"
        case .active: return "hist.colActive"
        case .growth: return "hist.colGrowth"
        }
    }
}

enum LeadersLogic {
    private static let mb = 1_048_576.0

    /// 每个维度看哪三列。
    ///
    /// CPU / 磁盘用「活跃占比」当第三列：它回答「是不是经常在干活」，
    /// 跟均值互补——均值会被长时间待机摊薄，活跃占比不会。
    /// 内存没有「活跃」这个概念（占着就是占着），换成窗口内的增长量，
    /// 慢慢泄漏的程序在均值上看不出来，在增长上一眼就看得到。
    static func cols(for dim: DimKey) -> [ColKey] {
        switch dim {
        case .cpu: return [.mean, .peak, .active]
        case .mem: return [.mean, .peak, .growth]
        case .io: return [.mean, .peak, .active]
        }
    }

    static func value(_ r: Leader, _ dim: DimKey, _ col: ColKey) -> Double {
        if dim == .mem {
            switch col {
            case .growth: return r.mem.lastMb - r.mem.firstMb
            case .peak: return r.mem.peakMb
            default: return r.mem.meanMb
            }
        }
        let s = dim == .cpu ? r.cpu : r.io
        switch col {
        case .peak: return s.peak
        case .active: return s.active
        default: return s.mean
        }
    }

    /// 条形图的满格基准：取所有行的峰值，这样均值和峰值两个量级都能落在条里。
    static func barScale(_ rows: [Leader], _ dim: DimKey) -> Double {
        let m = rows.reduce(0.0) { max($0, value($1, dim, .peak)) }
        return m > 0 ? m : 1
    }

    /// 数值 → 展示文本。内存内部存的是 MB，磁盘存的是 KB/s。
    static func format(_ dim: DimKey, _ col: ColKey, _ v: Double) -> String {
        if dim == .mem {
            if col == .growth {
                return "\(v >= 0 ? "+" : "−")\(Fmt.bytes(abs(v) * mb, digits: 0))"
            }
            return Fmt.bytes(v * mb, digits: 0)
        }
        if col == .active { return String(format: "%.0f%%", v) }
        if dim == .io { return Fmt.rate(v * 1024) }
        return String(format: "%.1f%%", v)
    }

    /// 峰值时刻：内存和 CPU 各记各的，取当前维度对应的那个。
    static func peakTs(_ r: Leader, _ dim: DimKey) -> UInt64 {
        switch dim {
        case .mem: return r.mem.peakTs
        case .cpu: return r.cpu.peakTs
        case .io: return r.io.peakTs
        }
    }

    /// 排序。`name` 兜底，不然同值的行每次重排都换位置，看着像在跳。
    static func sort(_ rows: [Leader], _ dim: DimKey, _ col: ColKey, desc: Bool) -> [Leader] {
        rows.sorted { a, b in
            let d = value(a, dim, col) - value(b, dim, col)
            if d != 0 { return desc ? d > 0 : d < 0 }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
