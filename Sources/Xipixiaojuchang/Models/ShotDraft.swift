import Foundation

/// 分镜内对素材库条目的引用
struct MaterialRef: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let libraryItemID: UUID
    var role: ReferenceImageRole?   // 仅图片使用

    init(id: UUID = UUID(), libraryItemID: UUID, role: ReferenceImageRole? = nil) {
        self.id = id
        self.libraryItemID = libraryItemID
        self.role = role
    }
}

/// 分镜草稿（一张卡片）：提示词 + 引用素材 + 参数 + 提交后关联任务
struct ShotDraft: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var projectKey: String        // 所属项目（新建项目时生成，或历史项目的 groupKey）
    var model: String             // 模型名（渠道里配置的 ChannelModel.name；旧 WanModel rawValue 原样保留）
    var providerID: String        // 生成渠道名（提交时写入；老值原样保留）
    var prompt: String
    var duration: Int
    var aspectRatio: AspectRatio
    var resolution: Resolution    // 视频分辨率档位（统一字段；旧 jimeng/dashScope 分辨率解码时兜底）
    var generateAudio: Bool
    var watermark: Bool
    var imageRefs: [MaterialRef]
    var videoRefs: [MaterialRef]
    var audioRefs: [MaterialRef]
    var taskID: String?   // 最新提交的任务 ID（兼容旧数据）
    var taskIDs: [String] // 该分镜提交过的所有任务 ID（历史版本，最新在最后）
    var createdAt: Date?  // 分镜创建时间（旧数据缺失为 nil）

    /// 文件名 / 标题编号（`A-B-版本`）—— 见 `ShotNumbering` 的说明。
    ///
    /// ⚠️ **必须可选**：旧 shots.json 里没有这个字段 —— 加**非可选**字段会让旧数据整个解码失败
    /// 被空数组覆盖（2026-09-05 已经这样丢过 28 个分镜）。读取处一律走 `AppModel.numbering(of:)` 兜底。
    var numbering: ShotNumbering?
    /// **参数脏标记**（2026-09-26 用户定的卡片规则，与生图侧同一套）：改过参数（模型/分辨率/比例/时长）
    /// 但**还没按这套提交生成** → true（卡片参数显示为蓝色）；提交后转灰。0 版 + 没改过 → 卡片不显示参数行。
    var paramsDirty: Bool = false
    /// **「待生成」版本**（2026-10-15 用户）：重新推理出来、还没生成视频的提示词，算这张卡的一个版本，排在历史版本最后。
    /// 一张卡最多一个，再推理一次就覆盖它；点「生成」后它就成了正式的新版本（清掉）。
    /// - `pendingIsCurrent`：当前版本就是它（提示词在 `prompt` 里；`taskID` 置空——缩略图 / 大预览 / 卡片照「还没有视频」显示成「待生成」，
    ///   历史版本都还在 `taskIDs` 里）
    /// - `pendingPrompt`：点了别的版本时把它的提示词收在这里，点回「待生成」再放回 `prompt`
    /// 没生成过视频的卡用不着它（整张卡本来就是待生成）
    var pendingIsCurrent: Bool = false
    var pendingPrompt: String?

    /// 有「待生成」版本（当前是它，或收起来了）
    var hasPendingVersion: Bool { !taskIDs.isEmpty && (pendingIsCurrent || pendingPrompt != nil) }
    /// 当前版本是「待生成」
    var showsPendingVersion: Bool { pendingIsCurrent && !taskIDs.isEmpty }

    init(id: UUID = UUID(),
         projectKey: String = "",
         model: String = "",
         providerID: String = "",
         prompt: String = "",
         duration: Int = 5,
         aspectRatio: AspectRatio = .ratio16x9,
         resolution: Resolution = .p720,
         generateAudio: Bool = true,
         watermark: Bool = false,
         imageRefs: [MaterialRef] = [],
         videoRefs: [MaterialRef] = [],
         audioRefs: [MaterialRef] = [],
         taskID: String? = nil,
         taskIDs: [String] = [],
         createdAt: Date? = Date(),
         numbering: ShotNumbering? = nil) {
        self.id = id
        self.projectKey = projectKey
        self.model = model
        self.providerID = providerID
        self.prompt = prompt
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.generateAudio = generateAudio
        self.watermark = watermark
        self.imageRefs = imageRefs
        self.videoRefs = videoRefs
        self.audioRefs = audioRefs
        self.taskID = taskID
        self.taskIDs = taskIDs
        self.createdAt = createdAt
        self.numbering = numbering
    }

    /// 预估费用（分）：新协议不预估，统一 0。
    var costFen: Int { 0 }

    // MARK: Codable（taskIDs / createdAt 兼容旧数据缺失）

    enum CodingKeys: String, CodingKey {
        case id, projectKey, model, providerID, prompt, duration, aspectRatio
        case resolution
        case generateAudio, watermark, imageRefs, videoRefs, audioRefs
        case taskID, taskIDs, createdAt
        case numbering
        case paramsDirty
        case pendingIsCurrent, pendingPrompt
        // 旧字段：只解码、不再编码（见 `init(from:)`）
        case jimengMode, jimengResolution
        case dashScopeResolution, dashScopeMode
        case customResolution
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectKey = try c.decode(String.self, forKey: .projectKey)
        // 旧数据里 model 是 WanModel rawValue（本身就是 String）→ 原样保留、界面照常显示
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        // 旧数据里 providerID 是 VideoProviderID rawValue（String）→ 原样保留
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? ""
        prompt = try c.decode(String.self, forKey: .prompt)
        duration = try c.decode(Int.self, forKey: .duration)
        aspectRatio = try c.decode(AspectRatio.self, forKey: .aspectRatio)
        // 分辨率新字段；旧数据缺失时从 dashScope/jimeng/custom 兜底（宽容解码：单个坏字段不拖垮整条）
        if let value = try? c.decodeIfPresent(Resolution.self, forKey: .resolution) {
            resolution = value
        } else if let value = try? c.decodeIfPresent(Resolution.self, forKey: .dashScopeResolution) {
            resolution = value
        } else if let value = try? c.decodeIfPresent(Resolution.self, forKey: .jimengResolution) {
            resolution = value
        } else if let value = try? c.decodeIfPresent(Resolution.self, forKey: .customResolution) {
            resolution = value
        } else {
            resolution = .p720
        }
        generateAudio = try c.decode(Bool.self, forKey: .generateAudio)
        watermark = try c.decode(Bool.self, forKey: .watermark)
        imageRefs = try c.decode([MaterialRef].self, forKey: .imageRefs)
        videoRefs = try c.decode([MaterialRef].self, forKey: .videoRefs)
        audioRefs = try c.decode([MaterialRef].self, forKey: .audioRefs)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        taskIDs = try c.decodeIfPresent([String].self, forKey: .taskIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        numbering = try c.decodeIfPresent(ShotNumbering.self, forKey: .numbering)
        paramsDirty = try c.decodeIfPresent(Bool.self, forKey: .paramsDirty) ?? false
        pendingIsCurrent = try c.decodeIfPresent(Bool.self, forKey: .pendingIsCurrent) ?? false
        pendingPrompt = try c.decodeIfPresent(String.self, forKey: .pendingPrompt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(projectKey, forKey: .projectKey)
        try c.encode(model, forKey: .model)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(duration, forKey: .duration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(generateAudio, forKey: .generateAudio)
        try c.encode(watermark, forKey: .watermark)
        try c.encode(imageRefs, forKey: .imageRefs)
        try c.encode(videoRefs, forKey: .videoRefs)
        try c.encode(audioRefs, forKey: .audioRefs)
        try c.encodeIfPresent(taskID, forKey: .taskID)
        try c.encode(taskIDs, forKey: .taskIDs)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(numbering, forKey: .numbering)
        try c.encode(paramsDirty, forKey: .paramsDirty)
        if pendingIsCurrent { try c.encode(pendingIsCurrent, forKey: .pendingIsCurrent) }
        try c.encodeIfPresent(pendingPrompt, forKey: .pendingPrompt)
        // 旧字段（jimengMode/jimengResolution/dashScopeResolution/dashScopeMode/customResolution）不再写入
    }
}

/// 分镜的**编号**：文件名 `A-B-版本`、标题「分镜A-B」（用户 2026-09-13 定的格式）。
///
/// - `a` **段号**：原始分镜 = 它自己的序号；**插入的分镜 = 前一个分镜的 a**（挂在那个分镜下）
/// - `b` **段内序号**：原始分镜 = 1；插入的 = 该段已有的最大 b + 1
///
/// 例：分镜一 → 标题「分镜1-1」、文件 `1-1-1`；在它后面插入 → 「分镜1-2」、`1-2-1`；
/// 再插一个 → 「分镜1-3」、`1-3-1`。分镜二不受影响，永远是「分镜2-1」。
///
/// **「推理分镜」建的卡（2026-10-07 用户定）**：`a` = 第几集，`b` = 这一集的第几段。
/// 第 1 集的三段 = 分镜1-1、分镜1-2、分镜1-3；第 2 集 = 分镜2-1、分镜2-2…… 文件 `集号-段号-版本`。
/// 在生视频页给某张卡「增加分镜」仍是同一条规则：挂在那张卡的 a 下面，b 取该集已有的最大值 + 1。
///
/// **为什么不用位置序号**（旧实现是 `firstIndex + 1`）：删一个 / 插入一个，后面全体前移一位 →
/// 新下载的视频文件名**撞上旧文件**，而 `DownloadService` 遇同名是"直接删旧的再写" →
/// **静默丢视频**。现在插入的分镜只在**自己那一段**里递增，永远不挤动别人。
struct ShotNumbering: Codable, Equatable, Sendable {
    var a: Int
    var b: Int

    /// 标题：「分镜1-1」（与文件名的前两段一致，一眼能对上）
    var title: String { "分镜\(a)-\(b)" }

    /// 文件名前缀：「1-1」（版本号由调用方接在后面）
    var filePrefix: String { "\(a)-\(b)" }
}
