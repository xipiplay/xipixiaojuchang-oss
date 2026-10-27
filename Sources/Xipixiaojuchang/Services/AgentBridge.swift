import Foundation
import Observation

// MARK: - 外部智能体接力（2026-10-07）
//
// 让外部智能体（Claude Code 等）代替「设置里接入的文字模型 API」回答软件的文字类 AI 请求，并且能远程发起批量任务：
// 软件把每个请求写成一个文件放进收件目录，智能体把回答写回去，软件接着往下走——解析 / 校验 / 存盘 / 进度 / 失败重试
// 全是软件原来的逻辑，换掉的只是「谁来回答」。生图、生视频仍然走用户接的 API。
//
// 目录（`<应用数据>/AgentBridge/`）：
//   requests/<id>.json    软件写：一个待回答的请求（系统提示 + 正文 + 上下文）
//   responses/<id>.json   智能体写：{"id","ok","text"} 或 {"id","ok":false,"error"}（先写 .tmp 再改名）
//   commands/<id>.json    智能体写：一条命令（导入剧本 / 批量分割 / 提取 / 推理分镜 / 停止），处理完挪进 commands/done/
//   results/<id>.json     软件写：命令的受理结果（受理 ≠ 做完，做完看 status.json）
//   status.json           软件写：进度快照（待回答的请求、各项目各集的进度、批量任务、失败原因），一两秒刷新一次
//   claims/<id>.json      子智能体领走一个请求时写（`xipi.py unpack` 会写）：软件据此知道「有智能体在干活」，状态文件里也标「已领」
//   done/ stale/          处理完的请求 / 回答；过期、取消、上次运行遗留的请求
//
// 请求一旦被取消（用户点停止 / 超时），请求文件会被删掉：智能体回答前发现文件没了就丢弃，迟到的回答也会被软件忽略。

// MARK: 请求的上下文（哪个项目、哪一集、在做哪一步）

/// 任务启动时放进 TaskLocal，请求发出时取出来写进请求文件；底层的 chat 调用不用逐层传参。
struct AgentRequestContext: Sendable, Equatable {
    var project: String
    /// 这一集的 ID（一集一个任务的步骤）；一个任务里轮流处理好几集的（推理分镜）用 `episodeNumber`
    var episode: UUID?
    /// 集号（1 起）；有值时优先于 `episode`
    var episodeNumber: Int?
    /// 这一步的名字（「剧本分集」「时长分割」「提取角色」「推理分镜」…）
    var title: String
    /// 任务中心里这个任务的记录 ID：等智能体回答时，任务抽屉里那条要写明「等待外部智能体回答…」
    var aiRecordID: String?

    @TaskLocal static var current: AgentRequestContext?
}

// MARK: 文件格式

struct AgentRequest: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var id: String
    /// 这一步的名字：「剧本分集」「时长分割」「提取角色」「提取场景」「提取道具」「推理分镜」…（未知来源是「AI 请求」）
    var kind: String
    var project: String?
    var projectName: String?
    /// 集号（1 起）
    var episode: Int?
    var episodeTitle: String?
    var createdAt: Date
    /// 要遵守的系统提示（含输出格式要求）
    var system: String
    /// 要处理的内容
    var user: String
    /// 需要看的图片（绝对路径）；没有就是空数组
    var images: [String]
    /// 回答写到这里
    var responseFile: String
    var howToReply: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", id, kind, project, projectName, episode, episodeTitle, createdAt
        case system, user, images, responseFile, howToReply
    }
}

struct AgentReply: Codable, Equatable, Sendable {
    var id: String
    var ok: Bool
    var text: String?
    var error: String?
}

enum AgentBridgeError: LocalizedError, Equatable {
    case timeout
    case agentFailed(String)
    case badReply(String)
    case turnedOff

    var errorDescription: String? {
        switch self {
        case .timeout: "等外部智能体回答超时了（它可能没有在跑）。"
        case .agentFailed(let reason): "外部智能体没能完成这一步：\(reason)"
        case .badReply(let reason): "外部智能体的回答文件有问题：\(reason)"
        case .turnedOff: "外部智能体接力已关闭，这个请求没有被回答。"
        }
    }
}

// MARK: 左栏 AI 图标右上角的小圆点

/// 接力开着时：黄点 = 等智能体；绿点 = 智能体在工作。关着没有点。
@MainActor @Observable
final class AgentActivity {
    enum State: Equatable { case off, waiting, working }
    fileprivate(set) var state: State = .off
}

// MARK: 收件箱

@MainActor
final class AgentBridge {
    static var shared = AgentBridge(root: FileLocations.appSupport.appendingPathComponent("AgentBridge", isDirectory: true),
                                    writesStatusInBackground: true)
    nonisolated static let protocolVersion = 1
    /// 一个请求最多等多久。要长：一次批量分割会同时放出几十个请求，智能体按并发上限一批一批领，排在后面的要等很久
    nonisolated static let replyTimeout: TimeInterval = 3 * 3600
    /// 回答文件写了一半（不是有效 JSON）时多等几秒再判定出错
    nonisolated static let partialWriteGrace: TimeInterval = 5

    let root: URL
    var requestsDirectory: URL { root.appendingPathComponent("requests", isDirectory: true) }
    var responsesDirectory: URL { root.appendingPathComponent("responses", isDirectory: true) }
    var commandsDirectory: URL { root.appendingPathComponent("commands", isDirectory: true) }
    var commandsDoneDirectory: URL { commandsDirectory.appendingPathComponent("done", isDirectory: true) }
    var resultsDirectory: URL { root.appendingPathComponent("results", isDirectory: true) }
    var doneDirectory: URL { root.appendingPathComponent("done", isDirectory: true) }
    var staleDirectory: URL { root.appendingPathComponent("stale", isDirectory: true) }
    var claimsDirectory: URL { root.appendingPathComponent("claims", isDirectory: true) }
    /// 子智能体拆请求的工作目录（`xipi.py unpack` 建，放在收件目录里：智能体已经被授权访问这个目录，别处不一定有权限）
    var workDirectory: URL { root.appendingPathComponent("work", isDirectory: true) }
    var statusFile: URL { root.appendingPathComponent("status.json") }
    /// 最近多久内智能体动过（发命令 / 领请求 / 交回答），就算「在工作」
    nonisolated static let activityWindow: TimeInterval = 60

    weak var app: AppModel?
    /// 测试 / 调试用：命令触发的批量任务改用这个通道回答，不走真正的 AI（正常为 nil）
    var chatOverride: SimplePipeline.Chat?
    private(set) var isRunning = false
    let activity = AgentActivity()
    private var lastActivity: Date?
    /// 上一轮看到的、被领走且还在等回答的请求
    private(set) var claimedIDs: Set<String> = []

    private struct Waiter {
        var continuation: CheckedContinuation<String, Error>
        var deadline: Date
        var request: AgentRequest
        var recordID: String?
    }

    /// 任务抽屉里的说明（用户手动触发的任务在接力开着时也会进收件箱干等，要让他看得出来）
    nonisolated static let waitingNote = "等待外部智能体回答…"
    nonisolated static let workingNote = "外部智能体正在处理…"
    private var waiters: [String: Waiter] = [:]
    private var loop: Task<Void, Never>?
    /// 某个回答 / 命令文件第一次被发现「读不出来」的时间（可能只是还没写完）
    private var unreadableSince: [String: Date] = [:]
    private var lastStatus: AgentStatus?
    private var lastStatusWrite = Date.distantPast
    /// 每集的字数 / 分割段数缓存（见 `EpisodeStatusCacheEntry`）
    var episodeStatusCache: [UUID: EpisodeStatusCacheEntry] = [:]
    /// 开接力后每集的情况在后台算完了没有（2026-10-28 用户：启动后第一次开接力卡 0.7 秒——全部项目每一集的分割都在主线程上解析一遍）。
    /// 没算完之前每秒的状态刷新先不写，算完写一份
    private var statusReady = false
    private var warmUpTask: Task<Void, Never>?

    /// 状态文件在后台编码、写盘（2026-10-21 用户：批量回传时很卡——状态文件 360KB，原来每次都在主线程上编码，一次 0.3～0.5 秒，
    /// 批量任务时状态几乎每秒都变）。主线程只组装、比较；测试默认同步写，好在 `tick()` 之后马上读文件
    private let writesStatusInBackground: Bool
    /// 状态文件写盘的串行队列：按顺序落盘，后一次覆盖前一次
    private let statusWriteQueue = DispatchQueue(label: "io.github.xipiplay.xipixiaojuchang.agent-status", qos: .utility)

    init(root: URL, writesStatusInBackground: Bool = false) {
        self.root = root
        self.writesStatusInBackground = writesStatusInBackground
    }

    // MARK: 开关

    /// 按设置开 / 关：设置里开了「外部智能体接力」就开始收件和收命令，关了就停（在跑的请求报「已关闭」）
    func refresh(app: AppModel? = nil) {
        if let app { self.app = app }
        if PipelineAISettingsStore.load().config.usesAgent {
            start(app: self.app)
        } else if isRunning {
            stop()
        }
    }

    /// `poll`：false = 不开自动轮询（测试里手动调 `tick()`）
    func start(app: AppModel?, poll: Bool = true) {
        if let app { self.app = app }
        guard !isRunning else { return }
        prepareDirectories()
        sweepLeftovers()
        isRunning = true
        activity.state = .waiting
        lastActivity = nil
        claimedIDs = []
        if poll {
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.tick()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        warmUpStatus()
        AppLog.write("agent", "外部智能体接力已开启，目录：\(root.path)")
    }

    func stop() {
        loop?.cancel()
        loop = nil
        warmUpTask?.cancel()
        warmUpTask = nil
        statusReady = false
        isRunning = false
        activity.state = .off
        let pending = waiters
        waiters = [:]
        for (id, waiter) in pending {
            try? fm.removeItem(at: requestsDirectory.appendingPathComponent("\(id).json"))
            releaseClaim(id)
            waiter.continuation.resume(throwing: AgentBridgeError.turnedOff)
        }
        writeStatus(now: Date(), force: true)
        AppLog.write("agent", "外部智能体接力已关闭")
    }

    // MARK: 提问

    /// 发一个请求并等智能体回答。任务被取消 → 请求文件删掉、抛 `CancellationError`。
    func ask(system: String, user: String, images: [String] = [],
             timeout: TimeInterval = AgentBridge.replyTimeout) async throws -> String {
        if !isRunning { start(app: app) }
        let id = UUID().uuidString.lowercased()
        let request = makeRequest(id: id, system: system, user: user, images: images)
        let requestFile = requestsDirectory.appendingPathComponent("\(id).json")
        try write(request, to: requestFile)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                if Task.isCancelled {
                    try? fm.removeItem(at: requestFile)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let recordID = AgentRequestContext.current?.aiRecordID
                waiters[id] = Waiter(continuation: continuation, deadline: Date().addingTimeInterval(timeout),
                                     request: request, recordID: recordID)
                if let recordID { app?.jobCenter.aiProgress(recordID, note: Self.waitingNote) }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRequest(id) }
        }
    }

    /// 取消一个等待中的请求：删请求文件，让提问的任务抛 `CancellationError`
    func cancelRequest(_ id: String) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        try? fm.removeItem(at: requestsDirectory.appendingPathComponent("\(id).json"))
        releaseClaim(id)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func makeRequest(id: String, system: String, user: String, images: [String]) -> AgentRequest {
        let context = AgentRequestContext.current
        var number = context?.episodeNumber
        var episodeTitle: String?
        var projectName: String?
        if let context, let app {
            projectName = app.projectMetas[context.project]?.name
            if let archive = app.pipelineArchive(for: context.project) {
                if number == nil, let episode = context.episode {
                    number = archive.episodes.firstIndex { $0.id == episode }.map { $0 + 1 }
                }
                if let n = number, archive.episodes.indices.contains(n - 1) { episodeTitle = archive.episodes[n - 1].title }
            }
        }
        let responseFile = responsesDirectory.appendingPathComponent("\(id).json").path
        return AgentRequest(
            protocolVersion: Self.protocolVersion, id: id, kind: context?.title ?? "AI 请求",
            project: context?.project, projectName: projectName, episode: number, episodeTitle: episodeTitle,
            createdAt: Date(), system: system, user: user, images: images, responseFile: responseFile,
            howToReply: "按 system 的要求处理 user，只把结果正文写进回答文件：{\"id\":\"\(id)\",\"ok\":true,\"text\":\"…\"}；"
                + "做不了就写 {\"id\":\"\(id)\",\"ok\":false,\"error\":\"原因\"}。先写成 .tmp 再改名；请求文件已被删除说明这一步已取消，丢弃即可。"
        )
    }

    // MARK: 轮询

    /// 一轮：收回答 → 处理超时 → 收命令 → 刷新状态文件。自动轮询每秒调一次；测试直接调。
    func tick(now: Date = Date()) {
        guard isRunning else { return }
        collectReplies(now: now)
        processCommands(now: now)
        updateActivity(now: now)
        if statusReady { writeStatus(now: now) }
    }

    /// 开接力时：缓存里没有 / 过期的集在后台算好，再写第一份状态文件（主线程只抄一份各集原文和分割，很快）。
    /// 测试（状态同步写）里当场算完、当场写，好在 `start` 之后马上读文件
    private func warmUpStatus() {
        let missing: [(id: UUID, text: String, splitText: String?)] = app.map { app in
            app.projectMetas.keys.compactMap { app.pipelineArchive(for: $0) }.flatMap(\.episodes)
                .filter { episode in !(episodeStatusCache[episode.id]?.matches(episode) ?? false) }
                .map { ($0.id, $0.text, $0.splitText) }
        } ?? []
        guard writesStatusInBackground, !missing.isEmpty else {
            statusReady = true
            writeStatus(now: Date(), force: true)
            return
        }
        let started = Date()
        warmUpTask = Task { @MainActor [weak self] in
            let entries = await Task.detached(priority: .userInitiated) {
                missing.map { ($0.id, EpisodeStatusCacheEntry.make(text: $0.text, splitText: $0.splitText)) }
            }.value
            guard let self, !Task.isCancelled, self.isRunning else { return }
            for (id, entry) in entries { self.episodeStatusCache[id] = entry }
            self.statusReady = true
            self.writeStatus(now: Date(), force: true)
            self.warmUpTask = nil
            AppLog.write("agent", "状态文件已写出：后台算了 \(entries.count) 集，用了 \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        }
    }

    private func collectReplies(now: Date) {
        for (id, waiter) in waiters {
            let file = responsesDirectory.appendingPathComponent("\(id).json")
            if fm.fileExists(atPath: file.path) {
                guard let result = readReply(file, id: id, now: now) else { continue }   // nil = 还没写完，下一轮再看
                waiters[id] = nil
                unreadableSince[id] = nil
                archive(id)
                releaseClaim(id)
                lastActivity = now
                if let recordID = waiter.recordID { app?.jobCenter.aiProgress(recordID, note: nil) }
                waiter.continuation.resume(with: result)
            } else if now >= waiter.deadline {
                waiters[id] = nil
                move(requestsDirectory.appendingPathComponent("\(id).json"), into: staleDirectory)
                releaseClaim(id)
                waiter.continuation.resume(throwing: AgentBridgeError.timeout)
            }
        }
    }

    /// nil = 文件还读不出来（可能没写完），再等一会儿
    private func readReply(_ file: URL, id: String, now: Date) -> Result<String, Error>? {
        guard let data = try? Data(contentsOf: file), let reply = try? JSONDecoder().decode(AgentReply.self, from: data) else {
            let since = unreadableSince[id] ?? now
            unreadableSince[id] = since
            guard now.timeIntervalSince(since) >= Self.partialWriteGrace else { return nil }
            return .failure(AgentBridgeError.badReply("不是有效的 JSON（需要 {\"id\",\"ok\",\"text\"}）"))
        }
        guard reply.id == id else { return .failure(AgentBridgeError.badReply("里面的 id 和文件名对不上")) }
        guard reply.ok else { return .failure(AgentBridgeError.agentFailed(reply.error ?? "没有说明原因")) }
        let text = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(PipelineAIError.emptyResponse) }
        return .success(text)
    }

    // MARK: 命令

    private func processCommands(now: Date) {
        let urls = (try? fm.contentsOfDirectory(at: commandsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let files = urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { modified($0) < modified($1) }
        for file in files { handleCommand(file, now: now) }
    }

    private func handleCommand(_ file: URL, now: Date) {
        let stem = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else { return }
        let command: AgentCommand
        do {
            command = try JSONDecoder().decode(AgentCommand.self, from: data)
        } catch {
            // JSON 本身写坏了（多半还在写）：等几秒再判；JSON 没问题、只是内容不对：马上告诉智能体
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                let since = unreadableSince[file.lastPathComponent] ?? now
                unreadableSince[file.lastPathComponent] = since
                guard now.timeIntervalSince(since) >= Self.partialWriteGrace else { return }
            }
            unreadableSince[file.lastPathComponent] = nil
            report(AgentCommandResult(id: stem, ok: false, message: "命令文件格式不对：\(Self.describe(error))", project: nil, finishedAt: now))
            move(file, into: commandsDoneDirectory)
            return
        }
        unreadableSince[file.lastPathComponent] = nil
        lastActivity = now
        let id = command.id ?? stem
        guard let app else {
            report(AgentCommandResult(id: id, ok: false, message: "软件还没准备好接收命令", project: nil, finishedAt: now))
            move(file, into: commandsDoneDirectory)
            return
        }
        let outcome = AgentCommandRunner.run(command, app: app, chat: chatOverride)
        report(AgentCommandResult(id: id, ok: outcome.ok, message: outcome.message, project: outcome.project, finishedAt: now))
        AppLog.write("agent", "命令 \(command.cmd)（\(id)）：\(outcome.ok ? "受理" : "拒绝")，\(outcome.message)")
        move(file, into: commandsDoneDirectory)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? DecodingError {
        case .keyNotFound(let key, _): "缺少 \(key.stringValue)"
        case .dataCorrupted(let context): context.debugDescription
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "\(context.codingPath.map(\.stringValue).joined(separator: ".")) 的类型不对"
        default: "不是有效的 JSON（至少要有 cmd 字段）"
        }
    }

    private func report(_ result: AgentCommandResult) {
        try? write(result, to: resultsDirectory.appendingPathComponent("\(result.id).json"))
    }

    // MARK: 智能体在不在干活

    /// 黄点 / 绿点：有请求被子智能体领走还没交回答，或最近一分钟内智能体发过命令 / 领过请求 / 交过回答 = 绿；否则黄
    private func updateActivity(now: Date) {
        let claimed = Set(waiters.keys.filter { fm.fileExists(atPath: claimsDirectory.appendingPathComponent("\($0).json").path) })
        let newlyClaimed = claimed.subtracting(claimedIDs)
        if !newlyClaimed.isEmpty { lastActivity = now }
        for id in newlyClaimed {
            if let recordID = waiters[id]?.recordID { app?.jobCenter.aiProgress(recordID, note: Self.workingNote) }
        }
        claimedIDs = claimed
        let recent = lastActivity.map { now.timeIntervalSince($0) < Self.activityWindow } ?? false
        let next: AgentActivity.State = (!claimed.isEmpty || recent) ? .working : .waiting
        if activity.state != next { activity.state = next }
    }

    private func releaseClaim(_ id: String) {
        try? fm.removeItem(at: claimsDirectory.appendingPathComponent("\(id).json"))
        claimedIDs.remove(id)
    }

    // MARK: 状态文件

    private static let idleHeartbeat: TimeInterval = 8

    private func writeStatus(now: Date, force: Bool = false) {
        var status = buildStatus(now: now)
        status.updatedAt = Date(timeIntervalSince1970: 0)
        // 内容没变就最多每 `idleHeartbeat` 秒刷新一次（让 updatedAt 当心跳用），不每秒写盘。直接比结构体，不编码成 JSON 再比（编码很贵）。
        // 智能体判断「软件在线」的口径是心跳 15 秒内（`xipi.py` 的 `heartbeat_age`），3 秒 → 8 秒：空闲时写盘少一大半（状态文件近 200KB），仍留 7 秒余量
        guard force || status != lastStatus || now.timeIntervalSince(lastStatusWrite) >= Self.idleHeartbeat else { return }
        let neutral = status
        status.updatedAt = now
        let snapshot = status, url = statusFile
        let job = { try? Self.statusEncoder.encode(snapshot).write(to: url, options: .atomic) }
        // 开 / 关接力那一次（force）同步落盘：关掉时那份 agentMode=false 不能因为软件退出而丢；同一个队列，顺序不乱
        if writesStatusInBackground && !force {
            statusWriteQueue.async { _ = job() }
        } else {
            statusWriteQueue.sync { _ = job() }
        }
        lastStatus = neutral
        lastStatusWrite = now
    }

    /// 等开接力时后台那一遍算完（测试用）
    func waitForStatusWarmUp() async {
        await warmUpTask?.value
    }

    /// 等排着的状态文件写完（测试用）
    func flushStatusWrites() {
        statusWriteQueue.sync {}
    }

    /// 状态文件专用编码器（在后台队列上用，不和主线程共用 `encoder`）
    private nonisolated static let statusEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func pendingRequests() -> [AgentRequest] {
        waiters.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: 文件工具

    private let fm = FileManager.default

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try Self.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func move(_ file: URL, into directory: URL) {
        guard fm.fileExists(atPath: file.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(file.lastPathComponent)
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: file, to: target)
    }

    /// 回答收到后：请求和回答一起挪进 done/
    private func archive(_ id: String) {
        move(requestsDirectory.appendingPathComponent("\(id).json"), into: doneDirectory.appendingPathComponent("requests", isDirectory: true))
        move(responsesDirectory.appendingPathComponent("\(id).json"), into: doneDirectory.appendingPathComponent("responses", isDirectory: true))
    }

    private func prepareDirectories() {
        for directory in [requestsDirectory, responsesDirectory, commandsDirectory, commandsDoneDirectory, resultsDirectory, claimsDirectory, doneDirectory, staleDirectory] {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 里面有剧本全文：只有本人能读
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    /// 开启时清理上次运行遗留的：请求（等它的任务早没了）挪进 stale/，没人要的回答删掉；done / stale / results 里超过 3 天的删掉
    private func sweepLeftovers() {
        for file in (try? fm.contentsOfDirectory(at: requestsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            move(file, into: staleDirectory)
        }
        for directory in [responsesDirectory, claimsDirectory] {
            for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: file)
            }
        }
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        for directory in [staleDirectory, resultsDirectory, commandsDoneDirectory, workDirectory,
                          doneDirectory.appendingPathComponent("requests", isDirectory: true),
                          doneDirectory.appendingPathComponent("responses", isDirectory: true)] {
            for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where modified(file) < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
