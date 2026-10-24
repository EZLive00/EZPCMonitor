import Foundation

/// core 回给界面的错误。`String` 不满足 `Error`，包一层比到处用 `String?` 干净。
struct EngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// C ABI 的 Swift 包装。
///
/// 整个 core 只有一个入口 `ezpcm_call(handle, method, args)`，返回 JSON。
/// 这里把它包成泛型 `decode`，调用处就不用关心指针和释放了——
/// `ezpcm_string_free` 在 `defer` 里，忘记释放这种错误在这个文件之外不可能发生。
final class CoreEngine {
    private let handle: OpaquePointer

    init?(dataDir: URL, configDir: URL, smartctl: URL?) {
        // 路径要转成 C 字符串；Swift 会在调用点自动桥接，但可选值得显式展开
        let smart = smartctl?.path
        guard let h = ezpcm_engine_new(dataDir.path, configDir.path, smart) else {
            return nil
        }
        handle = h
    }

    deinit {
        ezpcm_engine_free(handle)
    }

    /// 原始调用。返回空 `Data` 表示句柄失效（正常不会发生）。
    @discardableResult
    func call(_ method: String, _ args: [String: Any]? = nil) -> Data {
        var argsJSON: String?
        if let args, !args.isEmpty {
            if let d = try? JSONSerialization.data(withJSONObject: args) {
                argsJSON = String(data: d, encoding: .utf8)
            }
        }
        guard let p = ezpcm_call(handle, method, argsJSON) else { return Data() }
        defer { ezpcm_string_free(p) }
        return Data(bytes: p, count: strlen(p))
    }

    func decode<T: Decodable>(_ type: T.Type, _ method: String, _ args: [String: Any]? = nil) -> T? {
        let data = call(method, args)
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - 常用的几个，省得调用处到处写字符串

    func tick() -> Tick? { decode(Tick.self, "snapshot") }
    func recent() -> [RecentPoint] { decode([RecentPoint].self, "recent") ?? [] }
    func history(from: UInt64? = nil) -> [HistoryPoint] {
        decode([HistoryPoint].self, "history", from.map { ["from": $0] }) ?? []
    }
    func stats() -> HistoryStats? { decode(HistoryStats.self, "stats") }
    func settings() -> Settings { decode(Settings.self, "settings") ?? .fallback }
    func locale() -> String { decode(String.self, "locale") ?? "en" }
    func version() -> String { decode(String.self, "version") ?? "0.1.0" }

    func leaders(from: UInt64? = nil) -> Leaders {
        decode(Leaders.self, "leaders", from.map { ["from": $0] }) ?? .empty
    }

    /// 硬盘健康。`force` 跳过 core 里的缓存，重新问一次 smartctl——
    /// 一次要几百毫秒到几秒，所以只在用户点「重新检测」时才传 true。
    func health(force: Bool = false) -> [DiskHealth] {
        decode([DiskHealth].self, "health", ["force": force]) ?? []
    }

    /// 顺序读写测速。
    ///
    /// 返回 `Result` 而不是可选值：失败原因是给用户看的（空间不足、只读卷、
    /// 权限不够），丢掉它界面上就只能写「失败」两个字。
    func bench(mount: String, sizeMb: UInt64) -> Result<BenchResult, EngineError> {
        let data = call("bench", ["mount": mount, "sizeMb": sizeMb])
        guard !data.isEmpty else { return .failure(EngineError(message: "no response")) }
        if let r = try? JSONDecoder().decode(BenchResult.self, from: data) {
            return .success(r)
        }
        struct Err: Decodable { let error: String }
        if let e = try? JSONDecoder().decode(Err.self, from: data) {
            return .failure(EngineError(message: e.error))
        }
        return .failure(EngineError(message: String(data: data, encoding: .utf8) ?? "unknown"))
    }

    @discardableResult
    func patch(_ patch: [String: Any]) -> Settings? {
        decode(Settings.self, "patch", patch)
    }

    func setWantProcs(_ on: Bool) {
        call("wantProcs", ["on": on])
    }

    func clearHistory() {
        call("clearHistory")
    }
}
