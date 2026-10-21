import Foundation

/// 模型能力：只做图片 / 视频两条路。
enum ModelCapability: String, Codable, Sendable {
    case image
    case video

    var displayName: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        }
    }
}

/// 渠道的**接入规范**：同一个 baseURL + apiKey，按哪种内置协议发请求。
///
/// - `.openAI`：OpenAI 规范（`POST {base}/v1/videos` multipart、`GET {base}/v1/videos/{id}`）。
/// - `.newAPI`：New API 通用视频（`POST {base}/v1/video/generations` JSON 任务制、
///   `GET {base}/v1/video/generations/{task_id}` 轮询，参考图走 OSS 直链）。
enum ChannelProtocol: String, Codable, Sendable {
    case openAI
    case newAPI

    var displayName: String {
        switch self {
        case .openAI: "OpenAI 规范"
        case .newAPI: "New API 视频"
        }
    }

    /// 分段选择器里的**短名**（设置页渠道编辑器专用）；摘要行仍用 `displayName`
    var shortName: String {
        switch self {
        case .openAI: "OpenAI"
        case .newAPI: "New API"
        }
    }
}

/// 渠道下的一个模型。`name` 即服务商要求的模型名（如 gpt-image-2.5 / minimax-h3）。
struct ChannelModel: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var capability: ModelCapability

    init(id: UUID = UUID(), name: String, capability: ModelCapability) {
        self.id = id
        self.name = name
        self.capability = capability
    }

    enum CodingKeys: String, CodingKey { case id, name, capability }

    /// 宽容解码：缺字段 / 未知能力值都不让整份配置解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let raw = try? c.decodeIfPresent(String.self, forKey: .capability) {
            capability = ModelCapability(rawValue: raw) ?? .video
        } else {
            capability = .video
        }
    }
}

/// 一次服务渠道：一个 baseURL + apiKey 下挂若干模型。
///
/// 统一替代旧的 `VideoProviderConfig`（视频）与 `ImageChannel`（图片）：
/// 渠道只描述"往哪发、用什么 Key"，能力（图片/视频）落在每个 `ChannelModel` 上。
struct ModelChannel: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String            // 渠道名
    var baseURL: String         // 如 https://api.example.com
    var apiKey: String
    var apiFormat: ChannelProtocol  // 接入规范（缺省 .openAI，兼容旧数据）
    var models: [ChannelModel]
    /// **提示词里的素材引用用 `@image1` 语法**（2026-09-26 加）。
    ///
    /// 有些上游要求在提示词里用 `@image1 / @video1 / @audio1`
    /// **按上传顺序**引用参考素材，而我们的提示词习惯写 `图1 / 视频1`（方括号是用户自己加的）。
    /// 打开这个开关后，提交时会把 `图N / 视频N / 音频N` 自动换成 `@imageN / @videoN / @audioN`。
    /// 默认关 —— 别的渠道认的是「图N」写法，开了反而对不上。
    var useAtImageSyntax: Bool

    init(id: UUID = UUID(), name: String, baseURL: String, apiKey: String,
         apiFormat: ChannelProtocol = .openAI, models: [ChannelModel] = [],
         useAtImageSyntax: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiFormat = apiFormat
        self.models = models
        self.useAtImageSyntax = useAtImageSyntax
    }

    enum CodingKeys: String, CodingKey { case id, name, baseURL, apiKey, apiFormat, models, useAtImageSyntax }

    /// 宽容解码：缺字段用默认，别让整份配置解码失败（旧/半截数据也能读出来）。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        // 宽容解码：旧数据没有该字段 / 存了未知规范值 → 一律回到 OpenAI 规范，不拖垮整份配置
        if let raw = try? c.decodeIfPresent(String.self, forKey: .apiFormat) {
            apiFormat = ChannelProtocol(rawValue: raw) ?? .openAI
        } else {
            apiFormat = .openAI
        }
        models = try c.decodeIfPresent([ChannelModel].self, forKey: .models) ?? []
        useAtImageSyntax = try c.decodeIfPresent(Bool.self, forKey: .useAtImageSyntax) ?? false
    }
}
