import Foundation

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
