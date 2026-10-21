import Foundation

/// 视频提交的单个文件输入：本地路径优先；没有本地文件时用远程 URL（客户端先下载成临时文件）。
struct VideoFileInput: Sendable, Equatable {
    let localPath: String?
    let remoteURL: String?
    let fileName: String

    init(localPath: String? = nil, remoteURL: String? = nil, fileName: String = "") {
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.fileName = fileName
    }
}

/// 视频提交请求。字段同时供两套接入规范使用：
/// - OpenAI 规范（`POST {base}/v1/videos`，multipart）：model / prompt / seconds / size /
///   resolution_name / generate_audio / watermark / mode + first_frame / last_frame / image[]。
/// - New API（`POST {base}/v1/video/generations`，JSON）：model / prompt / images / duration / 宽高 / metadata。
struct VideoGenerationRequest: Sendable {
    let model: String
    let prompt: String?
    let duration: Int
    let aspectRatio: AspectRatio    // New API 的 aspect_ratio（OpenAI 规范用 size，不用它）
    let size: String
    let resolutionName: String
    let generateAudio: Bool
    let watermark: Bool
    let mode: String?               // "frames" | "reference" | nil（纯文生，不带素材）
    let firstFrame: VideoFileInput?
    let lastFrame: VideoFileInput?
    let referenceImages: [VideoFileInput]
    /// 参考视频 / 音频：**URL 形式**（由服务端自己拉取）。
    /// OpenAI 规范不发送这两个字段（现状不变）。空串 = 该素材缺少远程 URL，提交时明确报错。
    let referenceVideos: [String]
    let referenceAudios: [String]
}

/// 视频轮询响应（`GET {base}/v1/videos/{id}`）。
///
/// 宽容解析：`{id, status, url?/result_url?/video_url?/content:{video_url?/url?}, error:{message}}`，
/// 字段名不完全统一，逐个候选键尝试，最后退到递归找视频直链。
struct VideoStatusResponse: Sendable {
    let status: String?
    let videoURL: URL?
    let failureReason: String?
    let progress: Double?
    /// 返回里带的上游报错（`error.message`，非空才算）。有的中转失败时只给这个、`status` 不变成 failed
    ///（2026-10-14 实测：`{"error":{"message":"<urlopen error … timed out>","type":"proxy_error"},"progress":100,…}`，
    /// 后台显示失败，软件却一直「生成中 100%」）。轮询层看它连续出现一段时间才判失败，见 `PollingManager.upstreamErrorVerdict`
    let upstreamError: String?

    init(data: Data) throws {
        let raw = try apiJSONDecoder.decode(JSONValue.self, from: data)
        // 先按 OpenAI 规范及旧代理的键取；`output.task_status` 是一些异步任务接口的状态写法，
        // 放在后面只为不改变既有渠道的解析优先级。
        status = raw.string(at: ["status"])
            ?? raw.string(at: ["state"])
            ?? raw.string(at: ["data", "status"])
            ?? raw.string(at: ["output", "task_status"])
        // New API 中转常返回 `{code,data}` 包装，失败原因在 `data.fail_reason` / `data.data.error`；
        // 空串不算命中（例如成功响应里 `message:""`），否则会盖住后面真正的失败原因。
        failureReason = Self.firstNonEmptyString(in: raw, paths: [
            ["error", "message"],
            ["output", "message"],
            ["output", "code"],
            ["error"],
            ["message"],
            ["fail_reason"],
            ["data", "fail_reason"],
            ["data", "error", "message"],
            ["data", "data", "error", "message"],
            ["data", "error"],
        ])
        upstreamError = Self.firstNonEmptyString(in: raw, paths: [["error", "message"]])
        videoURL = Self.findURL(in: raw)
        progress = Self.findProgress(in: raw)
    }

    /// 按路径取第一个非空字符串（空串 / 纯空白视为未命中）
    private static func firstNonEmptyString(in raw: JSONValue, paths: [[String]]) -> String? {
        for path in paths {
            if let value = raw.string(at: path),
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    var phase: TaskPhase? {
        guard let status else { return nil }
        return TaskPhase(serverStatus: status)
    }

    private static func findURL(in raw: JSONValue) -> URL? {
        let candidates: [String?] = [
            raw.string(at: ["url"]),
            raw.string(at: ["result_url"]),
            raw.string(at: ["video_url"]),
            raw.string(at: ["content", "video_url"]),
            raw.string(at: ["content", "url"]),
            raw.string(at: ["data", "url"]),
            raw.string(at: ["data", "video_url"]),
            raw.string(at: ["output", "video_url"]),
            // New API 中转的 `{code,data}` 包装（实测 geek）：
            // 任务记录在顶层 `data`，生成结果嵌在 `data.data`；`data.result_url` 与
            // `data.data.video_url` 都是中转转存直链（优先），`data.data.url` 是上游原始直链（回落）。
            raw.string(at: ["data", "result_url"]),
            raw.string(at: ["data", "data", "video_url"]),
            raw.string(at: ["data", "data", "url"]),
            raw.string(at: ["data", "data", "content", "video_url"]),
            raw.string(at: ["data", "data", "content", "url"]),
            raw.string(at: ["data", "data", "properties", "result_url"]),
            raw.string(at: ["data", "data", "properties", "url"]),
            raw.string(at: ["data", "properties", "result_url"]),
            raw.string(at: ["data", "properties", "url"]),
        ]
        for candidate in candidates {
            guard let candidate, let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { continue }
            return url
        }
        return raw.findVideoURL()
    }

    private static func findProgress(in node: JSONValue) -> Double? {
        switch node {
        case .object(let dict):
            if let value = dict["progress"] {
                switch value {
                case .string(let string):
                    let cleaned = string.replacingOccurrences(of: "%", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let number = Double(cleaned) { return number }
                case .number(let number):
                    return number
                default:
                    break
                }
            }
            for (_, value) in dict {
                if let found = findProgress(in: value) { return found }
            }
            return nil
        case .array(let items):
            for item in items {
                if let found = findProgress(in: item) { return found }
            }
            return nil
        default:
            return nil
        }
    }
}

enum ReferenceImageRole: String, Codable, Sendable {
    case firstFrame = "first_frame"
    case lastFrame = "last_frame"
    case referenceImage = "reference_image"
}

enum AspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case adaptive
    case ratio16x9 = "16:9"
    case ratio9x16 = "9:16"
    case ratio1x1 = "1:1"
    case ratio4x3 = "4:3"
    case ratio3x4 = "3:4"
    /// 兼容旧数据（H3 系列曾用横/竖）
    case horizontal
    case vertical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .adaptive: "自适应"
        case .ratio16x9: "16:9（横屏）"
        case .ratio9x16: "9:16（竖屏）"
        case .ratio1x1: "1:1（方形）"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        case .horizontal: "横屏"
        case .vertical: "竖屏"
        }
    }

    /// 纯比例标签：去掉「（横屏）/（竖屏）/（方形）」注解（任务列表等紧凑场景用）
    var plainLabel: String {
        switch self {
        case .adaptive: "自适应"
        case .ratio16x9: "16:9"
        case .ratio9x16: "9:16"
        case .ratio1x1: "1:1"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        case .horizontal: "16:9"
        case .vertical: "9:16"
        }
    }

    /// 画幅 → 通用 API `ratio` 字符串（`16:9` / `9:16` / `1:1` / `4:3` / `3:4` / `adaptive`）。
    var ratioValue: String {
        switch self {
        case .adaptive: "adaptive"
        case .ratio16x9, .horizontal: "16:9"
        case .ratio9x16, .vertical: "9:16"
        case .ratio1x1: "1:1"
        case .ratio4x3: "4:3"
        case .ratio3x4: "3:4"
        }
    }

    /// 画幅 → 视频 size（OpenAI 规范 /v1/videos）
    var videoSize: String {
        switch self {
        case .ratio16x9, .horizontal: "1280x720"
        case .ratio9x16, .vertical: "720x1280"
        case .ratio1x1: "1024x1024"
        case .ratio4x3: "1024x768"
        case .ratio3x4: "768x1024"
        case .adaptive: "1280x720"
        }
    }

    /// 画幅 → (width, height)（New API `v1/video/generations` 的独立宽高字段，如 16:9 → 1280×720）
    var videoDimensions: (width: Int, height: Int) {
        let parts = videoSize.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return (1280, 720) }
        return (parts[0], parts[1])
    }

    /// **画幅 + 分辨率 → (width, height)**（2026-09-19 修：New API 链路原来只按画幅写死尺寸，
    /// 用户选 1080P 发出去的还是 720×1280）。
    ///
    /// 基准 = `videoDimensions`（720P 档的尺寸表），按分辨率档的短边比例缩放：
    /// 480P → 2/3、720P → 1、768P → 16/15、1080P → 1.5、4K → 3。
    /// 结果取**偶数**（视频编码器要求；奇数宽高容易被上游拒）。
    func videoDimensions(for resolution: Resolution) -> (width: Int, height: Int) {
        let base = videoDimensions
        let scale: Double
        switch resolution {
        case .p480: scale = 480.0 / 720.0
        case .p720: scale = 1
        case .p768: scale = 768.0 / 720.0
        case .p1080: scale = 1080.0 / 720.0
        case .p4k: scale = 2160.0 / 720.0
        }
        return (Self.even(Double(base.width) * scale), Self.even(Double(base.height) * scale))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
}

/// 递归 JSON 值 —— 响应结构未文档化，全树扫描找状态/直链
enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法识别的 JSON 值")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// 按路径取字符串（如 ["task_id"]）
    func string(at path: [String]) -> String? {
        var node = self
        for key in path {
            guard case .object(let dict) = node, let next = dict[key] else { return nil }
            node = next
        }
        if case .string(let value) = node { return value }
        return nil
    }

    /// 递归查找视频直链：优先 http(s) 且扩展名为视频格式的链接，否则键名含 url/video 等片段的 http(s) 链接
    func findVideoURL() -> URL? {
        var strings: [(key: String, value: String)] = []
        collectStrings(from: self, key: "", into: &strings)

        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        let preferredKeys = ["url", "video", "download", "result", "content"]

        for (_, value) in strings {
            if let url = Self.httpURL(value), videoExtensions.contains(url.pathExtension.lowercased()) {
                return url
            }
        }
        for (key, value) in strings {
            let lower = key.lowercased()
            if preferredKeys.contains(where: { lower.contains($0) }),
               let url = Self.httpURL(value) { return url }
        }
        return nil
    }

    private static func httpURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func collectStrings(from node: JSONValue, key: String, into result: inout [(key: String, value: String)]) {
        switch node {
        case .string(let value):
            result.append((key, value))
        case .array(let items):
            for (index, item) in items.enumerated() {
                collectStrings(from: item, key: key.isEmpty ? "[\(index)]" : key, into: &result)
            }
        case .object(let dict):
            for (k, v) in dict {
                collectStrings(from: v, key: k, into: &result)
            }
        default:
            break
        }
    }
}
