import Foundation

// 量一个进程的 CPU / 内存，用**采集内核自己的口径**。
//
// 为什么不用 ps / top：它们要 task_for_pid 权限，在受限环境里直接
// "operation not permitted"。内核里本来就有一份全进程表的实现（sysinfo），
// 复用它还有个额外好处——量出来的数字和界面上显示的完全同源。
//
// 用法：probe <pid> [采样次数] [间隔秒]
// 输出：cpu=<中位数> mem=<字节> n=<样本数>

@_silgen_name("ezpcm_engine_new")
func ezpcm_engine_new(_ d: UnsafePointer<CChar>?, _ c: UnsafePointer<CChar>?,
                      _ s: UnsafePointer<CChar>?) -> OpaquePointer?
@_silgen_name("ezpcm_call")
func ezpcm_call(_ e: OpaquePointer?, _ m: UnsafePointer<CChar>?,
                _ a: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("ezpcm_string_free")
func ezpcm_string_free(_ p: UnsafeMutablePointer<CChar>?)
@_silgen_name("ezpcm_engine_free")
func ezpcm_engine_free(_ e: OpaquePointer?)

let args = CommandLine.arguments
let target = Int32(args.count > 1 ? args[1] : "0") ?? 0
let times = args.count > 2 ? (Int(args[2]) ?? 5) : 5
let gap = args.count > 3 ? (Double(args[3]) ?? 2) : 2

let tmp = NSTemporaryDirectory() + "ezpcm-probe-\(getpid())"
let engine = ezpcm_engine_new(tmp, tmp, nil)
_ = ezpcm_call(engine, "wantProcs", "{\"on\":true}")

var cpus: [Double] = []
var mem: UInt64 = 0

for _ in 0..<times {
    Thread.sleep(forTimeInterval: gap)
    guard let raw = ezpcm_call(engine, "snapshot", nil) else { break }
    let json = String(cString: raw)
    ezpcm_string_free(raw)
    guard
        let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
        let snap = obj["snapshot"] as? [String: Any],
        let procs = snap["procs"] as? [[String: Any]]
    else { continue }

    for p in procs where (p["pid"] as? Int32) == target {
        if let c = p["cpu"] as? Double { cpus.append(c) }
        if let m = p["mem"] as? UInt64 { mem = m }
    }
}

ezpcm_engine_free(engine)
try? FileManager.default.removeItem(atPath: tmp)

let sorted = cpus.sorted()
let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
print(String(format: "cpu=%.1f mem=%llu n=%d", median, mem, cpus.count))
