import Foundation

/// 工作台左边集列表的「添加集」（2026-10-15 用户：剧本 56 集，想再加一个空的第 57 集）。
///
/// - 只加在最后：分镜编号 / 视频文件名是「集号-段号-版本」，插在中间后面各集都要改号，已下载的视频就对不上了。
/// - 加的集原文是空的，点进「原文」粘贴 / 手写，之后和别的集一样走流水线。
/// - 不写回导入的整份剧本：以后对整部剧本重新分集，会按原来的剧本重新切，加的集就没了。
/// - 删除只给**最后一集、还没分割过、也没有分镜卡**的（加错了能删；删中间的集同样会让后面改号）。
enum EpisodeEdit {
    /// 末尾加一集「第 N 集」，原文空
    static func appending(to archive: ProjectPipelineArchive) -> (archive: ProjectPipelineArchive, index: Int) {
        var next = archive
        let number = next.episodes.count + 1
        next.episodes.append(Episode(title: "第\(number)集", text: ""))
        return (next, next.episodes.count - 1)
    }

    static func canDelete(_ index: Int, in archive: ProjectPipelineArchive) -> Bool {
        guard index == archive.episodes.count - 1, archive.episodes.count > 1 else { return false }
        let episode = archive.episodes[index]
        return (episode.splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (episode.shotIDs ?? []).isEmpty
    }

    static func deleting(_ index: Int, from archive: ProjectPipelineArchive) -> ProjectPipelineArchive? {
        guard canDelete(index, in: archive) else { return nil }
        var next = archive
        let id = next.episodes[index].id
        next.episodes.remove(at: index)
        if next.works.count > next.episodes.count { next.works.removeLast(next.works.count - next.episodes.count) }
        next.simpleWorks.removeAll { $0.id == id }
        next.epIndex = min(next.epIndex, next.episodes.count - 1)
        if let state = next.lastEndState, state.episode > next.works.count { next.lastEndState = nil }
        return next
    }
}
