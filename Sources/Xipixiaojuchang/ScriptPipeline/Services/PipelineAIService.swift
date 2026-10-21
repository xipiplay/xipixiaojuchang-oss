import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PipelineAIError: LocalizedError, Equatable {
    case notConfigured
    case invalidURL(String)
    case httpError(Int, String)
    case emptyResponse
    case noChoices
    case emptyContent(reasoningChars: Int, finish: String)
    /// 回复被截断（服务商返回的结束原因是 length / max_tokens）：内容不完整，不能当结果用
    case truncated(chars: Int)
    case invalidResult(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 AI 接口（请在设置中填写 baseURL、API Key 与模型名称）。"
        case .invalidURL(let url):
            return "AI 接口地址无效：\(url)"
        case .httpError(let code, let body):
            // 504 / 524 是服务商的网关等不及断开的（不是软件的超时）：思考型模型一次回答想太久最容易碰到
            let hint = [504, 524].contains(code)
                ? "（服务商的网关等了约 5 分钟没等到回答就断开了，多半是模型思考太久。到「设置 → 剧本流水线」把「思考强度」调低，或换成 flash 之类更快的模型）"
                : ""
            return "HTTP \(code)：\(body.prefix(300))\(hint)"
        case .emptyResponse:
            return "AI 响应为空。"
        case .noChoices:
            return "AI 响应中未包含有效 choices 内容。"
        case .emptyContent(let chars, let finish):
            return "模型思考占满输出额度（思考 \(chars) 字，结束原因=\(finish)），正文为空。建议稍后重试或切换为非推理模型（如 deepseek-chat）。"
        case .truncated(let chars):
            return "AI 的回复被截断了（达到了单次输出上限，只收到 \(chars) 字），这次结果不完整，没有使用。请换一个单次输出上限更大的模型，或少选几集分次处理。"
        case .invalidResult(let reason):
            return "AI 结果无法解析：\(reason)"
        }
    }
}

enum PipelineAIService: Sendable {
    /// 文字接口专用的网络会话。系统默认同一个服务器最多 6 个连接（HTTP/1.1 的服务商就只能同时跑 6 路，其余的排队，
    /// 排队也算在超时里）；HTTP/2 的服务商不受这个限制，但换到老式的中转站就会被偷偷限住。
    /// 生图 / 生视频那套（`APIClient`）早就调到 100；这里留够批量分割（10）+ 提取素材（3 类 × 3）+ 推理分镜（1）同时跑的量
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 24
        return URLSession(configuration: configuration)
    }()

    static func endpoint(for config: PipelineAISettings) throws -> URL {
        var base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let value = base.hasSuffix("/chat/completions")
            ? base
            : base + (base.hasSuffix("/v1") ? "/chat/completions" : "/v1/chat/completions")
        guard let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else {
            throw PipelineAIError.invalidURL(config.baseURL)
        }
        return url
    }

    /// 设置里填了「思考强度」就随请求发 `reasoning_effort`；留空不发（用模型自己的默认）
    static func applyReasoningEffort(to body: inout [String: Any], config: PipelineAISettings) {
        if let effort = config.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
    }

    /// 发起单轮对话，获取 AI 回复正文。
    /// `onProgress`：流式接收时，大约每 0.25 秒报一次进度（思考 / 输出了多少字、最近的内容）；不流式就不报。
    /// 是 async 的：调用方在主线程上更新界面，等它做完再收下一批，进度的先后次序不会乱
    static func chat(
        config: PipelineAISettings,
        system: String,
        user: String,
        session: URLSession = PipelineAIService.defaultSession,
        timeout: TimeInterval = 300,
        onProgress: (@Sendable (AIStreamProgress) async -> Void)? = nil
    ) async throws -> String {
        // 外部智能体接力：不调 API，放进收件目录等智能体回答（所有文字类 AI 步骤都从这里过）
        if config.usesAgent { return try await AgentBridge.shared.ask(system: system, user: user) }
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineAIError.notConfigured
        }

        let url = try endpoint(for: config)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": 0.7,
            // 顶格配置防止推理模型思考挤占正文输出空间
            "max_tokens": 393216
        ]
        applyReasoningEffort(to: &body, config: config)
        if config.usesStreaming {
            body["stream"] = true
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try await streamedChat(req, session: session, onProgress: onProgress)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PipelineAIError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw PipelineAIError.httpError(http.statusCode, bodyStr)
        }
        return try parseWholeReply(data)
    }

    /// 流式：一行一行读，攒出完整回答。服务商忽略了 `stream`、返回一整份 JSON 时，照普通回答解析（所以不会因为开了流式反而坏掉）。
    /// `timeoutInterval` 在这里是「多久没收到任何数据」：数据一直在流（包括思考的内容），就不会超时
    private static func streamedChat(_ req: URLRequest, session: URLSession,
                                     onProgress: (@Sendable (AIStreamProgress) async -> Void)?) async throws -> String {
        await onProgress?(AIStreamProgress())                               // 请求发出去了：先报一次「等待中」，计时从这里开始
        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw PipelineAIError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 20_000 { break }                           // 错误页够看了，别一直读
            }
            throw PipelineAIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        var accumulator = AIStreamAccumulator()
        var lastReport = Date.distantPast
        var lastPhase = AIStreamProgress.Phase.waiting
        for try await line in bytes.lines {
            try accumulator.feed(line: line)
            guard let onProgress else { continue }
            let progress = accumulator.progress
            if progress.phase != lastPhase || Date().timeIntervalSince(lastReport) >= AIStreamProgress.reportInterval {
                lastReport = Date()
                lastPhase = progress.phase
                await onProgress(progress)
            }
        }
        await onProgress?(accumulator.progress)

        if let plain = accumulator.plainBody { return try parseWholeReply(plain) }
        return try finish(content: accumulator.content, reasoningChars: accumulator.reasoningChars, finish: accumulator.finishReason)
    }

    /// 一整份 JSON 回答（不流式，或服务商忽略了流式）→ 正文
    private static func parseWholeReply(_ data: Data) throws -> String {
        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    var content: String?
                    var reasoning_content: String?
                }
                var message: Message?
                var finish_reason: String?
            }
            var choices: [Choice]
        }

        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = parsed.choices.first else {
            throw PipelineAIError.noChoices
        }
        return try finish(content: choice.message?.content ?? "", reasoningChars: choice.message?.reasoning_content?.count ?? 0,
                          finish: choice.finish_reason)
    }

    /// 收完整份回答之后的核对（流式和不流式共用）：正文是空的 / 被截断了，都不能当结果用
    private static func finish(content raw: String, reasoningChars: Int, finish: String?) throws -> String {
        let content = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            if reasoningChars > 0 { throw PipelineAIError.emptyContent(reasoningChars: reasoningChars, finish: finish ?? "?") }
            throw PipelineAIError.emptyResponse
        }
        // 被截断的回复也是「有内容」——不挡的话，最后一张卡 / 最后一段会以残缺的样子当成完整结果存下来，没有任何提示
        if let finish = finish?.lowercased(), finish == "length" || finish == "max_tokens" {
            throw PipelineAIError.truncated(chars: content.count)
        }
        return content
    }

    private static func imageContent(_ url: URL) throws -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url),
              data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let mime = UTType(identifier as String)?.preferredMIMEType,
              ["image/png", "image/jpeg", "image/webp"].contains(mime) else {
            throw PipelineAIError.invalidResult("场景图不可读取或格式不支持，请选择 PNG/JPEG/WebP（20MB以内），也可人工填写布局")
        }
        return [["type": "image_url", "image_url": ["url": "data:\(mime);base64," + data.base64EncodedString()]]]
    }

    /// 发起视觉多模态分析，提取场景空间布局
    static func vision(
        config: PipelineAISettings,
        imageURL: URL,
        session: URLSession = .shared,
        system: String = LayoutRules.visionSystem,
        context: String = "读取这张场景基图的可见布局，按约定 JSON 输出。"
    ) async throws -> String {
        // 外部智能体接力：图片以路径交给智能体（它自己能读图），不再塞 base64
        if config.usesAgent { return try await AgentBridge.shared.ask(system: system, user: context, images: [imageURL.path]) }
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineAIError.notConfigured
        }

        let userContent: [[String: Any]] = [["type": "text", "text": context]] + (try imageContent(imageURL))

        let url = try endpoint(for: config)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent]
            ],
            "temperature": 0.7,
            "max_tokens": 393216
        ]
        applyReasoningEffort(to: &body, config: config)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw PipelineAIError.emptyResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw PipelineAIError.httpError(http.statusCode, bodyStr)
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    var content: String?
                    var reasoning_content: String?
                }
                var message: Message?
                var finish_reason: String?
            }
            var choices: [Choice]
        }

        guard let parsed = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let choice = parsed.choices.first else {
            throw PipelineAIError.noChoices
        }

        let content = choice.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if content.isEmpty {
            let reasoning = choice.message?.reasoning_content ?? ""
            if !reasoning.isEmpty {
                throw PipelineAIError.emptyContent(reasoningChars: reasoning.count, finish: choice.finish_reason ?? "?")
            }
            throw PipelineAIError.emptyResponse
        }
        // 被截断的回复也是「有内容」——不挡的话，最后一张卡 / 最后一段会以残缺的样子当成完整结果存下来，没有任何提示
        if let finish = choice.finish_reason?.lowercased(), finish == "length" || finish == "max_tokens" {
            throw PipelineAIError.truncated(chars: content.count)
        }
        return content
    }

    /// 从原始模型回复中截取 JSON 结构（兼容 Markdown 代码块与包裹解释）
    static func extractJSON(_ raw: String) -> String {
        guard let start = raw.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return raw }
        let close: Character = raw[start] == "[" ? "]" : "}"
        guard let end = raw.lastIndex(of: close), start <= end else { return raw }
        return String(raw[start...end])
    }

    /// 解析分集 JSON，若解析失败保底包成单集
    static func parseEpisodes(from raw: String) -> (episodes: [Episode], isFallback: Bool) {
        struct Item: Decodable {
            var title: String?
            var text: String?
        }

        let json = extractJSON(raw)
        if let data = json.data(using: .utf8),
           let items = try? JSONDecoder().decode([Item].self, from: data),
           !items.isEmpty {
            let parsed = items.enumerated().map { index, item in
                let title = (item.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "第 \(index + 1) 集"
                let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Episode(title: title, text: text)
            }
            return (parsed, false)
        }

        // 保底：整段装入第 1 集
        return ([Episode(title: "第 1 集", text: raw.trimmingCharacters(in: .whitespacesAndNewlines))], true)
    }

    // MARK: - 清单扫描（分批）

    /// 按单批字符上限（默认 18000 字）将剧集切分为批次索引列表
    static func makeBatches(episodes: [Episode], maxChars: Int = 18000) -> [[Int]] {
        var out: [[Int]] = []
        var cur: [Int] = []
        var chars = 0
        for i in episodes.indices {
            let c = episodes[i].text.count
            if !cur.isEmpty, chars + c > maxChars {
                out.append(cur)
                cur = []
                chars = 0
            }
            cur.append(i)
            chars += c
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// 规范化条目首次出场集号
    static func firstEpisode(existing: Int?, reported: Int?, batch: ClosedRange<Int>) -> Int {
        let candidate = min(batch.upperBound, max(batch.lowerBound, reported ?? batch.lowerBound))
        return min(existing ?? candidate, candidate)
    }

    /// 将现有词典转为用于提示词上下文的名单摘要，避免重复提取
    static func rosterContext(for dictionary: [DictEntry]) -> String {
        guard !dictionary.isEmpty else { return "（空）" }
        var lines: [String] = []
        for kind in ["角色", "场景", "道具"] {
            let names = dictionary.filter { $0.kind == kind }.map(\.name)
            if !names.isEmpty {
                lines.append("- \(kind)：" + names.joined(separator: "、"))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 合并 AI 返回的清单 JSON 到现有词典中
    static func mergeRoster(raw: String, existing: inout [DictEntry], defaultFirstEp: Int, lastEp: Int) -> Bool {
        struct Item: Decodable {
            var kind: String
            var name: String
            var firstEp: Int?
        }
        let json = extractJSON(raw)
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return false
        }
        for it in items {
            let name = it.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard ["角色", "场景", "道具"].contains(it.kind) else { continue }
            if let idx = existing.firstIndex(where: { $0.name == name && $0.kind == it.kind }) {
                existing[idx].fromEp = firstEpisode(existing: existing[idx].fromEp, reported: it.firstEp, batch: defaultFirstEp...lastEp)
            } else {
                let first = firstEpisode(existing: nil, reported: it.firstEp, batch: defaultFirstEp...lastEp)
                existing.append(DictEntry(kind: it.kind, name: name, desc: "", fromEp: first, toEp: nil))
            }
        }
        return true
    }

    // MARK: - 词典上下文与本集描述

    // MARK: - 分镜与名字校验标记解析

}
