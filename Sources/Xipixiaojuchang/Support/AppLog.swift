import Foundation

/// 启动计时器（诊断用，验完可删）：给"启动各阶段"打点用 —— 日志的时间戳是**写入时刻**，
/// 而写入是异步排队的，所以量耗时必须**在调用处取时间**、把相对毫秒写进消息里。
enum StartupClock {
    static let t0 = Date()
    /// 距程序启动的毫秒数
    static func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
}

/// 追加式日志（诊断平台响应格式等）。超过 2MB 就把当前这份改名成 `app.log.1`（上一份的 .1 被顶掉）、再从头写——
/// 原来是直接删掉，排查「几个小时前发生了什么」时日志已经没了（2026-10-10 查智能体漏答时只剩下午的）
enum AppLog {
    private static let queue = DispatchQueue(label: "local.zizi.applog")

    static func write(_ tag: String, _ text: String) {
        let line = "[\(Date().formatted(.iso8601))] [\(tag)] \(text)\n"
        queue.async {
            do {
                try FileLocations.ensureDirectories()
                let url = FileLocations.logFile
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                   (attributes[.size] as? NSNumber)?.intValue ?? 0 > 2_000_000 {
                    let previous = url.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: previous)
                    try? FileManager.default.moveItem(at: url, to: previous)
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(line.utf8))
                }
            } catch {
                // 日志失败不影响主流程
            }
        }
    }
}
