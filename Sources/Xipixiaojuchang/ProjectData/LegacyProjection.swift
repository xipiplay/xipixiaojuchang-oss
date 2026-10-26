import Foundation

// MARK: - 2.0 项目文档 → 旧页面用的数组（P1–P4 适配层，P5 删除）
//
// 旧页面照旧读写 AppModel 里的 shots / imageItems / library / 剧本存档；
// 启动时由这里从 project.json 还原，存盘时再由 `LegacyMigrationPlanner`（`.live`）换算回去。
// 视频任务不在这里：任务记录仍在全局任务存储里（P2 并进任务中心），段上只记任务 ID。

enum LegacyProjection {
    static func snapshot(from docs: [ProjectDocument], projectsRoot: URL) -> LegacySnapshot {
        var s = LegacySnapshot()
        for doc in docs.sorted(by: { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }) {
            let p = project(doc, folder: projectsRoot.appendingPathComponent(doc.id, isDirectory: true))
            s.metas[doc.id] = ProjectMeta(name: doc.name, createdAt: doc.createdAt, updatedAt: doc.updatedAt)
            s.shots += p.shots
            s.imageItems += p.imageItems
            s.library += p.library
            if let archive = p.archive { s.pipelines[doc.id] = archive }
        }
        return s
    }

    /// 视频任务记录（P2 起不再有 tasks.json）：从各段的视频版本还原，旧页面照旧按任务 ID 查。
    static func tasks(from docs: [ProjectDocument], projectsRoot: URL) -> [LocalTask] {
        var out: [LocalTask] = []
        var seen = Set<String>()
        for doc in docs {
            let folder = projectsRoot.appendingPathComponent(doc.id, isDirectory: true)
            for segment in doc.episodes.flatMap(\.segments) {
                for v in segment.videos where seen.insert(v.taskID).inserted {
                    var t = LocalTask(id: v.taskID, model: v.params.model, providerID: v.params.providerID,
                                      prompt: v.prompt, duration: v.params.duration, aspectRatio: v.params.aspectRatio,
                                      resolution: v.params.resolution, generateAudio: v.params.generateAudio,
                                      phase: v.phase, createdAt: v.createdAt, updatedAt: v.updatedAt ?? v.createdAt)
                    t.localVideoPath = v.file.map { ProjectDocument.absolutePath($0, projectFolder: folder) }
                    t.resultURL = v.resultURL
                    t.errorMessage = v.errorMessage
                    t.referenceImageURLs = v.referenceImageURLs
                    t.referenceVideoURLs = v.referenceVideoURLs
                    t.referenceAudioURLs = v.referenceAudioURLs
                    t.groupID = doc.id
                    t.fileName = v.fileName
                    out.append(t)
                }
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    private struct Projected {
        var shots: [ShotDraft] = []
        var imageItems: [ImageGenItem] = []
        var library: [LibraryItem] = []
        var archive: ProjectPipelineArchive?
    }

    private static func project(_ doc: ProjectDocument, folder: URL) -> Projected {
        var out = Projected()
        let abs = { (file: String?) in file.map { ProjectDocument.absolutePath($0, projectFolder: folder) } }
        let settingsByID = Dictionary(doc.settings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        /// 引用 → 旧素材库条目 ID（没记具体条目就用这个设定的第一条）
        func libraryID(_ ref: MediaReference) -> UUID? {
            ref.legacyLibraryItemID ?? settingsByID[ref.settingID]?.legacy?.libraryEntries.first?.id
        }
        func materialRefs(_ refs: [MediaReference]) -> [MaterialRef] {
            refs.compactMap { r in libraryID(r).map { MaterialRef(id: r.id, libraryItemID: $0, role: r.role) } }
        }

        // 设定 → 生图卡片 + 素材库条目
        for setting in doc.settings {
            if let card = setting.legacy?.imageCard {
                var item = ImageGenItem(projectKey: doc.id, type: setting.kind.imageSubject, name: setting.name,
                                        prompt: setting.description, model: setting.imageModel,
                                        aspectRatio: setting.imageAspect ?? .ratio16x9,
                                        quality: setting.imageQuality ?? .k2,
                                        imageRefs: materialRefs(setting.references), status: card.status)
                item.id = card.itemID
                item.results = setting.versions.map { v in
                    ImageGenResult(id: v.id, localPath: abs(v.file), resultURL: v.resultURL, createdAt: v.createdAt,
                                   prompt: v.prompt, model: v.model,
                                   type: v.model == nil ? nil : setting.kind.imageSubject,
                                   aspectRatio: v.aspect, quality: v.quality,
                                   imageRefs: v.references.map(materialRefs))
                }
                item.selectedResultID = setting.selectedVersionID
                item.submittedAt = card.submittedAt
                item.errorMessage = card.errorMessage
                item.paramsDirty = card.paramsDirty
                item.stage = card.stage
                item.fromEpisode = card.fromEpisode
                item.referenceCardID = card.referenceCardID
                item.failures = card.failures ?? []
                item.voiceAudioID = card.voiceAudioID
                item.voiceText = card.voiceText
                item.voiceMode = card.voiceMode
                // 旧卡名字里的「第N集的」拆成起始集（存盘时起始集一起存，见 `LegacyImageCard.fromEpisode`）
                CardVersion.splitLegacyPrefix(&item)
                out.imageItems.append(item)
            }
            for entry in setting.legacy?.libraryEntries ?? [] {
                let version = entry.versionID.flatMap { id in setting.versions.first { $0.id == id } } ?? setting.portrait
                let kind: LibraryItem.Kind = switch setting.media {
                case .image: .image
                case .video: .video
                case .audio: .audio
                }
                var item = LibraryItem(id: entry.id, kind: kind, localPath: abs(entry.file ?? version?.file),
                                       fileName: entry.fileName, name: entry.name, duration: version?.duration,
                                       projectKey: doc.id)
                item.remoteURL = entry.remoteURL ?? version?.publicURL
                item.uploadState = entry.uploadState
                item.source = entry.source
                item.imageGenItemID = setting.legacy?.imageCard?.itemID ?? entry.imageGenItemID
                item.imageGenResultID = entry.versionID == entry.id ? nil : entry.versionID
                out.library.append(item)
            }
        }
        out.imageItems = ordered(out.imageItems, by: doc.legacy?.imageItemOrder, id: \.id)
        out.library = ordered(out.library, by: doc.legacy?.libraryOrder, id: \.id)

        // 段 → 分镜卡
        func shot(for seg: SegmentRecord) -> ShotDraft {
            let byMedia = { (m: MediaReference.Media) in materialRefs(seg.references.filter { $0.media == m }) }
            var shot = ShotDraft(id: seg.legacy?.shotID ?? seg.id, projectKey: doc.id,
                                 model: seg.params.model, providerID: seg.params.providerID, prompt: seg.prompt,
                                 duration: seg.params.duration, aspectRatio: seg.params.aspectRatio,
                                 resolution: seg.params.resolution ?? .p720,
                                 generateAudio: seg.params.generateAudio, watermark: seg.params.watermark,
                                 imageRefs: byMedia(.image), videoRefs: byMedia(.video), audioRefs: byMedia(.audio),
                                 taskID: seg.selectedVideoTaskID ?? seg.videos.last?.taskID, taskIDs: seg.videos.map(\.taskID),
                                 createdAt: seg.createdAt, numbering: seg.numbering)
            shot.paramsDirty = seg.legacy?.paramsDirty ?? false
            shot.pendingIsCurrent = seg.legacy?.pendingIsCurrent ?? false
            if shot.pendingIsCurrent { shot.taskID = nil }   // 当前是「待生成」：没有当前视频（不能兜底成最后一版）
            shot.pendingPrompt = seg.legacy?.pendingPrompt
            return shot
        }
        for episode in doc.episodes {
            for seg in episode.segments where episode.isFree || seg.legacy?.shotID != nil {
                out.shots.append(shot(for: seg))
            }
        }
        out.shots = ordered(out.shots, by: doc.legacy?.shotOrder, id: \.id)

        // 剧本存档
        if doc.legacy?.hasPipelineArchive == true {
            var archive = ProjectPipelineArchive()
            archive.projectId = doc.legacy?.pipelineArchiveID ?? UUID(uuidString: doc.id) ?? SimplePipeline.stableID(doc.id)
            archive.wholeScript = doc.script
            archive.loadedFileName = doc.scriptFileName
            archive.segmentSeconds = doc.segmentSeconds
            archive.epIndex = doc.legacy?.pipelineEpisodeIndex ?? 0
            archive.eraBackground = doc.legacy?.pipelineEra
            for episode in doc.episodes where !episode.isFree {
                archive.episodes.append(Episode(id: episode.id, title: episode.title, text: episode.text,
                                                splitText: episode.splitText, shotIDs: episode.storyboardShotIDs,
                                                storyboardSplitSignature: episode.storyboardSplitSignature))
                guard episode.assetsExtracted || !episode.segments.isEmpty || !episode.settingIDs.isEmpty else { continue }
                var work = SimpleEpisodeWork(id: episode.id, sourceKey: episode.sourceKey)
                work.assetsExtracted = episode.assetsExtracted
                if let assets = episode.legacy?.assets {
                    work.assets = assets.compactMap { a in
                        guard let s = settingsByID[a.settingID], let kind = s.kind.pipelineKind else { return nil }
                        return SimplePipelineAsset(id: a.id, kind: kind, name: s.name, description: a.description,
                                                   imageItemID: a.imageItemID, libraryItemID: a.libraryItemID)
                    }
                } else {
                    work.assets = episode.settingIDs.compactMap { id in
                        guard let s = settingsByID[id], let kind = s.kind.pipelineKind else { return nil }
                        return SimplePipelineAsset(id: s.id, kind: kind, name: s.name, description: s.description,
                                                   imageItemID: s.legacy?.imageCard?.itemID,
                                                   libraryItemID: s.legacy?.libraryEntries.first?.id)
                    }
                }
                work.segments = episode.segments.map { seg in
                    var out = SimplePipelineSegment(
                        id: seg.id, text: seg.text,
                        assetNames: seg.legacy?.assetNames
                            ?? seg.settingIDs.compactMap { settingsByID[$0]?.name } + seg.unresolvedNames,
                        prompt: seg.prompt, shotID: seg.legacy?.shotID)
                    out.sceneName = seg.sceneName
                    out.initialPositions = seg.initialPositions
                    out.endPositions = seg.endPositions
                    out.continuityKey = seg.continuityKey
                    return out
                }
                archive.simpleWorks.append(work)
            }
            out.archive = archive
        }
        return out
    }

    /// 按记下的旧顺序排；没记过的（新加的）排在后面，保持原相对顺序
    private static func ordered<T>(_ items: [T], by order: [UUID]?, id: KeyPath<T, UUID>) -> [T] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return items.enumerated().sorted {
            let a = rank[$0.element[keyPath: id]] ?? (order.count + $0.offset)
            let b = rank[$1.element[keyPath: id]] ?? (order.count + $1.offset)
            return a < b
        }.map(\.element)
    }
}
