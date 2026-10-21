import Foundation

enum PipelineEditingRules {
    @discardableResult
    static func addSegment(to work: inout SimpleEpisodeWork) -> UUID {
        let segment = SimplePipelineSegment(text: "")
        work.segments.append(segment)
        return segment.id
    }
    static func removeSegment(_ id: UUID, from work: inout SimpleEpisodeWork) {
        guard let removed = work.segments.firstIndex(where: { $0.id == id }) else { return }
        work.segments.remove(at: removed)
        // 只让被删位置**及其后**的段落重建承接（2026-10-06：原来清全部，
        // 删最后一段也会导致前面全量重推、重复看图）。
        for index in work.segments.indices where index >= removed { work.segments[index].continuityKey = "" }
    }
    static func clearPrompt(_ id: UUID, in work: inout SimpleEpisodeWork) {
        guard let index = work.segments.firstIndex(where: { $0.id == id }) else { return }
        work.segments[index].prompt = ""
        work.segments[index].initialPositions = ""
        work.segments[index].endPositions = ""
        for i in work.segments.indices where i >= index { work.segments[i].continuityKey = "" }
    }
    @discardableResult
    static func addAsset(kind: String, to work: inout SimpleEpisodeWork) -> UUID {
        var number = 1
        while work.assets.contains(where: { $0.name == "新\(kind)\(number)" }) { number += 1 }
        let asset = SimplePipelineAsset(kind: kind, name: "新\(kind)\(number)", description: "")
        work.assets.append(asset)
        return asset.id
    }
}
