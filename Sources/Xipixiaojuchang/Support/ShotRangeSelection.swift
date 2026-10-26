import Foundation

/// 生视频页「按范围选」（2026-10-27 用户：批量提交时要能一次选第几集到第几集、或者先选多少个）。
/// 只管选：选好了照旧走「批量提交」（先设参数、再确认）。
enum ShotRangeSelection {
    /// 选哪些
    struct Options: Equatable {
        /// 第几集到第几集（1 起）；nil = 全部（不属于任何一集的分镜也算）
        var episodes: ClosedRange<Int>? = nil
        /// 最多几个（按页面上的先后）；nil = 不限
        var limit: Int? = nil
        /// 跳过已完成、排队中、生成中、正在提交的
        var skipsBusyOrDone = true
    }

    /// `shots`：页面上看得见的分镜（已按状态筛选 / 搜索过），按显示顺序；`episodeOf`：分镜属于第几集（1 起，不属于任何一集 = nil）；
    /// `isBusyOrDone`：已完成 / 排队中 / 生成中 / 正在提交
    static func pick(_ shots: [ShotDraft], options: Options, episodeOf: (UUID) -> Int?,
                     isBusyOrDone: (ShotDraft) -> Bool) -> [UUID] {
        var picked: [UUID] = []
        for shot in shots {
            if let limit = options.limit, picked.count >= limit { break }
            if let range = options.episodes {
                guard let episode = episodeOf(shot.id), range.contains(episode) else { continue }
            }
            if options.skipsBusyOrDone, isBusyOrDone(shot) { continue }
            picked.append(shot.id)
        }
        return picked
    }

    /// 分镜 → 第几集（1 起）：按各集记着的分镜卡（`Episode.shotIDs`）
    static func episodeIndex(_ archive: ProjectPipelineArchive?) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, episode) in (archive?.episodes ?? []).enumerated() {
            for id in episode.shotIDs ?? [] where map[id] == nil { map[id] = index + 1 }
        }
        return map
    }
}
