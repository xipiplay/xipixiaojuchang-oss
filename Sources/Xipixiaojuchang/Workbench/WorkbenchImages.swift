import Foundation

// MARK: - 给设定生图（2026-10-07）
//
// 一键推进的「出图」步骤和制作页顶部「N 个设定还没有图」的面板共用这一套：
// 为素材建（或复用）生图卡片，写回素材的 `imageItemID`，返回卡片 ID；真正提交生成是调用方的事
// （一键推进走 `hooks.generateImage` 方便测试；面板直接 `requestImageGeneration`）。

@MainActor
enum WorkbenchImages {
    /// 要生成图的素材里，已经有图的不算（有生图结果、或素材上挂着素材库里的图），没描述的也不能出图
    static func needsImage(_ asset: SimplePipelineAsset, project: String, app: AppModel) -> Bool {
        guard ImageSubjectType.from(kind: asset.kind) != nil,
              !asset.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !WorkbenchMatching.hasImage(asset, project: project, app: app)
    }

    /// 能出图但还没图的素材（本集的素材 ∪ 段落里用到、这次没提取到的设定）
    static func assetsWithoutImage(work: SimpleEpisodeWork, doc: ProjectDocument?, project: String, app: AppModel) -> [SimplePipelineAsset] {
        WorkbenchMatching.episodeAssets(work: work, doc: doc).filter { needsImage($0, project: project, app: app) }
    }

    /// 为这些素材建（或复用）生图卡片。没有图片模型时抛错（一张都不建，不花钱）。
    /// 返回 (素材, 卡片 ID)；本集剧本里的素材会把 `imageItemID` 写回存档。
    static func prepareCards(for assets: [SimplePipelineAsset], project: String, episodeIndex: Int, app: AppModel) throws -> [(asset: SimplePipelineAsset, itemID: UUID)] {
        guard let model = app.defaultImageModel ?? app.imageModelNames.first, app.imageModelNames.contains(model) else {
            throw WorkbenchActions.Failure("还没有可用的图片模型。请先到设置里添加图片渠道与模型。")
        }
        guard var archive = app.pipelineArchive(for: project) else { throw WorkbenchActions.Failure("找不到剧本") }
        var work = SimplePipeline.work(in: archive, index: episodeIndex)
        let aspect = app.defaultImageAspect.flatMap(ImageAspect.init(rawValue:)) ?? .ratio16x9
        let quality = app.defaultImageQuality.flatMap(ImageQuality.init(rawValue:)) ?? .k2
        var result: [(SimplePipelineAsset, UUID)] = []
        var changed = false
        for asset in assets {
            let index = work.assets.firstIndex { $0.id == asset.id || ($0.name == asset.name && $0.kind == asset.kind) }
            let source = index.map { work.assets[$0] } ?? asset
            guard let id = app.savePipelineAssetImage(source, model: model, aspect: aspect, quality: quality,
                                                      type: ImageSubjectType.from(kind: asset.kind)) else { continue }
            if let index {
                if work.assets[index].imageItemID != id { work.assets[index].imageItemID = id; changed = true }
            } else {
                // 本集没有这个素材（段落里用到、别处定义的设定）：记进本集素材并挂上卡片。
                // 不挂的话，这张卡片会被换算成另一个同名的新设定，图出在那上面，段落引用的设定还是空的
                var adopted = source
                adopted.imageItemID = id
                work.assets.append(adopted)
                changed = true
            }
            result.append((source, id))
        }
        if changed {
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        return result
    }

    /// 给一个没有描述的素材写上描述（面板里「添加描述」）。本集剧本里有这个素材就改它；没有就不动（描述随生图卡片走）
    static func setDescription(_ text: String, forAssetNamed name: String, kind: String, project: String, episodeIndex: Int, app: AppModel) {
        guard var archive = app.pipelineArchive(for: project) else { return }
        var work = SimplePipeline.work(in: archive, index: episodeIndex)
        guard let i = work.assets.firstIndex(where: { $0.name == name && $0.kind == kind }) else { return }
        work.assets[i].description = text.trimmingCharacters(in: .whitespacesAndNewlines)
        SimplePipeline.save(work, to: &archive)
        app.savePipelineArchive(archive, for: project)
    }

    /// 把本集用到的设定都挂回本集素材，并把已有的生图卡片挂上（`imageItemID`）。返回有没有改动。
    ///
    /// 设定是从「各集素材 + 生图卡片」换算出来的：卡片只有挂在某个素材上，才会并进同名设定；没挂的会变成另一个
    /// 同名的新设定。段落里用到、但本集没提取到的设定（别的集提取的、或确认名字时新建的）如果在本集没有对应素材，
    /// 给它生的图就会出在那个「新设定」上（2026-10-07 实测：图生出来了，段落引用的设定还是空的）。
    /// 一键推进每轮开始前、缺图面板打开时都会做一遍；已经挂好的不动。
    @discardableResult
    static func adoptUsedSettings(project: String, episodeIndex: Int, app: AppModel) -> Bool {
        guard var archive = app.pipelineArchive(for: project), archive.episodes.indices.contains(episodeIndex) else { return false }
        var work = SimplePipeline.work(in: archive, index: episodeIndex)
        var changed = false
        for asset in WorkbenchMatching.episodeAssets(work: work, doc: app.workbenchDocument(for: project)) {
            let item = PipelineAssetImageRules.item(for: asset, projectKey: project, items: app.imageItems)
            if let index = work.assets.firstIndex(where: { $0.name == asset.name && $0.kind == asset.kind }) {
                if work.assets[index].imageItemID == nil, let item { work.assets[index].imageItemID = item.id; changed = true }
            } else if let item {
                var adopted = asset
                adopted.imageItemID = item.id
                work.assets.append(adopted)
                changed = true
            }
        }
        if changed {
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        return changed
    }
}
