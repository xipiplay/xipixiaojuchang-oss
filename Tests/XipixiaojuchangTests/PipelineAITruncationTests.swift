import XCTest
@testable import Xipixiaojuchang

/// 回复被截断（结束原因 length / max_tokens）不能当结果用（2026-10-09）：
/// 原来只检查「回复是不是空的」，截断的半截回复照样收下，最后一张卡 / 最后一段会以残缺的样子存下来，没有任何提示。
final class PipelineAITruncationTests: XCTestCase {
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = ""
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func ask(finish: String?, content: String) async throws -> String {
        let finishPart = finish.map { ",\"finish_reason\":\"\($0)\"" } ?? ""
        Stub.body = "{\"choices\":[{\"message\":{\"content\":\"\(content)\"}\(finishPart)}]}"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        let config = PipelineAISettings(baseURL: "https://example.test", apiKey: "k", model: "m")
        return try await PipelineAIService.chat(config: config, system: "s", user: "u", session: URLSession(configuration: configuration))
    }

    func testACompleteReplyIsReturned() async throws {
        let stopped = try await ask(finish: "stop", content: "完整回复")
        XCTAssertEqual(stopped, "完整回复")
        let unknown = try await ask(finish: nil, content: "没带结束原因的服务商")
        XCTAssertEqual(unknown, "没带结束原因的服务商")
    }

    func testATruncatedReplyIsAnErrorEvenThoughItHasContent() async {
        for finish in ["length", "max_tokens", "LENGTH"] {
            do {
                _ = try await ask(finish: finish, content: "半截回复")
                XCTFail("\(finish) 该当作被截断")
            } catch let error as PipelineAIError {
                XCTAssertEqual(error, .truncated(chars: 4))
                XCTAssertTrue(error.localizedDescription.contains("被截断"))
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    /// 2026-10-11：会思考的模型（GLM-5.3 默认思考到最深）一集分割要五分钟以上，原来默认 300 秒，一到点就被软件掐断报「请求超时」
    func testThePipelineWaitsFifteenMinutesForAReply() {
        XCTAssertEqual(SimplePipeline.requestTimeout, 900)
    }

    // MARK: 思考强度（2026-10-11）

    func testTheReasoningEffortIsSentOnlyWhenFilledIn() {
        var body: [String: Any] = ["model": "m"]
        PipelineAIService.applyReasoningEffort(to: &body, config: PipelineAISettings(baseURL: "https://x.test", apiKey: "k", model: "m"))
        XCTAssertNil(body["reasoning_effort"], "留空不发")
        var config = PipelineAISettings(baseURL: "https://x.test", apiKey: "k", model: "m")
        config.reasoningEffort = "  low "
        PipelineAIService.applyReasoningEffort(to: &body, config: config)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        config.reasoningEffort = "   "
        var blank: [String: Any] = [:]
        PipelineAIService.applyReasoningEffort(to: &blank, config: config)
        XCTAssertNil(blank["reasoning_effort"], "只有空格也不发")
    }

    func testTheSavedConfigStillLoadsWithoutTheNewKeyAndTheEffortIsTrimmedOnSave() throws {
        let old = #"{"baseURL":"https://x.test","apiKey":"k","model":"m"}"#
        let decoded = try JSONDecoder().decode(PipelineAISettings.self, from: Data(old.utf8))
        XCTAssertNil(decoded.reasoningEffort, "旧的已保存配置里没有这个键，要能读出来")
        var config = decoded
        config.reasoningEffort = " high "
        XCTAssertEqual(try config.validated().reasoningEffort, "high")
        config.reasoningEffort = "  "
        XCTAssertNil(try config.validated().reasoningEffort, "空白存成没填")
    }

    func testA504SaysTheGatewayGaveUpAndPointsAtTheThinkingStrength() {
        let message = PipelineAIError.httpError(504, "").localizedDescription
        XCTAssertTrue(message.hasPrefix("HTTP 504："))
        XCTAssertTrue(message.contains("思考强度"))
        XCTAssertFalse(PipelineAIError.httpError(500, "x").localizedDescription.contains("思考强度"), "别的错误不带这句")
    }
}
