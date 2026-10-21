import Foundation
import Observation

// MARK: - 任务中心（2026-10-06 P2）
//
// 视频、生图、剧本 AI 三种任务进同一个中心：
// - **不限同时数量**（2026-10-06 用户定：渠道不限并发，提交多少就同时发多少）。
//   剧本 AI 每集一次一个（PipelineFlow 本来就按集串行，推理分镜要承接上一段站位）。
// - **记录**：`jobs.json` 只放「还没提交出去的视频（占位）」和「剧本 AI 任务」；
//   已提交的视频在各段的视频版本里（project.json），生图状态在生图卡片上 —— 不重复存。
// - **重启**：排队中的视频 / 生图接着排；生成中的生图判失败（不自动重试，避免重复扣费）；
//   剧本 AI 标「已中断」，已完成的结果都在项目里。
//
// 列表显示（任务抽屉）由 `JobDrawerView` 把三处合起来；这里只管排队与记录。

struct JobRecord: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case video, ai }
    enum State: String, Codable, Sendable {
        case waiting, running, completed, failed, stopped, interrupted
        var isActive: Bool { self == .waiting || self == .running }
    }

    /// 视频：占位任务 ID（`pending-…`）；剧本 AI：随机 ID
    var id: String
    var kind: Kind
    var projectKey: String
    /// 「推理分镜」「生成视频」…
    var title: String
    var shotID: UUID?
    var episodeID: UUID?
    /// 不挂在某一集上、同一项目里可以同时有好几个的剧本 AI 任务（提取素材的三路、推理分镜）：停止时靠它找到任务
    var slot: String?
    /// 视频：提交用的渠道名
    var channel: String?
    var state: State
    var note: String?
    var createdAt: Date
    var updatedAt: Date
}

@MainActor
@Observable
final class JobCenter {
    /// 推理分镜整批那一行（不挂在某一集上、槽位 `infer`）：每一集有自己的一行（「停止」在那里、能停整批；
    /// 结果、失败原因也在那里），整批那一行就不显示、也不计数了，免得同一件事出现两次
    /// （2026-10-10 用户看到抽屉里「第 8 集」+「整部剧本」两条，左栏任务角标也是 2）。
    /// 只有这一批真的建过每一集的行才藏；旧版本留下的整批行（没有每一集的行）照常显示，里面有失败原因
    nonisolated static func hidesBatchDriver(_ record: JobRecord, among records: [JobRecord]) -> Bool {
        guard record.kind == .ai, record.slot == "infer", record.episodeID == nil else { return false }
        return records.contains {
            $0.kind == .ai && $0.projectKey == record.projectKey && $0.slot == "infer" && $0.episodeID != nil
                && $0.createdAt >= record.createdAt && (record.state.isActive || $0.createdAt <= record.updatedAt)
        }
    }

    /// 完成的任务在抽屉里留多久（2026-10-06 用户定：最近 7 天或最近 200 条）
    nonisolated static let keepDays: Double = 7
    nonisolated static let keepCount = 200

    private(set) var records: [JobRecord] = []
    /// 正在生成的生图卡片
    private(set) var imageRunning: Set<UUID> = []
    /// 正在提交的视频占位（请求还没回来）
    private(set) var videoSubmitting: Set<String> = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var imageTasks: [UUID: Task<Void, Never>] = [:]
    /// 这一轮生图（队列没清空之前）已经结束了几张，清空时一起提醒
    @ObservationIgnored private var imageFinishedSinceIdle = 0
    @ObservationIgnored private var saveWork: Task<Void, Never>?

    // 由 AppModel 接上
    @ObservationIgnored var startVideo: (_ placeholderID: String, _ shotID: UUID) -> Void = { _, _ in }
    @ObservationIgnored var runImage: (_ itemID: UUID) async -> Void = { _ in }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: 读写

    /// 读 jobs.json。上次退出时还在跑的剧本 AI → 已中断（结果已经存进项目，不会丢）。
    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? Self.decoder.decode([JobRecord].self, from: data) else { return }
        records = Self.afterRestart(decoded, now: Date())
    }

    nonisolated static func afterRestart(_ records: [JobRecord], now: Date) -> [JobRecord] {
        records.map { r in
            var r = r
            if r.kind == .ai, r.state.isActive {
                r.state = .interrupted
                r.note = "应用退出时中断；已完成的结果都保留，回到剧本页重新点这一步即可接着做"
                r.updatedAt = now
            }
            if r.kind == .video, r.state == .running {
                // 提交请求随进程消失，没拿到任务号 → 回到排队，重新提交（之前没提交成功，不会重复扣费）
                r.state = .waiting
            }
            return r
        }
    }

    /// 抽屉里留哪些：进行中的全留；结束的只留最近 7 天，且总数不超过 200
    nonisolated static func retained(_ records: [JobRecord], now: Date) -> [JobRecord] {
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        let active = records.filter { $0.state.isActive }
        let finished = records.filter { !$0.state.isActive && $0.updatedAt >= cutoff }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, keepCount - active.count))
        return (active + finished).sorted { $0.createdAt < $1.createdAt }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        saveWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveWork?.cancel()
        saveWork = nil
        records = Self.retained(records, now: Date())
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.write("jobs", "保存任务记录失败：\(error.localizedDescription)")
        }
    }

    private func upsert(_ record: JobRecord) {
        if let i = records.firstIndex(where: { $0.id == record.id }) { records[i] = record } else { records.append(record) }
        scheduleSave()
    }

    func removeRecord(id: String) {
        streamBoxes[id] = nil
        records.removeAll { $0.id == id }
        scheduleSave()
    }

    func removeRecords(projectKey: String) {
        for record in records where record.projectKey == projectKey { streamBoxes[record.id] = nil }
        records.removeAll { $0.projectKey == projectKey }
        scheduleSave()
    }

    // MARK: 视频排队

    /// 视频进任务中心并立刻提交（记录先落盘：提交途中退出，下次启动接着提交）
    func enqueueVideo(placeholderID: String, shotID: UUID, projectKey: String, channel: String) {
        let now = Date()
        upsert(JobRecord(id: placeholderID, kind: .video, projectKey: projectKey, title: "生成视频",
                         shotID: shotID, channel: channel, state: .waiting, createdAt: now, updatedAt: now))
        pumpVideos()
    }

    /// 提交结束：成功就删掉占位记录（任务已在视频版本里），失败留着给抽屉显示
    func videoSubmitFinished(placeholderID: String, error: String?) {
        videoSubmitting.remove(placeholderID)
        if let error, var r = records.first(where: { $0.id == placeholderID }) {
            r.state = .failed
            r.note = error
            r.updatedAt = Date()
            upsert(r)
        } else {
            removeRecord(id: placeholderID)
        }
        pumpVideos()
    }

    func cancelWaitingVideo(placeholderID: String) {
        guard let r = records.first(where: { $0.id == placeholderID }), r.state == .waiting else { return }
        removeRecord(id: placeholderID)
    }

    var waitingVideos: [JobRecord] {
        records.filter { $0.kind == .video && $0.state == .waiting }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 提交所有还没提交的视频（新进来的、上次退出时没提交完的）
    func pumpVideos() {
        for record in waitingVideos where !videoSubmitting.contains(record.id) {
            guard let shotID = record.shotID else { continue }
            videoSubmitting.insert(record.id)
            var running = record
            running.state = .running
            running.updatedAt = Date()
            upsert(running)
            startVideo(record.id, shotID)
        }
    }

    // MARK: 生图

    /// 开始生图（不限同时数量）；记下运行中的请求，停止时可以取消
    func enqueueImage(_ itemID: UUID) {
        guard !imageRunning.contains(itemID) else { return }
        imageRunning.insert(itemID)
        imageTasks[itemID] = Task { [weak self] in
            await self?.runImage(itemID)
            guard let self else { return }
            imageRunning.remove(itemID)
            imageTasks[itemID] = nil
            // 这一轮生图全部结束（队列清空）：软件不在前台就提醒一下
            imageFinishedSinceIdle += 1
            if imageRunning.isEmpty {
                AppAttention.notify(title: "生图完成", body: "\(imageFinishedSinceIdle) 张")
                imageFinishedSinceIdle = 0
            }
        }
    }

    /// 停止生图：取消请求（中转站可能已经在生成，仍可能扣费）
    func stopImage(_ itemID: UUID) {
        imageTasks[itemID]?.cancel()
    }

    // MARK: 剧本 AI 记录

    func aiStarted(projectKey: String, episodeID: UUID?, title: String, slot: String? = nil) -> String {
        let now = Date()
        let id = "ai-\(UUID().uuidString)"
        upsert(JobRecord(id: id, kind: .ai, projectKey: projectKey, title: title, episodeID: episodeID, slot: slot,
                         state: .running, createdAt: now, updatedAt: now))
        return id
    }

    /// 跑着的剧本 AI 任务的进度说明（任务抽屉里那一行小字；外部智能体接力用它写「等待外部智能体回答…」）。
    /// 只改说明，不动状态；任务已经结束就不管。
    func aiProgress(_ id: String, note: String?) {
        guard let r = records.first(where: { $0.id == id }), r.state.isActive, r.note != note else { return }
        var updated = r
        updated.note = note
        upsert(updated)
    }

    // MARK: 流式接收的实时进度（2026-10-11）：只在内存里，不存盘

    /// 任务 ID → 它的进度盒子。一个任务可能同时有好几个请求（比如提取素材分批并发），都在盒子里。
    /// 每个任务一个盒子、盒子自己被观察：这个任务的进度变了，只有它那一行重画。
    /// （原来所有任务共用一张表，任何一路变了，所有进行中的行都跟着重画。）盒子的增减不用被观察——行用到时现建
    @ObservationIgnored private var streamBoxes: [String: AIStreamBox] = [:]

    @Observable
    final class AIStreamBox {
        var parts: [UUID: AIStreamPart] = [:]
    }

    struct AIStreamPart: Equatable {
        var progress: AIStreamProgress
        var startedAt: Date
        var updatedAt: Date
    }

    /// 抽屉里这一行的进度汇总
    struct AIStreamSummary: Equatable {
        var requests: Int
        var waiting: Int
        var thinking: Int
        var writing: Int
        var reasoningChars: Int
        var contentChars: Int
        /// 最早的那个请求发出的时间（算「已用时」）
        var startedAt: Date
        /// 最近有动静的那个请求的内容（「看过程」里显示它）
        var latest: AIStreamProgress

        /// 第一行的前半：现在在干什么。短，不随字数变长（行高要稳，见 `AIStreamStatus`）
        var headline: String {
            if requests > 1 { return "\(requests) 个请求同时进行" }
            switch latest.phase {
            case .waiting: return "已发出请求，等待回答"
            case .thinking: return "思考中"
            case .writing: return "输出中"
            }
        }

        /// 第二行：字数。几路同时进行时多一段各阶段各几路
        var detail: String {
            if requests > 1 {
                let phases = [("等待", waiting), ("思考", thinking), ("输出", writing)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                return "\(phases) · 已想 \(reasoningChars) 字、已写 \(contentChars) 字"
            }
            switch latest.phase {
            case .waiting: return "还没有收到内容"
            case .thinking: return "已想 \(reasoningChars) 字"
            case .writing: return "已写 \(contentChars) 字" + (reasoningChars > 0 ? "（想了 \(reasoningChars) 字）" : "")
            }
        }

        /// 一句话：「思考中 · 已想 3200 字」「输出中 · 已写 800 字（想了 3200 字）」「3 个请求同时进行：思考 2 · 输出 1」
        var statusText: String {
            if requests > 1 {
                let phases = [("等待", waiting), ("思考", thinking), ("输出", writing)].filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                return "\(requests) 个请求同时进行：\(phases) · 已想 \(reasoningChars) 字、已写 \(contentChars) 字"
            }
            switch latest.phase {
            case .waiting: return "已发出请求，等待回答"
            case .thinking: return "思考中 · 已想 \(reasoningChars) 字"
            case .writing: return "输出中 · 已写 \(contentChars) 字" + (reasoningChars > 0 ? "（想了 \(reasoningChars) 字）" : "")
            }
        }
    }

    /// 一个请求有新进度了。任务已经结束就不收（晚到的进度不能把刚清掉的又写回来）
    func aiStream(_ id: String, request: UUID, progress: AIStreamProgress) {
        guard let box = streamBox(for: id) else { return }
        let now = Date()
        box.parts[request] = AIStreamPart(progress: progress, startedAt: box.parts[request]?.startedAt ?? now, updatedAt: now)
    }

    /// 这个请求收完了（成功、失败、被停都算）
    func aiStreamEnded(_ id: String, request: UUID) {
        guard let box = streamBoxes[id], box.parts[request] != nil else { return }
        box.parts[request] = nil
    }

    /// 这个任务的盒子；任务已经结束（或不存在）就没有，晚到的进度不能把刚清掉的又写回来
    private func streamBox(for id: String) -> AIStreamBox? {
        if let box = streamBoxes[id] { return box }
        guard records.first(where: { $0.id == id })?.state.isActive == true else { return nil }
        let box = AIStreamBox()
        streamBoxes[id] = box
        return box
    }

    func streamSummary(for id: String) -> AIStreamSummary? {
        guard let parts = streamBox(for: id)?.parts.values, !parts.isEmpty, let latest = parts.max(by: { $0.updatedAt < $1.updatedAt }),
              let first = parts.map(\.startedAt).min() else { return nil }
        func count(_ phase: AIStreamProgress.Phase) -> Int { parts.filter { $0.progress.phase == phase }.count }
        return AIStreamSummary(requests: parts.count, waiting: count(.waiting), thinking: count(.thinking), writing: count(.writing),
                               reasoningChars: parts.reduce(0) { $0 + $1.progress.reasoningChars },
                               contentChars: parts.reduce(0) { $0 + $1.progress.contentChars },
                               startedAt: first, latest: latest.progress)
    }

    /// 任务排队了（批量分割名额满了）：抽屉里显示「排队中」和原因
    func aiQueued(_ id: String, note: String) {
        guard var r = records.first(where: { $0.id == id }), r.state.isActive else { return }
        r.state = .waiting
        r.note = note
        r.updatedAt = Date()
        upsert(r)
    }

    /// 轮到了：从「排队中」变回进行中
    func aiRunning(_ id: String) {
        guard var r = records.first(where: { $0.id == id }), r.state == .waiting else { return }
        r.state = .running
        r.note = nil
        r.updatedAt = Date()
        upsert(r)
    }

    func aiFinished(_ id: String, state: JobRecord.State, note: String?) {
        streamBoxes[id]?.parts = [:]
        streamBoxes[id] = nil
        guard var r = records.first(where: { $0.id == id }) else { return }
        r.state = state
        r.note = note
        r.updatedAt = Date()
        upsert(r)
    }

    // MARK: 编码

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    nonisolated private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// 流式接收的进度要写进哪个任务中心（`SimplePipeline.chat` 在界面外的任务里发请求，够不到 AppModel）
@MainActor
enum AIStreamHub {
    static weak var jobCenter: JobCenter?
}
