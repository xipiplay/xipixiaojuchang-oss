import Foundation

/// 流式接收（2026-10-11）：软件直接调接口时，边生成边收，而不是等整份回答写完才一次性收到。
/// 好处：任务抽屉里能实时看到「思考中 / 输出中、已写多少字」，点开能看内容；数据一直在流，服务商的网关也不会因为等太久断开（504）。
///
/// 服务商按 SSE 返回：每个事件一行 `data: {json}`，最后一行 `data: [DONE]`；每个 json 里 `choices[0].delta` 有这一小段的
/// `content`（正文）和 `reasoning_content` / `reasoning`（思考，各家叫法不一样），最后一个事件带 `finish_reason`。
struct AIStreamProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// 请求发出去了，还没收到任何内容
        case waiting
        case thinking
        case writing
    }

    var phase: Phase = .waiting
    var reasoningChars = 0
    var contentChars = 0
    /// 最近的一段思考 / 正文（只留结尾，免得一份几万字的思考一直占着内存、一直往界面里塞）
    var reasoningTail = ""
    var contentTail = ""

    static let tailLimit = 6000
    /// 抽屉里的进度最多隔多久刷新一次（换阶段——开始思考、开始输出——不受限，马上报）。
    /// 原来 0.25 秒一次：10 路同时流式时每秒 40 次整张表刷新，每次所有进行中的行都跟着重画，滑动列表就卡
    static let reportInterval: TimeInterval = 1.0
}

/// 把流式返回的行一行一行喂进来，攒出完整的回答
struct AIStreamAccumulator {
    private(set) var content = ""
    private(set) var reasoningChars = 0
    private(set) var contentChars = 0
    private(set) var finishReason: String?
    /// 收到过 `data:` 行：说明服务商真的在流式返回。没有的话（有的中转站忽略了 stream 参数，返回一整份 JSON），
    /// 看 `plainBody`
    private(set) var sawStreamEvent = false
    private(set) var done = false
    private var reasoningTail = ""
    private var contentTail = ""
    /// 尾巴现在有多少字：边收边记。`String.count` 要把整段从头数一遍，一个数据块数两遍、10 路同时思考就是每秒上百万个字
    private var reasoningTailCount = 0
    private var contentTailCount = 0
    private var plainLines: [String] = []

    var progress: AIStreamProgress {
        let phase: AIStreamProgress.Phase = contentChars > 0 ? .writing : (reasoningChars > 0 ? .thinking : .waiting)
        return AIStreamProgress(phase: phase, reasoningChars: reasoningChars, contentChars: contentChars,
                                reasoningTail: Self.tail(reasoningTail, count: reasoningTailCount), contentTail: Self.tail(contentTail, count: contentTailCount))
    }

    /// 没有任何 `data:` 行时，收到的整份文字（当作一份普通的 JSON 回答去解析）
    var plainBody: Data? {
        guard !sawStreamEvent, !plainLines.isEmpty else { return nil }
        return Data(plainLines.joined(separator: "\n").utf8)
    }

    mutating func feed(line raw: String) throws {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if line.hasPrefix(":") { return }                                         // SSE 注释（保活）
        if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") { return }
        guard line.hasPrefix("data:") else {
            plainLines.append(raw)                                                // 不是 SSE：可能是整份 JSON 的一行
            return
        }
        sawStreamEvent = true
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { done = true; return }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // 服务商在回答中途报错：`data: {"error": {...}}`
        if let error = object["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? String(describing: error)
            throw PipelineAIError.invalidResult("服务商在回答中途返回了错误：\(message.prefix(300))")
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first else { return }    // 有的事件只带 usage，choices 是空的
        if let delta = choice["delta"] as? [String: Any] {
            if let piece = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String, !piece.isEmpty {
                reasoningChars += piece.count
                reasoningTail += piece
                reasoningTailCount += piece.count
            }
            if let piece = delta["content"] as? String, !piece.isEmpty {
                content += piece
                contentChars += piece.count
                contentTail += piece
                contentTailCount += piece.count
            }
        }
        if let finish = choice["finish_reason"] as? String, !finish.isEmpty { finishReason = finish }
        // 尾巴只留最后一段：超过两倍上限才裁一次（每次都裁会一直重排字符串）
        if reasoningTailCount > AIStreamProgress.tailLimit * 2 {
            reasoningTail = Self.tail(reasoningTail, count: reasoningTailCount)
            reasoningTailCount = AIStreamProgress.tailLimit
        }
        if contentTailCount > AIStreamProgress.tailLimit * 2 {
            contentTail = Self.tail(contentTail, count: contentTailCount)
            contentTailCount = AIStreamProgress.tailLimit
        }
    }

    private static func tail(_ text: String, count: Int) -> String {
        count > AIStreamProgress.tailLimit ? String(text.suffix(AIStreamProgress.tailLimit)) : text
    }
}
