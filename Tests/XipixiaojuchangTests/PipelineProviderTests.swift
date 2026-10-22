import XCTest
@testable import Xipixiaojuchang

/// 剧本流水线的文字服务商（2026-10-11）：一排卡片，选模型 / 思考强度，不手输
@MainActor
final class PipelineProviderTests: XCTestCase {
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "PipelineProviderTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    private func nvidia() -> PipelineProvider {
        PipelineProvider(name: "NVIDIA", baseURL: "https://integrate.api.nvidia.com/v1", apiKey: "nvapi-test", model: "z-ai/glm-5.3",
                         reasoningEffort: "low", streaming: nil)
    }

    // MARK: 合成各处在用的那一份配置

    func testTheActiveProviderBecomesTheConfigEveryoneReads() {
        var other = nvidia(); other.name = "DeepSeek"; other.baseURL = "https://api.deepseek.com"; other.model = "deepseek-chat"; other.reasoningEffort = nil
        var book = PipelineProviderBook(providers: [nvidia(), other], activeID: other.id, agentMode: nil)
        XCTAssertEqual(book.resolved.model, "deepseek-chat")
        XCTAssertEqual(book.resolved.baseURL, "https://api.deepseek.com")
        XCTAssertNil(book.resolved.reasoningEffort)
        book.activeID = book.providers[0].id
        XCTAssertEqual(book.resolved.model, "z-ai/glm-5.3")
        XCTAssertEqual(book.resolved.reasoningEffort, "low")
        book.activeID = UUID()                                        // 指向已经删掉的：用第一个
        XCTAssertEqual(book.active?.name, "NVIDIA")
    }

    func testTheRelaySwitchIsIndependentOfWhichProviderIsActive() {
        let book = PipelineProviderBook(providers: [nvidia()], activeID: nil, agentMode: true)
        XCTAssertTrue(book.resolved.usesAgent)
        XCTAssertEqual(book.resolved.model, "z-ai/glm-5.3", "接力开着时服务商的内容原样留着，关掉接力就回来")
    }

    func testWithNoProviderNothingIsConfiguredAndTheValidationSaysSo() {
        let config = PipelineProviderBook().resolved
        XCTAssertEqual(config.apiKey, "")
        XCTAssertThrowsError(try config.validated())
    }

    // MARK: 存取与迁移

    func testTheSingleConfigYouAlreadyHaveBecomesTheFirstCard() throws {
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        var config = PipelineAISettings(baseURL: "https://integrate.api.nvidia.com/v1", apiKey: "nvapi-test", model: "z-ai/glm-5.3")
        config.reasoningEffort = "low"; config.agentMode = true
        try PipelineAISettingsStore.save(config, defaults: defaults)

        let (book, error) = PipelineProviderStore.load(defaults: defaults)
        XCTAssertNil(error)
        XCTAssertEqual(book.providers.count, 1)
        XCTAssertEqual(book.providers[0].name, "integrate.api.nvidia.com", "名字取地址的域名")
        XCTAssertEqual(book.providers[0].model, "z-ai/glm-5.3")
        XCTAssertEqual(book.providers[0].reasoningEffort, "low")
        XCTAssertEqual(book.activeID, book.providers[0].id)
        XCTAssertEqual(book.agentMode, true)
        XCTAssertNil(defaults.data(forKey: PipelineProviderStore.defaultsKey), "读的时候不写：用户点保存才落盘")
    }

    func testAnUntouchedInstallStartsWithNoCards() {
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PipelineProviderStore.load(defaults: defaults).book.providers.count, 0)
    }

    func testSavingTheListMakesTheActiveProviderTheConfigAndKeepsTheOldKeyInSync() throws {
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let book = PipelineProviderBook(providers: [nvidia()], activeID: nil, agentMode: nil)
        try PipelineProviderStore.save(book, defaults: defaults)

        let loaded = PipelineAISettingsStore.load(defaults: defaults)
        XCTAssertEqual(loaded.config.model, "z-ai/glm-5.3")
        XCTAssertEqual(loaded.config.reasoningEffort, "low")
        XCTAssertEqual(PipelineProviderStore.load(defaults: defaults).book, book)
        let mirrored = try JSONDecoder().decode(PipelineAISettings.self, from: try XCTUnwrap(defaults.data(forKey: PipelineAISettingsStore.defaultsKey)))
        XCTAssertEqual(mirrored.baseURL, "https://integrate.api.nvidia.com/v1", "老的单份配置也同步了一份")
    }

    func testAHalfFilledActiveProviderDoesNotOverwriteTheLastGoodSingleConfig() throws {
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        try PipelineAISettingsStore.save(PipelineAISettings(baseURL: "https://old.example", apiKey: "k", model: "m"), defaults: defaults)
        let half = PipelineProvider(name: "新服务商", baseURL: "https://new.example", apiKey: "k", model: "")      // 还没选模型
        try PipelineProviderStore.save(PipelineProviderBook(providers: [half], activeID: half.id), defaults: defaults)
        let mirrored = try JSONDecoder().decode(PipelineAISettings.self, from: try XCTUnwrap(defaults.data(forKey: PipelineAISettingsStore.defaultsKey)))
        XCTAssertEqual(mirrored.baseURL, "https://old.example", "没配全的不写进去")
        XCTAssertEqual(PipelineAISettingsStore.load(defaults: defaults).config.model, "", "但读配置时以列表为准：这家还没选模型")
    }

    func testAnUnreadableListIsReportedAndNotOverwrittenByReading() {
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let junk = Data("不是 JSON".utf8)
        defaults.set(junk, forKey: PipelineProviderStore.defaultsKey)
        XCTAssertNotNil(PipelineProviderStore.load(defaults: defaults).error)
        XCTAssertNotNil(PipelineAISettingsStore.load(defaults: defaults).error)
        XCTAssertEqual(defaults.data(forKey: PipelineProviderStore.defaultsKey), junk)
    }

    func testOldSavedProvidersWithoutNewFieldsStillLoad() throws {
        let json = #"{"providers":[{"id":"\#(UUID().uuidString)","name":"A","baseURL":"https://a.example","apiKey":"k","model":"m"}]}"#
        let book = try JSONDecoder().decode(PipelineProviderBook.self, from: Data(json.utf8))
        XCTAssertNil(book.providers[0].reasoningEffort)
        XCTAssertNil(book.providers[0].fetchedModels)
        XCTAssertNil(book.agentMode)
    }

    // MARK: 思考强度下拉

    /// 2026-10-11：用户在 NVIDIA 的 GLM-5.3 上选了「中」，NVIDIA 不报错、当没选、按默认最高想了十万多字
    func testGlmModelsOnlyOfferTheLevelsTheirDocsListAndWarnAboutOthers() {
        XCTAssertEqual(ReasoningEffortOption.levels(forModel: "z-ai/glm-5.3-flash").map(\.value), ["", "low", "high", "max"], "没有 medium")
        XCTAssertEqual(ReasoningEffortOption.levels(forModel: "Z-AI/GLM-5.3").map(\.value), ["", "low", "high", "max"], "不分大小写")
        XCTAssertEqual(ReasoningEffortOption.levels(forModel: "deepseek-ai/deepseek-v4.1-flash").map(\.value), ["", "low", "medium", "high", "max"], "不认识的模型给常见几档")
        // 已经存着的 medium 还在下拉里，但标明这个模型不认
        let options = ReasoningEffortOption.options(forModel: "z-ai/glm-5.3-flash", including: "medium")
        XCTAssertEqual(options.last?.value, "medium")
        XCTAssertTrue(options.last?.label.contains("这个模型不认") == true, options.last?.label ?? "")
        // 提醒
        let warning = ReasoningEffortOption.warning(forModel: "z-ai/glm-5.3-flash", value: "medium")
        XCTAssertTrue(warning?.contains("低 / 高 / 最高") == true && warning?.contains("不会报错") == true && warning?.contains("最高") == true, warning ?? "")
        XCTAssertNil(ReasoningEffortOption.warning(forModel: "z-ai/glm-5.3-flash", value: "low"))
        XCTAssertNil(ReasoningEffortOption.warning(forModel: "z-ai/glm-5.3-flash", value: nil), "没选不用提醒")
        XCTAssertNil(ReasoningEffortOption.warning(forModel: "gpt-x", value: "medium"), "别的模型不提醒")
    }

    func testTheEffortDropdownHasTheCommonLevelsAndKeepsAValueSavedByHand() {
        XCTAssertEqual(ReasoningEffortOption.standard.map(\.value), ["", "low", "medium", "high", "max"])
        XCTAssertEqual(ReasoningEffortOption.options(including: "low").count, 5)
        XCTAssertEqual(ReasoningEffortOption.options(including: nil).count, 5)
        let custom = ReasoningEffortOption.options(including: "xhigh")
        XCTAssertEqual(custom.last?.value, "xhigh", "以前手输过的值不能一打开设置就丢了")
        XCTAssertEqual(ReasoningEffortOption.label(for: "high"), "高")
        XCTAssertEqual(ReasoningEffortOption.label(for: nil), "默认（不发）")
        XCTAssertEqual(ReasoningEffortOption.label(for: "xhigh"), "xhigh（自定义）")
    }
}

/// 获取模型：向服务商要 `/v1/models`
final class ModelListServiceTests: XCTestCase {
    func testTheListAddressIsBuiltFromWhateverFormTheAddressIsWrittenIn() throws {
        for (base, expected) in [("https://integrate.api.nvidia.com/v1", "https://integrate.api.nvidia.com/v1/models"),
                                 ("https://integrate.api.nvidia.com/v1/", "https://integrate.api.nvidia.com/v1/models"),
                                 ("https://api.deepseek.com", "https://api.deepseek.com/v1/models"),
                                 ("https://x.test/v1/chat/completions", "https://x.test/v1/models"),
                                 ("https://x.test/v1/models", "https://x.test/v1/models"),
                                 (" https://x.test ", "https://x.test/v1/models")] {
            XCTAssertEqual(try ModelListService.endpoint(for: base).absoluteString, expected, base)
        }
        XCTAssertThrowsError(try ModelListService.endpoint(for: "没有协议"))
        XCTAssertThrowsError(try ModelListService.endpoint(for: "file:///tmp/x"))
    }

    func testModelNamesAreReadFromTheCommonShapesDedupedAndSorted() {
        let openAI = Data(#"{"object":"list","data":[{"id":"z-ai/glm-5.3","object":"model"},{"id":"deepseek-ai/deepseek-v4.1-flash"},{"id":"z-ai/glm-5.3"},{"id":""}]}"#.utf8)
        XCTAssertEqual(ModelListService.parse(openAI), ["deepseek-ai/deepseek-v4.1-flash", "z-ai/glm-5.3"])
        let models = Data(#"{"models":[{"name":"models/gemini-pro"},{"id":"b-model"}]}"#.utf8)
        XCTAssertEqual(ModelListService.parse(models), ["b-model", "gemini-pro"], "带 models/ 前缀的去掉")
        XCTAssertEqual(ModelListService.parse(Data(#"["m2","m10","m1"]"#.utf8)), ["m1", "m2", "m10"], "数字按大小排：m2 在 m10 前面")
        XCTAssertEqual(ModelListService.parse(Data("不是 JSON".utf8)), [])
        XCTAssertEqual(ModelListService.parse(Data(#"{"error":"x"}"#.utf8)), [])
    }

    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body = ""
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var lastRequest: URLRequest?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lastRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    func testFetchingSendsTheKeyAndReturnsTheNames() async throws {
        Stub.status = 200
        Stub.body = #"{"data":[{"id":"b"},{"id":"a"}]}"#
        let names = try await ModelListService.fetch(baseURL: "https://x.test/v1", apiKey: " nvapi-test ", session: session())
        XCTAssertEqual(names, ["a", "b"])
        XCTAssertEqual(Stub.lastRequest?.url?.absoluteString, "https://x.test/v1/models")
        XCTAssertEqual(Stub.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer nvapi-test", "Key 两边的空格去掉")
        XCTAssertEqual(Stub.lastRequest?.httpMethod ?? "GET", "GET")
    }

    func testAnErrorOrAnEmptyListIsReportedWithAReason() async {
        Stub.status = 401; Stub.body = #"{"detail":"Authorization failed"}"#
        do { _ = try await ModelListService.fetch(baseURL: "https://x.test", apiKey: "bad", session: session()); XCTFail("401 该报错") }
        catch let error as PipelineAIError { XCTAssertEqual(error, .httpError(401, #"{"detail":"Authorization failed"}"#)) }
        catch { XCTFail("\(error)") }
        Stub.status = 200; Stub.body = #"{"data":[]}"#
        do { _ = try await ModelListService.fetch(baseURL: "https://x.test", apiKey: "k", session: session()); XCTFail("空列表该报错") }
        catch let error as PipelineAIError { XCTAssertTrue(error.localizedDescription.contains("没有返回模型列表"), error.localizedDescription) }
        catch { XCTFail("\(error)") }
    }
}
