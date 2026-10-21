import Foundation

/// 崩溃记录 + 异常退出检测（2026-09-18 用户要求）。
///
/// 两件事：
/// 1. **崩溃日志**：未捕获的 ObjC 异常 + 常见致命信号（SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP）
///    落一份 `crash-*.txt`（信号名、时间、版本、系统、当前线程调用栈），方便事后定位；
/// 2. **异常退出检测**：启动时写一个 `running.marker`，正常退出（`applicationWillTerminate`）时删掉。
///    下次启动 marker 还在 → 上次是崩溃或被强杀（SIGKILL 拦不住，但 marker 能兜住）。
///
/// ⚠️ 信号处理器里不能做复杂操作（async-signal-safe 限制），这里只做"写一个小文件 + 恢复默认 + 重新抛出"，
/// 桌面应用里这是常见且可接受的折中。
enum CrashReporter {
    private static var markerURL: URL { FileLocations.appSupport.appendingPathComponent("running.marker") }

    /// 上次是否异常退出（必须在 `install()` 之前读 —— install 会重建 marker）
    /// `nonisolated(unsafe)`：只在启动时（主线程）写、启动后（主线程）读，没有并发访问
    nonisolated(unsafe) private(set) static var lastRunCrashed = false
    /// 最近一份崩溃日志的路径（启动提示用）
    nonisolated(unsafe) private(set) static var lastCrashLogPath: String?

    static func install() {
        // 1) 先判断上次是否异常退出
        if FileManager.default.fileExists(atPath: markerURL.path) {
            lastRunCrashed = true
            lastCrashLogPath = latestCrashLog()?.path
        }
        // 2) 写本次运行标记
        try? Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: markerURL)

        // 3) 未捕获异常（C 函数指针不能捕获上下文 → 用文件级函数）
        NSSetUncaughtExceptionHandler(crashUncaughtExceptionHandler)

        // 4) 致命信号（同上）
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, crashSignalHandler)
        }
    }

    /// 正常退出时调用：清掉运行标记
    static func markCleanExit() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func latestCrashLog() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: FileLocations.appSupport,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("crash-") && $0.pathExtension == "txt" }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    fileprivate static func write(reason: String, detail: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileLocations.appSupport.appendingPathComponent("crash-\(f.string(from: Date())).txt")
        let info = Bundle.main.infoDictionary
        let text = """
        \(reason)
        时间：\(Date())
        版本：\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))
        系统：\(ProcessInfo.processInfo.operatingSystemVersionString)

        \(detail)
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    fileprivate static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT(6)"
        case SIGSEGV: return "SIGSEGV(11)"
        case SIGBUS: return "SIGBUS(10)"
        case SIGILL: return "SIGILL(4)"
        case SIGFPE: return "SIGFPE(8)"
        case SIGTRAP: return "SIGTRAP(5)"
        default: return "\(sig)"
        }
    }
}


/// 未捕获异常处理（文件级、无捕获 —— 必须能转成 C 函数指针）
private func crashUncaughtExceptionHandler(_ exception: NSException) {
    CrashReporter.write(reason: "未捕获异常：\(exception.name.rawValue)",
                        detail: "\(exception.reason ?? "")\n\(exception.callStackSymbols.joined(separator: "\n"))")
}

/// 致命信号处理（文件级、无捕获）
private func crashSignalHandler(_ sig: Int32) {
    CrashReporter.write(reason: "信号 \(CrashReporter.signalName(sig))",
                        detail: Thread.callStackSymbols.joined(separator: "\n"))
    // 恢复默认处理并重新抛出，保留系统崩溃报告（.ips）的行为
    signal(sig, SIG_DFL)
    raise(sig)
}
