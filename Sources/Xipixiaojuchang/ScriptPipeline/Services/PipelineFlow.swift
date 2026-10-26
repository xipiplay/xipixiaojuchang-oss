import SwiftUI

enum PipelineFlowStage: String, Sendable {
    case script = "剧本分集", duration = "时长分割", naming = "分段命名", assets = "提取素材", storyboard = "推理分镜"
}

/// 任务状态不依附页面，切换导航或项目不丢失进度，不阻塞窗口。
@MainActor @Observable
final class PipelineFlow {
    struct Job: Equatable {
        var stage: PipelineFlowStage
        var source: PipelineFlowStage? = nil
        var note: String
        var active: Bool
        /// 这次运行出错结束（取消和成功都不算）。一键推进的「重做」靠它判断这一步到底成没成功
        var failed = false
    }
    private(set) var jobs: [String: Job] = [:]

    /// 批量操作（批量分割 / 提取素材）在一个项目里的进度，显示在软件右上角（项目名那一行的右边）：
    /// 跑的时候「批量分割 12/60」，跑完分割显示「成功几集、失败几集」，提取显示「新建几张卡片」。
    struct BatchState: Equatable {
        enum Kind: Equatable { case split, extract, infer, naming, voice }
        /// `label`：失败的是谁（「第 2 集」/「场景」）；`order`：排序用（集号 / 角色场景道具的顺序）
        struct Failure: Equatable { var order: Int; var label: String; var message: String }
        var kind: Kind
        var title: String
        var total: Int
        var succeeded = 0
        var failures: [Failure] = []
        /// 提取素材 / 推理分镜：已经建出来（或重推时更新）的卡片数
        var created = 0
        /// 提取音色：跟着更新了【音色】行的分镜段数
        var shotsUpdated = 0
        /// 推理分镜是一集一集串行跑的，停在某一集（失败 / 停止）之后没轮到的集数
        var skipped = 0
        /// 提取素材：不算失败、但值得让人知道的提醒（卡名和分镜头行的名字对不上、名单里有名字没提取出来…）
        var notes: [String] = []
        var completed: Int { succeeded + failures.count }
        var finished: Bool { completed + skipped >= total }
    }
    private(set) var batches: [String: BatchState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokens: [String: UUID] = [:]
    /// 任务中心：每次运行记一条，任务抽屉里能看到、能停止（2026-10-06 P2）
    @ObservationIgnored weak var jobCenter: JobCenter?

    static func key(_ project: String, _ episode: UUID?) -> String { project + "/" + (episode?.uuidString ?? "script") }
    static func slotKey(_ project: String, _ slot: String) -> String { project + "/" + slot }
    func active(project: String, episode: UUID?) -> Bool { jobs[Self.key(project, episode)]?.active == true }
    func active(project: String, slot: String) -> Bool { jobs[Self.slotKey(project, slot)]?.active == true }
    func glowing(_ stage: PipelineFlowStage, project: String) -> Bool {
        jobs.contains { $0.key.hasPrefix(project + "/") && $0.value.active && ($0.value.stage == stage || $0.value.source == stage) }
    }
    func waitForJob(project: String, episode: UUID?) async { await tasks[Self.key(project, episode)]?.value }
    /// 等这个项目里所有在跑的任务（含提取素材那三路）都结束
    func waitForAll(project: String) async {
        for task in tasks.filter({ $0.key.hasPrefix(project + "/") }).map(\.value) { await task.value }
    }

    /// 清掉已经结束的旧记录（一键推进每步开始前调用，免得把上一次的失败当成这一次的结果）。正在跑的不动
    func clearFinished(project: String, episode: UUID?) {
        let key = Self.key(project, episode)
        if jobs[key]?.active != true { jobs[key] = nil }
    }

    func cancel(project: String, episode: UUID?, slot: String? = nil) {
        let key = slot.map { Self.slotKey(project, $0) } ?? Self.key(project, episode)
        tasks[key]?.cancel()
        tasks[key] = nil
        tokens[key] = nil
        if var job = jobs[key] { job.active = false; job.note = "已停止，已完成的结果保留"; jobs[key] = job }
    }

    /// 停掉一个项目里所有在跑的 AI 任务（外部命令的「stop」用）；已完成的结果保留
    func cancelAll(project: String) {
        let prefix = project + "/"
        for key in Array(tasks.keys) where key.hasPrefix(prefix) {
            tasks[key]?.cancel()
            tasks[key] = nil
            tokens[key] = nil
            if var job = jobs[key] { job.active = false; job.note = "已停止，已完成的结果保留"; jobs[key] = job }
        }
    }

    /// `onFinish`：这一轮结束时调用，nil = 成功，否则是失败 / 停止的原因。返回 false = 这一集正在做别的步骤，没有开始。
    @discardableResult
    private func start(project: String, episode: UUID?, stage: PipelineFlowStage, source: PipelineFlowStage? = nil,
                       slot: String? = nil, title: String? = nil,
                       onFinish: (@MainActor (String?) -> Void)? = nil,
                       operation: @escaping @MainActor () async throws -> Void) -> Bool {
        // slot：同一个项目里要并发跑好几个不挂在某一集上的任务时（提取素材的 角色 / 场景 / 道具），各用一个槽位
        let key = slot.map { Self.slotKey(project, $0) } ?? Self.key(project, episode)
        let title = title ?? stage.rawValue
        guard jobs[key]?.active != true else { return false }
        DropdownPanel.shared.dismiss()
        jobs[key] = Job(stage: stage, source: source, note: "正在\(title)…", active: true)
        let token = UUID()
        tokens[key] = token
        let record = jobCenter?.aiStarted(projectKey: project, episodeID: episode, title: title, slot: slot)
        // 外部智能体接力：这个任务里发出的 AI 请求带上「哪个项目 / 哪一集 / 哪一步」（见 `AgentRequestContext`）
        let context = AgentRequestContext(project: project, episode: episode, title: title, aiRecordID: record)
        tasks[key] = AgentRequestContext.$current.withValue(context) { Task { @MainActor in
            do {
                try await operation()
                try Task.checkCancellation()
                if let record { jobCenter?.aiFinished(record, state: .completed, note: nil) }
                onFinish?(nil)
                guard tokens[key] == token else { return }
                jobs[key] = Job(stage: stage, note: "\(title)完成", active: false)
            } catch where error is CancellationError || Task.isCancelled {
                // 网络请求被取消时抛的是 URLError(.cancelled)，不是 CancellationError：任务已被取消就一律算「已停止」
                if let record { jobCenter?.aiFinished(record, state: .stopped, note: "已停止，已完成的结果保留") }
                onFinish?("已停止")
                guard tokens[key] == token else { return }
                jobs[key] = Job(stage: stage, note: "已停止，已完成的结果保留", active: false)
            } catch {
                if let record { jobCenter?.aiFinished(record, state: .failed, note: error.localizedDescription) }
                onFinish?(error.localizedDescription)
                guard tokens[key] == token else { return }
                jobs[key] = Job(stage: stage, note: error.localizedDescription, active: false, failed: true)
            }
            tasks[key] = nil
            tokens[key] = nil
        } }
        return true
    }

    // MARK: 批量分割（2026-10-07）

    /// 批量分割同时最多发几集的**默认值**：选了更多集，多出来的在任务抽屉里显示「排队中」，前面有一集做完才轮到。
    /// 2026-10-11 先定 10；当天 NVIDIA（40 次/分钟）一次放出 10 个就被回了一串 429，用户改保守成 5。
    /// 2026-10-12 起可以在设置里每张服务商卡片上改（`PipelineAISettings.concurrency`），没改过就是这个
    static let splitConcurrency = PipelineAISettings.defaultConcurrency

    /// 对选中的几集跑「分割（时长）」，**同时最多 `splitConcurrency` 集**：每集把原文发给 AI，返回的文字存成这一集的 `splitText`（原文不动）。
    /// 每集各自一个后台任务（任务抽屉里能看到、失败原因在里面）；整体进度记在 `batches[project]`。
    /// `episodeIndices`：0 起的集序号。上一轮批量还没跑完时不再开新的一轮。
    /// `note`：这一次手写的补充要求（见 `RerunNote`）——比如「把第 2 段和第 3 段合并」，AI 重分这一集，整集的分段都被新结果覆盖
    /// `concurrency`：同时最多几集；nil = 用当前服务商卡片上设的「同时请求数」
    func batchSplit(app: AppModel, project: String, episodeIndices: [Int], note: String = "", chat: SimplePipeline.Chat? = nil,
                    concurrency: Int? = nil) {
        guard let snapshot = app.pipelineArchive(for: project) else { return }
        if let running = batches[project], !running.finished { return }
        let targets = episodeIndices.filter { snapshot.episodes.indices.contains($0) }
        guard !targets.isEmpty else { return }
        batches[project] = BatchState(kind: .split, title: "批量分割", total: targets.count)
        let config = PipelineAISettingsStore.load().config
        let request = chat ?? SimplePipeline.chat(config: config)
        let limit = concurrency ?? config.requestConcurrency
        let gate = AsyncGate(limit: limit)
        for index in targets {
            let episode = snapshot.episodes[index]
            let number = index + 1
            let started = start(project: project, episode: episode.id, stage: .duration,
                                onFinish: { [weak self] message in
                                    self?.recordBatch(project: project, order: number, label: "第 \(number) 集", failure: message)
                                }) {
                // 名额满了：这一集先排队（抽屉里是「排队中」），有一集做完再轮到；排队时点「停止」直接退出排队
                let recordID = AgentRequestContext.current?.aiRecordID
                if await !gate.tryAcquire() {
                    if let recordID { self.jobCenter?.aiQueued(recordID, note: "排队中：同时最多 \(limit) 集在跑，前面有一集做完就轮到") }
                    try await gate.acquire()
                    if let recordID { self.jobCenter?.aiRunning(recordID) }
                }
                do {
                    let output = try await SimplePipeline.splitText(episode: episode, note: note, chat: request)
                    guard var latest = app.pipelineArchive(for: project),
                          let i = latest.episodes.firstIndex(where: { $0.id == episode.id }) else {
                        throw PipelineAIError.invalidResult("这一集已经不在了")
                    }
                    latest.episodes[i].splitText = output
                    try self.save(latest, app: app, project: project)
                    await gate.release()
                } catch {
                    await gate.release()
                    throw error
                }
            }
            if !started { recordBatch(project: project, order: number, label: "第 \(number) 集", failure: "这一集正在做别的步骤，没有开始") }
        }
    }

    // MARK: 分段命名（2026-10-11）

    /// 给选中的几集写每一段的【场景】【角色】【道具】【本段在场】（见 `SegmentNaming`）。
    /// **一集一集串行**：每一集都带着前面各集已经用过的名字，同一个对象沿用同一个写法（并行就看不到彼此）。
    /// 还没有分割的集跳过不算（失败里写明）；已经推理过分镜的集名字会变，分镜要重新推理才跟得上（面板里提醒）。
    /// 一集失败（回复读不出来 / 段数对不上）就停在那里，没轮到的记为「未跑」，已经写好的集保留。
    func batchName(app: AppModel, project: String, episodeIndices: [Int], note: String = "", chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project) else { return }
        if let running = batches[project], !running.finished { return }
        let targets = Array(Set(episodeIndices.filter { snapshot.episodes.indices.contains($0) })).sorted()
        guard !targets.isEmpty else { return }
        batches[project] = BatchState(kind: .naming, title: "分段命名", total: targets.count)
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config)
        let slot = "name"
        let started = start(project: project, episode: nil, stage: .naming, slot: slot, title: "分段命名") {
            for (position, index) in targets.enumerated() {
                let number = index + 1
                self.jobs[Self.slotKey(project, slot)]?.note = "正在给第 \(number) 集的各段命名（\(position + 1)/\(targets.count)）"
                let episodeRecord = self.jobCenter?.aiStarted(projectKey: project, episodeID: snapshot.episodes[index].id, title: "分段命名", slot: slot)
                do {
                    try await self.nameEpisode(app: app, project: project, index: index, note: note, chat: request, recordID: episodeRecord)
                    if let episodeRecord { self.jobCenter?.aiFinished(episodeRecord, state: .completed, note: nil) }
                    guard var state = self.batches[project] else { continue }
                    state.succeeded += 1
                    self.batches[project] = state
                } catch {
                    let stopped = error is CancellationError || Task.isCancelled
                    if let episodeRecord {
                        self.jobCenter?.aiFinished(episodeRecord, state: stopped ? .stopped : .failed,
                                                   note: stopped ? "已停止，已完成的结果保留" : error.localizedDescription)
                    }
                    guard var state = self.batches[project] else { throw error }
                    state.failures.append(.init(order: number, label: "第 \(number) 集", message: stopped ? "已停止" : error.localizedDescription))
                    state.skipped = targets.count - position - 1
                    self.batches[project] = state
                    throw stopped ? CancellationError() : error
                }
            }
        }
        if !started { batches[project] = nil }
    }

    /// 命名一集：读这一集的分割文本和原文，加上前面各集的名字，AI 返回每段的头行，写回分割文本。出错一律不动这一集
    private func nameEpisode(app: AppModel, project: String, index: Int, note: String, chat: SimplePipeline.Chat,
                             recordID: String? = nil) async throws {
        guard let archive = app.pipelineArchive(for: project), archive.episodes.indices.contains(index) else {
            throw SegmentNaming.Failure("这一集已经不在了")
        }
        let episode = archive.episodes[index]
        guard let split = episode.splitText, !split.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !SplitSegments.parse(split).isEmpty else {
            throw SegmentNaming.Failure("这一集还没有时长分割（或分割里没有时间标号），先点「分割」")
        }
        let expected = SplitSegments.parse(split).count
        let names = SegmentNaming.existingNames(in: archive.episodes, before: index)
        var context = AgentRequestContext.current ?? AgentRequestContext(project: project, title: "分段命名")
        context.episodeNumber = index + 1
        if let recordID { context.aiRecordID = recordID }
        let raw = try await AgentRequestContext.$current.withValue(context) {
            try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.namingPrompt),
                           SegmentNaming.userMessage(episode: episode, names: names, note: note))
        }
        try Task.checkCancellation()
        let heads = try SegmentNaming.parse(raw, expected: expected)
        guard var latest = app.pipelineArchive(for: project),
              let i = latest.episodes.firstIndex(where: { $0.id == episode.id }) else {
            throw SegmentNaming.Failure("这一集已经不在了")
        }
        // 命名期间这一集的分割被改了（手改 / 重新分割）：段数对不上就不写，免得名字错位
        guard let merged = SegmentNaming.merge(heads, into: latest.episodes[i].splitText ?? "") else {
            throw SegmentNaming.Failure("命名期间这一集的分割变了（段数对不上），没有写入，请重试")
        }
        latest.episodes[i].splitText = merged
        try self.save(latest, app: app, project: project)
    }

    private func recordBatch(project: String, order: Int, label: String, failure: String?) {
        guard var state = batches[project] else { return }
        if let failure { state.failures.append(.init(order: order, label: label, message: failure)) } else { state.succeeded += 1 }
        batches[project] = state
        if state.finished {
            AppAttention.notify(title: "\(state.title)完成",
                                body: "成功 \(state.succeeded)/\(state.total)" + (state.failures.isEmpty ? "" : "，失败 \(state.failures.count)"),
                                failed: !state.failures.isEmpty)
        }
    }

    // MARK: 提取素材（2026-10-07）

    /// 提取素材的三类：场景提取 / 角色提取 / 道具提取，各自一个按钮（生图页右上角），按钮顺序也是这个
    enum ExtractionKind: String, CaseIterable, Identifiable, Sendable {
        case scene = "场景", role = "角色", prop = "道具"
        var id: String { rawValue }
        var buttonTitle: String { rawValue + "提取" }
        /// 提取出来的卡片在生图页的类型
        var subjectType: ImageSubjectType {
            switch self {
            case .scene: .scene
            case .role: .character
            case .prop: .prop
            }
        }
        var icon: String {
            switch self {
            case .scene: "mountain.2"
            case .role: "person"
            case .prop: "cube"
            }
        }
        /// 设置里对应的那条提示词（保存了自己的文字就用自己的，没有用内置默认）
        @MainActor var prompt: String {
            switch self {
            case .scene: PipelinePromptStore.scenePrompt
            case .role: PipelinePromptStore.rolePrompt
            case .prop: PipelinePromptStore.propPrompt
            }
        }
    }

    /// 选中的集里还没有推理分镜（一张分镜卡都没有）的，0 起的集序号，升序。
    /// 提取的名字取自分镜头行（2026-10-09 起），所以要先推理分镜。项目没分集时没有「分镜」可言，返回空。
    static func episodesMissingStoryboard(app: AppModel, project: String, archive: ProjectPipelineArchive, episodeIndices: [Int]) -> [Int] {
        guard !archive.episodes.isEmpty else { return [] }
        let prompts = storyboardPrompts(app: app, project: project, archive: archive)
        return Set(episodeIndices).filter { archive.episodes.indices.contains($0) }.sorted().filter { index in
            !(prompts[index] ?? []).contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// 每一集（0 起）各段分镜卡现在的提示词，按段序；卡被删了的那一段是空串（段号不错位）
    static func storyboardPrompts(app: AppModel, project: String, archive: ProjectPipelineArchive) -> [Int: [String]] {
        let byID = Dictionary(app.shots.filter { $0.projectKey == project }.map { ($0.id, $0.prompt) }, uniquingKeysWith: { first, _ in first })
        return Dictionary(uniqueKeysWithValues: archive.episodes.enumerated().map { index, episode in
            (index, (episode.shotIDs ?? []).map { byID[$0] ?? "" })
        })
    }

    /// 提取对账（2026-10-17）带上的「已有素材」：这个项目里**这一类全部卡**。
    /// 原来只带早于本次范围的：本次范围内 / 之后建过什么 AI 看不到，重复提取同一批也看不见自己建过什么，只能再长一张卡。
    /// 现在全带上，配合「沿用：名字」协议和软件侧对账，重复提取 = 幂等。
    /// - 只要这一类、有真名字的卡（「图片 7」这种占位名不要）；
    static func existingCards(kind: ExtractionKind, items: [ImageGenItem], project: String) -> [StoryboardNames.Existing] {
        items.filter { $0.projectKey == project && $0.type == kind.subjectType
                && ImageCardNaming.placeholderNumber(of: $0.name) == nil
                && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }.map { card in
            // 名册里写「沈惊澜（第1集起）」：名字只写基础名，版本写在括号里（2026-10-14 名字与形态分离第 2 步）
            let written = card.versionNote.map { "\(card.baseName)（\($0)）" } ?? card.baseName
            return StoryboardNames.Existing(base: StageName.compose(card.baseName, stage: card.stage), line: "\(written)：\(rosterCore(of: card.prompt))")
        }
    }

    static func existingRoster(kind: ExtractionKind, items: [ImageGenItem], project: String) -> [String] {
        existingCards(kind: kind, items: items, project: project).map(\.line)
    }

    /// 卡片提示词里的核心描述：「电影写实风格」之前的部分（后面是每张卡都一样的固定后缀，不带）；没有这个词就取前 300 字
    static func rosterCore(of prompt: String) -> String {
        let flat = prompt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var core = Substring(flat)
        if let r = flat.range(of: "电影写实风格"), r.lowerBound > flat.startIndex { core = flat[..<r.lowerBound] }
        let trimmed = String(core.prefix(400)).trimmingCharacters(in: CharacterSet(charactersIn: " “\"「。，,；;"))
        return trimmed.isEmpty ? String(flat.prefix(300)) : trimmed
    }

    /// 一次提取要发的请求（2026-10-09）：名字取自分镜头行，描述去原文（角色、道具）/ 分镜（场景）里找。
    /// 名字多、证据长就分成几批，每批一个请求（见 `StoryboardNames` 的上限）；没分集的项目读整篇剧本、一个请求。
    struct ExtractionPlan {
        var messages: [String]
        /// 分镜头行里这一类的名字；没分集的项目没有，为空
        var entries: [StoryboardNames.Entry]
        /// 前面各集已经有卡的名字（基础名）
        var existing: Set<String>
        /// 没分集的项目：分镜头行无从谈起，读整篇剧本
        var wholeScript: Bool
    }

    /// `names`：只提取这几个名字（头行里的名字）；nil = 选中各集头行里这一类的全部名字。
    /// 想补一个漏掉的、重提某一个（比如「周承山」年轻时的样子）时用——不用把整集这一类的名字都重新提取一遍。
    static func extractionPlan(app: AppModel, project: String, archive: ProjectPipelineArchive, kind: ExtractionKind,
                               episodeIndices: [Int], names: Set<String>? = nil) -> ExtractionPlan {
        guard !archive.episodes.isEmpty else {
            return ExtractionPlan(messages: [archive.wholeScript.trimmingCharacters(in: .whitespacesAndNewlines)],
                                  entries: [], existing: [], wholeScript: true)
        }
        let selected = Set(episodeIndices).filter { archive.episodes.indices.contains($0) }.sorted()
        let allEntries = extractionEntries(app: app, project: project, archive: archive, kind: kind, episodeIndices: selected)
        let entries = names.map { wanted in allEntries.filter { wanted.contains($0.name) } } ?? allEntries
        let existing = existingCards(kind: kind, items: app.imageItems, project: project)
        let texts = selected.map { (episode: $0 + 1, text: archive.episodes[$0].text) }
        let batches = kind == .scene ? StoryboardNames.sceneBatches(entries) : StoryboardNames.nameBatches(entries)
        let messages = batches.map { batch in
            StoryboardNames.message(kind: kind, entries: batch, existing: existing,
                                    source: kind == .scene ? "" : StoryboardNames.source(episodes: texts, for: batch))
        }
        return ExtractionPlan(messages: messages, entries: entries, existing: Set(existing.map(\.base)), wholeScript: false)
    }

    /// 选中各集分镜头行里这一类的名字（按第一次出现的先后）。角色名带上这一段的【阶段】，合成逻辑名「周承山（四十岁）」（见 `StageName`）。
    /// 提取面板列名单和真正提取**用同一份**（2026-10-14：面板原来自己拼、没带阶段，阶段版被当成「已有卡」，也提取不出来）
    static func extractionEntries(app: AppModel, project: String, archive: ProjectPipelineArchive, kind: ExtractionKind,
                                  episodeIndices: [Int]) -> [StoryboardNames.Entry] {
        let selected = Set(episodeIndices).filter { archive.episodes.indices.contains($0) }.sorted()
        let prompts = storyboardPrompts(app: app, project: project, archive: archive)
        // 各段的【阶段】，和 `prompts`（按 shotIDs 的顺序）对齐
        let stages = Dictionary(uniqueKeysWithValues: selected.map { index -> (Int, [[String: String]]) in
            let byShot = SplitSegments.stagesByShot(archive.episodes[index])
            return (index + 1, (archive.episodes[index].shotIDs ?? []).map { byShot[$0] ?? [:] })
        })
        return StoryboardNames.collect(selected.map { (episode: $0 + 1, prompts: prompts[$0] ?? []) }, stages: stages)[kind] ?? []
    }

    /// 同时最多几个提取请求在跑（一类素材分成几批时）
    /// 提取素材每一类同时最多几个请求（服务商卡片上的「同时请求数」设得更大也按这个封顶）
    static let extractionConcurrency = 3

    /// 把几个请求并发做完（最多 `limit` 个同时），结果按输入顺序返回；任何一个失败就整体失败、其余取消
    private static func mapConcurrently(_ inputs: [String], limit: Int,
                                        _ work: @escaping @Sendable (String) async throws -> (raw: String, parsed: [ImagePromptParser.Parsed])) async throws -> [(raw: String, parsed: [ImagePromptParser.Parsed])] {
        var results = [(raw: String, parsed: [ImagePromptParser.Parsed])](repeating: ("", []), count: inputs.count)
        try await withThrowingTaskGroup(of: (Int, (raw: String, parsed: [ImagePromptParser.Parsed])).self) { group in
            var iterator = inputs.enumerated().makeIterator()
            for _ in 0..<min(max(limit, 1), inputs.count) {
                guard let (index, input) = iterator.next() else { break }
                group.addTask { (index, try await work(input)) }
            }
            while let (index, value) = try await group.next() {
                results[index] = value
                if let (next, input) = iterator.next() { group.addTask { (next, try await work(input)) } }
            }
        }
        return results
    }

    /// 「第 3、4 集」；太多就只列前几个
    static func describeEpisodes(_ indices: [Int]) -> String {
        let numbers = indices.map { String($0 + 1) }
        return numbers.count <= 8 ? "第 \(numbers.joined(separator: "、")) 集"
                                  : "第 \(numbers.prefix(8).joined(separator: "、")) 等 \(numbers.count) 集"
    }

    /// 点「场景提取 / 角色提取 / 道具提取」之一（2026-10-09 改：先推理分镜、后提取）。
    /// **名字取自选中各集分镜卡的头行** `[场景][角色][道具]`，AI 只给这些名字写描述：角色、道具去**原文**里找，
    /// 场景去**用到它的分镜**里找（见 `StoryboardNames`）。名字多就分几批（一类素材最多 `extractionConcurrency` 个请求同时跑）。
    /// 输出按生图页的解析规则切开，在生图页追加成卡片（不动已有的卡片）。
    /// 选中的集里有没推理分镜的：整次不跑，任务里写明是哪几集、先去推理分镜。项目没分集时读整篇剧本（没有分镜头行可言）。
    ///
    /// 三个按钮各管一类，可以一个接一个点、同时跑（右上角合在一份进度里）；同一类还在跑时不能再点，
    /// 分割 / 推理分镜在跑时也不开新的一轮。没提取出任何东西（空输出 / 没有可切的块）算新建 0 张，不算失败。
    /// 提取回来的卡名和头行名字对不上（或名单里的名字没人写）不算失败，记进 `notes` 提醒。
    /// `episodeIndices`：0 起的集序号；项目没分集时忽略。`prompt` 给测试用。
    /// `note`：这一次手写的补充要求（见 `RerunNote`），这一类的每个请求都带上
    /// `names`：只提取这几个名字（nil = 这一类的全部名字）。没有写进头行的名字不会被提取
    func batchExtract(app: AppModel, project: String, kind: ExtractionKind, episodeIndices: [Int], note: String = "", names: Set<String>? = nil,
                      prompt: String? = nil, chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project) else { return }
        let slot = "extract-\(kind.rawValue)"
        guard jobs[Self.slotKey(project, slot)]?.active != true else { return }
        if let running = batches[project], !running.finished, running.kind != .extract { return }
        let hasEpisodes = !snapshot.episodes.isEmpty
        if hasEpisodes {
            guard episodeIndices.contains(where: { snapshot.episodes.indices.contains($0) }) else { return }
        } else {
            guard !snapshot.wholeScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        }
        let promptText = prompt ?? kind.prompt
        let missing = Self.episodesMissingStoryboard(app: app, project: project, archive: snapshot, episodeIndices: episodeIndices)
        // 整段 / 整批的输入输出都很长：超时放宽到 15 分钟
        let config = PipelineAISettingsStore.load().config
        let request = chat ?? SimplePipeline.chat(config: config, timeout: 900)
        // 每一类同时几个请求：服务商卡片上的「同时请求数」，但最多 3（名字一批一批发，多了也用不上）
        let extractLimit = min(config.requestConcurrency, Self.extractionConcurrency)
        if var state = batches[project], !state.finished {
            state.total += 1                                    // 前一类还在跑：合进同一份进度
            batches[project] = state
        } else {
            batches[project] = BatchState(kind: .extract, title: "提取素材", total: 1)
        }
        let order = ExtractionKind.allCases.firstIndex(of: kind) ?? 0
        start(project: project, episode: nil, stage: .assets, slot: slot, title: "提取\(kind.rawValue)",
              onFinish: { [weak self] message in
                  self?.recordBatch(project: project, order: order, label: kind.buttonTitle, failure: message)
              }) {
            guard missing.isEmpty else {
                throw StoryboardInference.Failure("\(Self.describeEpisodes(missing))还没有推理分镜，先点工作台底部的「分镜」，再提取\(kind.rawValue)（名字取自分镜头行）")
            }
            let plan = Self.extractionPlan(app: app, project: project, archive: snapshot, kind: kind, episodeIndices: episodeIndices, names: names)
            if plan.messages.isEmpty {
                let reason = names == nil ? "选中的分镜头行里没有\(kind.rawValue)" : "指定的名字不在选中的分镜头行里"
                self.batches[project]?.notes.append("\(kind.rawValue)提取：\(reason)，没有发请求")
                return
            }
            let era = snapshot.eraBackground
            let replies = try await Self.mapConcurrently(plan.messages.map { RerunNote.prefixed(EraBackground.prefixed($0, era: era), note: note) }, limit: extractLimit) { message in
                try await SimplePipeline.extractCardsReply(prompt: promptText, text: message, chat: request)
            }
            try Task.checkCancellation()
            // 「参考：基础名字」那一行（换了名字的变化版才有）：读出来记成关联，从卡片提示词里去掉——它不是给生图模型看的
            let parsedWithReferences = replies.flatMap { $0.parsed }.map { card -> (card: ImagePromptParser.Parsed, reference: String?) in
                let split = ReferenceLinks.splitReferenceLine(card.prompt)
                return (ImagePromptParser.Parsed(type: card.type, name: card.name, prompt: split.prompt), split.name)
            }
            // 提取对账（2026-10-17）：先和项目里已有的全部素材对一遍再决定建什么——沿用不建、同版本槽不重复建、
            // 没声明变化的"新版本"不建（进待确认）。规则见仓库根 `方案-提取对账.md`
            let reused = replies.flatMap { ExtractionReconcile.reusedNames(in: $0.raw) }
            let outcome = ExtractionReconcile.apply(pairs: parsedWithReferences, reused: reused,
                                                    mode: names == nil ? .batch : .refresh,
                                                    kind: kind, listedNames: Set(plan.entries.map(\.name)),
                                                    project: project, app: app)
            self.batches[project]?.created += outcome.created
            self.batches[project]?.notes += outcome.notes
            if !plan.wholeScript {
                // 名字核对（名单里没人写的 / 名单外冒出来的）：按「起始集」「阶段」读成字段之后再比；「沿用」行也算有交代
                let made = parsedWithReferences.map { CardVersion.takeVersionLines($0.card) }
                self.batches[project]?.notes += StoryboardNames.reconcile(kind: kind, entries: plan.entries, existing: plan.existing,
                                                                          parsed: made, reused: reused)
            }
        }
    }

    /// 切到别的项目 / 用户看完结果后，清掉右上角的汇总
    func clearBatch(project: String) {
        if batches[project]?.finished == true { batches[project] = nil }
    }

    // MARK: 推理分镜（2026-10-07）

    /// 一集一集（串行）读「分镜提示词」+ 这一集的「时长分割」，推理出的每个 30 秒段在生视频页建一张卡（分镜 集号-段号）。
    /// 串行的原因：一集的输入输出都很大；而且上一集结尾的站位要带给下一集（同场景时）。
    /// 停在第一个失败 / 被停止的那一集：后面不跑（跳过会让下一集接错上一集），前面已经建好的卡保留。
    /// `note`：这一次手写的补充要求（见 `RerunNote`），每一集的请求都带上
    func batchInfer(app: AppModel, project: String, episodeIndices: [Int], note: String = "", chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project) else { return }
        if let running = batches[project], !running.finished { return }
        let targets = Array(Set(episodeIndices.filter { snapshot.episodes.indices.contains($0) })).sorted()
        guard !targets.isEmpty else { return }
        batches[project] = BatchState(kind: .infer, title: "推理分镜", total: targets.count)
        // 一集的分镜输出很长：超时放宽到 15 分钟
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config, timeout: 900)
        let slot = "infer"
        let started = start(project: project, episode: nil, stage: .storyboard, slot: slot, title: "推理分镜") {
            for (position, index) in targets.enumerated() {
                let number = index + 1
                self.jobs[Self.slotKey(project, slot)]?.note = "正在推理第 \(number) 集（\(position + 1)/\(targets.count)）"
                // 每一集在任务抽屉里单独一行（和批量分割一样；原来整批只有一行「整部剧本」，2026-10-10 用户要求）：
                // 轮到这一集才建，做完标完成 / 失败 / 已停止；整批那一行（上面的）只在跑的时候显示，用来停止
                let episodeRecord = self.jobCenter?.aiStarted(projectKey: project, episodeID: snapshot.episodes[index].id, title: "推理分镜", slot: slot)
                do {
                    let cards = try await self.inferEpisode(app: app, project: project, index: index, note: note, chat: request,
                                                            recordID: episodeRecord)
                    if let episodeRecord { self.jobCenter?.aiFinished(episodeRecord, state: .completed, note: nil) }
                    guard var state = self.batches[project] else { continue }
                    state.succeeded += 1
                    state.created += cards
                    self.batches[project] = state
                } catch {
                    let stopped = error is CancellationError || Task.isCancelled
                    if let episodeRecord {
                        self.jobCenter?.aiFinished(episodeRecord, state: stopped ? .stopped : .failed,
                                                   note: stopped ? "已停止，已完成的结果保留" : error.localizedDescription)
                    }
                    guard var state = self.batches[project] else { throw error }
                    state.failures.append(.init(order: number, label: "第 \(number) 集", message: stopped ? "已停止" : error.localizedDescription))
                    state.skipped = targets.count - position - 1
                    self.batches[project] = state
                    throw stopped ? CancellationError() : error
                }
            }
        }
        if !started { batches[project] = nil }
    }

    /// 推理一集：成功返回这一集的卡片数。出错一律不建卡、不动这一集原来的卡。
    private func inferEpisode(app: AppModel, project: String, index: Int, note: String = "", chat: SimplePipeline.Chat,
                              recordID: String? = nil) async throws -> Int {
        guard let archive = app.pipelineArchive(for: project), archive.episodes.indices.contains(index) else {
            throw StoryboardInference.Failure("这一集已经不在了")
        }
        let episode = archive.episodes[index]
        let splitText = (episode.splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !splitText.isEmpty else { throw StoryboardInference.Failure("这一集还没有时长分割，先点「批量分割」") }
        guard SplitSegments.isNamed(splitText) else {
            throw StoryboardInference.Failure("这一集的各段还没有命名（【场景】【角色】【道具】），先点「命名」")
        }
        // 衔接：上一集最后一张卡现在的提示词（上一集没推理过 / 卡被删了就没有，这一集从头起手）
        let previous = index > 0 ? archive.episodes[index - 1].shotIDs?.last.flatMap { id in
            app.shots.first { $0.id == id && $0.projectKey == project }?.prompt
        } : nil
        let user = RerunNote.prefixed(StoryboardInference.userMessage(splitText: splitText, previousPrompt: previous), note: note)
        var context = AgentRequestContext.current ?? AgentRequestContext(project: project, title: "推理分镜")
        context.episodeNumber = index + 1
        if let recordID { context.aiRecordID = recordID }       // 「外部智能体正在处理…」写在这一集的那一行上
        let raw = try await AgentRequestContext.$current.withValue(context) {
            try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.shotsPrompt), user)
        }
        try Task.checkCancellation()
        let blocks = StoryboardInference.blocks(from: raw)
        guard !blocks.isEmpty else {
            throw StoryboardInference.Failure("AI 的回复里没有识别到分镜（找不到「[场景][角色][道具]」开头的段落），没有建卡，请重试")
        }
        if let expected = StoryboardInference.expectedBlockCount(in: splitText), expected != blocks.count {
            throw StoryboardInference.Failure(StoryboardInference.countMismatchMessage(got: blocks.count, expected: expected))
        }
        guard var latest = app.pipelineArchive(for: project),
              let i = latest.episodes.firstIndex(where: { $0.id == episode.id }) else {
            throw StoryboardInference.Failure("这一集已经不在了")
        }
        let ids = app.writeStoryboardCards(project: project, episodeNumber: i + 1,
                                           existing: latest.episodes[i].shotIDs ?? [],
                                           before: latest.episodes[..<i].flatMap { $0.shotIDs ?? [] },
                                           after: latest.episodes[(i + 1)...].flatMap { $0.shotIDs ?? [] },
                                           prompts: blocks)
        latest.episodes[i].shotIDs = ids
        latest.episodes[i].storyboardSplitSignature = Episode.splitSignature(latest.episodes[i].splitText)   // 之后分割的段落变了就知道对不上
        // 提示词按位置被新的覆盖了：旧的「图N」没了，卡上还挂着的参考图跟着清掉（和单段「重新推理」一样；再点「应用素材」重新挂）
        for id in ids { app.clearImageRefsMissingFromPrompt(id) }
        try self.save(latest, app: app, project: project)
        return ids.count
    }

    /// **重新推理一段**（工作台按段详情里的「重新推理」，2026-10-09）：只把这一段的分割文本发给 AI（带上前一段的分镜提示词承接站位），
    /// 只改这一段分镜卡的提示词，别的段不动。新提示词里没有旧的「图N」，所以这一段挂着的参考图一并清掉——点「应用素材」再挂。
    /// 这一段还没有分镜卡（没做过「分镜」）/ 批量任务在跑 / 这一段正在推理：不开始，返回 false。
    @discardableResult
    func inferSegment(app: AppModel, project: String, episodeIndex: Int, segmentNumber: Int, note: String = "",
                      chat: SimplePipeline.Chat? = nil) -> Bool {
        guard let archive = app.pipelineArchive(for: project), archive.episodes.indices.contains(episodeIndex) else { return false }
        if let running = batches[project], !running.finished { return false }
        let episode = archive.episodes[episodeIndex]
        let split = episode.splitText ?? ""
        // 分割改过、段和分镜卡对不上：单段重推没意义（会写到错的卡上），要整集重新推理
        guard !episode.storyboardIsStale,
              let segment = SplitSegments.parse(split).first(where: { $0.number == segmentNumber }),
              let ids = episode.shotIDs, ids.indices.contains(segmentNumber - 1) else { return false }
        let shotID = ids[segmentNumber - 1]
        let episodeID = episode.id
        let previousID = segmentNumber >= 2 ? ids[segmentNumber - 2] : nil
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config, timeout: 900)
        let title = "重新推理第 \(episodeIndex + 1) 集第 \(segmentNumber) 段"
        return start(project: project, episode: nil, stage: .storyboard, slot: "infer-segment", title: title) {
            // 只发这一段：文字 + 它自己的时间标号（和整集的分割文本同一种写法，段末或段首）；缺的【场景】【角色】【道具】补上
            let one = SplitSegments.standaloneText(for: segment, style: StoryboardInference.markerStyle(of: split))
            let previous = previousID.flatMap { id in app.shots.first { $0.id == id && $0.projectKey == project }?.prompt }
            let user = RerunNote.prefixed(StoryboardInference.userMessage(splitText: one, previousPrompt: previous), note: note)
            var context = AgentRequestContext.current ?? AgentRequestContext(project: project, title: "推理分镜")
            context.episodeNumber = episodeIndex + 1
            let raw = try await AgentRequestContext.$current.withValue(context) {
                try await request(PipelinePromptStore.apiReady(PipelinePromptStore.shotsPrompt), user)
            }
            try Task.checkCancellation()
            let blocks = StoryboardInference.blocks(from: raw)
            guard blocks.count == 1 else {
                throw StoryboardInference.Failure(blocks.isEmpty
                    ? "AI 的回复里没有识别到分镜（找不到「[场景][角色][道具]」开头的段落），这一段的提示词没有改，请重试"
                    : "AI 写了 \(blocks.count) 块，这一段只该有 1 块，这一段的提示词没有改，请重试")
            }
            guard let index = app.shots.firstIndex(where: { $0.id == shotID && $0.projectKey == project }) else {
                // 这一段的卡在生视频页被删了（2026-10-12 逻辑审查）：在原来的位置补一张新卡，编号就是这一段
                guard var latest = app.pipelineArchive(for: project),
                      let e = latest.episodes.firstIndex(where: { $0.id == episodeID }),
                      var slots = latest.episodes[e].shotIDs, slots.indices.contains(segmentNumber - 1) else {
                    throw StoryboardInference.Failure("这一集已经不在了")
                }
                let created = app.writeStoryboardCards(project: project, episodeNumber: e + 1, existing: [],
                                                       before: latest.episodes[..<e].flatMap { $0.shotIDs ?? [] } + Array(slots[..<(segmentNumber - 1)]),
                                                       after: Array(slots[segmentNumber...]) + latest.episodes[(e + 1)...].flatMap { $0.shotIDs ?? [] },
                                                       prompts: [blocks[0]], firstNumber: segmentNumber)
                slots[segmentNumber - 1] = created[0]
                latest.episodes[e].shotIDs = slots
                try self.save(latest, app: app, project: project)
                return
            }
            if app.shots[index].prompt != blocks[0] { app.markShotReinferred(shotID) }   // 生成过的卡：新的是「待生成」版本
            app.shots[index].prompt = blocks[0]
            app.clearImageRefsMissingFromPrompt(shotID)          // 旧的「图N」没了：挂着的参考图跟着清掉（手动挂的视频 / 音频不动）
            app.touchProject(project)
            app.persistShots()
        }
    }

    private func latest(_ app: AppModel, project: String, episode: Episode, expected: SimpleEpisodeWork) throws -> (ProjectPipelineArchive, Int) {
        guard let archive = app.pipelineArchive(for: project),
              let index = archive.episodes.firstIndex(where: { $0.id == episode.id }),
              archive.episodes[index] == episode,
              SimplePipeline.work(in: archive, index: index) == expected else {
            throw PipelineAIError.invalidResult("剧本或制作内容已变化，请重试")
        }
        return (archive, index)
    }
    private func save(_ value: ProjectPipelineArchive, app: AppModel, project: String) throws {
        try Task.checkCancellation()
        app.savePipelineArchive(value, for: project)
        guard app.pipelineArchive(for: project) == value else { throw PipelineAIError.invalidResult("结果保存失败") }
    }

    /// 剧本分集（2026-10-09 改）：**剧本里有「第 N 集」标题（至少两处）就在本地按标题切**，没有标题才让 AI 切。
    ///
    /// 原来一律交给 AI：整部剧本（几万字）发过去、再让它把全文原样输出成 JSON——贵、慢、可能超时 / 被截断，
    /// 而且模型会悄悄改字、丢掉标题行（用户 60 集的项目里每集正文就是从「场景：」直接开头的，集号只剩在标题字段里）。
    /// 本地切分（`EpisodeSplitter`）一个字不改，**标题行原样留在每集正文开头**，集号随正文走；不调用 AI。
    func splitScript(app: AppModel, project: String, chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project) else { return }
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config)
        start(project: project, episode: nil, stage: .script) {
            var episodes = EpisodeSplitter.split(snapshot.wholeScript)
            if episodes.isEmpty {
                let raw = try await request(PipelinePromptStore.splitPrompt, snapshot.wholeScript)
                let reply = PipelineAIService.parseEpisodes(from: raw)
                guard !reply.isFallback, reply.episodes.allSatisfy({ !$0.text.isEmpty }) else {
                    throw PipelineAIError.invalidResult("AI 未返回有效分集，请重试")
                }
                episodes = reply.episodes
            }
            guard var latest = app.pipelineArchive(for: project), latest.wholeScript == snapshot.wholeScript,
                  latest.episodes == snapshot.episodes else { throw PipelineAIError.invalidResult("剧本已变化") }
            latest.episodes = episodes
            latest.works = episodes.map { _ in EpWork() }
            latest.simpleWorks = []
            latest.epIndex = 0
            latest.splitStage = 2
            try self.save(latest, app: app, project: project)
        }
    }

    func splitDuration(app: AppModel, project: String, episodeIndex: Int, source: PipelineFlowStage = .duration,
                       chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project), snapshot.episodes.indices.contains(episodeIndex) else { return }
        let episode = snapshot.episodes[episodeIndex]
        let initial = SimplePipeline.work(in: snapshot, index: episodeIndex)
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config)
        start(project: project, episode: episode.id, stage: .duration, source: source) {
            let rules = app.nameRules(for: project)   // 用户确认过的别名 / 忽略名单：新分出来的段按它自动对上
            let result = try await SimplePipeline.split(episode: episode, assets: [], seconds: snapshot.segmentSeconds, chat: request)
                .map { segment -> SimplePipelineSegment in
                    var segment = segment
                    segment.assetNames = rules.normalize(segment.assetNames)
                    return segment
                }
            var (latest, _) = try self.latest(app, project: project, episode: episode, expected: initial)
            var next = initial
            next.segments = result.map { segment in initial.segments.first { $0.text == segment.text } ?? segment }
            SimplePipeline.save(next, to: &latest)
            try self.save(latest, app: app, project: project)
        }
    }

    func extract(app: AppModel, project: String, episodeIndex: Int, chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project), snapshot.episodes.indices.contains(episodeIndex) else { return }
        let episode = snapshot.episodes[episodeIndex]
        let initial = SimplePipeline.work(in: snapshot, index: episodeIndex)
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config)
        start(project: project, episode: episode.id, stage: .assets) {
            guard !initial.segments.isEmpty else { throw PipelineAIError.invalidResult("请先完成时长分割") }
            let source = Episode(id: episode.id, title: episode.title, text: initial.segments.map(\.text).joined(separator: "\n\n---\n\n"))
            let rules = app.nameRules(for: project)
            // 已确认成别名 / 忽略的名字，AI 又提取出来也不再新建一份
            let values = try await SimplePipeline.extract(episode: source, previousAssets: initial.assets, chat: request)
                .filter { rules.keepsExtractedAsset(named: $0.name) }
            var (latest, _) = try self.latest(app, project: project, episode: episode, expected: initial)
            var next = initial
            PipelineAssetImageRules.merge(values, into: &next)
            SimplePipeline.save(next, to: &latest)
            try self.save(latest, app: app, project: project)
        }
    }

    /// 单独重提某一项素材的生图描述（素材页「重新提取」）。
    func reextractAsset(app: AppModel, project: String, episodeIndex: Int, assetID: UUID, chat: SimplePipeline.Chat? = nil) {
        guard let snapshot = app.pipelineArchive(for: project), snapshot.episodes.indices.contains(episodeIndex) else { return }
        let episode = snapshot.episodes[episodeIndex]
        let initial = SimplePipeline.work(in: snapshot, index: episodeIndex)
        guard initial.assets.contains(where: { $0.id == assetID }) else { return }
        let request = chat ?? SimplePipeline.chat(config: PipelineAISettingsStore.load().config)
        start(project: project, episode: episode.id, stage: .assets) {
            guard !initial.segments.isEmpty else { throw PipelineAIError.invalidResult("请先完成时长分割") }
            let source = Episode(id: episode.id, title: episode.title,
                                 text: initial.segments.map(\.text).joined(separator: "\n\n---\n\n"))
            guard let asset = initial.assets.first(where: { $0.id == assetID }) else { return }
            let description = try await SimplePipeline.reextract(episode: source, asset: asset,
                                                                 allAssets: initial.assets, chat: request)
            var (latest, _) = try self.latest(app, project: project, episode: episode, expected: initial)
            var next = initial
            guard let index = next.assets.firstIndex(where: { $0.id == assetID }) else { return }
            next.assets[index].description = description
            SimplePipeline.save(next, to: &latest)
            try self.save(latest, app: app, project: project)
        }
    }

    func infer(app: AppModel, project: String, episodeIndex: Int, only: Int? = nil, chat: SimplePipeline.Chat? = nil,
               vision: PipelineContinuity.Vision? = nil) {
        guard let snapshot = app.pipelineArchive(for: project), snapshot.episodes.indices.contains(episodeIndex) else { return }
        let episode = snapshot.episodes[episodeIndex]
        let initial = SimplePipeline.work(in: snapshot, index: episodeIndex)
        let config = PipelineAISettingsStore.load().config
        let request = chat ?? SimplePipeline.chat(config: config)
        let look = vision ?? { url, context in
            try await PipelineAIService.vision(config: config, imageURL: url, system: PipelineContinuity.visionPrompt,
                                              context: context)
        }
        start(project: project, episode: episode.id, stage: .storyboard) {
            guard !initial.segments.isEmpty else { throw PipelineAIError.invalidResult("请先完成时长分割") }
            let seconds = snapshot.segmentSeconds
            var expected = initial
            var previous: SimplePipelineSegment? = only.flatMap { index in
                index > 0 && expected.segments.indices.contains(index - 1) ? expected.segments[index - 1] : nil
            }
            for index in (only.map { [$0] } ?? Array(expected.segments.indices)) {
                try Task.checkCancellation()
                let segment = expected.segments[index]
                let scenes = try PipelineContinuity.sceneSequence(for: segment, assets: expected.assets)
                guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PipelineAIError.invalidResult("第 \(index + 1) 段剧情为空，请先填写剧情。")
                }
                let scenePaths = scenes.map { PipelineContinuity.imagePath(scene: $0, project: project, items: app.imageItems, library: app.library) }
                let imageKey = scenePaths.map { $0.flatMap { ReferenceAsset.fileRevision($0) } ?? "" }.joined(separator: "|")
                let inputKey = PipelineContinuity.inputKey(segment: segment, assets: expected.assets, previous: previous) + imageKey
                if only == nil, segment.continuityKey == inputKey, !segment.prompt.isEmpty, !segment.endPositions.isEmpty {
                    previous = segment
                    continue
                }
                let key = Self.key(project, episode.id)
                self.jobs[key]?.note = "正在推理第 \(index + 1)/\(expected.segments.count) 段"
                var positions: [String] = []
                // 先检查所有新场景的图片，缺图时不浪费前面的看图调用。
                for (sceneIndex, scene) in scenes.enumerated() {
                    if sceneIndex == 0, previous?.sceneName == scene.name, previous?.endPositions.isEmpty == false { continue }
                    guard scenePaths[sceneIndex] != nil else {
                        throw PipelineAIError.invalidResult("第 \(index + 1) 段缺少场景「\(scene.name)」图片。补图后点击推理分镜继续。")
                    }
                }
                for (sceneIndex, scene) in scenes.enumerated() {
                    if sceneIndex == 0, let previous, previous.sceneName == scene.name, !previous.endPositions.isEmpty {
                        positions.append(previous.endPositions)
                    } else if let path = scenePaths[sceneIndex] {
                        let position = try await look(URL(fileURLWithPath: path), "场景：\(scene.name)\n只安排进入此场景时的站位。\n本段剧情：\n\(segment.text)")
                        guard !position.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw PipelineAIError.invalidResult("看图没有返回站位，请重试")
                        }
                        positions.append(position)
                    }
                    try Task.checkCancellation()
                }
                let initialPositions = scenes.count == 1 ? positions[0] : zip(scenes, positions).map { "场景「\($0.name)」：\n\($1)" }.joined(separator: "\n\n")
                try Task.checkCancellation()
                guard !initialPositions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PipelineAIError.invalidResult("看图没有返回站位，请重试")
                }
                let inferred = try await PipelineContinuity.infer(segment: segment, assets: expected.assets,
                                                                sceneName: scenes.map(\.name).joined(separator: " → "), initialPositions: initialPositions, seconds: seconds, chat: request)
                try Task.checkCancellation()
                var (latest, _) = try self.latest(app, project: project, episode: episode, expected: expected)
                let latestPaths = scenes.map { PipelineContinuity.imagePath(scene: $0, project: project, items: app.imageItems, library: app.library) }
                guard latestPaths == scenePaths,
                      latestPaths.map({ $0.flatMap { ReferenceAsset.fileRevision($0) } ?? "" }).joined(separator: "|") == imageKey else {
                    throw PipelineAIError.invalidResult("场景图片已变化，请重新推理。")
                }
                let linked = PipelineStoryboardRules.shot(for: segment, episode: episodeIndex + 1, index: index,
                                                         projectKey: project, shots: app.shots)
                expected.segments[index].prompt = inferred.prompt
                expected.segments[index].sceneName = scenes.last!.name
                expected.segments[index].initialPositions = initialPositions
                expected.segments[index].endPositions = inferred.endPositions
                expected.segments[index].continuityKey = inputKey
                if let linked { expected.segments[index].shotID = linked.id }
                SimplePipeline.save(expected, to: &latest)
                try self.save(latest, app: app, project: project)
                if let linked { app.updateShotPrompt(linked.id, prompt: inferred.prompt) }
                previous = expected.segments[index]
            }
        }
    }
}

extension View {
    /// 有对应的后台任务在跑时，给按钮描一圈主色细线（不再有光晕 / 阴影）。静态，不留下点击遮挡，也不启动持续重绘动画。
    func pipelineActivityGlow(_ active: Bool) -> some View {
        overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(active ? Theme.accent : .clear, lineWidth: 1.5)
            .allowsHitTesting(false))
    }
}

// MARK: 提取音色（2026-10-26）
// 放在这个文件里：要改 `batches`（private(set)）、用 `start` / `mapConcurrently`

extension PipelineFlow {
    /// 生图页「提取音色」：给勾选的角色卡写文本音色（见 `VoiceExtraction`）。和提取素材同一张服务商卡片，选的是外部智能体就走接力。
    /// 右上角显示「提取音色：填了 N 张卡，更新 M 段分镜」；别的批量（分割 / 推理分镜 / 提取素材）在跑时不开。
    /// `note`：这一次手写的补充要求。`prompt` / `chat` 给测试用
    func batchExtractVoices(app: AppModel, project: String, cardIDs: [UUID], note: String = "",
                            prompt: String? = nil, chat: SimplePipeline.Chat? = nil) {
        let slot = "extract-voice"
        guard jobs[Self.slotKey(project, slot)]?.active != true else { return }
        if let running = batches[project], !running.finished { return }
        let wanted = Set(cardIDs)
        let cards = app.imageItems.filter { $0.projectKey == project && wanted.contains($0.id) }
        guard !cards.isEmpty else { return }
        let archive = app.pipelineArchive(for: project)
        let episodes = archive?.episodes ?? []
        let appearances: [String: [Int]]
        if let archive, !episodes.isEmpty {
            let entries = Self.extractionEntries(app: app, project: project, archive: archive, kind: .role,
                                                 episodeIndices: Array(episodes.indices))
            appearances = Dictionary(entries.map { ($0.name, $0.episodes) }, uniquingKeysWith: { first, _ in first })
        } else {
            appearances = [:]
        }
        let targets = VoiceExtraction.targets(cards: cards, appearances: appearances)
        let texts: [(episode: Int, text: String)] = episodes.isEmpty
            ? [(1, archive?.wholeScript ?? "")]
            : episodes.enumerated().map { ($0.offset + 1, $0.element.text) }
        let batchesOfTargets = stride(from: 0, to: targets.count, by: VoiceExtraction.namesPerRequest)
            .map { Array(targets[$0..<min($0 + VoiceExtraction.namesPerRequest, targets.count)]) }
        let era = archive?.eraBackground ?? ""
        let messages = batchesOfTargets.map { batch in
            RerunNote.prefixed(EraBackground.prefixed(VoiceExtraction.message(batch: batch, source: VoiceExtraction.source(episodes: texts, for: batch)),
                                                      era: era), note: note)
        }
        let promptText = prompt ?? PipelinePromptStore.voicePrompt
        let config = PipelineAISettingsStore.load().config
        let request = chat ?? SimplePipeline.chat(config: config, timeout: 900)
        let limit = min(config.requestConcurrency, Self.extractionConcurrency)
        batches[project] = BatchState(kind: .voice, title: "提取音色", total: 1)
        start(project: project, episode: nil, stage: .assets, slot: slot, title: "提取音色",
              onFinish: { [weak self] message in
                  self?.recordBatch(project: project, order: 0, label: "音色", failure: message)
              }) {
            let replies = try await Self.mapConcurrently(messages, limit: limit) { message in
                let raw = try await request(PipelinePromptStore.apiReady(promptText), message)
                return (raw, [])
            }
            try Task.checkCancellation()
            let parsed = replies.flatMap { VoiceExtraction.parse($0.raw) }
            let matched = VoiceExtraction.match(parsed, to: targets)
            let result = app.applyExtractedVoices(matched.voices)
            self.batches[project]?.created += result.cards
            self.batches[project]?.shotsUpdated += result.shots
            self.batches[project]?.notes += matched.notes
            AppLog.write("voice", "提取音色：名单 \(targets.count) 人，写了 \(result.cards) 张卡，更新 \(result.shots) 段分镜")
        }
    }
}
