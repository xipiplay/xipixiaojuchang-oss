import Foundation

/// 工作台（2026-10-09）：每一集的「下一步」和底部流水线胶囊的进度。
/// 不碰界面、不碰 AI——只从现有数据（分集 / 分镜卡 / 生图卡 / 素材库 / 视频任务）算出来，所以和各页面永远是一份数据。
///
/// 一集的下一步，按流水线顺序看第一个没做完的：
/// 分割 → 命名（每段的场景 / 角色 / 道具 / 本段在场）→ 推理分镜 → 提取素材（头行里的名字有没有卡）→ 出图（用到的卡有没有图）→ 匹配素材（分镜有没有挂上这些图）→ 生成视频。
enum WorkbenchStatus {
    typealias Kind = PipelineFlow.ExtractionKind

    enum VideoState: Equatable { case none, running, completed, failed }

    enum Stage: Equatable {
        case toSplit, toName, toInfer, toExtract, toGenerateImages, toMatch, toGenerateVideo, generatingVideo, done

        var title: String {
            switch self {
            case .toSplit: "待分割"
            case .toName: "待命名"
            case .toInfer: "待推理分镜"
            case .toExtract: "待提取素材"
            case .toGenerateImages: "待出图"
            case .toMatch: "待匹配素材"
            case .toGenerateVideo: "待生成视频"
            case .generatingVideo: "视频生成中"
            case .done: "已完成"
            }
        }
    }

    struct Progress: Equatable {
        var done = 0
        var total = 0
        var isComplete: Bool { total > 0 && done >= total }
    }

    /// 头行里的一个名字现在的情况：有卡有图 / 有卡没图 / 没有卡
    enum NameState: Equatable { case ready, noImage, missing }
    /// 有卡没图的名字，这张卡的出图现在怎么样：还没动 / 正在出（排队、生成、下载）/ 上次出失败了
    enum ImageActivity: Equatable { case idle, running, failed }
    struct NameStatus: Equatable {
        var kind: Kind
        var name: String
        var state: NameState
        /// 只在 `state == .noImage` 时有意义
        var activity: ImageActivity = .idle
    }
    /// 一段分镜自己的下一步（和一集的下一步同一套规则，只看这一段）
    struct ShotStatus: Equatable {
        var stage: Stage
        var names: [NameStatus]
        var video: VideoState

        /// 这一段缺图的名字里，有没有正在出的 / 出失败的
        var imagesRunning: Bool { names.contains { $0.state == .noImage && $0.activity == .running } }
        var imagesFailed: Bool { names.contains { $0.state == .noImage && $0.activity == .failed } }

        /// 卡片右上角的状态字：视频失败最醒目；缺图时区分「出图中 / 出图失败 / 待出图」
        var title: String {
            if video == .failed { return "视频失败" }
            guard stage == .toGenerateImages else { return stage.title }
            if imagesRunning { return "出图中" }
            return imagesFailed ? "出图失败" : stage.title
        }
        var isProblem: Bool { video == .failed || (stage == .toGenerateImages && !imagesRunning && imagesFailed) }

        /// 卡片底部那一排小圆点：这一段的四步各走到哪了（还没做 / 正在做 / 做完了 / 出了问题）
        enum StepState: Equatable { case pending, running, done, problem }
        struct Steps: Equatable {
            var extract: StepState
            var images: StepState
            var match: StepState
            var video: StepState
        }
        var steps: Steps {
            let missing = names.contains { $0.state == .missing }
            let noImage = names.contains { $0.state == .noImage }
            let images: StepState = missing ? .pending
                : (!noImage ? .done : (imagesRunning ? .running : (imagesFailed ? .problem : .pending)))
            let matched = stage == .toGenerateVideo || stage == .generatingVideo || stage == .done
            let video: StepState
            switch self.video {
            case .completed: video = .done
            case .running: video = .running
            case .failed: video = .problem
            case .none: video = .pending
            }
            return Steps(extract: missing ? .pending : .done, images: images, match: matched ? .done : .pending, video: video)
        }
    }

    /// 一集的状态，还带着「这一集要做的事」的清单（胶囊的出图 / 匹配 / 生视频按它们算范围，和这里的数字永远一致）
    struct EpisodeStatus: Equatable {
        var stage: Stage = .toSplit
        /// 补充说明（缺几张卡、已匹配几段……），可空
        var detail = ""
        var hasFailure = false
        /// 这一集有提示词的分镜（按段序）
        var shotIDs: [UUID] = []
        /// 这一集用到、还没有图的卡（每个名字取它在这一集的版本；变化版的基础版排在前面）
        var cardsToGenerate: [UUID] = []
        /// 其中正在出图（排队 / 生成 / 下载）的、上次出图失败的各有几张
        var imagesRunning = 0
        var imagesFailed = 0
        /// 这一集用到的名字里**没有卡**的（按类型）
        var missingNames: [Kind: [String]] = [:]
        /// 头行里的名字有图、但分镜还没挂上这些图的分镜
        var unmatchedShotIDs: [UUID] = []
        /// 还没有视频、或最近一次失败的分镜（可以提交的候选）
        var shotsToSubmit: [UUID] = []
        /// 每段分镜自己的状态（分段卡片用）
        var shots: [UUID: ShotStatus] = [:]

        /// 一行字：「待提取素材 · 缺 3 张卡」
        var line: String { detail.isEmpty ? stage.title : "\(stage.title) · \(detail)" }
    }

    /// 底部胶囊每一步的进度（整个项目）
    struct Totals: Equatable {
        var split = Progress()
        var naming = Progress()
        var infer = Progress()
        var names: [Kind: Progress] = [:]
        var images = Progress()
        var match = Progress()
        var video = Progress()
    }

    struct Board: Equatable {
        var episodes: [EpisodeStatus] = []
        var totals = Totals()
        /// 「其他分镜」（2026-10-14 把生视频并进工作台）：不属于任何一集的分镜，按项目里的先后（早期直接在生视频页做的、手动新建的）
        var otherShotIDs: [UUID] = []
        /// 它们各自的状态：头行里的名字挑「全程有效」的版本（相当于第 0 集——没有集号可按）
        var others: [UUID: ShotStatus] = [:]
    }

    struct Inputs {
        var episodes: [Episode]
        /// 这个项目的分镜卡（按 ID 找）
        var shots: [UUID: ShotDraft]
        /// 这个项目的生图卡
        var cards: [ImageGenItem]
        /// 素材库条目的匹配关键词（`LibraryItem.matchKeyword`）
        var libraryKeyword: (UUID) -> String?
        var videoState: (ShotDraft) -> VideoState
        /// 素材库条目是从哪张生图卡入库的（`LibraryItem.imageGenItemID`）：挂没挂上按卡的名字 + 阶段认，不只看关键词
        var libraryCardID: (UUID) -> UUID? = { _ in nil }
        /// 这个项目分镜的先后（`shots` 是字典、没有顺序）：「其他分镜」按它排。空 = 不算「其他分镜」
        var shotOrder: [UUID] = []
    }

    private struct NameKey: Hashable {
        var type: ImageSubjectType
        var name: String
        /// 阶段（`ImageGenItem.stage`；nil = 主时间线）：不同阶段是不同的一组，不互相顶替
        var stage: String? = nil
    }

    /// 一张分镜的参考图解码结果 + 名字归属判断（2026-10-17）：这一段「挂没挂、挂的是哪张」只在这里认一次，
    /// 状态 / 匹配 / 选集统一用它——原来状态只按「按集号选的默认卡」算，手动挂上的旧图被同名空卡盖住，
    /// 显示「待出图」、自动匹配也跳过（用户：项目82 第7集的空卡遮住第6集已出图的卡）。
    /// 认法：名字一模一样的参考图优先；只差重名序号的兄弟也算，除非头行里另有一行正好是那张图的名字。
    private struct ShotRefs {
        let headNames: [String]
        let refs: [(card: ImageGenItem?, keyword: String?)]
        /// 这张参考图算不算 `name` 这个名字的（2 一模一样 / 1 只差重名序号 / 0 不相干）
        func level(_ ref: (card: ImageGenItem?, keyword: String?), _ name: String) -> Int {
            if let card = ref.card { return StageName.match(card: card, logical: name) }
            guard let keyword = ref.keyword else { return 0 }
            let whole = AssetVersionName.match(keyword, to: name)
            return whole > 0 ? whole : AssetVersionName.match(keyword, to: StageName.split(name).name)
        }
        func isAttached(_ name: String) -> Bool {
            refs.contains { ref in
                switch level(ref, name) {
                case 2: return true
                case 1: return !headNames.contains { $0 != name && level(ref, $0) == 2 }
                default: return false
                }
            }
        }
        /// 这一段挂着的 `name` 的那张卡（名字一模一样的优先）。没挂 / 认不出卡 = nil
        func attachedCard(kind: Kind, name: String) -> ImageGenItem? {
            var sibling: ImageGenItem?
            for ref in refs {
                switch level(ref, name) {
                case 2:
                    if let card = ref.card, card.type == kind.subjectType { return card }
                case 1:
                    if sibling == nil, let card = ref.card, card.type == kind.subjectType,
                       !headNames.contains(where: { $0 != name && level(ref, $0) == 2 }) { sibling = card }
                default: break
                }
            }
            return sibling
        }
    }

    static func board(_ input: Inputs) -> Board {
        // 卡片按（类型, 基础名）归组：「第1集的周承山」「第24集的周承山」是同一个名字的两个版本；
        // 再按（类型, 去掉重名序号的名字）归一组：「周承山 2」是「周承山」又提取一次的卡，没有名字一模一样的卡可用时拿它们顶
        var versions: [NameKey: [ImageGenItem]] = [:]
        var families: [NameKey: [ImageGenItem]] = [:]
        for card in input.cards {
            guard let type = card.type else { continue }
            let base = card.baseName, stage = CardVersion.normalizedStage(card.stage)
            versions[NameKey(type: type, name: base, stage: stage), default: []].append(card)
            families[NameKey(type: type, name: AssetVersionName.withoutDuplicateNumber(base), stage: stage), default: []].append(card)
        }
        // 每张卡的起始集只算一次（原来每挑一次版本就把这个名字下所有卡的名字再用正则解析一遍，
        // 同一个名字一集要挑几十次——600 段的项目里这是大头，2026-10-13 稳定性）
        var episodeOfCard: [UUID: Int] = [:]
        for card in input.cards { episodeOfCard[card.id] = card.versionEpisode }
        let cardsByID = Dictionary(input.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct PickKey: Hashable { var type: ImageSubjectType; var name: String; var episode: Int }
        var picked: [PickKey: ImageGenItem?] = [:]
        /// 逻辑名（「周承山（四十岁）」，见 `StageName`）能对上的卡组：先按整个名字、主时间线找（旧卡就叫「沈砚（少年）」的），找不到再拆成（名字, 阶段）
        func groups(_ kind: Kind, _ logical: String) -> [[ImageGenItem]?] {
            let type = kind.subjectType
            var result: [[ImageGenItem]?] = [versions[NameKey(type: type, name: logical)],
                                              families[NameKey(type: type, name: AssetVersionName.withoutDuplicateNumber(logical))]]
            let (name, stage) = StageName.split(logical)
            if let stage {
                result += [versions[NameKey(type: type, name: name, stage: stage)],
                           families[NameKey(type: type, name: AssetVersionName.withoutDuplicateNumber(name), stage: stage)]]
            }
            return result
        }
        func pick(_ kind: Kind, _ name: String, episode: Int) -> ImageGenItem? {
            let key = PickKey(type: kind.subjectType, name: name, episode: episode)
            if let hit = picked[key] { return hit }
            var result: ImageGenItem?
            for list in groups(kind, name) {
                if let list, let index = AssetVersionName.pick(versions: list.map { episodeOfCard[$0.id] ?? 0 }, episode: episode) {
                    result = list[index]
                    break
                }
            }
            picked[key] = result
            return result
        }
        func hasImage(_ card: ImageGenItem) -> Bool { !card.results.isEmpty }

        var board = Board()
        var allNames: [Kind: Set<String>] = [:]
        var coveredNames: [Kind: Set<String>] = [:]
        var pickedCards: [UUID: Bool] = [:]       // 用到的卡 → 有没有图
        var shotTotal = 0, shotMatched = 0, shotCompleted = 0
        // 胶囊上的「匹配 n/m」只数**真的挂好了**的：有名字还没卡、还没图的分镜，现在还谈不上匹配

        for (index, episode) in input.episodes.enumerated() {
            let number = index + 1
            var status = EpisodeStatus()
            let hasSplit = !(episode.splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // 分割改过、段和卡对不上时是空的（`pairedShotIDs`）：这一集回到「待推理分镜」
            let shots = episode.pairedShotIDs.compactMap { input.shots[$0] }
                .filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            status.shotIDs = shots.map(\.id)
            // 命名：每一段都有场景和角色（分割自带头行的旧数据也算）。算一次，下面定下一步时还要用
            let named = hasSplit && SplitSegments.isNamed(episode.splitText ?? "")
            if hasSplit { board.totals.split.done += 1 }
            if named { board.totals.naming.done += 1 }
            if !shots.isEmpty { board.totals.infer.done += 1 }

            // 头行里的名字 → 这一集用到的卡
            var needed: [Kind: [String]] = [:]
            var shotNames: [UUID: [(Kind, String)]] = [:]
            // 头行里只写基础名；这一段的【阶段】（分割文本里）把它合成逻辑名「周承山（四十岁）」
            let stagesByShot = SplitSegments.stagesByShot(episode)
            for shot in shots {
                guard let head = StoryboardNames.head(of: shot.prompt) else { continue }
                let stages = stagesByShot[shot.id] ?? [:]
                let headGroups: [(Kind, [String])] = [(.scene, head.scenes), (.role, head.roles.map { StageName.logical($0, stages: stages) }), (.prop, head.props)]
                for (kind, names) in headGroups {
                    for name in names {
                        if !(needed[kind]?.contains(name) ?? false) { needed[kind, default: []].append(name) }
                        shotNames[shot.id, default: []].append((kind, name))
                    }
                }
            }
            for kind in Kind.allCases {
                for name in needed[kind] ?? [] {
                    allNames[kind, default: []].insert(name)
                    if groups(kind, name).contains(where: { $0 != nil }) { coveredNames[kind, default: []].insert(name) }
                }
            }
            // 每一段的参考图解码一次，后面选集 / 匹配 / 状态一起用
            var shotRefs: [UUID: ShotRefs] = [:]
            for shot in shots {
                shotRefs[shot.id] = ShotRefs(headNames: (shotNames[shot.id] ?? []).map(\.1), refs: shot.imageRefs.map { ref in
                    (input.libraryCardID(ref.libraryItemID).flatMap { cardsByID[$0] }, input.libraryKeyword(ref.libraryItemID))
                })
            }
            // 每个名字用哪张卡：这一段挂着的优先，没挂才按集号选版本（2026-10-17：同名空卡不再盖住挂上的旧图）
            var toGenerate: [ImageGenItem] = []
            for shot in shots {
                guard let refs = shotRefs[shot.id] else { continue }
                for (kind, name) in shotNames[shot.id] ?? [] {
                    guard let card = refs.attachedCard(kind: kind, name: name) ?? pick(kind, name, episode: number) else {
                        if !(status.missingNames[kind]?.contains(name) ?? false) { status.missingNames[kind, default: []].append(name) }
                        continue
                    }
                    pickedCards[card.id] = hasImage(card)
                    if !hasImage(card), !toGenerate.contains(where: { $0.id == card.id }) { toGenerate.append(card) }
                }
            }
            // 变化版要等基础版出图：基础版（没图的）排在前面，一起进清单
            var ordered: [ImageGenItem] = []
            func append(_ card: ImageGenItem) {
                guard !ordered.contains(where: { $0.id == card.id }), !hasImage(card) else { return }
                if let baseID = card.referenceCardID, let base = cardsByID[baseID] { append(base) }
                ordered.append(card)
            }
            toGenerate.forEach(append)
            status.cardsToGenerate = ordered.map(\.id)
            status.imagesRunning = ordered.filter { $0.status.isBusy }.count
            status.imagesFailed = ordered.filter { !$0.status.isBusy && $0.status == .failed }.count

            // 匹配：头行里的名字「现在用的那张」有图的，分镜的参考图里要有它
            var fullyMatched = 0
            for shot in shots {
                guard let refs = shotRefs[shot.id] else { continue }
                let names = shotNames[shot.id] ?? []
                let wanted: [String] = names.compactMap { kind, name in
                    guard let card = refs.attachedCard(kind: kind, name: name) ?? pick(kind, name, episode: number), hasImage(card) else { return nil }
                    return name
                }
                let attachedAll = wanted.allSatisfy { refs.isAttached($0) }
                if !attachedAll { status.unmatchedShotIDs.append(shot.id) }
                if attachedAll, wanted.count == names.count { fullyMatched += 1 }
            }

            // 视频
            var running = 0, completed = 0, failed = 0
            for shot in shots {
                switch input.videoState(shot) {
                case .running: running += 1
                case .completed: completed += 1
                case .failed: failed += 1; status.shotsToSubmit.append(shot.id)
                case .none: status.shotsToSubmit.append(shot.id)
                }
            }
            for shot in shots {
                let refs = shotRefs[shot.id]
                let names = (shotNames[shot.id] ?? []).map { kind, name -> NameStatus in
                    guard let card = refs?.attachedCard(kind: kind, name: name) ?? pick(kind, name, episode: number) else { return NameStatus(kind: kind, name: name, state: .missing) }
                    if hasImage(card) { return NameStatus(kind: kind, name: name, state: .ready) }
                    return NameStatus(kind: kind, name: name, state: .noImage, activity: card.status.isBusy ? .running : (card.status == .failed ? .failed : .idle))
                }
                let video = input.videoState(shot)
                let stage: Stage
                if names.contains(where: { $0.state == .missing }) { stage = .toExtract }
                else if names.contains(where: { $0.state == .noImage }) { stage = .toGenerateImages }
                else if status.unmatchedShotIDs.contains(shot.id) { stage = .toMatch }
                else {
                    switch video {
                    case .running: stage = .generatingVideo
                    case .completed: stage = .done
                    case .none, .failed: stage = .toGenerateVideo
                    }
                }
                status.shots[shot.id] = ShotStatus(stage: stage, names: names, video: video)
            }
            shotTotal += shots.count
            shotMatched += fullyMatched
            shotCompleted += completed
            status.hasFailure = failed > 0 || status.imagesFailed > 0

            // 下一步
            let missingCount = status.missingNames.values.reduce(0) { $0 + $1.count }
            let failedNote = failed > 0 ? "\(failed) 段失败" : ""
            func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
            if !hasSplit {
                status.stage = .toSplit
            } else if shots.isEmpty {
                status.stage = named ? .toInfer : .toName
                if episode.storyboardIsStale { status.detail = "分割改过，要重新推理分镜" }
            } else if missingCount > 0 {
                status.stage = .toExtract
                status.detail = "缺 \(missingCount) 张卡"
            } else if !status.cardsToGenerate.isEmpty {
                status.stage = .toGenerateImages
                status.detail = joined("\(status.cardsToGenerate.count) 张没有图",
                                       status.imagesRunning > 0 ? "\(status.imagesRunning) 张出图中" : "",
                                       status.imagesFailed > 0 ? "\(status.imagesFailed) 张出图失败" : "")
            } else if !status.unmatchedShotIDs.isEmpty {
                status.stage = .toMatch
                status.detail = "已匹配 \(shots.count - status.unmatchedShotIDs.count)/\(shots.count) 段"
            } else if running > 0 {
                status.stage = .generatingVideo
                status.detail = joined("已完成 \(completed)/\(shots.count) 段", failedNote)
            } else if completed == shots.count {
                status.stage = .done
                status.detail = "\(shots.count) 段"
            } else {
                status.stage = .toGenerateVideo
                status.detail = joined(completed > 0 ? "已完成 \(completed)/\(shots.count) 段" : "\(shots.count) 段", failedNote)
            }
            board.episodes.append(status)
        }

        board.totals.split.total = input.episodes.count
        board.totals.naming.total = input.episodes.count
        board.totals.infer.total = input.episodes.count
        for kind in Kind.allCases {
            board.totals.names[kind] = Progress(done: coveredNames[kind]?.count ?? 0, total: allNames[kind]?.count ?? 0)
        }
        board.totals.images = Progress(done: pickedCards.values.filter { $0 }.count, total: pickedCards.count)
        board.totals.match = Progress(done: shotMatched, total: shotTotal)
        board.totals.video = Progress(done: shotCompleted, total: shotTotal)

        // 「其他分镜」：不属于任何一集的（任何一集的分镜列表里都没有它；分割改过、还没重新配对的也算那一集的）
        let inEpisodes = Set(input.episodes.flatMap { $0.shotIDs ?? [] })
        board.otherShotIDs = input.shotOrder.filter { !inEpisodes.contains($0) && input.shots[$0] != nil }
        for id in board.otherShotIDs {
            guard let shot = input.shots[id] else { continue }
            board.others[id] = otherStatus(shot)
        }
        return board

        /// 一张「其他分镜」的状态：和集里的分镜同一套规则，挑版本按第 0 集（只认全程有效的版本）
        func otherStatus(_ shot: ShotDraft) -> ShotStatus {
            let head = StoryboardNames.head(of: shot.prompt)
            let names: [(Kind, String)] = head.map { h in h.scenes.map { (Kind.scene, $0) } + h.roles.map { (.role, $0) } + h.props.map { (.prop, $0) } } ?? []
            let refs = ShotRefs(headNames: names.map(\.1), refs: shot.imageRefs.map { ref in
                (input.libraryCardID(ref.libraryItemID).flatMap { cardsByID[$0] }, input.libraryKeyword(ref.libraryItemID))
            })
            let statuses = names.map { kind, name -> NameStatus in
                guard let card = refs.attachedCard(kind: kind, name: name) ?? pick(kind, name, episode: 0) else { return NameStatus(kind: kind, name: name, state: .missing) }
                if hasImage(card) { return NameStatus(kind: kind, name: name, state: .ready) }
                return NameStatus(kind: kind, name: name, state: .noImage, activity: card.status.isBusy ? .running : (card.status == .failed ? .failed : .idle))
            }
            let unmatched = statuses.contains { status in
                status.state == .ready && !refs.isAttached(status.name)
            }
            let video = input.videoState(shot)
            let stage: Stage
            if statuses.contains(where: { $0.state == .missing }) { stage = .toExtract }
            else if statuses.contains(where: { $0.state == .noImage }) { stage = .toGenerateImages }
            else if unmatched { stage = .toMatch }
            else {
                switch video {
                case .running: stage = .generatingVideo
                case .completed: stage = .done
                case .none, .failed: stage = .toGenerateVideo
                }
            }
            return ShotStatus(stage: stage, names: statuses, video: video)
        }
    }
}
