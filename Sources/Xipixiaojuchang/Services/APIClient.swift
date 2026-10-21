import Foundation

let apiJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

let apiJSONDecoder = JSONDecoder()

enum APIError: LocalizedError, Sendable {
    case http(status: Int, body: String)
    case transport(String)
    case noTaskID
    case rejected(String)
    case invalidContent
    /// 本地配置缺失 / 前置条件不满足（如未配 OSS）。**原样展示**，不加「网络错误」等误导前缀。
    case config(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let detail = body.isEmpty ? "" : "：\(body.prefix(300))"
            return "请求失败（HTTP \(status)）\(detail)"
        case .transport(let message): return "网络错误：\(message)"
        case .noTaskID: return "平台未返回任务 ID"
        case .rejected(let message): return "提交被拒绝：\(message)"
        case .invalidContent: return "未能从结果中找到视频链接"
        case .config(let message): return message
        }
    }
}

/// 统一视频 API 客户端：按渠道的 `apiFormat` 路由到内置接入规范。
struct APIClient: Sendable {
    let channel: ModelChannel

    init(channel: ModelChannel) { self.channel = channel }

    // MARK: 提交

    func submit(_ request: VideoGenerationRequest) async throws -> String {
        switch channel.apiFormat {
        case .openAI: return try await submitOpenAI(request)
        case .newAPI: return try await submitNewAPI(request)
        }
    }

    // MARK: 提交 —— OpenAI 规范

    private func submitOpenAI(_ request: VideoGenerationRequest) async throws -> String {
        // 先把文件读出来（本地优先，远程下载成临时数据），再拼 multipart body
        var files: [MultipartFile] = []
        if let first = request.firstFrame {
            files.append(try await loadFile(field: "first_frame", input: first))
        }
        if let last = request.lastFrame {
            files.append(try await loadFile(field: "last_frame", input: last))
        }
        for image in request.referenceImages {
            files.append(try await loadFile(field: "image[]", input: image))
        }

        let boundary = "----XipixiBoundary\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        func appendField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        appendField("model", request.model)
        if let prompt = request.prompt, !prompt.isEmpty { appendField("prompt", prompt) }
        appendField("seconds", String(request.duration))
        appendField("size", request.size)
        appendField("resolution_name", request.resolutionName)
        appendField("generate_audio", request.generateAudio ? "true" : "false")
        appendField("watermark", request.watermark ? "true" : "false")
        if let mode = request.mode { appendField("mode", mode) }
        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")

        var urlRequest = URLRequest(url: try url(path: "v1/videos"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(channel.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        AppLog.write("submit", "渠道=\(channel.name) 模型=\(request.model) mode=\(request.mode ?? "-") 文件=\(files.count)")
        let response = try await perform(urlRequest)
        let raw = try apiJSONDecoder.decode(JSONValue.self, from: response)
        if let id = raw.string(at: ["id"])
            ?? raw.string(at: ["task_id"])
            ?? raw.string(at: ["data", "id"])
            ?? raw.string(at: ["data", "task_id"]) {
            return id
        }
        throw APIError.noTaskID
    }

    // MARK: 提交 —— New API 通用视频（JSON、任务制）

    /// New API 规范提交：`POST {base}/v1/video/generations`（JSON）。
    ///
    /// 提交体字段取自 New API 文档：`model` / `prompt` / `image` / `images` / `reference_images` /
    /// `duration` / `width` / `height` / `metadata`。参考图**必须是公网直链**（OSS），
    /// 由 `AppModel` 在组装阶段上传。
    ///
    /// 参考图**三种字段全带**（不同上游校验器认的字段不同，实机验证）：
    /// - `images`：**全部**参考图 URL 数组（manxue-2.5 上游只认这个：缺它报 `contains 0 images`）；
    /// - `reference_images`：同上（部分上游认这个）；
    /// - `image`：第一张（兼容只认单图 `image` 的路径）。
    /// 数组顺序 = 首帧、尾帧、参考图。
    private func submitNewAPI(_ request: VideoGenerationRequest) async throws -> String {
        struct Metadata: Encodable {
            let watermark: Bool
            let generateAudio: Bool
            enum CodingKeys: String, CodingKey {
                case watermark
                case generateAudio = "generate_audio"
            }
        }
        struct Body: Encodable {
            let model: String
            let prompt: String?
            let image: String?
            let images: [String]
            let referenceImages: [String]
            let duration: Int
            let width: Int
            let height: Int
            let metadata: Metadata
            /// 比例（2026-09-19 加：有的上游要 `aspect_ratio: "9:16"`，
            /// 不发它就用自己的默认 16:9 —— 实测"选了 9:16 出片是 1280x720"）
            let aspectRatio: String
            /// 时长（**字符串**形式）：同一家上游要 `seconds: "30"`；和 `duration` 并存，
            /// 哪家不收哪个就被自适应重试去掉
            let seconds: String
            /// 上游明确说"不该存在"的字段（键 = JSON 名）。见提交处的自适应重试。
            var drop: Set<String> = []

            enum CodingKeys: String, CodingKey {
                case model, prompt, image, images
                case referenceImages = "reference_images"
                case duration, width, height, metadata
                case aspectRatio = "aspect_ratio"
                case seconds
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(model, forKey: .model)
                if let prompt, !prompt.isEmpty { try c.encode(prompt, forKey: .prompt) }
                if !drop.contains(CodingKeys.image.rawValue), let image, !image.isEmpty { try c.encode(image, forKey: .image) }
                if !drop.contains(CodingKeys.images.rawValue), !images.isEmpty { try c.encode(images, forKey: .images) }
                if !drop.contains(CodingKeys.referenceImages.rawValue), !referenceImages.isEmpty { try c.encode(referenceImages, forKey: .referenceImages) }
                if !drop.contains(CodingKeys.duration.rawValue) { try c.encode(duration, forKey: .duration) }
                if !drop.contains(CodingKeys.width.rawValue) { try c.encode(width, forKey: .width) }
                if !drop.contains(CodingKeys.height.rawValue) { try c.encode(height, forKey: .height) }
                if !drop.contains(CodingKeys.metadata.rawValue) { try c.encode(metadata, forKey: .metadata) }
                if !drop.contains(CodingKeys.aspectRatio.rawValue) { try c.encode(aspectRatio, forKey: .aspectRatio) }
                if !drop.contains(CodingKeys.seconds.rawValue) { try c.encode(seconds, forKey: .seconds) }
            }
        }

        // 所有参考图走 OSS 直链：顺序 = 首帧、尾帧、参考图；
        // `images` / `reference_images` 带全部，`image` 取第一张兼容单图路径。
        let imageInputs = [request.firstFrame, request.lastFrame].compactMap { $0 } + request.referenceImages
        let imageURLs = try imageInputs.map { try remoteURL(for: $0, label: "参考图") }
        // ⚠️ 尺寸要**跟着分辨率档走**（2026-09-19 修）：原来只按画幅写死（9:16 永远 720×1280），
        // 用户选 1080P 发出去的还是 720p。现在 1080P → 1080×1920、4K → 2160×3840。
        let resolution = Resolution.allCases.first { $0.apiValue == request.resolutionName } ?? .p720
        let dimensions = request.aspectRatio.videoDimensions(for: resolution)
        // ⚠️ **`image`（单图字段）只在"首尾帧"模式发**（2026-09-19 修，用户实测反馈）：
        // 参考图模式也发它的话，上游会优先认这个单图字段、把**第一张参考图当首帧** →
        // 整条走成"图生视频"（现象：画面从那张图长出来、衣服/场景对，但 8 张角色参考图
        // 只被弱参考 → **角色脸不锁定**）。参考图模式现在只发 `images` + `reference_images`，
        // 让上游走"参考生视频"。
        let isFramesMode = request.mode == "frames"
        // ⚠️ **seed 系模型只发 `images`**（2026-09-19 二修）：原来 `images` + `reference_images`
        // 各带全部（实测 body 里每张参考出现两遍）。先试了"只发 reference_images"——
        // 上游直接 400：`missing_reference_attachments: prompt declares reference index 8
        // but request contains 0 images` —— **实锤它只数 `images`**（提示词里的"图N"就是按
        // `images` 下标对应的）。所以 seed 系只发 `images`（顺序 = 图1、图2…，必须和提示词一致），
        // `reference_images` 不发（避免重复）。其它模型保持两个都发（有的上游认 reference_images）。
        let seedModel = request.model.lowercased().hasPrefix("seed")
        // 提示词引用语法（2026-09-26）：渠道要求 @image1 时把「图N」换掉
        let promptText: String? = channel.useAtImageSyntax
            ? Self.atImagePrompt(request.prompt ?? "",
                                 imageCount: imageURLs.count,
                                 videoCount: request.referenceVideos.filter { !$0.isEmpty }.count,
                                 audioCount: request.referenceAudios.filter { !$0.isEmpty }.count)
            : request.prompt
        let body = Body(
            model: request.model,
            prompt: promptText,
            image: isFramesMode ? imageURLs.first : nil,
            images: imageURLs,
            referenceImages: seedModel ? [] : imageURLs,
            duration: request.duration,
            width: dimensions.width,
            height: dimensions.height,
            metadata: Metadata(watermark: request.watermark, generateAudio: request.generateAudio),
            aspectRatio: request.aspectRatio.ratioValue,
            seconds: String(request.duration)
        )

        var urlRequest = URLRequest(url: try url(path: "v1/video/generations"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(channel.apiKey)", forHTTPHeaderField: "Authorization")

        // **自适应提交（2026-09-19）**：不同中转的上游校验严格程度不一样 —— 有的实测直接回
        // `property height should not exist, property reference_images should not exist,
        // property width should not exist`。这类 400 不会产生任务、不会重复扣费，
        // 所以按报错把那些字段去掉再试一次，免得每次都手动改代码。
        // ⚠️ `image`/`images` 是参考素材本身，**不允许被去掉**（去掉就等于静默丢了参考图），
        // 上游要是连它们都不收，就把原始错误抛给用户。
        let droppable: Set<String> = ["width", "height", "duration", "metadata", "reference_images", "aspect_ratio", "seconds"]
        var dropped: Set<String> = []
        for attempt in 0..<2 {
            var attemptBody = body
            attemptBody.drop = dropped
            let data = try apiJSONEncoder.encode(attemptBody)
            urlRequest.httpBody = data
            AppLog.write("submit", "渠道=\(channel.name)[New API] 模型=\(request.model) 参考图=\(imageURLs.count)\(dropped.isEmpty ? "" : " 已去掉字段=\(dropped.sorted())") body=\(String(data: data, encoding: .utf8) ?? "<binary>")")
            do {
                let response = try await perform(urlRequest)
                let raw = try apiJSONDecoder.decode(JSONValue.self, from: response)
                if let id = raw.string(at: ["task_id"])
                    ?? raw.string(at: ["id"])
                    ?? raw.string(at: ["data", "task_id"])
                    ?? raw.string(at: ["data", "id"]) {
                    return id
                }
                throw APIError.noTaskID
            } catch let APIError.http(status, text) where status == 400 {
                let rejected = Self.rejectedPropertyNames(in: text)
                let fresh = rejected.intersection(droppable).subtracting(dropped)
                guard attempt == 0, !fresh.isEmpty else { throw APIError.http(status: status, body: text) }
                dropped.formUnion(fresh)
                AppLog.write("submit", "上游不接受字段 \(fresh.sorted()) → 去掉后重试一次")
            }
        }
        throw APIError.noTaskID
    }

    /// 把提示词里的「图N / 视频N / 音频N」换成「@imageN / @videoN / @audioN」。
    ///
    /// 只在渠道打开了 `useAtImageSyntax` 时调用 —— 有些上游要求
    /// **按上传顺序**用 `@image1` 引用素材，而我们的提示词习惯写「图1」。
    ///
    /// 只换**实际存在的槽位**（N ≤ 各自素材数），避免误伤提示词里真在说"第 2 张图"的句子；
    /// 从大到小替换，防止「图1」命中「图10」的前两位。
    static func atImagePrompt(_ prompt: String, imageCount: Int, videoCount: Int, audioCount: Int) -> String {
        var out = prompt
        for (token, at, count) in [("图", "@image", imageCount), ("视频", "@video", videoCount), ("音频", "@audio", audioCount)] {
            guard count > 0 else { continue }
            for i in stride(from: count, through: 1, by: -1) {
                out = out.replacingOccurrences(of: "\(token)\(i)", with: "\(at)\(i)")
            }
        }
        return out
    }

    /// 从上游的校验错误里抽出"不该存在的字段名"（形如 `property width should not exist`）
    private static func rejectedPropertyNames(in text: String) -> Set<String> {
        var names: Set<String> = []
        guard let regex = try? NSRegularExpression(pattern: "property ([A-Za-z_][A-Za-z0-9_]*) should not exist") else { return names }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: ns) {
            if let range = Range(match.range(at: 1), in: text) {
                names.insert(String(text[range]))
            }
        }
        return names
    }

    /// 参考素材只接受公网可拉取的 URL；本地文件 / 未上传的素材必须给出清晰错误。
    private func remoteURL(for input: VideoFileInput, label: String) throws -> String {
        if let remote = input.remoteURL, !remote.isEmpty { return remote }
        throw APIError.transport("\(label)需要先上传（缺远程 URL）")
    }

    /// 单个文件：本地文件直接读；否则远程 URL 先下载成数据。
    private func loadFile(field: String, input: VideoFileInput) async throws -> MultipartFile {
        if let localPath = input.localPath, let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
            let name = input.fileName.isEmpty ? URL(fileURLWithPath: localPath).lastPathComponent : input.fileName
            return MultipartFile(field: field, filename: name, mimeType: Self.mimeType(for: name), data: data)
        }
        if let remoteURL = input.remoteURL, let url = URL(string: remoteURL) {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let name = input.fileName.isEmpty ? url.lastPathComponent : input.fileName
                return MultipartFile(field: field, filename: name, mimeType: Self.mimeType(for: name), data: data)
            } catch {
                throw APIError.transport("参考素材下载失败：\(remoteURL)")
            }
        }
        throw APIError.transport("参考素材不可用：\(input.fileName.isEmpty ? field : input.fileName)")
    }

    private struct MultipartFile {
        let field: String
        let filename: String
        let mimeType: String
        let data: Data
    }

    private static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp4", "m4v": return "video/mp4"
        default: return "image/png"
        }
    }

    // MARK: 轮询 / 内容

    func status(of taskID: String) async throws -> VideoStatusResponse {
        let data: Data
        switch channel.apiFormat {
        case .openAI:
            data = try await request(path: "v1/videos/\(taskID)", method: "GET")
        case .newAPI:
            // New API 任务查询：GET /v1/video/generations/{task_id}
            // （中转常返回 `{code,data}` 包装 + 大写状态，见 VideoStatusResponse 的宽容解析）
            data = try await request(path: "v1/video/generations/\(taskID)", method: "GET")
        }
        // 带 `error` 的返回记完整（最多 8000 字）：失败时 `status` 常排在长提示词后面，截到 600 字就看不到了
        let text = String(data: data, encoding: .utf8)
        let limit = text?.contains("\"error\"") == true ? 8000 : 600
        AppLog.write("status", "task=\(taskID) resp=\(text?.prefix(limit) ?? "<binary>")")
        return try VideoStatusResponse(data: data)
    }

    /// 完成状态没有直链时的回落：内容端点直接返回视频二进制。
    /// New API 没有独立内容端点（完成直链就在任务查询响应里），
    /// 直接报「找不到链接」让轮询层收尾。
    func downloadContent(of taskID: String) async throws -> Data {
        if channel.apiFormat != .openAI { throw APIError.invalidContent }
        let data = try await request(path: "v1/videos/\(taskID)/content", method: "GET")
        guard data.count > 1024 else { throw APIError.transport("内容端点返回为空") }
        return data
    }

    private func request(path: String, method: String) async throws -> Data {
        try await request(url: try url(path: path), method: method)
    }

    private func request(url: URL, method: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(channel.apiKey)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    /// 拼接请求地址：若 baseURL 路径已含 path 的首段（如已带 /v1），避免重复拼接出 /v1/v1
    ///
    /// ⚠️ 查询串**不能塞进 path**：`appendingPathComponent` 会把 `?` 转义成 `%3F`
    /// （状态轮询就踩过这个坑）。要用 `query:` 参数。
    private func url(path: String, query: String? = nil) throws -> URL {
        guard let base = URL(string: channel.baseURL) else { throw APIError.transport("渠道地址无效：\(channel.baseURL)") }
        let basePath = base.path
        let resolved: URL
        if let firstSegment = path.split(separator: "/").first, !firstSegment.isEmpty,
           basePath.hasSuffix("/" + firstSegment) {
            let rest = path.split(separator: "/").dropFirst().joined(separator: "/")
            resolved = base.appendingPathComponent(rest)
        } else {
            resolved = base.appendingPathComponent(path)
        }
        guard let query, !query.isEmpty,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return resolved }
        components.percentEncodedQuery = query
        guard let withQuery = components.url else { throw APIError.transport("渠道地址无效：\(channel.baseURL)") }
        return withQuery
    }

    /// 测试用：换成带桩的会话，看真正发出去的请求体（nil = 正常的会话）
    nonisolated(unsafe) static var testSession: URLSession?

    /// 视频请求会话：同域名并发连接上限 100（默认 6，批量提交会排队挂起）
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 100
        return URLSession(configuration: config)
    }()

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await (Self.testSession ?? Self.session).data(for: request) }
        catch { throw APIError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("非 HTTP 响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
