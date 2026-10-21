import Foundation

/// 生图结果：中转可能直接给 URL，也可能给 b64（已落盘为本地文件）。
enum ImageGenOutput: Sendable, Equatable {
    case url(URL)
    case localFile(String)
}

/// OpenAI 兼容图片生成服务（覆盖绝大多数中转站）。
enum ImageGenService {
    struct Request: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let size: String
        let quality: String
        let response_format: String
    }

    struct Response: Decodable {
        struct DataItem: Decodable {
            let url: String?
            let b64_json: String?
        }
        let data: [DataItem]
    }

    /// 提交一次生图请求，返回结果列表（b64 响应会解码存盘为本地文件）。
    ///
    /// `referenceImagePaths` 为空 → `/v1/images/generations`（纯文生图，JSON）；
    /// 非空 → `/v1/images/edits`（图生图，multipart：单张 `image`、多张 `image[]`）。
    /// 两个端点响应结构一致，解析共用。
    static func generate(channel: ModelChannel,
                         modelName: String,
                         prompt: String,
                         size: String,
                         quality: String,
                         count: Int = 1,
                         referenceImagePaths: [String] = []) async throws -> [ImageGenOutput] {
        let data: Data
        if referenceImagePaths.isEmpty {
            data = try await postJSON(channel: channel, modelName: modelName, prompt: prompt,
                                      size: size, quality: quality, count: count)
        } else {
            data = try await postEdits(channel: channel, modelName: modelName, prompt: prompt,
                                       size: size, quality: quality, count: count,
                                       imagePaths: referenceImagePaths)
        }

        AppLog.write("imagegen", "resp=\(String(data: data, encoding: .utf8)?.prefix(500) ?? "<binary>")")
        let response = try apiJSONDecoder.decode(Response.self, from: data)
        return try response.data.map { item in
            // b64 优先（不依赖临时直链），没有再取 url
            if let b64 = item.b64_json, let path = saveBase64(b64) {
                return .localFile(path)
            }
            if let urlString = item.url, let url = URL(string: urlString) {
                return .url(url)
            }
            throw APIError.invalidContent
        }
    }

    /// 纯文生图（JSON）
    private static func postJSON(channel: ModelChannel, modelName: String, prompt: String,
                                 size: String, quality: String, count: Int) async throws -> Data {
        let url = try makeURL(channel: channel)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(channel.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try apiJSONEncoder.encode(Request(
            model: modelName,
            prompt: prompt,
            n: count,
            size: size,
            quality: quality,
            response_format: "b64_json"
        ))
        AppLog.write("imagegen", "渠道=\(channel.name) 模型=\(modelName) size=\(size) quality=\(quality) 参考图=0 prompt=\(String(prompt.prefix(80)))")
        return try await perform(urlRequest)
    }

    /// 图生图：参考图以 multipart 上传。单张字段名 `image`，多张重复 `image[]`。
    private static func postEdits(channel: ModelChannel,
                                  modelName: String,
                                  prompt: String,
                                  size: String,
                                  quality: String,
                                  count: Int,
                                  imagePaths: [String]) async throws -> Data {
        let url = try makeEditURL(channel: channel)
        let boundary = "----XipixiBoundary\(UUID().uuidString)"

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        func appendField(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }

        let fieldName = imagePaths.count == 1 ? "image" : "image[]"
        for path in imagePaths {
            let fileURL = URL(fileURLWithPath: path)
            guard let fileData = try? Data(contentsOf: fileURL) else {
                // 不静默跳过：用户以为挂了参考图、实际没传上去，比直接报错更难查
                throw APIError.transport("参考图读取失败：\((path as NSString).lastPathComponent)")
            }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
            append("Content-Type: \(mimeType(for: fileURL.pathExtension))\r\n\r\n")
            body.append(fileData)
            append("\r\n")
        }

        appendField("model", modelName)
        appendField("prompt", prompt)
        appendField("size", size)
        appendField("quality", quality)
        appendField("n", String(count))
        appendField("response_format", "b64_json")
        append("--\(boundary)--\r\n")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(channel.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body
        AppLog.write("imagegen", "渠道=\(channel.name) 模型=\(modelName) size=\(size) quality=\(quality) 参考图=\(imagePaths.count) prompt=\(String(prompt.prefix(80)))")
        return try await perform(urlRequest)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }

    private static func makeURL(channel: ModelChannel) throws -> URL {
        guard let base = URL(string: channel.baseURL) else {
            throw APIError.transport("渠道地址无效：\(channel.baseURL)")
        }
        // 地址已含 /v1 则直接追加，否则补上，避免出现 /v1/v1 重复路径
        if base.path.hasSuffix("/v1") {
            return base.appendingPathComponent("images/generations")
        }
        return base.appendingPathComponent("v1/images/generations")
    }

    /// 图生图端点（同 `makeURL` 的 /v1 去重规则）
    private static func makeEditURL(channel: ModelChannel) throws -> URL {
        guard let base = URL(string: channel.baseURL) else {
            throw APIError.transport("渠道地址无效：\(channel.baseURL)")
        }
        if base.path.hasSuffix("/v1") {
            return base.appendingPathComponent("images/edits")
        }
        return base.appendingPathComponent("v1/images/edits")
    }

    private static func saveBase64(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }
        try? FileLocations.ensureDirectories()
        let name = "img-\(UUID().uuidString).png"
        let url = FileLocations.appSupport.appendingPathComponent("Images", isDirectory: true).appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    /// 带超时的会话：正常生图 35~50 秒；中转站对重复提示词会挂起不返回，90 秒兜底快速失败；
    /// 同域名并发连接上限提到 100，避免批量提交在客户端排队
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // ⚠️ 90 → 300（2026-09-18 用户实测）：带 3 张参考图的请求跑了 90+ 秒还没回，
        // 中转站其实**已经生成成功**，是这边先超时放弃了 ✗。放宽到 5 分钟。
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 100
        return URLSession(configuration: config)
    }()

    private static func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // 超时单独提示：图片可能已在中转站生成完成（自动重试会重复扣费）
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                throw APIError.transport("生成超时——图片可能已在中转站生成完成，请到后台确认或稍后重试")
            }
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(status: http.statusCode, body: body)
        }
        return data
    }
}
