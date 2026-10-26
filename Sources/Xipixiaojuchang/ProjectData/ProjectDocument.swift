import Foundation

// MARK: - 2.0 数据格式（每项目一个文件夹：project.json + images/ videos/ imports/）
//
// 规则（重设计方案「数据模型」节）：
// - 对象之间只用 ID 关联，名字只用于显示；改名不断链。
// - 提示词只存一份：设定描述 = 唯一的生图提示词，段提示词 = 唯一的视频提示词；
//   版本里存的是「当时的快照」。
// - 文件路径相对项目文件夹（如 "images/xxx.png"），项目文件夹整个搬走也能用；
//   只有拷贝失败的外部文件才保留绝对路径（以 "/" 开头）。
//
// ⚠️ **以后给已有结构加字段必须是可选（`?`）**：合成的 Decodable 不认默认值，
// 非可选字段在旧文件里缺键会让整个项目读不出来。
//
// ⚠️ 名字以 `legacy` 开头的字段只给 P1–P4 期间的旧页面用（适配层要靠它们把数据原样还原成
// 旧的分镜卡 / 生图条目 / 素材库条目），新页面不读不写，P5 和旧页面一起删掉。

/// 一个项目的全部数据（`<项目文件夹>/project.json`）
struct ProjectDocument: Codable, Equatable, Sendable {
    static let currentFormatVersion = 2
    static let fileName = "project.json"
    static let imagesFolder = "images"
    static let videosFolder = "videos"
    static let importsFolder = "imports"

    static func encode(_ doc: ProjectDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(doc)
    }

    static func decode(_ data: Data) throws -> ProjectDocument {
        try JSONDecoder().decode(ProjectDocument.self, from: data)
    }

    /// 文件字段 → 绝对路径（相对路径按项目文件夹解析；以 "/" 开头的是没拷进来的外部文件）
    static func absolutePath(_ file: String, projectFolder: URL) -> String {
        file.hasPrefix("/") ? file : projectFolder.appendingPathComponent(file).path
    }

    var formatVersion = ProjectDocument.currentFormatVersion
    /// 项目 ID = 项目文件夹名。迁移来的项目沿用旧 projectKey（含 `vid_…` 这种老格式）。
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// 剧本原文（整份）
    var script: String = ""
    var scriptFileName: String = ""
    /// 每段目标秒数（时长分割用）
    var segmentSeconds: Int = 30
    /// 剧本集按序号排列；「自由集」（`isFree`）放在最后
    var episodes: [EpisodeRecord] = []
    var settings: [SettingRecord] = []
    /// 迁移来源（新建的项目为 nil）
    var migration: MigrationStamp?
    var legacy: LegacyProjectInfo?
    /// 用户确认过「不是设定」的名字（AI 写的、画面里不需要出图的东西，如「床」）：之后各集不再提醒。
    /// 别名放在对应设定的 `aliases` 里。⚠️ 新加字段必须是可选（见文件头）。
    var ignoredNames: [String]?
}

struct MigrationStamp: Codable, Equatable, Sendable {
    var fromVersion: String
    var migratedAt: Date
    /// 迁移前的项目名（迁移时为去重改过名才有值）
    var previousName: String?
    /// 合并进来的旧 projectKey（「迁移-未归属图片」项目会有多个）
    var legacyKeys: [String]
}

// MARK: 集与段

struct EpisodeRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    /// 本集原文；自由集为空
    var text: String = ""
    /// 自由集：不走剧本、直接写提示词生视频的段都在这里
    var isFree = false
    /// 原文指纹（`SimplePipeline.key`），原文改了据此判断段过期
    var sourceKey: String = ""
    var assetsExtracted = false
    /// 本集提取出的设定（顺序 = 提取顺序）
    var settingIDs: [UUID] = []
    var segments: [SegmentRecord] = []
    var legacy: LegacyEpisodeInfo?
    /// 「批量分割」的结果（2026-10-07）：用分割（时长）提示词整理出的这一集文本，和原文各存一份。
    /// ⚠️ 必须可选：旧项目文件里没有这个字段，非可选会让整个项目读不出来。
    var splitText: String?
    /// 「推理分镜」给这一集建的生视频卡（按段顺序，卡片 ID）。同上，必须可选。
    var storyboardShotIDs: [UUID]?
    /// 推理分镜时分割的段落结构（见 `Episode.storyboardSplitSignature`）。同上，必须可选
    var storyboardSplitSignature: String?
}

struct SegmentRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 段原文；自由集的段为空
    var text: String = ""
    /// 自由集沿用旧分镜卡的「分镜 a-b」编号（视频文件名前缀也靠它）
    var numbering: ShotNumbering?
    /// 用到的设定（顺序 = 提示词里出现的顺序）
    var settingIDs: [UUID] = []
    /// AI 给出、但按「名称 + 别名」对不上任何设定的名字，等用户确认
    var unresolvedNames: [String] = []
    /// 视频提示词（唯一一份）
    var prompt: String = ""
    /// 提交视频时带的参考素材（首帧 / 尾帧 / 参考图、参考视频、参考音频）
    var references: [MediaReference] = []
    // 站位承接（推理分镜产出）
    var sceneName: String = ""
    var initialPositions: String = ""
    var endPositions: String = ""
    var continuityKey: String = ""
    var params: VideoParams
    /// 提交过的视频（按提交顺序；迁移时只带成功的，之后的生成中 / 失败也在这里）
    var videos: [VideoVersion] = []
    /// 用户指定的当前版本（任务 ID）；nil = 跟随最新提交
    var selectedVideoTaskID: String?
    var createdAt: Date?
    var legacy: LegacySegmentInfo?

    /// 进成片的那一版：用户指定的，否则最新一个成功的
    var selectedVideo: VideoVersion? {
        selectedVideoTaskID.flatMap { id in videos.first { $0.taskID == id } } ?? videos.last { $0.phase == .completed }
    }
}

/// 对一个设定的引用（段的参考素材、生图参考图、生图版本的参考快照共用）
struct MediaReference: Codable, Equatable, Identifiable, Sendable {
    enum Media: String, Codable, Sendable { case image, video, audio }
    var id: UUID
    var settingID: UUID
    var media: Media
    var role: ReferenceImageRole?
    /// 旧页面引用的是哪条素材库条目（同一设定可能被存过多次）
    var legacyLibraryItemID: UUID?
}

struct VideoParams: Codable, Equatable, Sendable {
    /// 旧分镜卡的默认参数（剧本段还没建卡时用）
    static let legacyDefault = VideoParams(shot: ShotDraft())

    var model: String
    var providerID: String
    var duration: Int
    var aspectRatio: AspectRatio
    var resolution: Resolution?
    var generateAudio: Bool
    var watermark: Bool
}

extension VideoParams {
    init(shot: ShotDraft) {
        self.init(model: shot.model, providerID: shot.providerID, duration: shot.duration,
                  aspectRatio: shot.aspectRatio, resolution: shot.resolution,
                  generateAudio: shot.generateAudio, watermark: shot.watermark)
    }

    init(task: LocalTask, watermark: Bool) {
        self.init(model: task.model, providerID: task.providerID, duration: task.duration,
                  aspectRatio: task.aspectRatio, resolution: task.resolution,
                  generateAudio: task.generateAudio, watermark: watermark)
    }
}

/// 一次视频提交
struct VideoVersion: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 服务端任务 ID（任务进度在全局任务记录里，P2 并进任务中心）
    var taskID: String
    var createdAt: Date
    var phase: TaskPhase
    /// 相对项目文件夹；nil = 本地文件不在（可用 resultURL 重下，链接可能已过期）
    var file: String?
    var resultURL: String?
    /// 提交时的快照
    var prompt: String
    var params: VideoParams
    var referenceImageURLs: [String] = []
    var referenceVideoURLs: [String] = []
    var referenceAudioURLs: [String] = []
    // P2 起（任务记录并进项目文件）。⚠️ 新加字段一律可选：旧 project.json 里没有这些键，
    // 合成的 Decodable 不认默认值，非可选字段缺键会让整个项目读不出来。
    var errorMessage: String?
    var updatedAt: Date?
    /// 下载文件名（「X-分镜-Y」）
    var fileName: String?
}

// MARK: 设定

enum SettingKind: String, Codable, CaseIterable, Sendable {
    case character, scene, prop
    /// 生成但没标类型的图（旧生图页「默认」类型）
    case other
    /// 用户自带的图 / 视频 / 音频
    case imported

    var displayName: String {
        switch self {
        case .character: "角色"
        case .scene: "场景"
        case .prop: "道具"
        case .other: "其他"
        case .imported: "导入"
        }
    }

    var pipelineKind: String? {
        switch self {
        case .character: "角色"
        case .scene: "场景"
        case .prop: "道具"
        case .other, .imported: nil
        }
    }

    var imageSubject: ImageSubjectType? {
        switch self {
        case .character: .character
        case .scene: .scene
        case .prop: .prop
        case .other, .imported: nil
        }
    }

    init?(pipelineKind: String) {
        switch pipelineKind {
        case "角色": self = .character
        case "场景": self = .scene
        case "道具": self = .prop
        default: return nil
        }
    }

    init(imageSubject: ImageSubjectType?) {
        switch imageSubject {
        case .character: self = .character
        case .scene: self = .scene
        case .prop: self = .prop
        case nil: self = .other
        }
    }
}

struct SettingRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: SettingKind
    var name: String
    var aliases: [String] = []
    /// 生图提示词（唯一一份）；导入类为空
    var description: String = ""
    /// 导入类的媒体类型；生成类恒为 image
    var media: MediaReference.Media = .image
    /// 生成结果 / 导入文件（导入类只有一版）
    var versions: [MediaVersion] = []
    /// 用户挑的定妆图；nil = 跟随最新一版
    var selectedVersionID: UUID?
    // 生图参数
    var imageModel: String?
    var imageAspect: ImageAspect?
    var imageQuality: ImageQuality?
    /// 生图时带的参考图（顺序 = 提示词里的「图1 / 图2」）
    var references: [MediaReference] = []
    /// 迁移时合并了多条描述不同的来源，等用户确认
    var needsReview = false
    var reviewNotes: [String] = []
    var legacy: LegacySettingInfo?

    /// 定妆图（被视频引用的那一版）
    var portrait: MediaVersion? {
        selectedVersionID.flatMap { id in versions.first { $0.id == id } } ?? versions.last
    }
}

/// 一个文件版本：生成的图，或导入的图 / 视频 / 音频
struct MediaVersion: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// 相对项目文件夹；nil = 本地文件已丢失
    var file: String?
    /// 生成服务返回的原始链接（有时效）
    var resultURL: String?
    /// 上传后的公网直链缓存（提交视频时直接用）
    var publicURL: String?
    var createdAt: Date
    /// 音视频时长（秒）
    var duration: Double?
    /// 生成时的快照（导入的为 nil）
    var prompt: String?
    var model: String?
    var aspect: ImageAspect?
    var quality: ImageQuality?
    /// 生成时带的参考图快照；nil = 旧版本没记
    var references: [MediaReference]?
}

// MARK: - 适配层字段（P5 删除）

struct LegacyProjectInfo: Codable, Equatable, Sendable {
    /// 旧剧本存档是否存在（不存在时剧本页显示导入空态）
    var hasPipelineArchive = false
    var pipelineArchiveID: UUID?
    var pipelineEpisodeIndex = 0
    /// 时代背景（提取素材时每个请求都带上）。⚠️ 新加字段必须是可选
    var pipelineEra: String?
    /// 旧数组里的先后顺序（页面按数组顺序显示）
    var shotOrder: [UUID] = []
    var imageItemOrder: [UUID] = []
    var libraryOrder: [UUID] = []
}

struct LegacyEpisodeInfo: Codable, Equatable, Sendable {
    /// 旧版「每集一份素材」：同名设定合并后，各集原来的描述和链接
    var assets: [LegacyEpisodeAsset] = []
}

struct LegacyEpisodeAsset: Codable, Equatable, Sendable {
    var id: UUID
    var settingID: UUID
    var description: String
    var imageItemID: UUID?
    var libraryItemID: UUID?
}

struct LegacySegmentInfo: Codable, Equatable, Sendable {
    /// 旧分镜卡 ID（剧本段并进来的卡、自由集的卡都记）
    var shotID: UUID?
    var paramsDirty = false
    /// 「待生成」版本（`ShotDraft.pendingIsCurrent` / `pendingPrompt`，2026-10-15）。旧文件没有 = nil
    var pendingIsCurrent: Bool? = nil
    var pendingPrompt: String? = nil
    /// AI 给的原始素材名（顺序原样）
    var assetNames: [String] = []
}

struct LegacySettingInfo: Codable, Equatable, Sendable {
    /// 旧生图页的卡片（没有 = 这个设定在生图页不显示）
    var imageCard: LegacyImageCard?
    /// 旧素材库里指向这个设定的条目（可能存过多次）
    var libraryEntries: [LegacyLibraryEntry] = []
}

struct LegacyImageCard: Codable, Equatable, Sendable {
    var itemID: UUID
    var status: ImageGenStatus
    var errorMessage: String?
    var submittedAt: Date?
    var paramsDirty = false
    /// 卡片的阶段 / 起始集（`ImageGenItem.stage` / `fromEpisode`，2026-10-14 名字与形态分离）。旧文件没有 = nil
    var stage: String? = nil
    var fromEpisode: Int? = nil
    /// 变化版的基础版（`ImageGenItem.referenceCardID`，出图时拿它的图当参考图）。原来没存进项目文件，重开项目就丢了（2026-10-14 补）
    var referenceCardID: UUID? = nil
    /// 失败的生图（`ImageGenItem.failures`，2026-10-16 起留成版本）。旧文件没有 = nil
    var failures: [ImageGenFailure]? = nil
    /// 角色卡绑的音色（`ImageGenItem.voiceAudioID` = 素材库条目 ID / `voiceText` / `voiceMode` 用哪种，2026-10-26）。旧文件没有 = nil
    var voiceAudioID: UUID? = nil
    var voiceText: String? = nil
    var voiceMode: VoiceMode? = nil
}

struct LegacyLibraryEntry: Codable, Equatable, Sendable {
    var id: UUID
    var name: String?
    var fileName: String?
    /// 素材库复制件自己的文件；nil = 用 versionID 那一版（没有就用定妆图）
    var file: String?
    var versionID: UUID?
    var remoteURL: String?
    var uploadState: LibraryItem.UploadState
    var source: LibraryItem.Source?
    /// 原始的来源生图条目 ID（来源已删时是悬空的，原样保留）
    var imageGenItemID: UUID?
}
