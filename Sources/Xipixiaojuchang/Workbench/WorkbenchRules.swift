import Foundation

// MARK: - 制作页的显示规则（纯函数，2026-10-07 P3-1）
//
// 制作页读的是 `ProjectDocument`（由旧数组换算出来，见 `AppModel.workbenchDocument`）。
// 这里只算「每集 / 每段现在做到哪了」，页面直接用，每条都有单测。

enum SegmentVideoState: Equatable {
    case none, running, paused, failed, done
}

struct EpisodeProgress: Equatable {
    var segments = 0
    var promptsReady = 0
    var videosDone = 0
    var videosRunning = 0
    var videosFailed = 0
    /// AI 写的名字对不上设定的个数（同一个名字只算一次）
    var unresolvedNames = 0
    /// 本集用到、但还没有任何图的设定数
    var settingsWithoutImage = 0
}

/// 一集的步骤条（剧本集：分段 → 提取素材 → 出图 → 挑定妆图 → 推理分镜 → 匹配素材 → 提交视频）
struct EpisodeStep: Equatable, Identifiable {
    enum State: Equatable { case done, current, todo }
    /// 要用户确认才往下走的步骤（挑定妆图 / 提交视频）
    var isGate: Bool
    var title: String
    var state: State
    var id: String { title }
}

enum WorkbenchRules {
    // MARK: 段

    static func hasPrompt(_ segment: SegmentRecord) -> Bool {
        !segment.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 以最近一次提交为准；之前成功过的视频照旧可以看（`displayedVideo`）
    static func videoState(_ segment: SegmentRecord) -> SegmentVideoState {
        guard let last = segment.videos.last else { return .none }
        switch last.phase {
        case .queued, .inProgress: return .running
        case .paused: return .paused
        case .failed: return .failed
        case .completed: return .done
        }
    }

    /// 提示词改过、但现有的视频还是按旧提示词生成的（失败的不算：它没出片）
    static func promptChangedSinceLastVideo(_ segment: SegmentRecord) -> Bool {
        guard hasPrompt(segment), let last = segment.videos.last(where: { $0.phase != .failed }) else { return false }
        return last.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            != segment.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 缩略图 / 版本条里「当前」那一版：用户指定的，否则最新成功的
    static func displayedVideo(_ segment: SegmentRecord) -> VideoVersion? {
        segment.selectedVideo
    }

    static func segmentTitle(_ segment: SegmentRecord, index: Int, isFree: Bool) -> String {
        if isFree, let n = segment.numbering { return "分镜 \(n.a)-\(n.b)" }
        return "第 \(index + 1) 段"
    }

    /// 「00:00–00:30」
    static func timecode(index: Int, segmentSeconds: Int) -> String {
        func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
        return "\(mmss(index * segmentSeconds))–\(mmss((index + 1) * segmentSeconds))"
    }

    /// 本段用到的设定，按提示词里出现的顺序；找不到的（已删除）跳过
    static func settings(of segment: SegmentRecord, in doc: ProjectDocument) -> [SettingRecord] {
        let byID = Dictionary(doc.settings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return segment.settingIDs.compactMap { byID[$0] }
    }

    // MARK: 集

    /// 本集用到的设定 ID：提取出来的 ∪ 各段用到的（自由集只有后者）
    static func usedSettingIDs(in episode: EpisodeRecord) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in episode.settingIDs + episode.segments.flatMap(\.settingIDs) where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    static func progress(of episode: EpisodeRecord, in doc: ProjectDocument) -> EpisodeProgress {
        var p = EpisodeProgress()
        p.segments = episode.segments.count
        for segment in episode.segments {
            if hasPrompt(segment) { p.promptsReady += 1 }
            switch videoState(segment) {
            case .done: p.videosDone += 1
            case .running: p.videosRunning += 1
            case .failed: p.videosFailed += 1
            case .none, .paused: break
            }
        }
        p.unresolvedNames = Set(episode.segments.flatMap(\.unresolvedNames)).count
        let byID = Dictionary(doc.settings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        p.settingsWithoutImage = usedSettingIDs(in: episode).filter { byID[$0]?.portrait == nil }.count
        return p
    }

    /// 对不上设定的名字 → 出现在第几段（1 起）
    static func unresolvedNames(in episode: EpisodeRecord) -> [(name: String, segments: [Int])] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (i, segment) in episode.segments.enumerated() {
            for name in segment.unresolvedNames {
                if map[name] == nil { order.append(name) }
                map[name, default: []].append(i + 1)
            }
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    static func settingsWithoutImage(in episode: EpisodeRecord, doc: ProjectDocument) -> [SettingRecord] {
        let byID = Dictionary(doc.settings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return usedSettingIDs(in: episode).compactMap { byID[$0] }.filter { $0.portrait == nil }
    }

    /// 步骤条。「挑定妆图」在 P3-1 里跟着「出图」走（用户明确挑过哪张的记录要等一键推进那一步才有）。
    static func steps(of episode: EpisodeRecord, in doc: ProjectDocument) -> [EpisodeStep] {
        let p = progress(of: episode, in: doc)
        let segmented = p.segments > 0
        let extracted = episode.assetsExtracted
        let imaged = extracted && p.settingsWithoutImage == 0
        let prompted = segmented && p.promptsReady == p.segments
        let videoed = segmented && p.videosDone == p.segments
        // 匹配素材：每一段都挂上了图（提示词里的「图N」和分镜卡的参考图是一起的）
        let matched = prompted && episode.segments.allSatisfy { segment in
            !segment.videos.isEmpty || segment.references.contains { $0.media == .image }
        }
        let flags = [segmented, extracted, imaged, imaged, prompted, matched, videoed]
        let titles = ["分段", "提取素材", "出图", "挑定妆图", "推理分镜", "匹配素材", "提交视频"]
        let gates: Set<String> = ["挑定妆图", "提交视频"]
        var foundCurrent = false
        return zip(titles, flags).map { title, done in
            let state: EpisodeStep.State
            if done { state = .done } else if !foundCurrent { state = .current; foundCurrent = true } else { state = .todo }
            return EpisodeStep(isGate: gates.contains(title), title: title, state: state)
        }
    }

    /// 段落表里一格文字最多显示多少字。
    ///
    /// ⚠️ **必须在交给 `Text` 之前截断**，不能靠 `.lineLimit`（2026-10-07 实测）：SwiftUI 为了知道哪里截断，
    /// 要把整段先排完；一条 2900 字的提示词压成一行，一行就要 ~210ms（系统的「最优换行」对长段落是平方级），
    /// 截到 90 字只要 ~10ms。段落表一屏十几行、点选 / 滚动都要重画，这就是「段落表好卡」的根因。
    static let excerptLimit = 90
    static let textExcerptLimit = 120

    /// 提示词在段落表里的摘要：跳过第一行的素材引用标签（「[图1…][图2…]」），其余压成一行，并截短
    static func promptExcerpt(_ prompt: String, limit: Int = excerptLimit) -> String {
        // 只看开头一小段：整条提示词有几千字，没必要全部拆开
        let head = prompt.prefix(limit * 6 + 400)
        var lines = head.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.count > 1, lines[0].hasPrefix("[") { lines.removeFirst() }
        return clipped(lines.joined(separator: " "), limit: limit)
    }

    /// 原文在段落表里的摘要（保留换行，截短）
    static func textExcerpt(_ text: String, limit: Int = textExcerptLimit) -> String {
        clipped(String(text.prefix(limit + 1)), limit: limit)
    }

    static func clipped(_ s: String, limit: Int) -> String {
        s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    /// 一句话进度：「4 段 · 视频 1/4」
    static func summaryLine(_ p: EpisodeProgress, textLength: Int, isFree: Bool) -> String {
        if p.segments == 0 { return isFree ? "还没有分镜" : "\(textLength) 字 · 待分段" }
        var line = "\(p.segments) 段 · 视频 \(p.videosDone)/\(p.segments)"
        if p.videosRunning > 0 { line += " · 生成中 \(p.videosRunning)" }
        if p.videosFailed > 0 { line += " · 失败 \(p.videosFailed)" }
        return line
    }

    // MARK: 选中

    /// 默认打开哪一集：上次选中的还在就用它；否则第一个有段的剧本集；再否则第一集
    static func defaultEpisodeID(in doc: ProjectDocument, preferred: UUID?) -> UUID? {
        if let preferred, doc.episodes.contains(where: { $0.id == preferred }) { return preferred }
        return (doc.episodes.first { !$0.isFree && !$0.segments.isEmpty } ?? doc.episodes.first)?.id
    }

    static func defaultSegmentID(in episode: EpisodeRecord, preferred: UUID?) -> UUID? {
        if let preferred, episode.segments.contains(where: { $0.id == preferred }) { return preferred }
        return episode.segments.first?.id
    }
}
