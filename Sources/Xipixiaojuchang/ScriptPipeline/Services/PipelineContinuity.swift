import Foundation

enum PipelineContinuity {
    typealias Vision = @Sendable (URL, String) async throws -> String
    static let visionPrompt = """
    看场景图片并结合本段剧情，安排本段开头的角色站位、朝向和相对位置。
    左右以图片画面为准，说明门窗、通道、主要家具的位置，角色站位应与剧情动作一致。
    不编造图中不可见的建筑布局。只输出站位及空间说明正文。
    """
    struct Reply: Decodable { var prompt: String; var endPositions: String }

    static func scene(for segment: SimplePipelineSegment, assets: [SimplePipelineAsset]) throws -> SimplePipelineAsset {
        try sceneSequence(for: segment, assets: assets)[0]
    }

    static func sceneSequence(for segment: SimplePipelineSegment, assets: [SimplePipelineAsset]) throws -> [SimplePipelineAsset] {
        let scenes = assets.filter { $0.kind == "场景" }
        let markedLines = segment.text.components(separatedBy: .newlines).filter { $0.contains("场景") }
        var ordered: [SimplePipelineAsset] = []
        for line in markedLines {
            if let scene = scenes.sorted(by: { $0.name.count > $1.name.count }).first(where: { line.contains($0.name) }),
               ordered.last?.id != scene.id { ordered.append(scene) }
        }
        if !ordered.isEmpty { return ordered }
        let referenced = scenes.filter { segment.assetNames.contains($0.name) || segment.text.contains($0.name) }
        if referenced.count == 1 { return referenced }
        if scenes.count == 1, markedLines.isEmpty { return scenes }
        throw PipelineAIError.invalidResult("无法确定本段场景，请在剧情中写明素材页的场景名称。")
    }

    static func imagePath(scene: SimplePipelineAsset, project: String, items: [ImageGenItem], library: [LibraryItem]) -> String? {
        if let item = PipelineAssetImageRules.item(for: scene, projectKey: project, items: items),
           let result = item.results.first(where: { $0.id == item.selectedResultID }) ?? item.latestResult,
           let path = result.localPath, FileManager.default.fileExists(atPath: path) { return path }
        if let id = scene.libraryItemID, let item = library.first(where: { $0.id == id && $0.projectKey == project }),
           let path = item.existingLocalImageURL?.path { return path }
        return nil
    }

    static func inputKey(segment: SimplePipelineSegment, assets: [SimplePipelineAsset], previous: SimplePipelineSegment?) -> String {
        // 只纳入"本段实际使用"的素材：改其它素材不会连累本段重跑（缺图补图后可从缺口处继续）。
        let used = assets.filter { segment.assetNames.contains($0.name) || segment.text.contains($0.name) }
        return SimplePipeline.key(segment.text + used.map { "\($0.kind)|\($0.name)|\($0.description)|\($0.imageItemID?.uuidString ?? "")" }.joined() + (previous?.sceneName ?? "") + (previous?.endPositions ?? ""))
    }

    static func infer(segment: SimplePipelineSegment, assets: [SimplePipelineAsset], sceneName: String,
                      initialPositions: String, seconds: Int = 30, chat: SimplePipeline.Chat) async throws -> Reply {
        let context = assets.filter { segment.assetNames.contains($0.name) || segment.text.contains($0.name) || $0.name == sceneName }
            .map { "\($0.kind)「\($0.name)」：\($0.description)" }.joined(separator: "\n")
        let raw = try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.shotsPrompt) + """

        本段是一条完整的\(seconds)秒多镜头视频，严格从给定的初始站位起手，不重置人物位置。
        按剧情动作推进站位；若本段换场景，严格使用各场景分别给出的初始站位，不能把旧场景的空间搬过去。
        结束时输出最后一个场景内各角色最终位置、朝向和空间关系，供下一段继承。
        只输出JSON：{"prompt":"完整视频提示词","endPositions":"段末角色站位"}。
        """, "【场景】\(sceneName)\n【素材】\n\(context)\n【继承的初始站位】\n\(initialPositions)\n【剧情】\n\(segment.text)")
        guard let data = PipelineAIService.extractJSON(raw).data(using: .utf8),
              let value = try? JSONDecoder().decode(Reply.self, from: data),
              !value.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.endPositions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineAIError.invalidResult("分镜回复缺少完整提示词或段末站位，请重试")
        }
        return value
    }
}
