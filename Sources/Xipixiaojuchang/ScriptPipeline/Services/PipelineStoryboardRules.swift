import Foundation

enum PipelineStoryboardRules {
    /// 只使用稳定链接、真实集段号或同一项目的精确提示词匹配，不能按项目数组序号猜测。
    static func shot(for segment: SimplePipelineSegment, episode: Int, index: Int,
                     projectKey: String, shots: [ShotDraft]) -> ShotDraft? {
        if let id = segment.shotID {
            return shots.first { $0.id == id && $0.projectKey == projectKey }
        }
        if !segment.prompt.isEmpty, let found = shots.first(where: {
            $0.projectKey == projectKey && $0.numbering == ShotNumbering(a: episode, b: index + 1) && $0.prompt == segment.prompt
        }) { return found }
        guard !segment.prompt.isEmpty else { return nil }
        let matches = shots.filter { $0.projectKey == projectKey && $0.prompt == segment.prompt }
        return matches.count == 1 ? matches.first : nil
    }

    /// 批量解析按当前集的段落顺序写提示词，要求条数相同，保留段落剧情和视频链接。
    static func apply(_ prompts: [String], to work: inout SimpleEpisodeWork) throws {
        guard !work.segments.isEmpty, prompts.count == work.segments.count else {
            throw PipelineAIError.invalidResult("识别到 \(prompts.count) 份提示词，本集有 \(work.segments.count) 个段落，请按每段一份导入。")
        }
        guard prompts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PipelineAIError.invalidResult("分镜提示词不能为空")
        }
        for index in work.segments.indices { work.segments[index].prompt = prompts[index] }
    }
}
