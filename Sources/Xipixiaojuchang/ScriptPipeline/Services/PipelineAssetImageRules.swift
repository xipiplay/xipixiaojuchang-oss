import Foundation

/// 素材页按项目、类型和名称复用生图条目，保留现有生成结果。
enum PipelineAssetImageRules {
    static func item(for asset: SimplePipelineAsset, projectKey: String, items: [ImageGenItem]) -> ImageGenItem? {
        if let id = asset.imageItemID,
           let item = items.first(where: { $0.id == id && $0.projectKey == projectKey }) { return item }
        return items.first { $0.projectKey == projectKey && $0.name == asset.name && $0.type == ImageSubjectType.from(kind: asset.kind) }
    }

    static func merge(_ assets: [SimplePipelineAsset], into work: inout SimpleEpisodeWork) {
        work.assets = assets.map { asset in
            guard var old = work.assets.first(where: { $0.kind == asset.kind && $0.name == asset.name }) else { return asset }
            old.description = asset.description
            return old
        }
        work.assetsExtracted = true
    }

    static func appendParsed(_ parsed: [ImagePromptParser.Parsed], to work: inout SimpleEpisodeWork) {
        for value in parsed {
            let kind = value.type.namePrefix
            if work.assets.contains(where: { $0.kind == kind && $0.name == value.name && $0.description == value.prompt }) { continue }
            work.assets.append(SimplePipelineAsset(kind: kind, name: value.name, description: value.prompt))
        }
        work.assetsExtracted = true
    }
}
