import Foundation

/// 一张生图卡被哪些分段用到（2026-10-10：生图右栏的「用到它的分段」）。
///
/// 一个分段「用到」一张卡 = 这一段分镜的头行 `[场景][角色][道具]` 里有这个名字，而且这一段**现在用的**正好是这张卡
/// （同一个名字有「第1集的周承山」「第24集的周承山」几个版本时，第 5 集的分镜用前一张）。
/// 现在用的哪张（2026-10-17 统一解析，和工作台的状态 / 匹配同一套）：这一段挂着的就按挂着的算
/// （`attachedCardID` 闭包，调用方用 `WorkbenchVersions.attachedCardID` 给；手动挂上 / 换过版本的算数），
/// 没挂才按集号选版本。名字一模一样的卡优先，没有再用「只差重名序号」的同名卡。
@MainActor
enum CardUsage {
    typealias Kind = PipelineFlow.ExtractionKind

    struct Entry: Equatable, Identifiable {
        var id: UUID { shotID }
        let shotID: UUID
        /// 「分镜1-1」
        let title: String
        /// 0 起
        let episodeIndex: Int
        /// 1 起
        let segment: Int
    }

    /// 第 `episode` 集（1 起）里 `name` 这个名字用的是哪张卡
    /// `stage`：这一段要的阶段（nil = 主时间线），别的阶段的卡不算（2026-10-14 名字与形态分离）
    /// `name` 也可以是逻辑名「周承山（四十岁）」（见 `StageName`）
    static func cardInForce(kind: Kind, name: String, stage: String? = nil, episode: Int, cards: [ImageGenItem]) -> ImageGenItem? {
        let logical = StageName.compose(name, stage: stage)
        let ofKind = cards.filter { $0.type == kind.subjectType }
        let exact = ofKind.filter { StageName.match(card: $0, logical: logical) == 2 }
        let family = ofKind.filter { StageName.match(card: $0, logical: logical) > 0 }
        for list in [exact, family] where !list.isEmpty {
            if let index = AssetVersionName.pick(versions: list.map(\.versionEpisode), episode: episode) {
                return list[index]
            }
        }
        return nil
    }

    /// 用到 `card` 的分段，按集、按段的顺序；不是场景 / 角色 / 道具卡（没有类型）或还没分集 = 空
    /// `attachedCardID`：这一段这个名字挂着的卡（调用方用 `WorkbenchVersions.attachedCardID` 给）；不给 = 只看版本规则
    ///
    /// ⚠️ 性能（2026-10-10 用户：进项目感觉慢；卡顿采样里这里占了主线程 ~18%）：原来每个分镜的每个名字都把全部卡过滤 + 解析一遍
    /// （段数 × 名字数 × 卡数 次字符串解析，右栏每次重算都跑）。现在同类型的卡**一次**按名字归好组（并算好各自的起效集号），
    /// 之后每个名字只是查表。选版本的规则和 `cardInForce` 完全一样（测试里对拍）。
    static func entries(for card: ImageGenItem, cards: [ImageGenItem], shots: [ShotDraft], archive: ProjectPipelineArchive?,
                        attachedCardID: ((Kind, String, ShotDraft) -> UUID?)? = nil,
                        title: (ShotDraft) -> String) -> [Entry] {
        guard let type = card.type, let kind = Kind.allCases.first(where: { $0.subjectType == type }), let archive else { return [] }
        // 名字一模一样（去掉「第N集的」之后）的卡 / 只差重名序号的卡，按（名字, 阶段）分组；组内保持原顺序，带着各自的起效集号
        struct Key: Hashable { var name: String; var stage: String? }
        var exact: [Key: [(card: ImageGenItem, episode: Int)]] = [:]
        var family: [Key: [(card: ImageGenItem, episode: Int)]] = [:]
        for candidate in cards where candidate.type == type {
            let base = candidate.baseName, stage = CardVersion.normalizedStage(candidate.stage)
            let entry = (card: candidate, episode: candidate.versionEpisode)
            exact[Key(name: base, stage: stage), default: []].append(entry)
            family[Key(name: AssetVersionName.withoutDuplicateNumber(base), stage: stage), default: []].append(entry)
        }
        /// 逻辑名「周承山（四十岁）」：先按整个名字、主时间线找（旧卡就叫「沈砚（少年）」的），再拆成（名字, 阶段）找。和 `StageName.match` 同一个口径
        func inForce(_ logical: String, episode: Int) -> ImageGenItem? {
            var lists = [exact[Key(name: logical, stage: nil)], family[Key(name: AssetVersionName.withoutDuplicateNumber(logical), stage: nil)]]
            let (name, stage) = StageName.split(logical)
            if let stage {
                lists += [exact[Key(name: name, stage: stage)], family[Key(name: AssetVersionName.withoutDuplicateNumber(name), stage: stage)]]
            }
            for list in lists {
                guard let list, !list.isEmpty else { continue }
                if let index = AssetVersionName.pick(versions: list.map(\.episode), episode: episode) { return list[index].card }
            }
            return nil
        }
        let byID = Dictionary(shots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Entry] = []
        for (episodeIndex, episode) in archive.episodes.enumerated() {
            let stagesByShot = kind == .role ? SplitSegments.stagesByShot(episode) : [:]
            for (offset, id) in episode.pairedShotIDs.enumerated() {
                guard let shot = byID[id], let head = StoryboardNames.head(of: shot.prompt) else { continue }
                let names: [String]
                switch kind {
                case .scene: names = head.scenes
                case .role: names = head.roles.map { StageName.logical($0, stages: stagesByShot[id] ?? [:]) }
                case .prop: names = head.props
                }
                if names.contains(where: { name in
                    (attachedCardID?(kind, name, shot) ?? inForce(name, episode: episodeIndex + 1)?.id) == card.id
                }) {
                    result.append(Entry(shotID: id, title: title(shot), episodeIndex: episodeIndex, segment: offset + 1))
                }
            }
        }
        return result
    }
}

extension AppModel {
    /// 跳到工作台的某一集某一段（生图页「用到它的分段」点进去用）
    func workbenchOpenSegment(episodeIndex: Int, segment: Int) {
        guard let key = currentProjectKey, var archive = pipelineArchive(for: key), archive.episodes.indices.contains(episodeIndex) else { return }
        if archive.epIndex != episodeIndex {
            archive.epIndex = episodeIndex
            savePipelineArchive(archive, for: key)
        }
        workbenchLocations[key] = .init(projectKey: key, episodeIndex: episodeIndex, segment: segment)
        openScriptPage()
    }
}
