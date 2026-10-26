import Foundation

// MARK: - 旧数据 → 2.0 项目文档（纯函数）
//
// 两种用法：
// - `.migration`：1.x → 2.0 一次性迁移。口径见 2026-10-06 用户确认的「P1 迁移映射」（按推荐 6 条）：
//   1. 压测项目不迁移；2. 无元数据的生图 / 素材并进「迁移-未归属图片」；
//   3. 无类型生图 → 「其他」类设定；4. 应用外文件一律拷进项目；
//   5. 旧词典不转设定（只迁页面上看得到的新版素材）；6. 重名项目迁移时加序号。
//   另外：同名同类型的生图条目合并成一个设定，失败 / 未完成的视频不迁。
// - `.live`：P1–P4 适配层每次存盘用。旧页面在内存里改的是旧数组，存盘时整体换算成项目文档；
//   一条生图条目 = 一个设定、所有视频提交都保留，ID 尽量沿用上一次存的文档，保证来回换算不漂。
//
// 只算「新数据长什么样、要拷哪些文件」，不碰磁盘；文件是否存在由调用方注入。

/// 旧数据：1.x 的全部持久化数据（已用旧类型解码，旧字段兼容逻辑沿用各类型自己的 init(from:)）
struct LegacySnapshot: Sendable {
    var metas: [String: ProjectMeta] = [:]
    var shots: [ShotDraft] = []
    var imageItems: [ImageGenItem] = []
    var library: [LibraryItem] = []
    var tasks: [LocalTask] = []
    var pipelines: [String: ProjectPipelineArchive] = [:]
}

struct MigrationOptions {
    enum Mode { case migration, live }
    var mode: Mode = .migration
    var excludedKeys: Set<String> = ["STRESS-100-100"]
    var orphanProjectID = "migrated-orphans"
    var orphanProjectName = "迁移-未归属图片"
    var fromVersion = "1.x"
    var now = Date()
    /// 项目文件夹的父目录：已经在 `<root>/<项目ID>/` 里的文件直接记相对路径，不再拷
    var projectsRoot: URL?
    /// 上一次存的文档（`.live` 用：沿用设定 ID、迁移戳、待确认标记）
    var previous: [String: ProjectDocument] = [:]
    /// 只组装这几个项目（存盘时只算改过的，2026-10-12）。各项目的组装互不依赖、查找表用全量，结果和全部组装时的同一个项目一模一样。nil = 全部
    var onlyKeys: Set<String>?
    /// 目标文件是否已被占用（`.live` 用：项目文件夹里已有同名文件时换个名字）
    var targetExists: (String, String) -> Bool = { _, _ in false }

    static func live(root: URL, previous: [String: ProjectDocument], now: Date = Date()) -> MigrationOptions {
        var o = MigrationOptions()
        o.mode = .live
        o.excludedKeys = []
        o.now = now
        o.projectsRoot = root
        o.previous = previous
        o.targetExists = { id, relative in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(id).appendingPathComponent(relative).path)
        }
        return o
    }
}

struct PlannedFileCopy: Equatable, Sendable {
    var source: String
    var projectID: String
    /// 相对项目文件夹
    var relativePath: String
}

struct MigrationPlan: Sendable {
    var projects: [ProjectDocument]
    var copies: [PlannedFileCopy]
    var report: MigrationReport
}

struct MigrationReport: Codable, Equatable, Sendable {
    struct ProjectRow: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var previousName: String?
        var episodes = 0
        var segments = 0
        var freeSegments = 0
        var settingsByKind: [String: Int] = [:]
        var mediaVersions = 0
        var videoVersions = 0
        var needsReview: [String] = []
        var unresolvedNames: [String] = []
        var missingFiles: [String] = []
        var skippedUnfinishedTasks = 0
        var missingTaskIDs = 0
        var danglingReferences = 0
        var crossProjectReferences = 0
    }

    var projects: [ProjectRow] = []
    /// 「名字（key）」
    var excluded: [String] = []
    var orphanKeys: [String] = []
    /// 不属于任何分镜卡的视频任务（不迁移）
    var unownedTasks = 0
    /// 缓存目录里没有任何记录引用的文件（留在旧目录，执行阶段填）
    var unreferencedFiles: [String] = []
}

enum LegacyMigrationPlanner {
    static func plan(_ snapshot: LegacySnapshot,
                     options: MigrationOptions = MigrationOptions(),
                     fileExists: @escaping (String) -> Bool) -> MigrationPlan {
        let excluded = options.excludedKeys
        let live = options.mode == .live
        var projectKeys = Set(snapshot.metas.keys)
        projectKeys.formUnion(snapshot.shots.map(\.projectKey).filter { !$0.isEmpty })
        projectKeys.formUnion(snapshot.pipelines.keys)
        var orphanKeys = Set(snapshot.imageItems.map(\.projectKey))
        orphanKeys.formUnion(snapshot.library.map { $0.projectKey ?? "" })
        if live {
            // 存盘时每个 key 都是项目（迁移后已经没有孤儿；万一出现也各自成项目，不并到别处）
            projectKeys.formUnion(orphanKeys.filter { !$0.isEmpty })
        }
        projectKeys.subtract(excluded)
        orphanKeys.subtract(projectKeys)
        if let only = options.onlyKeys { projectKeys.formIntersection(only) }
        orphanKeys.subtract(excluded)
        if live { orphanKeys.removeAll() }

        var report = MigrationReport()
        report.excluded = excluded.sorted().compactMap { key in
            let used = snapshot.metas[key] != nil || snapshot.shots.contains { $0.projectKey == key }
            return used ? "\(snapshot.metas[key]?.name ?? "（无名）")（\(key)）" : nil
        }
        report.orphanKeys = orphanKeys.sorted()

        var taskOwner: [String: String] = [:]
        for shot in snapshot.shots {
            for id in shot.taskIDs + [shot.taskID].compactMap({ $0 }) where taskOwner[id] == nil {
                taskOwner[id] = shot.projectKey
            }
        }
        report.unownedTasks = snapshot.tasks.filter { taskOwner[$0.id] == nil }.count

        let index = SnapshotIndex(snapshot)
        let ordered = projectKeys.sorted {
            let a = snapshot.metas[$0]?.createdAt ?? .distantPast
            let b = snapshot.metas[$1]?.createdAt ?? .distantPast
            return a != b ? a < b : $0 < $1
        }

        // 重名只改后来的那个；序号要避开所有现有名字（否则「X」的重名会抢走已有的「X 2」）。存盘时不改名。
        let originals = ordered.map { snapshot.metas[$0]?.name ?? options.previous[$0]?.name ?? "项目" }
        var taken: Set<String> = []
        var reserved = Set(originals)
        var projects: [ProjectDocument] = []
        var copies: [PlannedFileCopy] = []
        for (key, original) in zip(ordered, originals) {
            let name = !live && taken.contains(original) ? AppModel.uniqueProjectName(original, taken: reserved) : original
            taken.insert(name)
            reserved.insert(name)
            let previous = options.previous[key]
            let meta = snapshot.metas[key]
            var builder = ProjectBuilder(id: key, sourceKeys: [key], index: index, options: options, fileExists: fileExists)
            builder.buildPipeline(snapshot.pipelines[key])
            builder.buildImageItems()
            builder.buildLibrary()
            builder.buildShots()
            builder.finish()
            let archive = snapshot.pipelines[key]
            let migration = live ? previous?.migration
                : MigrationStamp(fromVersion: options.fromVersion, migratedAt: options.now,
                                 previousName: name == original ? nil : original, legacyKeys: [key])
            let doc = ProjectDocument(
                id: key, name: name,
                createdAt: meta?.createdAt ?? previous?.createdAt ?? options.now,
                updatedAt: meta?.updatedAt ?? previous?.updatedAt ?? options.now,
                script: archive?.wholeScript ?? "",
                scriptFileName: archive?.loadedFileName ?? "",
                segmentSeconds: archive?.segmentSeconds ?? 30,
                episodes: builder.episodes, settings: builder.settings,
                migration: migration,
                legacy: builder.legacyInfo(archive: archive),
                ignoredNames: live ? previous?.ignoredNames : nil)
            projects.append(doc)
            copies += builder.copies
            report.projects.append(builder.reportRow(doc))
        }

        if !orphanKeys.isEmpty {
            let id = options.orphanProjectID
            let name = AppModel.uniqueProjectName(options.orphanProjectName, taken: reserved)
            var builder = ProjectBuilder(id: id, sourceKeys: orphanKeys, index: index, options: options, fileExists: fileExists)
            builder.buildImageItems()
            builder.buildLibrary()
            builder.finish()
            let doc = ProjectDocument(
                id: id, name: name, createdAt: options.now, updatedAt: options.now,
                settings: builder.settings,
                migration: MigrationStamp(fromVersion: options.fromVersion, migratedAt: options.now,
                                          previousName: nil, legacyKeys: orphanKeys.sorted()),
                legacy: builder.legacyInfo(archive: nil))
            projects.append(doc)
            copies += builder.copies
            report.projects.append(builder.reportRow(doc))
        }
        return MigrationPlan(projects: projects, copies: copies, report: report)
    }
}

// MARK: - 索引

private struct SnapshotIndex {
    let imageItemsByKey: [String: [ImageGenItem]]
    let libraryByKey: [String: [LibraryItem]]
    let shotsByKey: [String: [ShotDraft]]
    let library: [UUID: LibraryItem]
    let tasks: [String: LocalTask]

    init(_ s: LegacySnapshot) {
        imageItemsByKey = Dictionary(grouping: s.imageItems, by: \.projectKey)
        libraryByKey = Dictionary(grouping: s.library, by: { $0.projectKey ?? "" })
        shotsByKey = Dictionary(grouping: s.shots, by: \.projectKey)
        library = Dictionary(s.library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        tasks = Dictionary(s.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - 单个项目的构建

private struct ProjectBuilder {
    let id: String
    let sourceKeys: Set<String>
    let index: SnapshotIndex
    let live: Bool
    let options: MigrationOptions
    let fileExists: (String) -> Bool
    /// 上一次文档里：生图条目 / 素材库条目 → 设定 ID（`.live` 沿用，避免每次存盘换 ID）
    private let previousByItem: [UUID: UUID]
    private let previousByLibrary: [UUID: UUID]
    private let previousSettings: [UUID: SettingRecord]
    /// 用户确认过「不是设定」的名字（上次存的文档里带着）
    private let ignoredNames: Set<String>

    var episodes: [EpisodeRecord] = []
    var settings: [SettingRecord] = []
    var copies: [PlannedFileCopy] = []

    private var settingByMergeKey: [String: Int] = [:]
    private var settingByImageItem: [UUID: Int] = [:]
    private var versionByResult: [UUID: (setting: Int, version: Int, path: String?)] = [:]
    private var settingByLibrary: [UUID: (setting: Int, entryID: UUID)] = [:]
    /// 剧本段 ← 分镜卡：卡 ID → (集, 段)
    private var segmentByShot: [UUID: (Int, Int)] = [:]
    private var pendingItemRefs: [(Int, [MaterialRef])] = []
    private var pendingResultRefs: [(Int, Int, [MaterialRef])] = []
    private var copiedPath: [String: String] = [:]
    private var usedRelative: Set<String> = []
    private var shotOrder: [UUID] = []
    private var imageItemOrder: [UUID] = []
    private var libraryOrder: [UUID] = []

    private var missingFiles: [String] = []
    private var skippedUnfinishedTasks = 0
    private var missingTaskIDs = 0
    private var danglingReferences = 0
    private var crossProjectReferences = 0

    init(id: String, sourceKeys: Set<String>, index: SnapshotIndex, options: MigrationOptions,
         fileExists: @escaping (String) -> Bool) {
        self.id = id
        self.sourceKeys = sourceKeys
        self.index = index
        self.options = options
        self.live = options.mode == .live
        self.fileExists = fileExists
        var byItem: [UUID: UUID] = [:], byLibrary: [UUID: UUID] = [:], byID: [UUID: SettingRecord] = [:]
        for s in options.previous[id]?.settings ?? [] {
            byID[s.id] = s
            if let card = s.legacy?.imageCard { byItem[card.itemID] = s.id }
            for e in s.legacy?.libraryEntries ?? [] { byLibrary[e.id] = s.id }
        }
        previousByItem = byItem
        previousByLibrary = byLibrary
        previousSettings = byID
        ignoredNames = Set(options.mode == .live ? (options.previous[id]?.ignoredNames ?? []) : [])
    }

    // MARK: 剧本（新版四步层；旧词典不转）

    mutating func buildPipeline(_ archive: ProjectPipelineArchive?) {
        guard let archive else { return }
        for (e, episode) in archive.episodes.enumerated() {
            let work = SimplePipeline.work(in: archive, index: e)
            var record = EpisodeRecord(id: episode.id, title: episode.title, text: episode.text,
                                       sourceKey: work.sourceKey, assetsExtracted: work.assetsExtracted)
            record.splitText = episode.splitText
            record.storyboardShotIDs = episode.shotIDs
            record.storyboardSplitSignature = episode.storyboardSplitSignature
            var assets: [LegacyEpisodeAsset] = []
            for asset in work.assets {
                guard let kind = SettingKind(pipelineKind: asset.kind) else { continue }
                let s = mergeSetting(sourceKey: id, kind: kind, name: asset.name, description: asset.description)
                if let item = asset.imageItemID, settingByImageItem[item] == nil { settingByImageItem[item] = s }
                if !record.settingIDs.contains(settings[s].id) { record.settingIDs.append(settings[s].id) }
                assets.append(LegacyEpisodeAsset(id: asset.id, settingID: settings[s].id, description: asset.description,
                                                 imageItemID: asset.imageItemID, libraryItemID: asset.libraryItemID))
            }
            if !assets.isEmpty { record.legacy = LegacyEpisodeInfo(assets: assets) }
            for (g, seg) in work.segments.enumerated() {
                record.segments.append(SegmentRecord(
                    id: seg.id, text: seg.text, prompt: seg.prompt,
                    sceneName: seg.sceneName, initialPositions: seg.initialPositions,
                    endPositions: seg.endPositions, continuityKey: seg.continuityKey,
                    params: .legacyDefault,
                    legacy: LegacySegmentInfo(assetNames: seg.assetNames)))
                if let shot = seg.shotID { segmentByShot[shot] = (episodes.count, g) }
            }
            episodes.append(record)
        }
    }

    // MARK: 生图条目 → 设定 + 图片版本

    mutating func buildImageItems() {
        let items = sourceKeys.sorted().flatMap { index.imageItemsByKey[$0] ?? [] }
        imageItemOrder = items.map(\.id)
        for item in items {
            let s: Int
            if let linked = settingByImageItem[item.id] {
                s = linked
                if settings[s].description.isEmpty { settings[s].description = item.prompt }
            } else if let type = item.type, !live {
                s = mergeSetting(sourceKey: item.projectKey, kind: SettingKind(imageSubject: type), name: item.name,
                                 description: item.prompt)
            } else {
                s = appendSetting(SettingRecord(id: previousByItem[item.id] ?? item.id,
                                                kind: SettingKind(imageSubject: item.type),
                                                name: item.name, description: item.prompt))
            }
            settingByImageItem[item.id] = s
            if settings[s].legacy?.imageCard == nil {
                var legacy = settings[s].legacy ?? LegacySettingInfo()
                legacy.imageCard = LegacyImageCard(itemID: item.id, status: item.status, errorMessage: item.errorMessage,
                                                   submittedAt: item.submittedAt, paramsDirty: item.paramsDirty,
                                                   stage: item.stage, fromEpisode: item.fromEpisode,
                                                   referenceCardID: item.referenceCardID,
                                                   failures: item.failures.isEmpty ? nil : item.failures,
                                                   voiceAudioID: item.voiceAudioID, voiceText: item.voiceText,
                                                   voiceMode: item.voiceMode)
                settings[s].legacy = legacy
            }
            settings[s].imageModel = item.model
            settings[s].imageAspect = item.aspectRatio
            settings[s].imageQuality = item.quality
            for result in item.results {
                let file = copy(result.localPath, into: ProjectDocument.imagesFolder)
                settings[s].versions.append(MediaVersion(
                    id: result.id, file: file, resultURL: result.resultURL, createdAt: result.createdAt,
                    prompt: result.prompt, model: result.model, aspect: result.aspectRatio, quality: result.quality))
                let v = settings[s].versions.count - 1
                versionByResult[result.id] = (s, v, result.localPath)
                if let refs = result.imageRefs { pendingResultRefs.append((s, v, refs)) }
            }
            if let selected = item.selectedResultID { settings[s].selectedVersionID = selected }
            if !item.imageRefs.isEmpty { pendingItemRefs.append((s, item.imageRefs)) }
        }
    }

    // MARK: 素材库 → 设定（生图复制件并进来源设定，只留一条条目记录给旧页面）

    mutating func buildLibrary() {
        let items = sourceKeys.sorted().flatMap { index.libraryByKey[$0] ?? [] }
        libraryOrder = items.map(\.id)
        for item in items { _ = settingIndex(forLibrary: item, asCopyFor: nil) }
        for (s, refs) in pendingItemRefs {
            settings[s].references = refs.compactMap { reference($0, media: .image, counting: false) }
        }
        for (s, v, refs) in pendingResultRefs {
            settings[s].versions[v].references = refs.compactMap { reference($0, media: .image, counting: false) }
        }
    }

    /// 素材库条目在本项目里对应的设定；没有就建一个。
    /// `asCopyFor`：别的项目的条目被本项目引用时，在本项目建一份（条目 ID 另起，避免两个项目里出现同一 ID）。
    private mutating func settingIndex(forLibrary item: LibraryItem, asCopyFor: UUID?) -> (setting: Int, entryID: UUID) {
        let entryID = asCopyFor.map { SimplePipeline.stableID("\(id)-xref-\($0)") } ?? item.id
        if let hit = settingByLibrary[entryID] { return hit }
        var entry = LegacyLibraryEntry(id: entryID, name: item.name, fileName: item.fileName,
                                       remoteURL: item.remoteURL, uploadState: item.uploadState,
                                       source: item.source, imageGenItemID: item.imageGenItemID)
        let s: Int
        if asCopyFor == nil, let gen = item.imageGenItemID, let linked = settingByImageItem[gen] {
            s = linked
            // 同名合并后来源条目可能已并掉：统一指向留下来的那张生图卡片
            entry.imageGenItemID = settings[s].legacy?.imageCard?.itemID ?? gen
            var target: Int?
            if let result = item.imageGenResultID, let hit = versionByResult[result], hit.setting == s {
                target = hit.version
                entry.versionID = result
                if settings[s].versions[hit.version].publicURL == nil {
                    settings[s].versions[hit.version].publicURL = item.remoteURL
                }
                // 生图原文件丢了、素材库复制件还在 → 用复制件补上
                if settings[s].versions[hit.version].file == nil,
                   let file = copy(item.localPath, into: ProjectDocument.imagesFolder, reportMissing: false) {
                    settings[s].versions[hit.version].file = file
                    missingFiles.removeAll { $0 == hit.path }
                }
            }
            let shown = target.map { settings[s].versions[$0] } ?? settings[s].portrait
            if live {
                let file = copy(item.localPath, into: ProjectDocument.imagesFolder)
                if file != shown?.file { entry.file = file }
            }
            if entry.remoteURL == shown?.publicURL { entry.remoteURL = nil }
        } else {
            let generated = item.source == .imageGenerated || item.imageGenItemID != nil
            let kind: SettingKind = generated ? SettingKind(imageSubject: item.subjectType(sourceType: nil)) : .imported
            let media: MediaReference.Media = switch item.kind {
            case .image: .image
            case .video: .video
            case .audio: .audio
            }
            let folder = kind == .imported ? ProjectDocument.importsFolder : ProjectDocument.imagesFolder
            let file = copy(item.localPath, into: folder)
            var name = generated ? item.matchKeyword : item.matchName
            if name == "未命名", let path = item.localPath, !path.isEmpty {
                name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            }
            let settingID = previousByLibrary[entryID] ?? entryID
            var setting = SettingRecord(id: settingID, kind: kind, name: name, media: media)
            setting.versions = [MediaVersion(id: entryID, file: file, publicURL: item.remoteURL,
                                             createdAt: Date(timeIntervalSinceReferenceDate: 0), duration: item.duration)]
            entry.versionID = entryID
            entry.remoteURL = nil
            if live, let previous = previousSettings[settingID] { setting.needsReview = previous.needsReview }
            s = appendSetting(setting)
        }
        var legacy = settings[s].legacy ?? LegacySettingInfo()
        legacy.libraryEntries.append(entry)
        settings[s].legacy = legacy
        settingByLibrary[entryID] = (s, entryID)
        return (s, entryID)
    }

    private mutating func reference(_ ref: MaterialRef, media: MediaReference.Media, counting: Bool) -> MediaReference? {
        guard let item = index.library[ref.libraryItemID] else {
            if counting { danglingReferences += 1 }
            return nil
        }
        let foreign = !sourceKeys.contains(item.projectKey ?? "")
        if counting, foreign { crossProjectReferences += 1 }
        let hit = settingIndex(forLibrary: item, asCopyFor: foreign ? item.id : nil)
        return MediaReference(id: ref.id, settingID: settings[hit.setting].id, media: media, role: ref.role,
                              legacyLibraryItemID: hit.entryID)
    }

    // MARK: 分镜卡 → 段（并进剧本段，或进自由集）+ 视频版本

    mutating func buildShots() {
        let shots = sourceKeys.sorted().flatMap { index.shotsByKey[$0] ?? [] }
        shotOrder = shots.map(\.id)
        var free: [SegmentRecord] = []
        for shot in shots {
            var references: [MediaReference] = []
            for (refs, media) in [(shot.imageRefs, MediaReference.Media.image), (shot.videoRefs, .video),
                                  (shot.audioRefs, .audio)] {
                references += refs.compactMap { reference($0, media: media, counting: true) }
            }
            let videos = videoVersions(of: shot)
            // 旧「显示当前」只改 shot.taskID（见 AppModel.setCurrentVersion）；指向最新那条时不记
            let selected = shot.taskID.flatMap { id in
                id != videos.last?.taskID && videos.contains { $0.taskID == id } ? id : nil
            }
            if let (e, g) = segmentByShot[shot.id] {
                var seg = episodes[e].segments[g]
                // 旧推理分镜页「不一致时以卡为准」
                if !shot.prompt.isEmpty { seg.prompt = shot.prompt }
                seg.numbering = shot.numbering
                seg.references = references
                seg.params = VideoParams(shot: shot)
                seg.videos = videos
                seg.selectedVideoTaskID = selected
                seg.createdAt = shot.createdAt
                seg.legacy?.shotID = shot.id
                seg.legacy?.paramsDirty = shot.paramsDirty
                seg.legacy?.pendingIsCurrent = shot.pendingIsCurrent ? true : nil
                seg.legacy?.pendingPrompt = shot.pendingPrompt
                episodes[e].segments[g] = seg
            } else {
                var ids: [UUID] = []
                for r in references where !ids.contains(r.settingID) { ids.append(r.settingID) }
                free.append(SegmentRecord(
                    id: shot.id, numbering: shot.numbering, settingIDs: ids, prompt: shot.prompt,
                    references: references, params: VideoParams(shot: shot),
                    videos: videos, selectedVideoTaskID: selected, createdAt: shot.createdAt,
                    legacy: LegacySegmentInfo(shotID: shot.id, paramsDirty: shot.paramsDirty,
                                              pendingIsCurrent: shot.pendingIsCurrent ? true : nil, pendingPrompt: shot.pendingPrompt)))
            }
        }
        if !free.isEmpty {
            episodes.append(EpisodeRecord(id: SimplePipeline.stableID("\(id)-free-episode"), title: "自由集",
                                          isFree: true, segments: free))
        }
    }

    private mutating func videoVersions(of shot: ShotDraft) -> [VideoVersion] {
        var ids = shot.taskIDs
        if let last = shot.taskID, !ids.contains(last) { ids.append(last) }
        var result: [VideoVersion] = []
        for taskID in ids {
            guard let task = index.tasks[taskID] else { missingTaskIDs += 1; continue }
            guard live || task.phase == .completed else { skippedUnfinishedTasks += 1; continue }
            let file = copy(task.localVideoPath, into: ProjectDocument.videosFolder)
            result.append(VideoVersion(
                id: SimplePipeline.stableID("video-\(task.id)"), taskID: task.id, createdAt: task.createdAt,
                phase: task.phase, file: file, resultURL: task.resultURL, prompt: task.prompt,
                params: VideoParams(task: task, watermark: shot.watermark),
                referenceImageURLs: task.referenceImageURLs ?? [],
                referenceVideoURLs: task.referenceVideoURLs ?? [],
                referenceAudioURLs: task.referenceAudioURLs ?? [],
                errorMessage: task.errorMessage,
                updatedAt: task.updatedAt == task.createdAt ? nil : task.updatedAt,
                fileName: task.fileName))
        }
        return result
    }

    // MARK: 收尾：剧本段的素材名 → 设定 ID；沿用上次的待确认标记

    mutating func finish() {
        // ⚠️ 先带回上次的别名和待确认标记，**再**解析段里的名字：顺序反了的话，确认过的别名
        // 下次存盘又会变回「对不上」（2026-10-07 名字确认时改的）
        if live {
            for i in settings.indices {
                guard let previous = previousSettings[settings[i].id] else { continue }
                settings[i].aliases = previous.aliases
                if previous.needsReview { settings[i].needsReview = true }
                for note in previous.reviewNotes where !settings[i].reviewNotes.contains(note) {
                    settings[i].reviewNotes.append(note)
                }
            }
        }
        for e in episodes.indices {
            for g in episodes[e].segments.indices {
                guard let names = episodes[e].segments[g].legacy?.assetNames, !episodes[e].isFree else { continue }
                var ids: [UUID] = []
                var unresolved: [String] = []
                for name in names where !ignoredNames.contains(name) {
                    if let s = settings.first(where: { $0.name == name || $0.aliases.contains(name) }) {
                        if !ids.contains(s.id) { ids.append(s.id) }
                    } else {
                        unresolved.append(name)
                    }
                }
                episodes[e].segments[g].settingIDs = ids
                episodes[e].segments[g].unresolvedNames = unresolved
            }
        }
    }

    /// 顺序表只记最终还在的条目，并且和适配层还原出来的顺序一致（合并掉的不记，新建的排后面），
    /// 这样「文档 → 旧数组 → 文档」来回一遍完全不变。
    func legacyInfo(archive: ProjectPipelineArchive?) -> LegacyProjectInfo {
        func settle(_ order: [UUID], _ existing: [UUID]) -> [UUID] {
            let set = Set(existing)
            let head = order.filter { set.contains($0) }
            let seen = Set(head)
            return head + existing.filter { !seen.contains($0) }
        }
        let cards = settings.compactMap { $0.legacy?.imageCard?.itemID }
        let entries = settings.flatMap { $0.legacy?.libraryEntries.map(\.id) ?? [] }
        return LegacyProjectInfo(hasPipelineArchive: archive != nil, pipelineArchiveID: archive?.projectId,
                                 pipelineEpisodeIndex: archive?.epIndex ?? 0, pipelineEra: archive?.eraBackground, shotOrder: shotOrder,
                                 imageItemOrder: settle(imageItemOrder, cards), libraryOrder: settle(libraryOrder, entries))
    }

    // MARK: 工具

    private mutating func appendSetting(_ setting: SettingRecord) -> Int {
        settings.append(setting)
        return settings.count - 1
    }

    /// 同一来源项目内按「类型 + 名字」合并；描述不同 → 待确认
    private mutating func mergeSetting(sourceKey: String, kind: SettingKind, name: String, description: String) -> Int {
        let key = "\(sourceKey)|\(kind.rawValue)|\(name)"
        guard let s = settingByMergeKey[key] else {
            let s = appendSetting(SettingRecord(id: SimplePipeline.stableID("\(id)-setting-\(key)"),
                                                kind: kind, name: name, description: description))
            settingByMergeKey[key] = s
            return s
        }
        let a = settings[s].description.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty {
            settings[s].description = description
        } else if !b.isEmpty, a != b, !settings[s].reviewNotes.contains(b) {
            settings[s].needsReview = true
            settings[s].reviewNotes.append(b)
        }
        return s
    }

    /// 文件字段：已在本项目文件夹里 → 相对路径；外部文件 → 规划拷贝（同一源只拷一次，目标重名加「-2」）；
    /// 外部文件不存在 → 迁移时记丢失、返回 nil，存盘时原样保留绝对路径（可能只是外接盘没插）。
    private mutating func copy(_ path: String?, into folder: String, reportMissing: Bool = true) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if let done = copiedPath[path] { return done }
        if let root = options.projectsRoot {
            let prefix = root.appendingPathComponent(id, isDirectory: true).path + "/"
            if path.hasPrefix(prefix) {
                let relative = String(path.dropFirst(prefix.count))
                usedRelative.insert(relative)
                copiedPath[path] = relative
                return relative
            }
        }
        guard fileExists(path) else {
            if live { return path }
            if reportMissing, !missingFiles.contains(path) { missingFiles.append(path) }
            return nil
        }
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var relative = "\(folder)/\(name)"
        var n = 2
        while usedRelative.contains(relative) || options.targetExists(id, relative) {
            relative = "\(folder)/\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            n += 1
        }
        usedRelative.insert(relative)
        copiedPath[path] = relative
        copies.append(PlannedFileCopy(source: path, projectID: id, relativePath: relative))
        return relative
    }

    func reportRow(_ doc: ProjectDocument) -> MigrationReport.ProjectRow {
        var row = MigrationReport.ProjectRow(id: doc.id, name: doc.name, previousName: doc.migration?.previousName)
        row.episodes = doc.episodes.filter { !$0.isFree }.count
        row.segments = doc.episodes.filter { !$0.isFree }.reduce(0) { $0 + $1.segments.count }
        row.freeSegments = doc.episodes.filter(\.isFree).reduce(0) { $0 + $1.segments.count }
        for s in doc.settings { row.settingsByKind[s.kind.displayName, default: 0] += 1 }
        row.mediaVersions = doc.settings.reduce(0) { $0 + $1.versions.count }
        row.videoVersions = doc.episodes.flatMap(\.segments).reduce(0) { $0 + $1.videos.count }
        row.needsReview = doc.settings.filter(\.needsReview).map { "\($0.kind.displayName)·\($0.name)" }
        row.unresolvedNames = Array(Set(doc.episodes.flatMap(\.segments).flatMap(\.unresolvedNames))).sorted()
        row.missingFiles = missingFiles
        row.skippedUnfinishedTasks = skippedUnfinishedTasks
        row.missingTaskIDs = missingTaskIDs
        row.danglingReferences = danglingReferences
        row.crossProjectReferences = crossProjectReferences
        return row
    }
}
