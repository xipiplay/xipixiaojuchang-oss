import Foundation

// MARK: - 匹配素材（2026-10-07，用户指出推理分镜之后缺这一步）
//
// 视频 / 图片提交时，有参考素材的话，**提示词里要在对应名字前写「图N」**（编辑提示词弹窗里的 @ 素材，
// 底层就是「图N」，提交时按素材顺序上传，渠道开了 @image 语法再换成 `@imageN`）。
// 旧版是在「编辑提示词」弹窗里点「自动匹配」：按素材名在提示词开头 `[场景][角色][道具]` 方括号行里找名字，
// 在名字前插「图N」，同时把对应的图挂进分镜卡的参考素材（`AppModel.autoMatchMaterials`）。
// 新版的做法一样，只是：
// - **候选素材 = 本段用到的设定、各自选中的那一张图**（「挑定妆图」选的才会传到视频里），不是整个素材库；
// - 先**对账**（提示词里没有「图N」的引用先去掉），所以推理分镜重做后再匹配也是对的；
// - 没有分镜卡的段先建一张（和提交时建的是同一张），提示词和卡两边一起更新；
// - 可以反复做（幂等）；一键推进在「推理分镜」之后做一遍，提交每一段之前也会再做一遍。

@MainActor
enum WorkbenchMatching {
    /// 一段的匹配情况
    struct Status: Equatable {
        /// 提示词里已经「图N + 名字」对上的设定名（按图号）
        var matched: [String] = []
        /// 本段用到、有图，但提示词里没对上（方括号行里没有这个名字）
        var unmatched: [String] = []
        /// 本段用到、还没有图
        var noImage: [String] = []
    }

    // MARK: 本段用到的素材

    /// 本段用到的素材：本集剧本里的素材（名字写在段落记录或原文里的）∪ 段落里写了名字、
    /// 但这次没提取到的项目设定（按名字 / 别名在设定里找；描述取设定的描述）。
    static func usedAssets(of segment: SimplePipelineSegment, work: SimpleEpisodeWork, doc: ProjectDocument?) -> [SimplePipelineAsset] {
        var result = work.assets.filter { segment.assetNames.contains($0.name) || segment.text.contains($0.name) }
        for name in segment.assetNames where !result.contains(where: { $0.name == name }) {
            if let extra = settingAsset(named: name, doc: doc), !result.contains(where: { $0.name == extra.name && $0.kind == extra.kind }) {
                result.append(extra)
            }
        }
        return result
    }

    /// 本集所有要有图的素材：剧本里的素材 ∪ 各段名字对应的、没被提取到的项目设定
    static func episodeAssets(work: SimpleEpisodeWork, doc: ProjectDocument?) -> [SimplePipelineAsset] {
        var result = work.assets
        for segment in work.segments {
            for name in segment.assetNames where !result.contains(where: { $0.name == name }) {
                if let extra = settingAsset(named: name, doc: doc), !result.contains(where: { $0.name == extra.name && $0.kind == extra.kind }) {
                    result.append(extra)
                }
            }
        }
        return result
    }

    private static func settingAsset(named name: String, doc: ProjectDocument?) -> SimplePipelineAsset? {
        guard let setting = doc?.settings.first(where: { $0.name == name || $0.aliases.contains(name) }),
              let kind = setting.kind.pipelineKind else { return nil }
        return SimplePipelineAsset(id: SimplePipeline.stableID("setting-\(setting.id)"), kind: kind, name: setting.name,
                                   description: setting.description)
    }

    // MARK: 素材 → 素材库条目（选中的那一张）

    /// 这个素材该用的图：用户挑的（没挑 = 最新）那一版，没有生图结果才退回素材上记的素材库条目。
    /// `create`：那一版还没入库就入库（入库名「角色-名」，和旧流程一样）；只读判断时传 false。
    static func chosenLibraryItemID(for asset: SimplePipelineAsset, project key: String, app: AppModel, create: Bool) -> UUID? {
        if let image = PipelineAssetImageRules.item(for: asset, projectKey: key, items: app.imageItems),
           let result = image.results.first(where: { $0.id == image.selectedResultID }) ?? image.latestResult {
            if let existing = app.library.first(where: { $0.projectKey == key && $0.imageGenResultID == result.id }) { return existing.id }
            return create ? app.saveImageItemToLibrary(image.id, resultID: result.id) : nil
        }
        return asset.libraryItemID.flatMap { app.libraryItem($0)?.id }
    }

    /// 这个素材有没有图（有生图结果，或素材上挂着素材库里的图）
    static func hasImage(_ asset: SimplePipelineAsset, project key: String, app: AppModel) -> Bool {
        if let image = PipelineAssetImageRules.item(for: asset, projectKey: key, items: app.imageItems), !image.results.isEmpty { return true }
        return asset.libraryItemID.flatMap { app.libraryItem($0) } != nil
    }

    // MARK: 只读：这一段现在匹配到哪了

    static func status(of segment: SimplePipelineSegment, work: SimpleEpisodeWork, doc: ProjectDocument?, project key: String,
                       app: AppModel) -> Status {
        var status = Status()
        let shot = segment.shotID.flatMap { id in app.shots.first { $0.id == id && $0.projectKey == key } }
        if let shot {
            for (index, ref) in shot.imageRefs.enumerated() where shot.prompt.contains("图\(index + 1)") {
                if let name = app.libraryItem(ref.libraryItemID)?.matchKeyword { status.matched.append(name) }
            }
        }
        for asset in usedAssets(of: segment, work: work, doc: doc) {
            if status.matched.contains(asset.name) { continue }
            if hasImage(asset, project: key, app: app) { status.unmatched.append(asset.name) } else { status.noImage.append(asset.name) }
        }
        return status
    }

    // MARK: 匹配（会写数据）

    /// 给一段做匹配：建卡（没有的话）→ 换成选中的图 → 对账 → 按名字在方括号行里插「图N」→ 提示词写回剧本。
    @discardableResult
    static func prepare(segmentID: UUID, episodeID: UUID, doc: ProjectDocument?, app: AppModel) throws -> Status {
        guard let key = app.currentProjectKey, var archive = app.pipelineArchive(for: key),
              let e = archive.episodes.firstIndex(where: { $0.id == episodeID }) else { throw WorkbenchActions.Failure("找不到这一集") }
        var work = SimplePipeline.work(in: archive, index: e)
        guard let i = work.segments.firstIndex(where: { $0.id == segmentID }) else { throw WorkbenchActions.Failure("找不到这一段") }
        let segment = work.segments[i]
        let doc = doc ?? app.workbenchDocument(for: key)

        // 分镜卡：已有的用它（提示词以卡为准，和制作页显示一致）；没有就建一张
        var shot: ShotDraft
        if let id = segment.shotID, let existing = app.shots.first(where: { $0.id == id && $0.projectKey == key }) {
            shot = existing
        } else {
            let prompt = segment.prompt
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return status(of: segment, work: work, doc: doc, project: key, app: app)
            }
            shot = WorkbenchActions.preparedShot(existing: nil, projectKey: key, episodeNumber: e + 1, segmentNumber: i + 1,
                                                 prompt: prompt, params: WorkbenchActions.defaultParams(app),
                                                 generateAudio: app.generateAudioDefault, watermark: app.watermarkDefault)
            app.shots.append(shot)
        }
        if shot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let idx = app.shots.firstIndex(where: { $0.id == shot.id }) {
            app.shots[idx].prompt = segment.prompt
            shot = app.shots[idx]
        }

        // 候选 = 本段用到的素材、各自选中的那张图
        var items: [LibraryItem] = []
        for asset in usedAssets(of: segment, work: work, doc: doc) {
            if let id = chosenLibraryItemID(for: asset, project: key, app: app, create: true), let item = app.libraryItem(id) {
                items.append(item)
            }
        }
        // 已经挂着同一个设定的旧版本图（重新挑过定妆图）：原位换成选中的这一张，图号不变
        if let idx = app.shots.firstIndex(where: { $0.id == shot.id }) {
            for k in app.shots[idx].imageRefs.indices {
                let old = app.shots[idx].imageRefs[k]
                guard let oldItem = app.libraryItem(old.libraryItemID),
                      let replacement = items.first(where: { sameSetting($0, oldItem) && $0.id != oldItem.id }) else { continue }
                app.shots[idx].imageRefs[k] = MaterialRef(id: old.id, libraryItemID: replacement.id, role: old.role)
            }
        }
        // 不按提示词摘素材（2026-10-16 用户定：提示词里删素材，素材区的不删）；提示词里缺「图N」的由自动匹配补上
        app.autoMatchMaterials(shot.id, candidates: items, detectsDuration: false)
        app.persistShots()

        // 提示词（带「图N」）写回剧本；承接指纹不动——只是加了引用，段落内容没变
        if let latest = app.shots.first(where: { $0.id == shot.id }) {
            work.segments[i].shotID = latest.id
            work.segments[i].prompt = latest.prompt
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: key)
        }
        return status(of: work.segments[i], work: work, doc: doc, project: key, app: app)
    }

    /// 本集所有有提示词的段都做一遍。返回每段的情况（段 ID → 情况）
    @discardableResult
    static func prepareEpisode(episodeID: UUID, app: AppModel) throws -> [UUID: Status] {
        guard let key = app.currentProjectKey, let archive = app.pipelineArchive(for: key),
              let e = archive.episodes.firstIndex(where: { $0.id == episodeID }) else { throw WorkbenchActions.Failure("找不到这一集") }
        let doc = app.workbenchDocument(for: key)
        // 已经出过视频的段不动：改了提示词会让「视频是按旧提示词生成的」的提醒冒出来
        let rendered = Set(doc?.episodes.first { $0.id == episodeID }?.segments.filter { !$0.videos.isEmpty }.map(\.id) ?? [])
        var result: [UUID: Status] = [:]
        for segment in SimplePipeline.work(in: archive, index: e).segments
        where !segment.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !rendered.contains(segment.id) {
            result[segment.id] = try prepare(segmentID: segment.id, episodeID: episodeID, doc: doc, app: app)
        }
        return result
    }

    /// 同一个设定的两个版本（「角色-甲」「角色-甲-1」）：类型前缀和匹配关键词都一样
    private static func sameSetting(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        func category(_ item: LibraryItem) -> String {
            ["场景-", "角色-", "道具-"].first { item.matchName.hasPrefix($0) } ?? ""
        }
        return category(a) == category(b) && a.matchKeyword == b.matchKeyword
    }
}
