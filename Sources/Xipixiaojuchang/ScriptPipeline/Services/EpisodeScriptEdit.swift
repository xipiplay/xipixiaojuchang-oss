import Foundation

/// 剧本页「本集剧本」直接编辑后写回存档（2026-10-07）。纯函数，页面只负责什么时候调。
///
/// ⚠️ 已知后果：一集的分段 / 素材 / 提示词（`SimpleEpisodeWork`）是按**原文**绑定的（`sourceKey`），
/// 原文一改，这一集原来的分段就对不上了，页面上看到的是「还没分段」（旧结果还留在存档里，
/// 原文改回原样就又对上；但这一集再保存任何新结果时会把旧的覆盖）。
enum EpisodeScriptEdit {
    /// 改的是哪一份文本：原文，还是「批量分割」出来的时长分割
    enum Field: String, CaseIterable { case original = "原文", split = "时长分割" }

    /// 把草稿应用到存档。`episodeID == nil` = 还没分集的整篇剧本。没有变化 / 对不上返回 nil。
    static func applying(title: String, text: String, episodeID: UUID?, field: Field = .original,
                         to archive: ProjectPipelineArchive) -> ProjectPipelineArchive? {
        var updated = archive
        if let episodeID {
            guard let i = updated.episodes.firstIndex(where: { $0.id == episodeID }) else { return nil }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case .original:
                guard updated.episodes[i].title != trimmed || updated.episodes[i].text != text else { return nil }
                updated.episodes[i].title = trimmed
                updated.episodes[i].text = text
            case .split:
                // 还没分割过、框里也是空的：不算改动（不要因为点了一下就凭空多出一份空的）
                let before = updated.episodes[i].splitText
                guard updated.episodes[i].title != trimmed || (before ?? "") != text else { return nil }
                updated.episodes[i].title = trimmed
                updated.episodes[i].splitText = (before == nil && text.isEmpty) ? nil : text
            }
        } else {
            // 已经分过集的存档里，整篇剧本是分集的来源，不在这里改
            guard field == .original, updated.episodes.isEmpty, updated.wholeScript != text else { return nil }
            updated.wholeScript = text
        }
        return updated
    }
}
