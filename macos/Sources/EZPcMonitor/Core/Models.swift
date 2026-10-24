import Foundation

// MARK: - 采集快照
//
// 字段跟 `core/src/metrics.rs` 一一对应，key 是 camelCase，所以不用写 CodingKeys。
// 唯一要留神的是「后端可能缺字段」——比如 GPU 在某些机器上永远是 nil，
// 所以可选的一律 `Optional`，缺了也不该让整次解码失败。

struct Host: Decodable {
    let name: String
    let os: String
    let kernel: String
    let arch: String
    let appVersion: String
}

struct CPU: Decodable {
    let usage: Double
    let perCore: [Double]
    let brand: String
    let cores: Int
    let physical: Int
    let freqMhz: UInt64
}

struct Mem: Decodable {
    let total: UInt64
    let used: UInt64
    let available: UInt64
    let swapTotal: UInt64
    let swapUsed: UInt64

    var percent: Double {
        total > 0 ? Double(used) / Double(total) * 100 : 0
    }
}

struct Disk: Decodable, Identifiable {
    let name: String
    let mount: String
    let fs: String
    let kind: String
    let total: UInt64
    let free: UInt64
    let used: UInt64
    let readBps: Double
    let writeBps: Double
    let removable: Bool

    /// 挂载点天然唯一，拿它当 id 比另造一个 UUID 好——重排时不会闪。
    var id: String { mount }
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

struct Net: Decodable {
    let rxBps: Double
    let txBps: Double
    let totalRx: UInt64
    let totalTx: UInt64
}

struct Temp: Decodable, Identifiable {
    let label: String
    let value: Double
    let max: Double?
    let critical: Double?
    let primary: Bool

    var id: String { label }
}

struct GPU: Decodable {
    let name: String
    let utilization: Double?
    let memUsed: UInt64?
    let memTotal: UInt64?
}

struct Proc: Decodable, Identifiable {
    let pid: UInt32
    let name: String
    let cpu: Double
    let mem: UInt64

    var id: UInt32 { pid }
}

struct Snapshot: Decodable {
    let ts: UInt64
    let host: Host
    let cpu: CPU
    let mem: Mem
    let disks: [Disk]
    let diskTotalReadBps: Double
    let diskTotalWriteBps: Double
    let net: Net
    let temps: [Temp]
    let gpu: GPU?
    let load: [Double]
    let uptime: UInt64
    let procs: [Proc]

    /// 主温度：优先 `primary` 那条，没有就取第一条。
    var primaryTemp: Double? {
        (temps.first(where: { $0.primary }) ?? temps.first)?.value
    }

    var diskTotalBps: Double { diskTotalReadBps + diskTotalWriteBps }
}

/// `snapshot` 方法的外层包装。`seq` 每采一拍加一，界面据此判断要不要重绘——
/// 采集节奏由设置里的 `intervalMs` 决定，跟界面的刷新节奏解耦。
struct Tick: Decodable {
    let seq: UInt64
    let snapshot: Snapshot
}

// MARK: - 历史

/// 内存里最近 300 个点（`recent` 方法）。悬浮窗的迷你折线用它。
struct RecentPoint: Decodable {
    let ts: UInt64
    let cpu: Double
    let mem: Double
    let temp: Double
    let rx: Double
    let tx: Double
    let disk: Double
}

/// 落盘的历史点（`history` 方法）。字段名比 `RecentPoint` 短，因为它是文件格式。
struct HistoryPoint: Decodable, Identifiable {
    let t: UInt64
    let cpu: Double
    let mem: Double
    let temp: Double
    let rx: UInt64
    let tx: UInt64
    let disk: UInt64
    let gpu: Double

    var id: UInt64 { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

struct HistoryStats: Decodable {
    let enabled: Bool
    let retentionSecs: UInt64
    let sampleSecs: UInt64
    let minRetentionSecs: UInt64
    let maxRetentionSecs: UInt64
    let presets: [UInt64]
    let count: UInt64
    let bytes: UInt64
    let bytesPerRecord: UInt64
    let oldest: UInt64
    let newest: UInt64
    let procSampleSecs: UInt64
    let procBytes: UInt64
    let procBytesPerSample: UInt64
}

// MARK: - 设置

struct Settings: Decodable, Equatable {
    let intervalMs: UInt64
    let historyEnabled: Bool
    let historyRetentionSecs: UInt64
    let language: String
    let theme: String

    static let fallback = Settings(
        intervalMs: 1000,
        historyEnabled: false,
        historyRetentionSecs: 86_400,
        language: "auto",
        theme: "auto"
    )

    /// 界面实际用的语言标签。`auto` 时用系统解析结果。
    func resolvedLanguage(systemLocale: String) -> String {
        language == "auto" ? systemLocale : language
    }
}

// MARK: - 悬浮窗形态

enum WidgetMode: String, CaseIterable {
    case card
    case bar

    var label: String { self == .card ? "card" : "bar" }
}
