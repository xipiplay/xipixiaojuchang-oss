import Foundation

/// 工作台底部胶囊里「出图 / 匹配 / 生视频」三步对选中各集做的事（2026-10-09）。
/// 范围一律从 `WorkbenchStatus.Board` 里取——和集列表上看到的数字是同一份。
@MainActor
enum WorkbenchBatch {
    // MARK: 出图

    /// 选中各集要出图的卡（去重、保持顺序——变化版的基础版排在它前面，所以请求基础版先发出去、变化版才会排在它后面等）
    static func cardsToGenerate(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> [ImageGenItem] {
        var seen = Set<UUID>()
        var result: [ImageGenItem] = []
        for index in Set(indices).sorted() where board.episodes.indices.contains(index) {
            for id in board.episodes[index].cardsToGenerate where seen.insert(id).inserted {
                guard let card = app.imageItems.first(where: { $0.id == id }),
                      !card.status.isBusy,
                      !card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(card)
            }
        }
        return result
    }

    /// 卡片的模型还在配置里（没选 = 用第一个）
    static func imageModelConfigured(_ card: ImageGenItem, app: AppModel) -> Bool {
        guard !app.imageModelNames.isEmpty else { return false }
        guard let model = card.model, !model.isEmpty else { return true }
        return app.imageModelNames.contains(model)
    }

    @discardableResult
    static func generateImages(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> Int {
        let cards = cardsToGenerate(board: board, indices: indices, app: app).filter { imageModelConfigured($0, app: app) }
        for card in cards { app.requestImageGeneration(card.id) }
        return cards.count
    }

    // MARK: 分段弹窗的「生成图片」（2026-10-12 用户定：替掉原来的「保存到素材库」）

    /// 这一段右栏各行选中的卡，分成几堆：还没有图的、已经有图的（多半是前面的段生成过），以及生成不了的
    struct SegmentImagePlan: Equatable {
        /// 还没有图、可以生成（按右栏的顺序）
        var fresh: [UUID] = []
        /// 已经有图：重新生成会多出一版
        var withImage: [UUID] = []
        /// 正在出图（自动跳过）
        var busy = 0
        /// 还没提取、没有卡
        var noCard = 0
        /// 没写提示词 / 模型不在配置里：和生图页的批量提交一样，有一个就整批拦住
        var noPrompt = 0
        var modelIssue = 0

        var blocked: Bool { noPrompt > 0 || modelIssue > 0 }
    }

    /// `cardIDs`：右栏每一行选中的卡（nil = 这一行还没有卡）；同一张卡出现两次只算一次
    static func segmentImagePlan(cardIDs: [UUID?], app: AppModel,
                                 modelConfigured: ((ImageGenItem) -> Bool)? = nil) -> SegmentImagePlan {
        var plan = SegmentImagePlan()
        var seen = Set<UUID>()
        for id in cardIDs {
            guard let id else { plan.noCard += 1; continue }
            guard seen.insert(id).inserted else { continue }
            guard let card = app.imageItems.first(where: { $0.id == id }) else { plan.noCard += 1; continue }
            if card.status.isBusy { plan.busy += 1; continue }
            if card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { plan.noPrompt += 1 }
            if !(modelConfigured?(card) ?? imageModelConfigured(card, app: app)) { plan.modelIssue += 1 }
            if card.results.isEmpty { plan.fresh.append(id) } else { plan.withImage.append(id) }
        }
        return plan
    }

    /// 「应用素材」之前：选中的这些卡里，现在显示的那一版**还没入库**的（应用时会先存进素材库）。去重、保持顺序
    static func notInLibrary(cardIDs: [UUID?], app: AppModel) -> [UUID] {
        var seen = Set<UUID>()
        return cardIDs.compactMap { $0 }.filter { id in
            guard seen.insert(id).inserted, let card = app.imageItems.first(where: { $0.id == id }) else { return false }
            return app.batchSaveVerdict(card) == .ok
        }
    }

    // MARK: 匹配

    static func shotsInScope(board: WorkbenchStatus.Board, indices: [Int]) -> [UUID] {
        Set(indices).sorted().filter { board.episodes.indices.contains($0) }.flatMap { board.episodes[$0].shotIDs }
    }

    /// 一段要挂的素材：头行里每个有图的名字 → 它现在该用的那一版卡（和分段弹窗右栏、「应用素材」同一套规则）。
    /// 2026-10-12 用户：工具条的「匹配」原来走 `batchAutoMatch`，只在素材库里按名字找，没入库的生图卡匹配不上
    struct MatchItem {
        let shotID: UUID
        let selections: [(kind: WorkbenchVersions.Kind, name: String, cardID: UUID?)]
        /// 头行里有、但还没有图的名字（没卡 / 有卡没出图）
        let withoutImage: Int
    }

    static func matchPlan(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> [MatchItem] {
        matchPlan(board: board, indices: Array(board.episodes.indices).filter { Set(indices).contains($0) }, only: nil, app: app)
    }

    /// 生视频页拖选的「批量匹配」用（2026-10-12 用户：也要改）：只管选中的这几张里**属于某一集**的；
    /// 不属于任何一集的（生视频页自己新建的）不在里面，调用方照旧按素材库名字匹配
    static func matchPlan(board: WorkbenchStatus.Board, shotIDs: Set<UUID>, app: AppModel) -> [MatchItem] {
        matchPlan(board: board, indices: Array(board.episodes.indices), only: shotIDs, app: app)
    }

    /// 编辑提示词弹窗的「自动匹配」用（2026-10-14 用户：三处匹配要统一）：这张分镜属于某一集 → 和工具条「匹配」同一套的那一项；
    /// 不属于任何一集（生视频页自己新建的）→ nil，调用方照旧按素材库名字匹配
    static func matchItem(shotID: UUID, app: AppModel) -> MatchItem? {
        guard let key = app.currentProjectKey, let archive = app.currentPipelineArchive, !archive.episodes.isEmpty else { return nil }
        return matchPlan(board: app.workbenchBoard(project: key, archive: archive), shotIDs: [shotID], app: app).first
    }

    private static func matchPlan(board: WorkbenchStatus.Board, indices: [Int], only: Set<UUID>?, app: AppModel) -> [MatchItem] {
        let cards = app.currentImageItems
        var items: [MatchItem] = []
        for index in indices.sorted() where board.episodes.indices.contains(index) {
            let episode = board.episodes[index]
            for id in episode.shotIDs where only?.contains(id) ?? true {
                guard let shot = app.shots.first(where: { $0.id == id }), let status = episode.shots[id] else { continue }
                let ready = status.names.filter { $0.state == .ready }
                let selections = ready.map { name in
                    (kind: name.kind, name: name.name,
                     cardID: WorkbenchVersions.currentCardID(kind: name.kind, name: name.name, shot: shot, episode: index + 1, cards: cards, app: app))
                }
                items.append(MatchItem(shotID: id, selections: selections, withoutImage: status.names.count - ready.count))
            }
        }
        return items
    }

    /// 匹配时会先存进素材库的图（这一版还没入库；去重）
    static func matchNeedsLibrary(_ plan: [MatchItem], app: AppModel) -> Int {
        notInLibrary(cardIDs: plan.flatMap { $0.selections.map(\.cardID) }, app: app).count
    }

    struct MatchReport: Equatable {
        var shots = 0
        var applied = 0
        /// 头行里还没有图的名字（先提取、出图）
        var withoutImage = 0
        var notInHeadLine = 0
    }

    /// 对选中各集的每一段做「应用素材」：没入库的先入库，再挂到分镜上
    @discardableResult
    static func match(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> MatchReport {
        match(matchPlan(board: board, indices: indices, app: app), app: app)
    }

    @discardableResult
    static func match(_ plan: [MatchItem], app: AppModel) -> MatchReport {
        var report = MatchReport()
        for item in plan {
            report.shots += 1
            report.withoutImage += item.withoutImage
            guard !item.selections.isEmpty else { continue }
            let applied = WorkbenchVersions.apply(selections: item.selections, shotID: item.shotID, cards: app.currentImageItems, app: app)
            report.applied += applied.applied
            report.withoutImage += applied.noImage
            report.notInHeadLine += applied.notInHeadLine
            // 挂着的图提示词里却没有「图N」（用户在提示词里删了字，素材区不跟着删，2026-10-16 用户定）：补回来。候选给空 = 不挂新图
            app.autoMatchMaterials(item.shotID, candidates: [], detectsDuration: false)
        }
        return report
    }

    // MARK: 生视频

    static func videoModelConfigured(_ shot: ShotDraft, app: AppModel) -> Bool {
        !app.videoModelNames.isEmpty && app.videoModelNames.contains(shot.model)
    }

    /// 选中各集里可以提交的分镜：还没有视频（或上次失败）、参数合格、模型还在配置里。`blocked` = 候选里因为不合格被拦下的个数；
    /// `unmatched` = 能提交的里面，有素材图却还没挂到分镜上的（比如重新推理后参考图被清掉了，2026-10-12 逻辑审查）——照样能交，但视频里不会带这些参考图
    static func submittable(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> (ready: [ShotDraft], blocked: Int, unmatched: Int) {
        var ready: [ShotDraft] = [], blocked = 0, unmatched = 0
        for index in Set(indices).sorted() where board.episodes.indices.contains(index) {
            let episode = board.episodes[index]
            for id in episode.shotsToSubmit {
                guard let shot = app.shots.first(where: { $0.id == id }) else { continue }
                if ShotValidator.validate(shot).isEmpty, videoModelConfigured(shot, app: app) {
                    ready.append(shot)
                    if episode.unmatchedShotIDs.contains(id) { unmatched += 1 }
                } else { blocked += 1 }
            }
        }
        return (ready, blocked, unmatched)
    }

    /// 生视频页拖选的「批量提交」用：选中的分镜里，有素材图却还没挂上的有几张
    static func unmatchedCount(board: WorkbenchStatus.Board, shotIDs: Set<UUID>) -> Int {
        board.episodes.reduce(0) { $0 + $1.unmatchedShotIDs.filter { shotIDs.contains($0) }.count }
    }

    @discardableResult
    static func submitVideos(board: WorkbenchStatus.Board, indices: [Int], app: AppModel) -> Int {
        let ready = submittable(board: board, indices: indices, app: app).ready
        app.batchSubmitExecute(shots: ready)
        return ready.count
    }
}
