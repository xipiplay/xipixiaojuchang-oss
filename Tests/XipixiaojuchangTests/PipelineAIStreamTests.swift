import XCTest
import Observation
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 流式接收（2026-10-11）：边生成边收，抽屉里实时看到思考和输出；数据一直在流，网关不会因为等太久断开（504）
final class PipelineAIStreamTests: XCTestCase {
    // MARK: 逐行解析

    private func chunk(content: String? = nil, reasoning: String? = nil, reasoningKey: String = "reasoning_content", finish: String? = nil) -> String {
        var delta: [String] = []
        if let content { delta.append("\"content\":\(json(content))") }
        if let reasoning { delta.append("\"\(reasoningKey)\":\(json(reasoning))") }
        let finishPart = finish.map { ",\"finish_reason\":\"\($0)\"" } ?? ""
        return "data: {\"choices\":[{\"delta\":{\(delta.joined(separator: ","))}\(finishPart)}]}"
    }
    private func json(_ text: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self).dropFirst().dropLast().description
    }

    func testTheAccumulatorSeparatesThinkingFromTheAnswerAndCountsBoth() throws {
        var acc = AIStreamAccumulator()
        XCTAssertEqual(acc.progress.phase, .waiting)
        try acc.feed(line: chunk(reasoning: "先想一想，"))
        XCTAssertEqual(acc.progress.phase, .thinking)
        try acc.feed(line: ": keep-alive")                                   // SSE 注释
        try acc.feed(line: "event: message")
        try acc.feed(line: chunk(reasoning: "再想一想。", reasoningKey: "reasoning"))     // 另一家叫 reasoning
        try acc.feed(line: chunk(content: "第一段"))
        try acc.feed(line: "data:" + String(chunk(content: "，第二段", finish: "stop").dropFirst(5)))     // data: 后面没空格也要认
        try acc.feed(line: "data: [DONE]")
        XCTAssertEqual(acc.content, "第一段，第二段")
        XCTAssertEqual(acc.progress.phase, .writing)
        XCTAssertEqual(acc.progress.reasoningChars, 10)
        XCTAssertEqual(acc.progress.contentChars, 7)
        XCTAssertEqual(acc.progress.reasoningTail, "先想一想，再想一想。")
        XCTAssertEqual(acc.finishReason, "stop")
        XCTAssertTrue(acc.done && acc.sawStreamEvent)
    }

    func testEventsWithoutChoicesOrWithNullContentAreIgnored() throws {
        var acc = AIStreamAccumulator()
        try acc.feed(line: #"data: {"choices":[],"usage":{"total_tokens":9}}"#)
        try acc.feed(line: #"data: {"choices":[{"delta":{"role":"assistant","content":null}}]}"#)
        try acc.feed(line: "data: 这不是 JSON")
        try acc.feed(line: "")
        XCTAssertEqual(acc.content, "")
        XCTAssertEqual(acc.progress.phase, .waiting)
    }

    func testTheTailKeepsOnlyTheLatestText() throws {
        var acc = AIStreamAccumulator()
        for index in 0..<40 { try acc.feed(line: chunk(reasoning: String(repeating: "想", count: 500) + "\(index)。")) }
        XCTAssertGreaterThan(acc.progress.reasoningChars, 20_000)
        XCTAssertLessThanOrEqual(acc.progress.reasoningTail.count, AIStreamProgress.tailLimit)
        XCTAssertTrue(acc.progress.reasoningTail.hasSuffix("39。"), "留的是最后一段")
    }

    func testAnErrorInTheMiddleOfTheStreamIsReported() {
        var acc = AIStreamAccumulator()
        XCTAssertThrowsError(try acc.feed(line: #"data: {"error":{"message":"rate limit"}}"#)) {
            XCTAssertTrue($0.localizedDescription.contains("rate limit") && $0.localizedDescription.contains("中途"), $0.localizedDescription)
        }
    }

    func testAPlainJsonBodyIsKeptForTheFallback() throws {
        var acc = AIStreamAccumulator()
        for line in ["{", #"  "choices": [{"message": {"content": "整份回答"}}]"#, "}"] { try acc.feed(line: line) }
        XCTAssertFalse(acc.sawStreamEvent)
        let body = try XCTUnwrap(acc.plainBody)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("整份回答"))
        var streamed = AIStreamAccumulator()
        try streamed.feed(line: chunk(content: "x"))
        XCTAssertNil(streamed.plainBody, "真在流式返回的，不走这条")
    }

    // MARK: 经过 URLSession

    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var chunks: [String] = []
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var contentType = "text/event-stream"
        nonisolated(unsafe) static var lastBody = [String: Any]()
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                Self.lastBody = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.contentType])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for piece in Self.chunks { client?.urlProtocol(self, didLoad: Data(piece.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private actor Collected { var items: [AIStreamProgress] = []; func add(_ p: AIStreamProgress) { items.append(p) } }

    private func run(chunks: [String], status: Int = 200, contentType: String = "text/event-stream",
                     streaming: Bool? = nil, effort: String? = nil, collect: Collected? = nil) async throws -> String {
        Stub.chunks = chunks; Stub.status = status; Stub.contentType = contentType
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        var config = PipelineAISettings(baseURL: "https://example.test", apiKey: "k", model: "m")
        config.streaming = streaming
        config.reasoningEffort = effort
        var report: (@Sendable (AIStreamProgress) async -> Void)?
        if let collect { report = { @Sendable progress in await collect.add(progress) } }
        return try await PipelineAIService.chat(config: config, system: "s", user: "u", session: URLSession(configuration: configuration),
                                                onProgress: report)
    }

    func testAStreamedReplyIsAssembledEvenWhenAChunkEndsInTheMiddleOfALine() async throws {
        let lines = [chunk(reasoning: "想"), chunk(content: "你好，"), chunk(content: "世界", finish: "stop"), "data: [DONE]"].joined(separator: "\n\n") + "\n\n"
        let cut = lines.index(lines.startIndex, offsetBy: 37)               // 故意切在一行的中间
        let seen = Collected()
        let reply = try await run(chunks: [String(lines[..<cut]), String(lines[cut...])], collect: seen)
        XCTAssertEqual(reply, "你好，世界")
        XCTAssertEqual(Stub.lastBody["stream"] as? Bool, true, "请求里要带 stream: true")
        let progress = await seen.items
        XCTAssertEqual(progress.first?.phase, .waiting, "先报一次「等待中」")
        XCTAssertEqual(progress.last?.contentChars, 5)
        XCTAssertEqual(progress.last?.reasoningChars, 1)
        XCTAssertEqual(progress.last?.phase, .writing)
    }

    /// 一口气来了几百个数据块：抽屉里的进度只在「换阶段」和「隔了一秒」时报，不是每个块都报
    func testProgressIsReportedOnPhaseChangesAndAtMostOncePerInterval() async throws {
        var lines = (0..<300).map { chunk(reasoning: "想\($0)，") }
        lines += (0..<300).map { chunk(content: "写\($0)，") }
        lines += [chunk(content: "。", finish: "stop"), "data: [DONE]"]
        let seen = Collected()
        let reply = try await run(chunks: [lines.joined(separator: "\n\n") + "\n\n"], collect: seen)
        XCTAssertTrue(reply.hasSuffix("写299，。"))
        let progress = await seen.items
        XCTAssertEqual(progress.map(\.phase).filter { $0 == .waiting }.count, 1)
        XCTAssertLessThanOrEqual(progress.count, 6, "几百个块只该报几次：等待 / 开始思考 / 开始输出 / 收尾，实际 \(progress.count) 次")
        XCTAssertEqual(progress.first(where: { $0.phase == .thinking })?.reasoningChars, 3, "换阶段马上报，不等那一秒")
        XCTAssertEqual(progress.last?.contentChars, reply.count, "最后一次是收完时的完整数字")
    }

    func testTheReasoningEffortAndTheStreamFlagGoTogether() async throws {
        _ = try await run(chunks: [chunk(content: "ok", finish: "stop") + "\n\ndata: [DONE]\n\n"], effort: "low")
        XCTAssertEqual(Stub.lastBody["reasoning_effort"] as? String, "low")
        XCTAssertEqual(Stub.lastBody["stream"] as? Bool, true)
    }

    func testTurningStreamingOffSendsAPlainRequestAndReportsNoProgress() async throws {
        let seen = Collected()
        let reply = try await run(chunks: [#"{"choices":[{"message":{"content":"整份"},"finish_reason":"stop"}]}"#],
                                  contentType: "application/json", streaming: false, collect: seen)
        XCTAssertEqual(reply, "整份")
        XCTAssertNil(Stub.lastBody["stream"])
        let progress = await seen.items
        XCTAssertTrue(progress.isEmpty)
    }

    func testAServerThatIgnoresStreamAndReturnsOneJsonStillWorks() async throws {
        let body = "{\n  \"choices\": [{\"message\": {\"content\": \"忽略了流式\"}, \"finish_reason\": \"stop\"}]\n}"
        let reply = try await run(chunks: [body], contentType: "application/json")
        XCTAssertEqual(reply, "忽略了流式")
    }

    func testATruncatedOrEmptyStreamedReplyIsRefusedLikeBefore() async {
        do {
            _ = try await run(chunks: [chunk(content: "半截", finish: "length") + "\n\n"])
            XCTFail("length 该当作被截断")
        } catch let error as PipelineAIError { XCTAssertEqual(error, .truncated(chars: 2)) } catch { XCTFail("\(error)") }
        do {
            _ = try await run(chunks: [chunk(reasoning: "想了很多", finish: "length") + "\n\n"])
            XCTFail("正文是空的该报错")
        } catch let error as PipelineAIError { XCTAssertEqual(error, .emptyContent(reasoningChars: 4, finish: "length")) } catch { XCTFail("\(error)") }
        do {
            _ = try await run(chunks: ["data: [DONE]\n\n"])
            XCTFail("什么都没收到该报错")
        } catch let error as PipelineAIError { XCTAssertEqual(error, .emptyResponse) } catch { XCTFail("\(error)") }
    }

    func testAnHttpErrorKeepsItsBodyAndTheGatewayTimeoutHint() async {
        do {
            _ = try await run(chunks: ["<html>Gateway Time-out</html>"], status: 504, contentType: "text/html")
            XCTFail("504 该报错")
        } catch let error as PipelineAIError {
            XCTAssertEqual(error, .httpError(504, "<html>Gateway Time-out</html>"))
            XCTAssertTrue(error.localizedDescription.contains("思考强度"))
        } catch { XCTFail("\(error)") }
    }
}

/// 流式进度进任务抽屉（2026-10-11）
@MainActor
final class AIStreamJobCenterTests: XCTestCase {
    private func progress(_ phase: AIStreamProgress.Phase, thinking: Int = 0, writing: Int = 0) -> AIStreamProgress {
        AIStreamProgress(phase: phase, reasoningChars: thinking, contentChars: writing,
                         reasoningTail: String(repeating: "想", count: thinking), contentTail: String(repeating: "写", count: writing))
    }

    func testProgressIsKeptPerRequestSummedAndClearedWhenTheTaskEnds() {
        let app = AppModel()
        let id = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "提取角色")
        defer { app.jobCenter.removeRecord(id: id) }
        XCTAssertNil(app.jobCenter.streamSummary(for: id))

        let a = UUID(), b = UUID()
        app.jobCenter.aiStream(id, request: a, progress: progress(.waiting))
        XCTAssertEqual(app.jobCenter.streamSummary(for: id)?.statusText, "已发出请求，等待回答")
        app.jobCenter.aiStream(id, request: a, progress: progress(.thinking, thinking: 3200))
        XCTAssertEqual(app.jobCenter.streamSummary(for: id)?.statusText, "思考中 · 已想 3200 字")
        app.jobCenter.aiStream(id, request: a, progress: progress(.writing, thinking: 3200, writing: 800))
        XCTAssertEqual(app.jobCenter.streamSummary(for: id)?.statusText, "输出中 · 已写 800 字（想了 3200 字）")

        // 同一个任务里再来一个请求（提取素材分批并发）：汇总
        app.jobCenter.aiStream(id, request: b, progress: progress(.thinking, thinking: 100))
        let several = app.jobCenter.streamSummary(for: id)
        XCTAssertEqual(several?.requests, 2)
        XCTAssertEqual(several?.thinking, 1); XCTAssertEqual(several?.writing, 1)
        XCTAssertEqual(several?.reasoningChars, 3300); XCTAssertEqual(several?.contentChars, 800)
        XCTAssertTrue(several?.statusText.contains("2 个请求同时进行") == true, several?.statusText ?? "")

        app.jobCenter.aiStreamEnded(id, request: a)
        XCTAssertEqual(app.jobCenter.streamSummary(for: id)?.requests, 1)
        app.jobCenter.aiFinished(id, state: .completed, note: nil)
        XCTAssertNil(app.jobCenter.streamSummary(for: id), "任务结束，这一块就没有了")
    }

    func testAFinishedTaskIgnoresLateProgressAndNothingIsSavedToDisk() throws {
        let app = AppModel()
        let id = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "时长分割")
        defer { app.jobCenter.removeRecord(id: id) }
        app.jobCenter.aiFinished(id, state: .stopped, note: "已停止")
        app.jobCenter.aiStream(id, request: UUID(), progress: progress(.thinking, thinking: 10))
        XCTAssertNil(app.jobCenter.streamSummary(for: id), "晚到的进度不能把刚清掉的又写回来")

        let running = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "时长分割")
        defer { app.jobCenter.removeRecord(id: running) }
        app.jobCenter.aiStream(running, request: UUID(), progress: progress(.writing, thinking: 5000, writing: 5000))
        let saved = try JSONEncoder().encode(app.jobCenter.records)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("想想想"), "思考内容只在内存里，不存进任务记录")
    }

    private final class SlowStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"data: {"choices":[{"delta":{"reasoning_content":"先想一想"}}]}"#.utf8) + Data("\n\n".utf8))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                self.client?.urlProtocol(self, didLoad: Data(#"data: {"choices":[{"delta":{"content":"答案"},"finish_reason":"stop"}]}"#.utf8) + Data("\n\ndata: [DONE]\n\n".utf8))
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() {}
    }

    /// 从「请求属于哪个任务」到抽屉里的进度，整条链：任务里发请求 → 中途能看到「思考中」→ 收完这一块消失、结果照常返回
    func testTheWholeChainShowsThinkingWhileTheRequestIsRunningAndClearsItAfterwards() async throws {
        let app = AppModel()
        let id = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "时长分割")
        defer { app.jobCenter.removeRecord(id: id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowStub.self]
        let chat = SimplePipeline.chat(config: PipelineAISettings(baseURL: "https://example.test", apiKey: "k", model: "m"),
                                       session: URLSession(configuration: configuration))
        let context = AgentRequestContext(project: "p", title: "时长分割", aiRecordID: id)
        let task = Task { @MainActor in try await AgentRequestContext.$current.withValue(context) { try await chat("s", "u") } }

        var seen: AIStreamProgress.Phase?
        for _ in 0..<40 {                                              // 最多等 4 秒，等到「思考中」
            try await Task.sleep(for: .milliseconds(100))
            if let phase = app.jobCenter.streamSummary(for: id)?.latest.phase, phase == .thinking { seen = phase; break }
        }
        XCTAssertEqual(seen, .thinking, "请求还没收完时，抽屉里就该看到「思考中」")
        XCTAssertEqual(app.jobCenter.streamSummary(for: id)?.reasoningChars, 4)

        let reply = try await task.value
        XCTAssertEqual(reply, "答案")
        XCTAssertNil(app.jobCenter.streamSummary(for: id), "收完了，这一块消失")
    }

    /// 同时有好几个任务在流式接收：一个任务的进度变了，只有它那一行被通知重画，别的行不动
    func testOneTasksProgressOnlyInvalidatesItsOwnRow() throws {
        let app = AppModel()
        let first = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "时长分割")
        let second = app.jobCenter.aiStarted(projectKey: "p", episodeID: nil, title: "时长分割")
        defer { app.jobCenter.removeRecord(id: first); app.jobCenter.removeRecord(id: second) }
        let a = UUID(), b = UUID()
        app.jobCenter.aiStream(first, request: a, progress: progress(.waiting))
        app.jobCenter.aiStream(second, request: b, progress: progress(.waiting))

        nonisolated(unsafe) var firstRowRedrawn = false
        withObservationTracking { _ = app.jobCenter.streamSummary(for: first) } onChange: { firstRowRedrawn = true }

        app.jobCenter.aiStream(second, request: b, progress: progress(.thinking, thinking: 500))
        XCTAssertFalse(firstRowRedrawn, "别的任务有新进度，这一行不该重画")
        app.jobCenter.aiStream(first, request: a, progress: progress(.thinking, thinking: 100))
        XCTAssertTrue(firstRowRedrawn, "它自己有新进度，要重画")
    }

    func testStreamingIsOnByDefaultAndOldSavedConfigsStillLoad() throws {
        XCTAssertTrue(PipelineAISettings().usesStreaming)
        var config = PipelineAISettings(baseURL: "https://x.test", apiKey: "k", model: "m"); config.streaming = false
        XCTAssertFalse(config.usesStreaming)
        let old = #"{"baseURL":"https://x.test","apiKey":"k","model":"m"}"#
        let decoded = try JSONDecoder().decode(PipelineAISettings.self, from: Data(old.utf8))
        XCTAssertNil(decoded.streaming)
        XCTAssertTrue(decoded.usesStreaming, "旧配置里没有这个键：流式")
        XCTAssertEqual(try config.validated().streaming, false, "关掉的选择存得住")
    }
}

final class AIStreamTextLayoutTests: XCTestCase {
    private func summary(requests: Int, thinking: Int, writing: Int, phase: AIStreamProgress.Phase) -> JobCenter.AIStreamSummary {
        JobCenter.AIStreamSummary(requests: requests, waiting: 0, thinking: phase == .thinking ? requests : 0, writing: phase == .writing ? requests : 0,
                                  reasoningChars: thinking, contentChars: writing, startedAt: Date().addingTimeInterval(-3725),
                                  latest: AIStreamProgress(phase: phase, reasoningChars: thinking, contentChars: writing))
    }

    /// 抽屉大约 260 宽：数字从几位涨到六位、用时从几秒涨到一个多小时，这两行的高度必须不变（用户：数字一长列表就跳）
    @MainActor
    private func height(_ summary: JobCenter.AIStreamSummary) -> CGFloat {
        let view = NSHostingView(rootView: AIStreamStatus(summary: summary, expanded: false) {}.frame(width: 260).environment(AppModel()))
        return view.fittingSize.height
    }

    @MainActor
    func testTheStatusRowsKeepTheirHeightWhileTheNumbersGrow() {
        for phase in [AIStreamProgress.Phase.thinking, .writing] {
            let small = height(summary(requests: 1, thinking: 12, writing: phase == .writing ? 5 : 0, phase: phase))
            let large = height(summary(requests: 1, thinking: 123_456, writing: phase == .writing ? 98_765 : 0, phase: phase))
            XCTAssertEqual(small, large, accuracy: 0.5, "单路 \(phase)：数字变长，行高不该变")
        }
        let few = height(summary(requests: 5, thinking: 12, writing: 5, phase: .thinking))
        let many = height(summary(requests: 5, thinking: 1_234_567, writing: 987_654, phase: .writing))
        XCTAssertEqual(few, many, accuracy: 0.5, "几路同时进行：数字变长，行高不该变")
        XCTAssertGreaterThan(few, height(summary(requests: 1, thinking: 12, writing: 0, phase: .thinking)), "几路同时：第二行固定留两行")
    }

    func testTheHeadlineAndDetailSplitTheOldSentence() {
        let single = JobCenter.AIStreamSummary(requests: 1, waiting: 0, thinking: 1, writing: 0, reasoningChars: 3200, contentChars: 0,
                                               startedAt: Date(), latest: AIStreamProgress(phase: .thinking, reasoningChars: 3200))
        XCTAssertEqual(single.headline, "思考中")
        XCTAssertEqual(single.detail, "已想 3200 字")
        let several = JobCenter.AIStreamSummary(requests: 3, waiting: 0, thinking: 2, writing: 1, reasoningChars: 900, contentChars: 40,
                                                startedAt: Date(), latest: AIStreamProgress(phase: .thinking))
        XCTAssertEqual(several.headline, "3 个请求同时进行")
        XCTAssertEqual(several.detail, "思考 2 · 输出 1 · 已想 900 字、已写 40 字")
    }

    func testShortTextIsShownDirectlyAndLongTextScrolls() {
        XCTAssertTrue(AIStreamText.fitsWithoutScrolling("场景：客厅 日 内\n张三：你来了。"))
        XCTAssertFalse(AIStreamText.fitsWithoutScrolling(String(repeating: "想", count: 400)), "字多：滚动")
        XCTAssertFalse(AIStreamText.fitsWithoutScrolling((1...12).map { "第\($0)行" }.joined(separator: "\n")), "行多：滚动")
    }
}
