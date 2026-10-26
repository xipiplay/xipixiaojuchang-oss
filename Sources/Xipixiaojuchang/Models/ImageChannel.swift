import Foundation

/// 图片画幅
enum ImageAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case ratio16x9, ratio9x16, ratio1x1, ratio4x3, ratio3x4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        case .ratio1x1: "1:1"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        }
    }
}

/// 图片分辨率档位（几K）
enum ImageQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case k1, k2, k4

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .k1: "1K"
        case .k2: "2K"
        case .k4: "4K"
        }
    }

    /// OpenAI 规范 `quality` 字段值
    var apiValue: String {
        switch self {
        case .k1: "low"
        case .k2: "medium"
        case .k4: "high"
        }
    }
}

extension ImageQuality {
    /// 画幅 + 档位 → OpenAI size 字符串（如 2K 16:9 = 1920x1080）
    func sizeString(aspect: ImageAspect) -> String {
        switch self {
        case .k1:
            switch aspect {
            case .ratio16x9: return "1280x720"
            case .ratio9x16: return "720x1280"
            case .ratio1x1: return "1024x1024"
            case .ratio4x3: return "1152x864"
            case .ratio3x4: return "864x1152"
            }
        case .k2:
            switch aspect {
            case .ratio16x9: return "1920x1080"
            case .ratio9x16: return "1080x1920"
            case .ratio1x1: return "1408x1408"
            case .ratio4x3: return "1664x1248"
            case .ratio3x4: return "1248x1664"
            }
        case .k4:
            switch aspect {
            case .ratio16x9: return "2560x1440"
            case .ratio9x16: return "1440x2560"
            case .ratio1x1: return "2048x2048"
            case .ratio4x3: return "2304x1728"
            case .ratio3x4: return "1728x2304"
            }
        }
    }
}

/// 图片生成主题类型（角色/场景/道具）
enum ImageSubjectType: String, Codable, CaseIterable, Identifiable, Sendable {
    case character
    case scene
    case prop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .character: "角色图"
        case .scene: "场景图"
        case .prop: "道具图"
        }
    }

    /// 入库命名前缀
    var namePrefix: String {
        switch self {
        case .character: "角色"
        case .scene: "场景"
        case .prop: "道具"
        }
    }

    /// 批量解析关键字（用户已在推理规则里统一为全角冒号）
    var keyword: String {
        switch self {
        case .character: "这个人是"
        case .scene: "这个场景叫"
        case .prop: "这个物品名称叫"
        }
    }
}

/// 图片生成条目状态
enum ImageGenStatus: String, Codable, Sendable {
    case pending      // 待生成
    case queued       // 排队中（任务中心等渠道空位，2026-10-06 P2）
    case generating   // 生成中（等中转返回）
    case downloading  // 下载中（中转已返回，正在拉图转存）
    case success      // 成功
    case failed       // 失败

    /// 占着这张卡（排队中 / 生成中 / 下载中）：按钮置灰、显示进度
    var isBusy: Bool { self == .queued || self == .generating || self == .downloading }
}

/// 图片生成结果版本（一张生成好的图）
struct ImageGenResult: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var localPath: String?       // 下载转存后的本地路径
    var resultURL: String?       // 原始结果 URL（带时效）
    var createdAt: Date
    /// **这一版用的提示词**（2026-09-19 用户要求：提示词绑定到版本 —— 有的版本是微调过
    /// 提示词重新生成的）。老数据没有这个字段 → nil（用户已确认"老版本不用管"）。
    var prompt: String? = nil
    /// 提交生成时的设置快照。旧数据没有这些值；model 非空表示该版本有完整设置快照。
    var model: String? = nil
    var type: ImageSubjectType? = nil
    var aspectRatio: ImageAspect? = nil
    var quality: ImageQuality? = nil
    /// 生成时的参考图引用快照；nil 表示旧版本没有保存，空数组表示当时未使用参考图。
    var imageRefs: [MaterialRef]? = nil

    init(id: UUID = UUID(), localPath: String? = nil, resultURL: String? = nil,
         createdAt: Date = Date(), prompt: String? = nil, model: String? = nil,
         type: ImageSubjectType? = nil, aspectRatio: ImageAspect? = nil,
         quality: ImageQuality? = nil, imageRefs: [MaterialRef]? = nil) {
        self.id = id
        self.localPath = localPath
        self.resultURL = resultURL
        self.createdAt = createdAt
        self.prompt = prompt
        self.model = model
        self.type = type
        self.aspectRatio = aspectRatio
        self.quality = quality
        self.imageRefs = imageRefs
    }
}

/// 一次失败的生图（2026-10-16 用户：失败的生图也留成一个版本，和生视频一样）：提交时的提示词和设置 + 失败原因。
/// 没有图；在历史版本里占一个版本号，点它换回这次的提示词和参数改了再交
struct ImageGenFailure: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var error: String
    var prompt: String? = nil
    var model: String? = nil
    var type: ImageSubjectType? = nil
    var aspectRatio: ImageAspect? = nil
    var quality: ImageQuality? = nil
    var imageRefs: [MaterialRef]? = nil
}

/// 历史版本里的一项：成功的图，或者失败的那一次
enum ImageVersionEntry: Identifiable, Equatable {
    case result(ImageGenResult, number: Int)
    case failure(ImageGenFailure, number: Int)

    var id: UUID {
        switch self {
        case .result(let r, _): r.id
        case .failure(let f, _): f.id
        }
    }
    /// 第几版（成功和失败按时间先后一起数）
    var number: Int {
        switch self {
        case .result(_, let n), .failure(_, let n): n
        }
    }
    var result: ImageGenResult? { if case .result(let r, _) = self { r } else { nil } }
    var failure: ImageGenFailure? { if case .failure(let f, _) = self { f } else { nil } }
}

/// 角色卡音色用哪一种（编辑提示词弹窗「文本音色 / 音频音色」二选一；两边填的都留着）
enum VoiceMode: String, Codable, Sendable {
    case text, audio
}

/// 图片生成条目（批量解析产物，一条对应一张图；重新生成追加版本不覆盖；按项目隔离）
struct ImageGenItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var projectKey: String
    var type: ImageSubjectType?   // nil = 默认（不挂类型徽章、不入库，纯生图）
    var name: String
    var prompt: String
    var model: String?             // 卡片选择的图片模型名；空 = 用配置里第一个图片模型
    var aspectRatio: ImageAspect   // 画幅（卡片参数区）
    var quality: ImageQuality      // 分辨率档位（卡片参数区）
    var status: ImageGenStatus
    var results: [ImageGenResult]  // 生成结果版本列表
    /// 用户在缩略图详情中选中的版本；nil 表示跟随最新版本。
    /// 与结果列表一起写入项目数据，重开项目后仍显示用户选中的历史版本。
    var selectedResultID: UUID?
    var submittedAt: Date?         // 最近一次点「生成」的时间（任务列表按提交顺序排序用）
    var errorMessage: String?
    /// **参数脏标记**（2026-09-26 用户定的卡片规则）：用户改过参数（模型/画幅/档位）但
    /// **还没按这套参数生成过** → true（卡片参数显示为蓝色）；生成完成且期间没再改 → false（灰色）。
    /// 没生成过也没改过（false + 0 版）→ 卡片**不显示**参数行。
    var paramsDirty: Bool = false
    /// 参考图：生图时传给模型的图，**数组顺序即「图1 / 图2 …」**（提示词里的 token 按这个顺序编号）。
    /// 只存图片——生图走的是 OpenAI 的 `/v1/images/edits`，该端点只接受图片，视频/音频对生图无意义。
    var imageRefs: [MaterialRef] = []
    /// **变化版的基础版**（2026-10-09）：同一个人 / 地方 / 物品在另一个时期或状态下的卡（「第24集的周承山」「周承山十岁时期」），
    /// 出图时要拿基础版（通常是第一次出现的那张）当参考图，才还是同一个人。提取时记下，**点生成时**才去挂图
    /// （提取时基础版还没有图）；见 `AppModel.prepareBaseReference`。nil = 没有（普通卡，或用户把参考图删掉了）。
    var referenceCardID: UUID? = nil
    /// **阶段**（2026-10-14 名字与形态分离）：同一个人 / 地方 / 物品在另一个时间线上的形态（「四十岁」「少年」）；nil = 主时间线。
    /// 原来写在名字里（「周承山四十岁时期」），会跟着名字进生图 / 生视频提示词；现在名字只放基础名，阶段存这里。见 `CardVersion`
    var stage: String? = nil
    /// **起始集**：这一版从第几集起用（原来写成名字前缀「第3集的沈惊澜」）；nil = 全程有效。见 `CardVersion`
    var fromEpisode: Int? = nil
    /// 失败的生图（每次一条，和 `results` 一起按时间算版本号，见 `versionEntries`）
    var failures: [ImageGenFailure] = []
    /// 正在看的那一次失败（点了历史版本里失败的那一版）；nil = 看 `selectedResultID` / 最新的图。不存盘
    var viewingFailureID: UUID? = nil
    /// **音色**（2026-10-26 用户：音色和参考图一样绑在这个形象上，给生视频「全能参考」用）：素材库里的一段音频 / 一句文字描述，
    /// `voiceMode` 选用哪一种（nil = 有音频用音频，否则用文字）。每张卡只管自己的，**不沿用别的卡**（四十岁 / 少年是另外的形象，各绑各的）。
    /// 只给生视频用，**不传给生图模型**；换版本、重新生图都不动它。见 `CardVoice`
    var voiceAudioID: UUID? = nil
    var voiceText: String? = nil
    var voiceMode: VoiceMode? = nil

    init(id: UUID = UUID(),
         projectKey: String = "",
         type: ImageSubjectType? = nil,
         name: String,
         prompt: String,
         model: String? = nil,
         aspectRatio: ImageAspect = .ratio16x9,
         quality: ImageQuality = .k2,
         imageRefs: [MaterialRef] = [],
         status: ImageGenStatus = .pending) {
        self.id = id
        self.projectKey = projectKey
        self.type = type
        self.name = name
        self.prompt = prompt
        self.model = model
        self.aspectRatio = aspectRatio
        self.quality = quality
        self.imageRefs = imageRefs
        self.status = status
        self.results = []
        self.selectedResultID = nil
        self.submittedAt = nil
        self.errorMessage = nil
    }

    /// 生成请求用的尺寸字符串（画幅 + 档位组合）
    var sizeString: String {
        quality.sizeString(aspect: aspectRatio)
    }

    /// 最新结果版本（缩略图显示用）
    var latestResult: ImageGenResult? { results.last }

    /// 所有版本（成功的图 + 失败的那几次）按时间先后编号；列表显示时倒过来（最新的在前，2026-10-16 和生视频统一）
    var versionEntries: [ImageVersionEntry] {
        let merged: [(date: Date, entry: (Int) -> ImageVersionEntry)] =
            results.map { r in (r.createdAt, { .result(r, number: $0) }) } + failures.map { f in (f.createdAt, { .failure(f, number: $0) }) }
        return merged.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .enumerated().map { $0.element.element.entry($0.offset + 1) }
    }

    /// 某一版的版本号（第几版）
    func versionNumber(of id: UUID) -> Int? { versionEntries.first { $0.id == id }?.number }

    /// 正在看的失败（点了失败的那一版）
    var viewingFailure: ImageGenFailure? { viewingFailureID.flatMap { id in failures.first { $0.id == id } } }
}

// 自定义解码放扩展里（保留成员初始化器）：旧数据缺失字段时兜底
extension ImageGenItem {
    enum CodingKeys: String, CodingKey {
        case id, projectKey, type, name, prompt, model, aspectRatio, quality, status, results, selectedResultID, submittedAt, errorMessage
        case imageRefs
        case paramsDirty
        case referenceCardID
        case stage, fromEpisode
        case failures
        case voiceAudioID, voiceText, voiceMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectKey = try c.decodeIfPresent(String.self, forKey: .projectKey) ?? ""
        type = try c.decodeIfPresent(ImageSubjectType.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        prompt = try c.decode(String.self, forKey: .prompt)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        aspectRatio = try c.decodeIfPresent(ImageAspect.self, forKey: .aspectRatio) ?? .ratio16x9
        quality = try c.decodeIfPresent(ImageQuality.self, forKey: .quality) ?? .k2
        status = try c.decode(ImageGenStatus.self, forKey: .status)
        results = try c.decodeIfPresent([ImageGenResult].self, forKey: .results) ?? []
        selectedResultID = try c.decodeIfPresent(UUID.self, forKey: .selectedResultID)
        submittedAt = try c.decodeIfPresent(Date.self, forKey: .submittedAt)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        // ⚠️ 新字段必须同时加进 `CodingKeys` 和这里，**漏了不会编译报错、只会静默丢数据**
        // （这个类型是「手写 init(from:) + 合成 encode」的混合模式，编译器不会帮你检查）
        imageRefs = try c.decodeIfPresent([MaterialRef].self, forKey: .imageRefs) ?? []
        paramsDirty = try c.decodeIfPresent(Bool.self, forKey: .paramsDirty) ?? false
        referenceCardID = try c.decodeIfPresent(UUID.self, forKey: .referenceCardID)
        stage = try c.decodeIfPresent(String.self, forKey: .stage)
        fromEpisode = try c.decodeIfPresent(Int.self, forKey: .fromEpisode)
        failures = try c.decodeIfPresent([ImageGenFailure].self, forKey: .failures) ?? []
        voiceAudioID = try c.decodeIfPresent(UUID.self, forKey: .voiceAudioID)
        voiceText = try c.decodeIfPresent(String.self, forKey: .voiceText)
        voiceMode = try c.decodeIfPresent(VoiceMode.self, forKey: .voiceMode)
        // 旧卡：名字里的「第N集的」前缀拆成起始集（格式固定，拆得准；2026-10-14 名字与形态分离）
        CardVersion.splitLegacyPrefix(&self)
    }
}
