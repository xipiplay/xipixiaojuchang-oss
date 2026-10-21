import Foundation
import Observation

// MARK: - 一键推进（2026-10-07 P3-2 第 3 步，用户按推荐定的口径）
//
// 一集：分段 → 提取素材 → 出图 → 【挑定妆图】→ 推理分镜 → 匹配素材 → 【提交视频】，只在两个闸门停下等用户。
// - **只推进用户选中的这一集**；
// - 做法是一个**无状态的循环**：每轮先看数据，找出第一个没做完的步骤去做，做完回到循环。
//   所以失败后再点、停止后再点、两个闸门之后继续，都是同一套逻辑，已经做完的步骤自动跳过；
// - 某一步失败就**停在那一步**并给出原因，已完成的结果保留，不跳过失败项往下做；
// - 只用旧流程现成的入口（`pipelineFlow.splitDuration / extract / infer`、`requestImageGeneration`、
//   `WorkbenchActions.submit`），不另开写路径；
// - 重启应用后不会自动继续（运行状态只在内存里），步骤条按数据显示做到哪了，再点一下接着做。

@MainActor
@Observable
final class WorkbenchRunner {
    static let steps = ["分段", "提取素材", "出图", "挑定妆图", "推理分镜", "匹配素材", "提交视频"]
    /// 用户在「挑定妆图」面板里勾了「以后自动选最新一张」：这一步以后不再停（设置里也能改）
    static let autoPickKey = "workbenchAutoPickPortrait"

    enum Phase: Equatable {
        case running(step: String)
        case waitingPick
        case waitingSubmit
        case failed(step: String, message: String)
        case stopped
        case finished(String)
    }

    struct Run: Equatable {
        var phase: Phase
        /// 这次推进里新生成了图的生图卡片（「挑定妆图」只列它们）
        var generated: [UUID] = []
        var pickConfirmed = false
        /// 用户要求「重做」的步骤。在那一步成功之前一直保留：失败 / 停止后再点，还是接着重做那一步
        var redo: Set<String> = []
        /// 这次推进里每张生图卡片请求前已有几个结果（重做出图时靠「结果变多了」判断这次出成了没有）
        var baseline: [UUID: Int] = [:]
        /// 「匹配素材」这一步做完后每段的情况（提交闸门里显示：对上了哪些、哪些没对上 / 没有图）
        var matches: [UUID: WorkbenchMatching.Status] = [:]
    }

    /// 可以重做的步骤。分段不在里面：重新分段会改变段落，已有的提示词和视频只对文字没变的段保留，到「剧本」页做
    static let redoable = [steps[1], steps[2], steps[4], steps[5]]

    /// 可以替换的外部动作（测试里换成立刻完成的假实现）
    @MainActor
    struct Hooks {
        var splitDuration: @MainActor (AppModel, String, Int) -> Void = { app, project, index in
            app.pipelineFlow.splitDuration(app: app, project: project, episodeIndex: index)
        }
        var extract: @MainActor (AppModel, String, Int) -> Void = { app, project, index in
            app.pipelineFlow.extract(app: app, project: project, episodeIndex: index)
        }
        var infer: @MainActor (AppModel, String, Int) -> Void = { app, project, index in
            app.pipelineFlow.infer(app: app, project: project, episodeIndex: index)
        }
        var generateImage: @MainActor (AppModel, UUID) -> Void = { app, id in app.requestImageGeneration(id) }
        var submit: @MainActor (AppModel, SegmentRecord, EpisodeRecord, VideoParams) throws -> Void = { app, segment, episode, params in
            try WorkbenchActions.submit(segment: segment, episode: episode, params: params, app: app)
        }
        var pollInterval: Duration = .milliseconds(400)
    }

    private(set) var runs: [String: Run] = [:]
    @ObservationIgnored var hooks = Hooks()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// 每一轮推进一个令牌：停止后马上又点开始时，旧任务收尾不能动新一轮的状态
    @ObservationIgnored private var tokens: [String: UUID] = [:]

    static func key(_ project: String, _ episode: UUID) -> String { "\(project)/\(episode.uuidString)" }

    func run(project: String, episode: UUID) -> Run? { runs[Self.key(project, episode)] }

    func isActive(project: String, episode: UUID) -> Bool {
        if case .running = runs[Self.key(project, episode)]?.phase { return true }
        return false
    }

    /// 测试用：等这一集当前这段推进跑完（跑到闸门 / 完成 / 失败）
    func wait(project: String, episode: UUID) async {
        await tasks[Self.key(project, episode)]?.value
    }

    func dismiss(project: String, episode: UUID) {
        let key = Self.key(project, episode)
        if case .running = runs[key]?.phase { return }
        runs[key] = nil
    }

    // MARK: 开始 / 停止 / 过闸门

    /// 开始 / 继续推进。`redo` = 先把这一步当成没做过（提取素材 / 出图 / 推理分镜），做完再接着往后推
    func start(app: AppModel, project: String, episode: UUID, redo step: String? = nil) {
        let key = Self.key(project, episode)
        guard !isActive(project: project, episode: episode) else { return }
        var run = runs[key] ?? Run(phase: .running(step: Self.steps[0]))
        if let step {
            guard Self.redoable.contains(step) else { return }
            run.redo.insert(step)
            if step == Self.steps[2] {
                // 重新出图：只让「挑定妆图」列这一轮新出的，旧的不再拿来挑
                run.generated = []
                run.baseline = [:]
                run.pickConfirmed = false
            }
            if step == Self.steps[4] { Self.markInferenceStale(app: app, project: project, episode: episode) }
        }
        run.phase = .running(step: step ?? Self.steps[0])
        runs[key] = run
        resume(app: app, project: project, episode: episode)
    }

    /// 推理分镜的重做：清掉每段的「承接指纹」，旧流程就认为这些段的输入变了、会重推；
    /// 提示词先不动，推理成功一段换一段（中途失败也不会丢掉旧的），已经重推好的段再继续时会被跳过
    private static func markInferenceStale(app: AppModel, project: String, episode: UUID) {
        guard var archive = app.pipelineArchive(for: project),
              let index = archive.episodes.firstIndex(where: { $0.id == episode }) else { return }
        var work = SimplePipeline.work(in: archive, index: index)
        guard work.segments.contains(where: { !$0.continuityKey.isEmpty }) else { return }
        for i in work.segments.indices { work.segments[i].continuityKey = "" }
        SimplePipeline.save(work, to: &archive)
        app.savePipelineArchive(archive, for: project)
    }

    /// 挑好了：记下用户的选择，继续往下推
    func confirmPicks(app: AppModel, project: String, episode: UUID, picks: [UUID: UUID]) {
        let key = Self.key(project, episode)
        guard var run = runs[key], run.phase == .waitingPick else { return }
        for (itemID, resultID) in picks { app.selectImageResult(itemID, resultID: resultID) }
        run.pickConfirmed = true
        run.phase = .running(step: Self.steps[4])
        runs[key] = run
        resume(app: app, project: project, episode: episode)
    }

    /// 提交闸门确认：按用户勾的段提交视频。返回失败的段（段号 1 起 → 原因）
    @discardableResult
    func confirmSubmit(app: AppModel, project: String, episode: UUID, segmentIDs: [UUID],
                       params: (SegmentRecord) -> VideoParams) -> [(segment: Int, message: String)] {
        let key = Self.key(project, episode)
        guard runs[key]?.phase == .waitingSubmit,
              let doc = app.workbenchDocument(for: project), let ep = doc.episodes.first(where: { $0.id == episode }) else { return [] }
        var failures: [(Int, String)] = []
        var submitted = 0
        for (index, segment) in ep.segments.enumerated() where segmentIDs.contains(segment.id) {
            do {
                try hooks.submit(app, segment, ep, params(segment))
                submitted += 1
            } catch {
                failures.append((index + 1, error.localizedDescription))
            }
        }
        runs[key]?.phase = failures.isEmpty
            ? .finished("已提交 \(submitted) 条视频，进度在任务抽屉里")
            : .failed(step: Self.steps[6], message: "有 \(failures.count) 条没提交成功：" + failures.map { "第 \($0.0) 段 \($0.1)" }.joined(separator: "；"))
        return failures
    }

    func stop(app: AppModel, project: String, episode: UUID) {
        let key = Self.key(project, episode)
        tasks[key]?.cancel()
        tasks[key] = nil
        tokens[key] = nil
        app.pipelineFlow.cancel(project: project, episode: episode)
        // 这次推进里还在跑的生图一起取消（中转站可能已经在生成，仍可能扣费）
        for id in runs[key]?.generated ?? [] { app.stopImageGeneration(id) }
        if case .running = runs[key]?.phase { runs[key]?.phase = .stopped }
    }

    // MARK: 循环

    private func resume(app: AppModel, project: String, episode: UUID) {
        let key = Self.key(project, episode)
        let token = UUID()
        tokens[key] = token
        tasks[key] = Task { [weak self] in
            await self?.advance(app: app, project: project, episode: episode, token: token)
            guard self?.tokens[key] == token else { return }
            self?.tasks[key] = nil
            self?.tokens[key] = nil
        }
    }

    private struct Stop: Error { var step: String; var message: String }

    private func set(_ phase: Phase, _ key: String) { runs[key]?.phase = phase }

    private func advance(app: AppModel, project: String, episode: UUID, token: UUID) async {
        let key = Self.key(project, episode)
        do {
            try await loop(app: app, project: project, episode: episode, key: key)
        } catch {
            // 已经被停止（令牌换了或清了）：状态归新的一轮 / `stop` 管，这里不再动
            guard tokens[key] == token else { return }
            switch error {
            case is CancellationError:
                if case .running = runs[key]?.phase { runs[key]?.phase = .stopped }
            case let stop as Stop:
                runs[key]?.phase = .failed(step: stop.step, message: stop.message)
            default:
                runs[key]?.phase = .failed(step: "推进", message: error.localizedDescription)
            }
        }
    }

    private func loop(app: AppModel, project: String, episode: UUID, key: String) async throws {
        while true {
            try Task.checkCancellation()
            guard app.currentProjectKey == project else {
                throw Stop(step: "推进", message: "已经切换到别的项目，一键推进已停止。回到这个项目再点一次接着做。")
            }
            guard let archive = app.pipelineArchive(for: project),
                  let index = archive.episodes.firstIndex(where: { $0.id == episode }) else {
                throw Stop(step: "推进", message: "找不到这一集")
            }
            let work = SimplePipeline.work(in: archive, index: index)

            // ① 分段
            if work.segments.isEmpty {
                set(.running(step: Self.steps[0]), key)
                app.pipelineFlow.clearFinished(project: project, episode: episode)
                hooks.splitDuration(app, project, index)
                try await finishJob(app: app, project: project, episode: episode, step: Self.steps[0]) {
                    guard let a = app.pipelineArchive(for: project) else { return false }
                    return !SimplePipeline.work(in: a, index: index).segments.isEmpty
                }
                continue
            }
            // ② 提取素材
            let redo = runs[key]?.redo ?? []
            if !work.assetsExtracted || redo.contains(Self.steps[1]) {
                set(.running(step: Self.steps[1]), key)
                app.pipelineFlow.clearFinished(project: project, episode: episode)
                hooks.extract(app, project, index)
                try await finishJob(app: app, project: project, episode: episode, step: Self.steps[1]) {
                    guard let a = app.pipelineArchive(for: project) else { return false }
                    return SimplePipeline.work(in: a, index: index).assetsExtracted
                }
                runs[key]?.redo.remove(Self.steps[1])
                continue
            }
            // ③ 出图：缺图的素材自动出图（等全部结束；失败就停在这里）。重做时本集所有能出图的素材都重新出一张
            let redoImages = redo.contains(Self.steps[2])
            WorkbenchImages.adoptUsedSettings(project: project, episodeIndex: index, app: app)
            let targets = redoImages ? Self.assetsToRedraw(work: work, project: project, run: runs[key], app: app)
                                     : Self.assetsWithoutImage(work: work, project: project, app: app)
            if !targets.isEmpty {
                set(.running(step: Self.steps[2]), key)
                try await generateImages(app: app, project: project, episode: episode, index: index, assets: targets, key: key)
                if redoImages { runs[key]?.redo.remove(Self.steps[2]) }
                continue
            }
            if redoImages { runs[key]?.redo.remove(Self.steps[2]) }
            // ④ 挑定妆图（闸门）：只列这次新出图的；勾了自动选最新、或这次没出新图就不停
            if runs[key]?.pickConfirmed != true {
                let fresh = Self.freshItems(runs[key]?.generated ?? [], app: app)
                if fresh.isEmpty || UserDefaults.standard.bool(forKey: Self.autoPickKey) {
                    runs[key]?.pickConfirmed = true
                } else {
                    set(.waitingPick, key)
                    return
                }
            }
            // ⑤ 推理分镜
            if redo.contains(Self.steps[4]) || work.segments.contains(where: { $0.prompt.isEmpty || $0.endPositions.isEmpty }) {
                set(.running(step: Self.steps[4]), key)
                app.pipelineFlow.clearFinished(project: project, episode: episode)
                hooks.infer(app, project, index)
                try await finishJob(app: app, project: project, episode: episode, step: Self.steps[4]) {
                    guard let a = app.pipelineArchive(for: project) else { return false }
                    return SimplePipeline.work(in: a, index: index).segments.allSatisfy { !$0.prompt.isEmpty }
                }
                runs[key]?.redo.remove(Self.steps[4])
                continue
            }
            // ⑥ 匹配素材：在提示词的方括号行里给有图的设定名前面写「图N」，并把选中的图挂进分镜卡（已有视频的段不动）
            set(.running(step: Self.steps[5]), key)
            do {
                runs[key]?.matches = try WorkbenchMatching.prepareEpisode(episodeID: episode, app: app)
            } catch {
                throw Stop(step: Self.steps[5], message: error.localizedDescription + "。再点「一键推进」接着做。")
            }
            runs[key]?.redo.remove(Self.steps[5])
            // ⑦ 提交视频（闸门）：还没有视频的段
            if Self.segmentsToSubmit(app: app, project: project, episode: episode).isEmpty {
                set(.finished("本集已经做完，没有需要提交的段"), key)
            } else {
                set(.waitingSubmit, key)
            }
            return
        }
    }

    // MARK: 开始前的说明

    /// 点「一键推进」时先告诉用户：这次会自动做什么（会调 AI / 会出图的要写清楚）、会在哪里停下来
    struct Plan: Equatable {
        /// 会自动做的事（调 AI、出图）。空 = 没有需要自动花钱的步骤，不用先确认
        var lines: [String] = []
        /// 会停下来等用户的地方
        var gates: [String] = []
        var warnings: [String] = []
        var needsConfirm: Bool { !lines.isEmpty }
    }

    static func plan(app: AppModel, project: String, episode: UUID) -> Plan {
        guard let archive = app.pipelineArchive(for: project),
              let index = archive.episodes.firstIndex(where: { $0.id == episode }) else { return Plan() }
        let work = SimplePipeline.work(in: archive, index: index)
        var plan = Plan()
        if work.segments.isEmpty { plan.lines.append("把原文按时长分成若干段（调用剧本 AI）") }
        if !work.assetsExtracted { plan.lines.append("提取这一集用到的角色、场景、道具（调用剧本 AI）") }

        var imagesComing = false
        if work.assetsExtracted {
            let count = assetsWithoutImage(work: work, project: project, app: app).count
            if count > 0 {
                plan.lines.append("本集有 \(count) 个设定还没有图，将自动生成 \(count) 张图（调用图片模型，会扣费）")
                imagesComing = true
            }
        } else {
            plan.lines.append("提取完成后，给还没有图的设定各自动生成一张图（张数提取后才知道，调用图片模型，会扣费）")
            imagesComing = true
        }
        if imagesComing {
            if app.imageModelNames.isEmpty { plan.warnings.append("还没有可用的图片模型，到出图这一步会停下。先到设置里添加图片渠道与模型。") }
            plan.gates.append(UserDefaults.standard.bool(forKey: autoPickKey)
                              ? "出图后自动选最新一张作定妆图，不停下（设置里可以改）"
                              : "出图后停下，让你挑定妆图")
        }
        if work.segments.isEmpty || work.segments.contains(where: { $0.prompt.isEmpty || $0.endPositions.isEmpty }) {
            plan.lines.append("为每一段推理分镜提示词（调用剧本 AI）")
        }
        if !plan.lines.isEmpty { plan.lines.append("把选中的图对到提示词里的名字上（写「图N」，本地操作，不花钱）") }
        if work.segments.isEmpty || !segmentsToSubmit(app: app, project: project, episode: episode).isEmpty
            || work.segments.contains(where: { $0.prompt.isEmpty }) {
            plan.gates.append("最后停在「提交视频」，由你确认后才提交（视频会消耗额度）")
        }
        if let doc = app.workbenchDocument(for: project), let ep = doc.episodes.first(where: { $0.id == episode }) {
            let names = WorkbenchRules.unresolvedNames(in: ep).count
            if names > 0 { plan.warnings.append("有 \(names) 个名字对不上设定。可以先确认名字，否则这些名字在视频里不会带参考图。") }
        }
        return plan
    }

    // MARK: 各步骤的小工具

    /// 等旧流程的这一步跑完。数据上没达到预期就算失败，原因取流程里记的那句话
    private func finishJob(app: AppModel, project: String, episode: UUID, step: String,
                           reached: () -> Bool) async throws {
        await app.pipelineFlow.waitForJob(project: project, episode: episode)
        try Task.checkCancellation()
        // 数据上看「做完了」不够：重做时旧结果本来就在，所以流程自己报了失败也算没做完
        let job = app.pipelineFlow.jobs[PipelineFlow.key(project, episode)]
        guard job?.failed != true, reached() else {
            let note = job?.note
            throw Stop(step: step, message: (note?.isEmpty == false ? note! : "这一步没有完成") + "。处理好后再点「一键推进」，会从这一步接着做。")
        }
    }

    /// 本集还没有图的素材（剧本里提取的 ∪ 段落里用到、这次没提取到的设定；已有生图结果、或素材库里已挂了图的都算有）
    static func assetsWithoutImage(work: SimpleEpisodeWork, project: String, app: AppModel) -> [SimplePipelineAsset] {
        WorkbenchImages.assetsWithoutImage(work: work, doc: app.workbenchDocument(for: project), project: project, app: app)
    }

    /// 重做出图：本集所有能出图的素材，还没在这一轮出成的（出成 = 结果比请求前多了）
    static func assetsToRedraw(work: SimpleEpisodeWork, project: String, run: Run?, app: AppModel) -> [SimplePipelineAsset] {
        WorkbenchMatching.episodeAssets(work: work, doc: app.workbenchDocument(for: project)).filter { asset in
            guard ImageSubjectType.from(kind: asset.kind) != nil,
                  !asset.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let item = PipelineAssetImageRules.item(for: asset, projectKey: project, items: app.imageItems),
                  let before = run?.baseline[item.id] else { return true }
            return item.results.count <= before
        }
    }

    private func generateImages(app: AppModel, project: String, episode: UUID, index: Int,
                                assets: [SimplePipelineAsset], key: String) async throws {
        let ids: [UUID]
        do {
            ids = try WorkbenchImages.prepareCards(for: assets, project: project, episodeIndex: index, app: app).map(\.itemID)
        } catch let failure as WorkbenchActions.Failure {
            throw Stop(step: Self.steps[2], message: failure.message + "再点「一键推进」接着做。")
        }
        for id in ids {
            // 请求前先记下已有几个结果：出成没出成看「结果变多了」（重做时旧结果本来就在）
            if runs[key]?.baseline[id] == nil { runs[key]?.baseline[id] = app.imageItems.first { $0.id == id }?.results.count ?? 0 }
            hooks.generateImage(app, id)
        }
        // 记下来：停止时要能取消，「挑定妆图」要只列它们
        for id in ids where runs[key]?.generated.contains(id) != true { runs[key]?.generated.append(id) }

        // 等这批全部结束
        while ids.contains(where: { id in app.imageItems.first { $0.id == id }?.status.isBusy ?? false }) {
            try Task.checkCancellation()
            try await Task.sleep(for: hooks.pollInterval)
        }
        let failed = ids.compactMap { id in app.imageItems.first { $0.id == id } }
            .filter { $0.results.count <= (runs[key]?.baseline[$0.id] ?? 0) }
        if !failed.isEmpty {
            let reason = failed.first?.errorMessage.map { "：" + Formatters.errorSummary($0) } ?? ""
            throw Stop(step: Self.steps[2], message: "\(failed.count) 个设定出图失败（\(failed.prefix(3).map(\.name).joined(separator: "、"))）\(reason)。处理好后再点「一键推进」，已经出好的图保留。")
        }
    }

    /// 这次新出了图、还在的生图卡片
    static func freshItems(_ ids: [UUID], app: AppModel) -> [ImageGenItem] {
        ids.compactMap { id in app.imageItems.first { $0.id == id && !$0.results.isEmpty } }
    }

    /// 提交闸门要列的段：有提示词、还没有任何视频
    static func segmentsToSubmit(app: AppModel, project: String, episode: UUID) -> [SegmentRecord] {
        guard let doc = app.workbenchDocument(for: project), let ep = doc.episodes.first(where: { $0.id == episode }) else { return [] }
        return ep.segments.filter { WorkbenchRules.hasPrompt($0) && $0.videos.isEmpty }
    }
}
