import Foundation

/// 一段分镜里每个素材名的「版本」：列出同一个名字的所有卡（`第1集的周承山` / `第24集的周承山` / 没有前缀的），
/// 看这一段现在用的是哪个，换成另一个（2026-10-09 工作台第 3 步）。
/// 换版本只动这一段分镜自己的参考图，不碰卡片和素材库里别的东西；提示词里的「图N」编号不变。
@MainActor
enum WorkbenchVersions {
    typealias Kind = PipelineFlow.ExtractionKind

    struct Version: Equatable, Identifiable {
        var id: UUID { cardID }
        let cardID: UUID
        /// 「基础版」「第24集起」
        let label: String
        let cardName: String
        /// 这张卡现在显示的那张图（没选就最新）的本地路径；没图 = nil
        let imagePath: String?
        let hasImage: Bool
    }

    /// 卡片现在显示的那一版结果（`selectedResultID` 命中的，没选就最新）
    static func displayedResult(of card: ImageGenItem) -> ImageGenResult? {
        card.results.first { $0.id == card.selectedResultID } ?? card.latestResult
    }

    /// 另一个名字和 `name` 的关系（2 一模一样 / 1 只差重名序号 / 0 不相干，见 `AssetVersionName.match`）。
    /// 2026-10-10 用户实测：重新提取年轻时的周承山得到「周承山 2」，换版本的列表里却只有「周承山」——所以「只差重名序号」的也算这个名字的版本。
    static func nameMatch(_ other: String, to name: String) -> Int { AssetVersionName.match(other, to: name) }

    /// 这个名字的候选卡：名字一模一样的优先（有的话只用它们），没有才用「只差重名序号」的那些。
    /// `stage`：这一段要的阶段（nil = 主时间线）；别的阶段的卡不算（2026-10-14 名字与形态分离）
    /// `name` 可以是逻辑名「周承山（四十岁）」（见 `StageName`），也可以名字 + `stage` 分开给
    private static func candidates(kind: Kind, name: String, stage: String?, cards: [ImageGenItem]) -> [ImageGenItem] {
        let logical = StageName.compose(name, stage: stage)
        let related = cards.filter { $0.type == kind.subjectType }.map { ($0, StageName.match(card: $0, logical: logical)) }.filter { $0.1 > 0 }
        let exact = related.filter { $0.1 == 2 }.map(\.0)
        return exact.isEmpty ? related.map(\.0) : exact
    }

    /// 这个名字在项目里这个阶段的所有版本（含「只差重名序号」的同名卡），按起始集从早到晚
    static func versions(kind: Kind, name: String, stage: String? = nil, cards: [ImageGenItem]) -> [Version] {
        let logical = StageName.compose(name, stage: stage)
        return cards.filter { $0.type == kind.subjectType && StageName.match(card: $0, logical: logical) > 0 }
            .enumerated()
            .sorted { lhs, rhs in (lhs.element.versionEpisode, lhs.offset) < (rhs.element.versionEpisode, rhs.offset) }
            .map { _, card in
                let result = displayedResult(of: card)
                var label = card.versionNote ?? "基础版"
                if let number = AssetVersionName.duplicateNumber(card.baseName) { label += "（同名 \(number)）" }
                return Version(cardID: card.id, label: label, cardName: card.name,
                               imagePath: result?.localPath, hasImage: result != nil)
            }
    }

    /// 这一段的分镜**已经挂上**的是这个名字的哪张卡（参考图里挂着的、属于这个名字的那张图，对应到哪张卡）；没挂 = nil
    /// `library`：按 ID 找素材库条目（默认在整个素材库里线性找；分段页一次要问几百次，传一个字典查表进来）
    static func attachedCardID(kind: Kind, name: String, stage: String? = nil, shot: ShotDraft, cards: [ImageGenItem], app: AppModel,
                               library: ((UUID) -> LibraryItem?)? = nil) -> UUID? {
        let lookup = library ?? { app.libraryItem($0) }
        let logical = StageName.compose(name, stage: stage)
        let pool = cards.filter { $0.type == kind.subjectType && StageName.match(card: $0, logical: logical) > 0 }
        for index in ownedRefIndices(name: logical, shot: shot, app: app, library: lookup) {
            guard let resultID = lookup(shot.imageRefs[index].libraryItemID)?.imageGenResultID,
                  let card = pool.first(where: { $0.results.contains { $0.id == resultID } }) else { continue }
            return card.id
        }
        return nil
    }

    /// 这一段现在用的是哪个版本：挂着的那张；没挂就按这一集该用哪个版本
    static func currentCardID(kind: Kind, name: String, stage: String? = nil, shot: ShotDraft, episode: Int, cards: [ImageGenItem], app: AppModel,
                              library: ((UUID) -> LibraryItem?)? = nil) -> UUID? {
        if let attached = attachedCardID(kind: kind, name: name, stage: stage, shot: shot, cards: cards, app: app, library: library) { return attached }
        let pool = candidates(kind: kind, name: name, stage: stage, cards: cards)
        guard let index = AssetVersionName.pick(versions: pool.map(\.versionEpisode), episode: episode) else { return nil }
        return pool[index].id
    }

    enum Outcome: Equatable {
        /// 这一段原来就挂着这个名字的图：原位换成了这个版本
        case swapped
        /// 这一段原来没挂：按名字在头行里插了「图N」并挂上了
        case attached
        /// 头行里找不到这个名字，没法挂
        case notInHeadLine
        /// 这个版本没有图 / 入库没成功
        case noImage
    }

    /// 让这一段分镜用 `card` 这个版本。需要时把那张图入库（和匹配素材同一个做法）
    @discardableResult
    static func use(card: ImageGenItem, name: String, shotID: UUID, app: AppModel) -> Outcome {
        guard let result = displayedResult(of: card) else { return .noImage }
        guard let libraryID = app.library.first(where: { $0.imageGenResultID == result.id })?.id
                ?? app.saveImageItemToLibrary(card.id, resultID: result.id),
              let libraryItem = app.libraryItem(libraryID),
              let shotIndex = app.shots.firstIndex(where: { $0.id == shotID }) else { return .noImage }
        let refs = app.shots[shotIndex].imageRefs
        // 挂着的是同一个人别的阶段的图（这一段后来标了【阶段】，原来挂的是主时间线那张）：也原位换掉
        if let k = ownedRefIndices(name: name, shot: app.shots[shotIndex], app: app).first
            ?? otherStageRefIndex(of: card, shot: app.shots[shotIndex], app: app) {
            if refs[k].libraryItemID != libraryID {
                app.shots[shotIndex].imageRefs[k] = MaterialRef(id: refs[k].id, libraryItemID: libraryID, role: refs[k].role)
                app.persistShots()
            }
            return .swapped
        }
        // 选的是「周承山 2」这样的同名卡时，匹配会按头行里那一行的名字（「周承山」）去找它（见 `autoMatchMaterials` 的 `slotName`）
        return app.autoMatchMaterials(shotID, candidates: [libraryItem], detectsDuration: false) > 0 ? .attached : .notInHeadLine
    }

    /// 这一段分镜的参考图里，属于 `name` 这一行的那些（下标，名字一模一样的在前）。
    /// 只差重名序号的也算（行里写「周承山」、挂着「周承山 2」的图），除非头行里另有一行的名字正好就是那张图的名字——那张是人家的。
    /// 参考图里挂着的、和 `card` 同一个名字但**阶段不同**的那张（来源卡能认出来的才算）；没有 = nil。
    /// 同一段头行里两个阶段同时出现（「周承山（四十岁）、周承山」）时不算——那张是另一个阶段自己的
    static func otherStageRefIndex(of card: ImageGenItem, shot: ShotDraft, app: AppModel) -> Int? {
        let head = StoryboardNames.head(of: shot.prompt)
        let headNames = (head?.scenes ?? []) + (head?.roles ?? []) + (head?.props ?? [])
        return shot.imageRefs.indices.first { index in
            guard let cardID = app.libraryItem(shot.imageRefs[index].libraryItemID)?.imageGenItemID,
                  let other = app.imageItem(cardID),
                  other.id != card.id, other.type == card.type, !other.hasStage(card.stage),
                  nameMatch(other.name, to: card.baseName) > 0 else { return false }
            return !headNames.contains { StageName.split($0).name != $0 && StageName.match(card: other, logical: $0) > 0 }
        }
    }

    /// `name` 可以是逻辑名「周承山（四十岁）」：生图入库的图按来源卡的名字 + 阶段认（主时间线的「周承山」那张不算它的）；
    /// 别的素材只有关键词，按基础名认
    static func ownedRefIndices(name: String, shot: ShotDraft, app: AppModel, library: ((UUID) -> LibraryItem?)? = nil) -> [Int] {
        let lookup = library ?? { app.libraryItem($0) }
        let base = StageName.split(name).name
        let head = StoryboardNames.head(of: shot.prompt)
        let others = Set((head?.scenes ?? []) + (head?.roles ?? []) + (head?.props ?? [])).subtracting([name, base])
        var exact: [Int] = [], sibling: [Int] = []
        for (index, ref) in shot.imageRefs.enumerated() {
            guard let item = lookup(ref.libraryItemID) else { continue }
            let level: Int
            if let cardID = item.imageGenItemID, let card = app.imageItem(cardID) {
                level = StageName.match(card: card, logical: name)
            } else {
                let whole = nameMatch(item.matchKeyword, to: name)
                level = whole > 0 ? whole : nameMatch(item.matchKeyword, to: base)
            }
            switch level {
            case 2: exact.append(index)
            case 1: if !others.contains(where: { nameMatch(item.matchKeyword, to: $0) == 2 }) { sibling.append(index) }
            default: break
            }
        }
        return exact + sibling
    }

    struct ApplyReport: Equatable {
        /// 挂上 / 换好的素材个数
        var applied = 0
        /// 这个版本没有图（或入库没成功），跳过的
        var noImage = 0
        /// 头行里找不到这个名字，没法挂的
        var notInHeadLine = 0
    }

    /// 「应用素材」：把这一段**确定好的**每个素材（`selections`：名字 + 选中的版本卡）一个一个应用到分镜上——
    /// 原来挂着的原位换、没挂的在头行名字前插「图N」并挂上。只动这几个名字，不像「匹配素材」那样去素材库里按名字全找一遍。
    /// 没有选中版本 / 版本没有图的名字跳过，数进报告里。
    @discardableResult
    static func apply(selections: [(kind: Kind, name: String, cardID: UUID?)], shotID: UUID, cards: [ImageGenItem], app: AppModel) -> ApplyReport {
        var report = ApplyReport()
        for selection in selections {
            guard let cardID = selection.cardID, let card = cards.first(where: { $0.id == cardID }) else { report.noImage += 1; continue }
            switch use(card: card, name: selection.name, shotID: shotID, app: app) {
            case .swapped, .attached: report.applied += 1
            case .noImage: report.noImage += 1
            case .notInHeadLine: report.notInHeadLine += 1
            }
        }
        return report
    }

    /// 「添加素材」搜索框下面可以点的一项：生图页已经有的一个名字（同一个名字的几个版本合成一项）
    struct Suggestion: Equatable, Identifiable {
        var id: String { "\(kind.rawValue)|\(name)" }
        let kind: Kind
        let name: String
        /// 这个名字有几张卡（几个版本）
        let versions: Int
        /// 有没有哪一个版本已经出过图
        let hasImage: Bool
        /// 列表里显示的缩略图：最早一张出过图的卡现在显示的那张图（本地路径）；都没出过图 = nil
        var imagePath: String? = nil
    }

    /// 项目里所有有真名字、有类型的卡，按（类型, 基础名）合并；类型按 场景 → 角色 → 道具，同类型按名字排
    static func suggestions(cards: [ImageGenItem]) -> [Suggestion] {
        var order: [String] = []
        var grouped: [String: (kind: Kind, name: String, versions: Int, hasImage: Bool, imagePath: String?)] = [:]
        for card in cards {
            guard let type = card.type, let kind = Kind.allCases.first(where: { $0.subjectType == type }),
                  ImageCardNaming.placeholderNumber(of: card.name) == nil else { continue }
            let name = card.baseName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let key = "\(kind.rawValue)|\(name)"
            if grouped[key] == nil { order.append(key); grouped[key] = (kind, name, 0, false, nil) }
            grouped[key]!.versions += 1
            if !card.results.isEmpty { grouped[key]!.hasImage = true }
            if grouped[key]!.imagePath == nil, let path = displayedResult(of: card)?.localPath { grouped[key]!.imagePath = path }
        }
        let kinds = Kind.allCases
        return order.compactMap { grouped[$0] }
            .sorted { (kinds.firstIndex(of: $0.kind)!, $0.name) < (kinds.firstIndex(of: $1.kind)!, $1.name) }
            .map { Suggestion(kind: $0.kind, name: $0.name, versions: $0.versions, hasImage: $0.hasImage, imagePath: $0.imagePath) }
    }

    /// 只留这一类里名字包含搜索词的（不分大小写）；名字以搜索词开头的排在前面
    static func filter(_ list: [Suggestion], kind: Kind, query: String) -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ofKind = list.filter { $0.kind == kind }
        guard !q.isEmpty else { return ofKind }
        let matches = ofKind.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return matches.filter { $0.name.lowercased().hasPrefix(q.lowercased()) } + matches.filter { !$0.name.lowercased().hasPrefix(q.lowercased()) }
    }
}
