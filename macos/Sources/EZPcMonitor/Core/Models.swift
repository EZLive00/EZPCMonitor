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

/// 界面自己留的滑动窗口。
///
/// 不复用 `RecentPoint`：那个是 core 的返回结构，加一个指标就得动 core；
/// 也不缓存整个 `Snapshot`——它带着 20 条进程，120 份就是几千个对象，
/// 而折线只需要六个数字。
struct Sample {
    let ts: UInt64
    let cpu: Double
    let mem: Double
    let temp: Double
    let rx: Double
    let tx: Double
    /// 读写合计，首页磁盘卡和悬浮窗用
    let disk: Double
    /// 分开的读写，磁盘详情里的两张曲线要
    let diskRead: Double
    let diskWrite: Double
    let gpu: Double

    init(_ p: RecentPoint) {
        ts = p.ts
        cpu = p.cpu
        mem = p.mem
        temp = p.temp
        rx = p.rx
        tx = p.tx
        disk = p.disk
        diskRead = 0
        diskWrite = 0
        gpu = 0
    }

    init(_ s: Snapshot) {
        ts = s.ts
        cpu = s.cpu.usage
        mem = s.mem.percent
        temp = s.primaryTemp ?? 0
        rx = s.net.rxBps
        tx = s.net.txBps
        disk = s.diskTotalBps
        diskRead = s.diskTotalReadBps
        diskWrite = s.diskTotalWriteBps
        gpu = s.gpu?.utilization ?? 0
    }
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

// MARK: - 高占用程序榜

/// 某个维度（CPU / 磁盘）在一个时间窗里的统计。
struct DimStat: Decodable {
    let mean: Double
    let peak: Double
    /// 峰值出现的 unix 秒
    let peakTs: UInt64
    /// 活跃采样占全部采样的百分比（0~100）
    let active: Double
}

/// 内存是「存量」不是「流量」，所以除了均值和峰值还要给首尾值——
/// 首尾之差就是这个窗口里涨了多少，能暴露慢慢泄漏的程序。
struct MemStat: Decodable {
    let meanMb: Double
    let peakMb: Double
    let peakTs: UInt64
    let firstMb: Double
    let lastMb: Double
}

struct Leader: Decodable, Identifiable {
    let name: String
    /// 它出现过几次采样（缺席 = 低于门槛）
    let samples: UInt32
    let cpu: DimStat
    let mem: MemStat
    let io: DimStat

    var id: String { name }
}

struct Leaders: Decodable {
    /// 窗口内的总采样次数（含空拍），所有均值和占比都以它为分母
    let total: UInt64
    let sampleSecs: UInt64
    let rows: [Leader]

    static let empty = Leaders(total: 0, sampleSecs: 30, rows: [])
}

// MARK: - 硬盘健康

struct SmartAttr: Decodable, Identifiable {
    let name: String
    let value: String
    let extra: String
    /// 需要留意（低于阈值 / 关键计数非零）
    let critical: Bool

    var id: String { name + value + extra }
}

struct DiskHealth: Decodable, Identifiable {
    /// 对应的挂载点，靠它和 Disk 配对
    let mount: String
    let device: String
    let model: String
    let serial: String
    let firmware: String
    /// good | warning | bad | unknown
    let status: String
    let smartStatus: String
    let lifeLeft: Double?
    let lifeUsed: Double?
    let spare: Double?
    let temperature: Double?
    let powerOnHours: UInt64?
    let powerCycles: UInt64?
    let writtenBytes: UInt64?
    let readBytes: UInt64?
    let mediaErrors: UInt64?
    let unsafeShutdowns: UInt64?
    let solidState: Bool?
    let bus: String
    let attrs: [SmartAttr]
    /// 数据来源，界面上要如实展示（"diskutil" / "smartctl 7.3"）
    let source: String
    let note: String?

    var id: String { mount }
}

// MARK: - 测速

struct BenchResult: Decodable {
    let sizeMb: UInt64
    let writeMbps: Double
    let readMbps: Double
    let writeMs: UInt64
    let readMs: UInt64
    /// 实际写入的临时文件路径，用户有权知道我们把数据写到了哪
    let path: String
    let note: String?
}

// MARK: - 悬浮窗形态

enum WidgetMode: String, CaseIterable {
    case card
    case bar

    var label: String { self == .card ? "card" : "bar" }
}
