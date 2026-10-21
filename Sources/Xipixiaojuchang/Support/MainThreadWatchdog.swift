import Foundation

/// 主线程看门狗：后台线程给主线程发心跳，发现主线程"没回应"就记录下来。
///
/// **为什么需要它**：这个 App 报过"偶发卡顿 + 鼠标转圈"，而 `sample` 是概率采样 ——
/// 卡顿不落在采样窗口里就抓不到（已经白采样两次）。看门狗是**常驻**的：
/// 只要卡了就会留下时间戳；**卡超过 `sampleTrigger` 秒还会自动抓一份 sample**，
/// 在卡住的那一刻从外部拍下主线程栈 —— 事后再分析，不用用户配合复现。
///
/// 开销：每秒 10 次 `DispatchQueue.main.async`（只在上一次心跳已回应时才发），可忽略。
/// 关闭方式：把 `stallThreshold` 设为 nil。
/// 🧪 **诊断（临时）：统计各视图 body 的重算次数。**
///
/// 为什么不用 `Self._printChanges()`：**它在 release 构建里不输出**（实测：
/// 用 release 版跑了整整一轮，stdout 一个字节都没有）。而本项目一直是 `-c release`。
///
/// 为什么不直接往 AppLog 写每次重算：`AppLog` 每次写都要开/关一次文件，
/// 几百次/秒的话**本身就制造卡顿**，等于把测量对象干扰掉。
/// 所以只在内存里累加，由看门狗每秒汇总**一条**日志 —— 开销可忽略，
/// 且带时间戳、能和 `[watchdog] 主线程卡顿` 对齐。
///
/// body 都跑在主线程，所以无需加锁。
enum BodyEvalCounter {
    nonisolated(unsafe) static var counts: [String: Int] = [:]

    static func bump(_ name: String) { counts[name, default: 0] += 1 }

    /// 取走并清空（由看门狗每秒调一次）
    static func drain() -> String {
        guard !counts.isEmpty else { return "" }
        let s = counts.sorted { $0.value > $1.value }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        counts.removeAll()
        return s
    }
}

enum MainThreadWatchdog {
    /// 超过这个时长没回应就记一条日志（秒）。设为 nil = 整体关闭。
    /// 0.2 → 0.1（2026-09-12）：**0.2s 这个口径漏掉了用户真正感觉到的东西**。
    /// 实测教训：某轮改动后日志里一条 ≥200ms 都没有、我据此宣布"0 卡顿"，
    /// 但用户实际手感仍然是"一顿一顿"。原因是**看门狗测的是"主队列被阻塞多久"**，
    /// 而"大量短事件把交互拖慢"时每个事件都很短、主队列每次都能被服务 —— **一条都不会报**。
    /// **"没有 ≥200ms 的阻塞" ≠ "顺滑"**，别再把这两个混为一谈。
    static let stallThreshold: TimeInterval? = 0.1
    /// 超过这个时长就自动抓一份 sample（秒）。设 nil = 不抓。
    ///
    /// 1.0 → 0.3（2026-09-12）：**之前的阈值定错了**。常态卡顿是 200~370ms 这一档，
    /// 而阈值 1.0s 意味着**它们一次都没被采样到**——我一直在拿"1.7s 那次"的栈
    /// （body 里遍历文件系统，已修）去解释 300ms 的卡顿，那是两回事。
    static let sampleTrigger: TimeInterval? = 0.25
    /// 两次抓栈之间的冷却（秒）：避免连续卡顿时疯狂 spawn sample、把磁盘写满
    private static let sampleCooldown: TimeInterval = 30
    /// sample 抓多久（秒）
    private static let sampleDuration = 2

    // 下面这几个可变静态量**全部由 `lock` 保护**，但 Swift 6 的严格并发检查不认外部同步，
    // 所以显式标 `nonisolated(unsafe)` 来接管。（这也是编译器自己给的建议。）
    private static let lock = NSLock()
    /// 已发出、尚未被主线程回应的心跳时间；nil = 当前没有在途心跳
    private nonisolated(unsafe) static var pingSentAt: Date?
    private nonisolated(unsafe) static var started = false
    private nonisolated(unsafe) static var sampling = false
    /// 🧪 诊断：每秒汇总 body 重算次数用的计数（50ms × 20 = 1 秒）
    private nonisolated(unsafe) static var tickCount = 0
    /// 上次抓栈的时间（配合 `sampleCooldown` 限流）
    private nonisolated(unsafe) static var lastSampleAt = Date.distantPast

    static func start() {
        guard stallThreshold != nil, !started else { return }
        started = true
        AppLog.write("watchdog", "已启动：卡顿阈值 \(stallThreshold!)s，超过 \(sampleTrigger ?? -1)s 自动抓 sample")
        Thread.detachNewThread {
            pruneSamples(in: FileLocations.appSupport)
            loop()
        }
    }

    /// 抓下来的 sample 留多少：最近 `keepDays` 天、最多 `keepCount` 份。
    /// 原来从不清理（2026-10-14 用户电脑上攒了 3052 份、5.4 GB，一个月下来整个数据目录的大头）
    static let keepDays: Double = 7
    static let keepCount = 50

    /// 要删掉的那些 sample 文件：超过 `keepDays` 天的，以及按时间新的在前排、第 `keepCount` 份之后的。只看 `stall-*.txt`
    static func samplesToDelete(_ files: [(url: URL, date: Date)], now: Date) -> [URL] {
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        let samples = files.filter { $0.url.lastPathComponent.hasPrefix("stall-") && $0.url.pathExtension == "txt" }
            .sorted { $0.date > $1.date }
        return samples.enumerated().filter { index, file in index >= keepCount || file.date < cutoff }.map(\.element.url)
    }

    /// 启动时清一次（在后台线程，几千个文件也不卡界面）
    static func pruneSamples(in directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let files = urls.map { url in
            (url: url, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        let doomed = samplesToDelete(files, now: now)
        guard !doomed.isEmpty else { return }
        var removed = 0
        for url in doomed where (try? fm.removeItem(at: url)) != nil { removed += 1 }
        AppLog.write("watchdog", "清理旧的卡顿 sample：删了 \(removed) 份（留最近 \(Int(keepDays)) 天、最多 \(keepCount) 份）")
    }

    private static func loop() {
        while true {
            lock.lock()
            let hasOutstanding = pingSentAt != nil
            let sentAt = pingSentAt
            if !hasOutstanding { pingSentAt = Date() }
            lock.unlock()

            if hasOutstanding {
                // 心跳还挂着 —— 主线程正忙。超过阈值就在**卡着的当下**抓一份 sample。
                if let sentAt, let trigger = sampleTrigger, !sampling,
                   Date().timeIntervalSince(sentAt) >= trigger,
                   Date().timeIntervalSince(lastSampleAt) >= sampleCooldown {
                    sampling = true
                    lastSampleAt = Date()
                    captureSample(reason: Date().timeIntervalSince(sentAt))
                }
            } else {
                DispatchQueue.main.async { responded() }
            }

            // 🧪 诊断（临时）：每秒汇总一次 body 重算次数（只记非零的，避免刷屏）
            tickCount += 1
            if tickCount >= 50 {          // 50 × 20ms = 1 秒
                tickCount = 0
                DispatchQueue.main.async {
                    let summary = BodyEvalCounter.drain()
                    if !summary.isEmpty { AppLog.write("bodyEval", summary) }
                }
            }
            // ⚠️ **20ms 一跳，不要再调大**。原来是 50ms —— 而抓栈阈值是 300ms，
            // 对一个 320ms 的卡顿，每 50ms 只跳一次意味着"第 300ms 那一次检查"是**唯一**的机会
            // （`Thread.sleep` 本就不精确，稍有抖动就错过；下一跳时主线程已恢复、心跳被清空，
            //   就再也不会检查了）。实测：320ms 的卡顿因此**一次都没抓到**。
            // 仪器必须比被测对象细一档。
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// 主线程回应了：算从发心跳到现在过了多久
    private static func responded() {
        lock.lock()
        let sent = pingSentAt
        pingSentAt = nil
        let wasSampling = sampling
        if wasSampling { sampling = false }
        lock.unlock()

        guard let sent, let threshold = stallThreshold else { return }
        let lag = Date().timeIntervalSince(sent)
        if lag >= threshold {
            let suffix = wasSampling ? "（已抓 sample）" : ""
            AppLog.write("watchdog", String(format: "主线程卡顿 %.0f ms%@", lag * 1000, suffix))
            // 🧪 诊断（临时）：**同步打进 stdout**。body 探针（`_printChanges()`）也走 stdout，
            // 两者共用同一个缓冲、顺序不会乱 —— 于是"卡顿前后哪些视图在重算"可以直接按顺序读出来。
            print(String(format: "=== 卡顿 %.0f ms ===", lag * 1000))
        }
    }

    /// 在主线程卡住的**当下**从外部抓栈：调系统自带的 `sample` 打自己这个进程。
    /// 只在长时间卡顿时触发，一次一份文件，写完就退出。
    private static func captureSample(reason: TimeInterval) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let out = FileLocations.appSupport.appendingPathComponent("stall-\(stamp).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(pid)", "\(sampleDuration)", "1", "-file", out.path]
        AppLog.write("watchdog", String(format: "检测到主线程已卡 %.1fs，开始抓栈 → %@", reason, out.lastPathComponent))
        do {
            try p.run()
        } catch {
            AppLog.write("watchdog", "抓栈失败（sample 起不来）：\(error.localizedDescription)")
            lock.lock(); sampling = false; lock.unlock()
        }
    }
}
