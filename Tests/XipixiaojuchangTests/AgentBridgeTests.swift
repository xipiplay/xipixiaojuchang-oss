import XCTest
@testable import Xipixiaojuchang

/// 外部智能体接力（2026-10-07）：软件把文字类 AI 请求放进收件目录，由外部智能体回答；也接收命令、写进度快照。
@MainActor
final class AgentBridgeTests: XCTestCase {
    private var root: URL!
    private var bridge: AgentBridge!
    private var savedShared: AgentBridge!
    private var app: AppModel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xipi-agent-tests-\(UUID().uuidString)", isDirectory: true)
        bridge = AgentBridge(root: root)
        savedShared = AgentBridge.shared
        AgentBridge.shared = bridge                 // PipelineAIService 走的是 shared：换成临时目录的这一个，别写进真实数据目录
        app = AppModel()
        bridge.start(app: app, poll: false)
    }

    override func tearDown() async throws {
        bridge.stop()
        AgentBridge.shared = savedShared
        UserDefaults.standard.removeObject(forKey: PipelineAISettingsStore.defaultsKey)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 工具

    private func requestFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: bridge.requestsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }
    private func readRequest(_ url: URL) throws -> AgentRequest {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentRequest.self, from: Data(contentsOf: url))
    }
    private func writeReply(id: String, ok: Bool = true, text: String? = nil, error: String? = nil) throws {
        let data = try JSONEncoder().encode(AgentReply(id: id, ok: ok, text: text, error: error))
        try data.write(to: bridge.responsesDirectory.appendingPathComponent("\(id).json"), options: .atomic)
    }
    private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("等不到：\(what)"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func sendCommand(_ json: String, id: String = UUID().uuidString) throws -> AgentCommandResult {
        try Data(json.utf8).write(to: bridge.commandsDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        bridge.tick()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentCommandResult.self, from: Data(contentsOf: bridge.resultsDirectory.appendingPathComponent("\(id).json")))
    }
    private func status() throws -> AgentStatus {
        bridge.tick()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentStatus.self, from: Data(contentsOf: bridge.statusFile))
    }
    private func fixture(titles: [String]) -> (String, [Episode]) {
        let key = "agent-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "照骨局", createdAt: Date(), updatedAt: Date())
        let episodes = titles.map { Episode(title: $0, text: "原文·" + $0) }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: episodes.map(\.text).joined(separator: "\n"), episodes: episodes), for: key)
        return (key, episodes)
    }

    // MARK: 请求 / 回答

    func testAskWritesARequestFileAndReturnsTheAgentsReply() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "系统提示", user: "正文") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let request = try readRequest(requestFiles()[0])
        XCTAssertEqual(request.system, "系统提示")
        XCTAssertEqual(request.user, "正文")
        XCTAssertEqual(request.kind, "AI 请求", "没有任务上下文时用通用名")
        XCTAssertEqual(request.images, [])
        XCTAssertEqual(request.responseFile, bridge.responsesDirectory.appendingPathComponent("\(request.id).json").path)
        XCTAssertEqual(bridge.pendingRequests().map(\.id), [request.id])
        XCTAssertEqual(try status().pendingRequests.map(\.id), [request.id], "状态文件里也能看到在等的请求")

        try writeReply(id: request.id, text: "  回答正文\n")
        bridge.tick()
        let text = try await task.value
        XCTAssertEqual(text, "回答正文", "首尾空白去掉，和 API 返回的一样")
        XCTAssertTrue(requestFiles().isEmpty, "处理完的请求不留在收件目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.doneDirectory.appendingPathComponent("requests/\(request.id).json").path))
        XCTAssertTrue(bridge.pendingRequests().isEmpty)
    }

    func testTheRequestSaysWhichProjectEpisodeAndStepItBelongsTo() async throws {
        let (key, episodes) = fixture(titles: ["第一集", "第二集"])
        defer { app.removePipelineArchive(for: key) }
        let context = AgentRequestContext(project: key, episode: episodes[1].id, title: "时长分割")
        let task = AgentRequestContext.$current.withValue(context) {
            Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let request = try readRequest(requestFiles()[0])
        XCTAssertEqual(request.kind, "时长分割")
        XCTAssertEqual(request.project, key)
        XCTAssertEqual(request.projectName, "照骨局")
        XCTAssertEqual(request.episode, 2, "集号 1 起")
        XCTAssertEqual(request.episodeTitle, "第二集")
        try writeReply(id: request.id, text: "好")
        bridge.tick()
        _ = try await task.value
    }

    func testImagesAreHandedOverAsPaths() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "看图", user: "场景：客厅", images: ["/tmp/客厅.png"]) }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let request = try readRequest(requestFiles()[0])
        XCTAssertEqual(request.images, ["/tmp/客厅.png"])
        try writeReply(id: request.id, text: "站位")
        bridge.tick()
        _ = try await task.value
    }

    func testAFailureReplyBecomesAnErrorWithTheAgentsReason() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        try writeReply(id: try readRequest(requestFiles()[0]).id, ok: false, error: "剧本太长读不完")
        bridge.tick()
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            XCTAssertEqual(error as? AgentBridgeError, .agentFailed("剧本太长读不完"))
        }
    }

    func testAnEmptyReplyIsAnErrorLikeAnEmptyAPIReply() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        try writeReply(id: try readRequest(requestFiles()[0]).id, text: "  \n")
        bridge.tick()
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            XCTAssertEqual(error as? PipelineAIError, .emptyResponse)
        }
    }

    func testCancellingTheTaskDeletesTheRequestSoTheAgentDropsIt() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        task.cancel()
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(requestFiles().isEmpty, "请求文件没了 = 这一步取消了")
        XCTAssertTrue(bridge.pendingRequests().isEmpty)
        try writeReply(id: id, text: "迟到的回答")
        bridge.tick()                                       // 迟到的回答没人等，不会出事
    }

    func testAnAlreadyCancelledTaskNeverLeavesARequestBehind() async throws {
        let task = Task { @MainActor () throws -> String in
            try await Task.sleep(for: .seconds(30))        // 被取消时抛出
            return try await bridge.ask(system: "s", user: "u")
        }
        task.cancel()
        _ = await task.result
        XCTAssertTrue(requestFiles().isEmpty)
    }

    func testNoReplyInTimeFailsAndMovesTheRequestAside() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u", timeout: 10) }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        bridge.tick(now: Date().addingTimeInterval(60))
        do { _ = try await task.value; XCTFail("应该超时") } catch {
            XCTAssertEqual(error as? AgentBridgeError, .timeout)
        }
        XCTAssertTrue(requestFiles().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.staleDirectory.appendingPathComponent("\(id).json").path))
    }

    func testAHalfWrittenReplyIsWaitedForThenReportedAsBad() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        try Data("{\"id\":\"\(id)\",\"ok\":tr".utf8).write(to: bridge.responsesDirectory.appendingPathComponent("\(id).json"))
        let now = Date()
        bridge.tick(now: now)
        XCTAssertEqual(bridge.pendingRequests().count, 1, "刚发现读不出来：可能还在写，再等等")
        bridge.tick(now: now.addingTimeInterval(AgentBridge.partialWriteGrace + 1))
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            guard case .badReply = error as? AgentBridgeError else { return XCTFail("应该是 badReply：\(error)") }
        }
    }

    func testAReplyWhoseIDDoesNotMatchTheFileIsRejected() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        let wrong = try JSONEncoder().encode(AgentReply(id: "别的请求", ok: true, text: "串了"))
        try wrong.write(to: bridge.responsesDirectory.appendingPathComponent("\(id).json"))
        bridge.tick()
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            guard case .badReply = error as? AgentBridgeError else { return XCTFail("应该是 badReply：\(error)") }
        }
    }

    func testTurningTheBridgeOffFailsWaitingRequestsAndRemovesTheirFiles() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        bridge.stop()
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            XCTAssertEqual(error as? AgentBridgeError, .turnedOff)
        }
        XCTAssertTrue(requestFiles().isEmpty)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let last = try decoder.decode(AgentStatus.self, from: Data(contentsOf: bridge.statusFile))
        XCTAssertFalse(last.agentMode, "关了之后状态文件写最后一次：agentMode=false")
    }

    func testBackgroundStatusWritesLandInOrderAndTheClosingOneIsImmediate() async throws {
        // 软件里用的那一个：状态文件在后台写（批量回传时主线程不再编码 360KB 的 JSON）
        let dir = root.appendingPathComponent("background", isDirectory: true)
        let other = AgentBridge(root: dir, writesStatusInBackground: true)
        var (key, episodes) = fixture(titles: ["第一集"])
        episodes[0].splitText = "【场景】客厅\n【角色】张三\n【道具】无\n【本段在场】张三\n张三：你好。\n=== 00:00-00:30"
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "", episodes: episodes), for: key)
        defer { app.removePipelineArchive(for: key) }
        other.start(app: app, poll: false)
        // 每集的情况（要解析分割）在后台算：开关当场返回，主线程不等（2026-10-28 用户：启动后第一次开接力卡 0.7 秒）
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.statusFile.path), "还在后台算，没在主线程上当场写")
        other.tick(now: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.statusFile.path), "算完之前每秒的刷新也不写")
        await other.waitForStatusWarmUp()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let first = try decoder.decode(AgentStatus.self, from: Data(contentsOf: other.statusFile))
        XCTAssertTrue(first.agentMode, "算完马上写一份")
        let project = try XCTUnwrap(first.projects.first { $0.id == key })
        XCTAssertEqual(project.episodes.first?.split, true)
        XCTAssertEqual(project.episodes.first?.named, SplitSegments.isNamed(episodes[0].splitText ?? ""), "和主线程上算的一样")
        other.tick(now: first.updatedAt.addingTimeInterval(9))
        other.flushStatusWrites()
        let beat = try decoder.decode(AgentStatus.self, from: Data(contentsOf: other.statusFile))
        XCTAssertGreaterThan(beat.updatedAt, first.updatedAt, "心跳那一次在后台写，等队列做完就落盘")
        other.stop()
        let last = try decoder.decode(AgentStatus.self, from: Data(contentsOf: other.statusFile))
        XCTAssertFalse(last.agentMode, "关掉那一次不等后台：软件马上退出也不丢")
    }

    func testStartingUpSweepsRequestsLeftByTheLastRun() throws {
        let other = AgentBridge(root: root.appendingPathComponent("second", isDirectory: true))
        let fm = FileManager.default
        try fm.createDirectory(at: other.requestsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: other.responsesDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: other.requestsDirectory.appendingPathComponent("old.json"))
        try Data("{}".utf8).write(to: other.responsesDirectory.appendingPathComponent("old.json"))
        other.start(app: app, poll: false)
        defer { other.stop() }
        XCTAssertFalse(fm.fileExists(atPath: other.requestsDirectory.appendingPathComponent("old.json").path), "等它的任务早没了")
        XCTAssertTrue(fm.fileExists(atPath: other.staleDirectory.appendingPathComponent("old.json").path))
        XCTAssertFalse(fm.fileExists(atPath: other.responsesDirectory.appendingPathComponent("old.json").path))
    }

    // MARK: 左栏 AI 图标的小圆点（黄 = 等智能体，绿 = 智能体在工作）

    func testTheDotIsYellowWhileWaitingGreenWhenTheAgentActsAndGoneWhenTurnedOff() throws {
        XCTAssertEqual(bridge.activity.state, .waiting, "刚开启、智能体还没动：黄")
        bridge.tick()
        XCTAssertEqual(bridge.activity.state, .waiting)
        _ = try sendCommand(#"{"cmd":"ping"}"#)                                  // 智能体发了命令：开始执行
        XCTAssertEqual(bridge.activity.state, .working)
        bridge.tick(now: Date().addingTimeInterval(AgentBridge.activityWindow - 5))
        XCTAssertEqual(bridge.activity.state, .working, "刚动过不久，还是绿")
        bridge.tick(now: Date().addingTimeInterval(AgentBridge.activityWindow + 5))
        XCTAssertEqual(bridge.activity.state, .waiting, "一分钟没动静：回到黄")
        bridge.stop()
        XCTAssertEqual(bridge.activity.state, .off, "接力关了：没有点")
    }

    func testAClaimedRequestKeepsTheDotGreenUntilItIsAnswered() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        bridge.tick()
        XCTAssertEqual(bridge.activity.state, .waiting, "请求发出去了但还没人领：黄")
        XCTAssertEqual(try status().pendingRequests.first?.claimed, false)

        try Data("{}".utf8).write(to: bridge.claimsDirectory.appendingPathComponent("\(id).json"))      // 子智能体领走（xipi.py unpack）
        bridge.tick()
        XCTAssertEqual(bridge.activity.state, .working)
        XCTAssertEqual(try status().pendingRequests.first?.claimed, true, "状态文件里标「已领」")
        let later = Date().addingTimeInterval(600)
        bridge.tick(now: later)
        XCTAssertEqual(bridge.activity.state, .working, "领走了还没交回答（可能在想很久）：一直是绿")

        try writeReply(id: id, text: "好")
        bridge.tick(now: later)
        _ = try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.claimsDirectory.appendingPathComponent("\(id).json").path), "回答收到后认领记录清掉")
        bridge.tick(now: later.addingTimeInterval(AgentBridge.activityWindow + 5))
        XCTAssertEqual(bridge.activity.state, .waiting, "没有在做的请求、也没新动静：回到黄")
    }

    func testACancelledRequestReleasesItsClaim() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let id = try readRequest(requestFiles()[0]).id
        try Data("{}".utf8).write(to: bridge.claimsDirectory.appendingPathComponent("\(id).json"))
        bridge.tick()
        task.cancel()
        _ = await task.result
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.claimsDirectory.appendingPathComponent("\(id).json").path))
        bridge.tick(now: Date().addingTimeInterval(AgentBridge.activityWindow + 5))
        XCTAssertEqual(bridge.activity.state, .waiting)
    }

    /// 用户在软件里手动触发的任务，接力开着时会进收件箱干等：任务抽屉里要写明在等谁，别让人以为软件卡了
    func testTheTaskDrawerSaysWhenAJobIsWaitingForTheAgent() async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(PipelineAISettings(agentMode: true)), forKey: PipelineAISettingsStore.defaultsKey)
        let (key, _) = fixture(titles: ["第一集"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0])
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        func note() -> String? { app.jobCenter.records.first { $0.kind == .ai && $0.projectKey == key }?.note }
        XCTAssertEqual(note(), AgentBridge.waitingNote, "请求发出去、还没人领：等待外部智能体回答")

        let id = try readRequest(requestFiles()[0]).id
        try Data("{}".utf8).write(to: bridge.claimsDirectory.appendingPathComponent("\(id).json"))
        bridge.tick()
        XCTAssertEqual(note(), AgentBridge.workingNote, "被子智能体领走：外部智能体正在处理")

        try writeReply(id: id, text: "分割结果")
        bridge.tick()
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertNil(note(), "做完了：说明清掉")
        XCTAssertEqual(app.jobCenter.records.first { $0.projectKey == key }?.state, .completed)
    }

    func testTheFolderIsPrivateBecauseItHoldsTheWholeScript() throws {
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
    }

    // MARK: 设置与走向

    func testOldSavedSettingsWithoutTheAgentKeyStillLoadAsAPI() throws {
        let old = Data(#"{"baseURL":"https://a.invalid","apiKey":"k","model":"m"}"#.utf8)
        let config = try JSONDecoder().decode(PipelineAISettings.self, from: old)
        XCTAssertNil(config.agentMode)
        XCTAssertFalse(config.usesAgent)
    }

    func testAgentModeNeedsNoAPIFieldsAndKeepsThemUntouched() throws {
        XCTAssertThrowsError(try PipelineAISettings(apiKey: "").validated(), "API 模式照旧要求填 Key")
        let agent = PipelineAISettings(baseURL: " https://keep.invalid ", apiKey: "", model: "m", agentMode: true)
        let checked = try agent.validated()
        XCTAssertTrue(checked.usesAgent)
        XCTAssertEqual(checked.baseURL, "https://keep.invalid", "接力模式下 API 字段原样保留（只去首尾空白）")
    }

    func testTheAIServiceRoutesToTheBridgeInAgentModeInsteadOfCallingTheAPI() async throws {
        let config = PipelineAISettings(agentMode: true)         // 没有 Key：走 API 的话会直接报「尚未配置」
        let task = Task { try await PipelineAIService.chat(config: config, system: "系统", user: "正文") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let request = try readRequest(requestFiles()[0])
        XCTAssertEqual(request.system, "系统")
        try writeReply(id: request.id, text: "智能体的回答")
        bridge.tick()
        let reply = try await task.value
        XCTAssertEqual(reply, "智能体的回答")
    }

    func testVisionRequestsCarryTheImagePath() async throws {
        let config = PipelineAISettings(agentMode: true)
        let task = Task { try await PipelineAIService.vision(config: config, imageURL: URL(fileURLWithPath: "/tmp/场景.png"), system: "看图", context: "场景：客厅") }
        try await waitUntil("请求文件") { !requestFiles().isEmpty }
        let request = try readRequest(requestFiles()[0])
        XCTAssertEqual(request.images, ["/tmp/场景.png"])
        XCTAssertEqual(request.user, "场景：客厅")
        try writeReply(id: request.id, text: "站位")
        bridge.tick()
        _ = try await task.value
    }

    func testTheConnectionTestDoesNotWaitForAnAgentInAgentMode() async throws {
        let result = await ConnectionProbe.ai(config: PipelineAISettings(agentMode: true))
        XCTAssertTrue(result.ok)
        XCTAssertTrue(requestFiles().isEmpty, "测试连接不发请求")
    }

    /// 批量分割不传 chat、设置里开着接力：每集的请求都带着「时长分割」和各自的集号，回答存进对应那一集
    func testBatchSplitRequestsCarryTheirEpisodeAndTheAnswersLandOnTheRightEpisodes() async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(PipelineAISettings(agentMode: true)), forKey: PipelineAISettingsStore.defaultsKey)
        let (key, _) = fixture(titles: ["第一集", "第二集"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0, 1])
        try await waitUntil("两个请求") { requestFiles().count == 2 }
        let requests = try requestFiles().map(readRequest).sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
        XCTAssertEqual(requests.map(\.kind), ["时长分割", "时长分割"])
        XCTAssertEqual(requests.map(\.episode), [1, 2])
        XCTAssertEqual(requests.map(\.user), ["原文·第一集", "原文·第二集"])
        for request in requests.reversed() { try writeReply(id: request.id, text: "分割结果·" + request.user) }   // 倒着答：不靠顺序
        bridge.tick()
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes.map(\.splitText), ["分割结果·原文·第一集", "分割结果·原文·第二集"])
    }

    // MARK: 命令

    func testPingAndUnknownCommands() throws {
        XCTAssertTrue(try sendCommand(#"{"cmd":"ping"}"#).ok)
        let unknown = try sendCommand(#"{"cmd":"fly"}"#)
        XCTAssertFalse(unknown.ok)
        XCTAssertTrue(unknown.message.contains("不认识"))
        let handled = (try? FileManager.default.contentsOfDirectory(at: bridge.commandsDirectory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "json" } ?? []
        XCTAssertTrue(handled.isEmpty, "处理过的命令文件挪进 done/，不会再执行第二遍")
    }

    func testABrokenCommandFileIsReportedAfterTheGracePeriod() throws {
        let file = bridge.commandsDirectory.appendingPathComponent("broken.json")
        try Data("{\"cmd\":".utf8).write(to: file)
        let now = Date()
        bridge.tick(now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "可能还在写，先等")
        bridge.tick(now: now.addingTimeInterval(AgentBridge.partialWriteGrace + 1))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(AgentCommandResult.self, from: Data(contentsOf: bridge.resultsDirectory.appendingPathComponent("broken.json")))
        XCTAssertFalse(result.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCommandsAreRefusedWithAReasonWhenTheyCannotRun() throws {
        let (key, _) = fixture(titles: ["第一集", "第二集"])
        defer { app.removePipelineArchive(for: key) }
        XCTAssertTrue(try sendCommand(#"{"cmd":"split"}"#).message.contains("缺少 project"))
        XCTAssertTrue(try sendCommand(#"{"cmd":"split","project":"没有这个项目"}"#).message.contains("不存在"))
        let outOfRange = try sendCommand(#"{"cmd":"split","project":"\#(key)","episodes":[3]}"#)
        XCTAssertFalse(outOfRange.ok)
        XCTAssertTrue(outOfRange.message.contains("第 3 集不存在"))
        XCTAssertTrue(try sendCommand(#"{"cmd":"split","project":"\#(key)","episodes":[0]}"#).message.contains("第 0 集不存在"), "集号从 1 起")
        XCTAssertTrue(try sendCommand(#"{"cmd":"split","project":"\#(key)","episodes":"some"}"#).message.contains("episodes"), "JSON 没写坏、内容不对：马上告诉智能体，不用等")
        XCTAssertTrue(try sendCommand(#"{"project":"x"}"#).message.contains("缺少 cmd"))
        let unapproved = try sendCommand(#"{"cmd":"infer","project":"\#(key)"}"#)
        XCTAssertFalse(unapproved.ok, "没有用户同意不能推理分镜")
        XCTAssertTrue(unapproved.message.contains("approved"))
        XCTAssertNil(app.pipelineFlow.batches[key], "被拒绝就什么都没发生")
        let noSplit = try sendCommand(#"{"cmd":"infer","project":"\#(key)","approved":true}"#)
        XCTAssertFalse(noSplit.ok)
        XCTAssertTrue(noSplit.message.contains("还没有时长分割"))
        XCTAssertTrue(try sendCommand(#"{"cmd":"extract","project":"\#(key)","kinds":["怪物"]}"#).message.contains("不认识的素材类型"))
        XCTAssertTrue(try sendCommand(#"{"cmd":"import-script","file":"/没有/这个.txt"}"#).message.contains("读不出剧本"))
        XCTAssertTrue(try sendCommand(#"{"cmd":"import-script","file":"/tmp/剧本.docx"}"#).message.contains("只支持 TXT"))
    }

    /// 导入 → 批量分割 → 推理分镜 → 提取（2026-10-09 起提取在推理分镜之后：名字取自分镜头行）：全程只发命令、读 status.json，回答由「假智能体」（chatOverride）给
    func testImportSplitExtractAndInferThroughCommandsAndTheStatusFile() async throws {
        let suffix = "必须按照镜头描述和角色台词生成。电影写实风格，无字幕，无音乐，角色说中文。"
        bridge.chatOverride = { system, user in
            if system.contains("顶级影视角色形象设计师") { return "这个人是：\"张三\"，三十岁，穿灰色西装。" }
            if system.contains("来提取场景") { return "这个场景叫：\"客厅\"，现代，一间朝南的客厅。" }
            if system.contains("按 30 秒为单位切分") { return "场景：客厅 日 内\n△ 画面\n[张三]：台词\n--- 00:00 - 00:30" }
            if system.contains("专业分镜脚本") { return "[客厅][张三][怀表]\n【角色初始站位与朝向】张三站在画面左侧。轴线锁定：画面左＝张三一侧。\n中景，镜头。\n\(suffix)" }
            return #"[{"title":"第1集","text":"甲甲"},{"title":"第2集","text":"乙乙"}]"#      // 剧本分集
        }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("照骨局测试-\(UUID().uuidString.prefix(6)).txt")
        try "甲甲\n乙乙".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        // 1) 导入 + 自动分集
        let imported = try sendCommand(#"{"cmd":"import-script","file":"\#(script.path)"}"#)
        XCTAssertTrue(imported.ok, imported.message)
        let key = try XCTUnwrap(imported.project)
        defer {
            app.removePipelineArchive(for: key)
            app.imageItems.removeAll { $0.projectKey == key }
            app.shots.removeAll { $0.projectKey == key }
            if FileLocations.projectFolder(key).lastPathComponent == key { try? FileManager.default.removeItem(at: FileLocations.projectFolder(key)) }
        }
        await app.pipelineFlow.waitForAll(project: key)
        var project = try XCTUnwrap(try status().projects.first { $0.id == key })
        XCTAssertEqual(project.episodes.map(\.title), ["第1集", "第2集"])
        XCTAssertEqual(project.episodes.map(\.split), [false, false])

        // 2) 批量分割（全部集）
        let split = try sendCommand(#"{"cmd":"split","project":"\#(key)"}"#)
        XCTAssertTrue(split.ok, split.message)
        let again = try sendCommand(#"{"cmd":"split","project":"\#(key)"}"#)
        XCTAssertFalse(again.ok, "上一轮还没跑完时不开新的一轮")
        await app.pipelineFlow.waitForAll(project: key)
        project = try XCTUnwrap(try status().projects.first { $0.id == key })
        XCTAssertEqual(project.episodes.map(\.split), [true, true])
        XCTAssertEqual(project.batch?.kind, "split")
        XCTAssertEqual(project.batch?.succeeded, 2)
        XCTAssertEqual(project.batch?.finished, true)

        // 3) 提取要等推理分镜（名字取自分镜头行）：没推理就被拒绝，并说明先做什么
        let tooEarly = try sendCommand(#"{"cmd":"extract","project":"\#(key)","kinds":["角色"]}"#)
        XCTAssertFalse(tooEarly.ok)
        XCTAssertTrue(tooEarly.message.contains("还没有推理分镜"), tooEarly.message)
        XCTAssertNotEqual(app.pipelineFlow.batches[key]?.kind, .extract, "被拒绝就什么都没发生")

        // 4) 推理分镜
        XCTAssertTrue(try sendCommand(#"{"cmd":"infer","project":"\#(key)","episodes":[1,2],"approved":true}"#).ok)
        await app.pipelineFlow.waitForAll(project: key)
        project = try XCTUnwrap(try status().projects.first { $0.id == key })
        XCTAssertEqual(project.videoCards, 2)
        XCTAssertEqual(project.episodes.map(\.storyboardCards), [1, 1])
        XCTAssertEqual(project.batch?.kind, "infer")
        XCTAssertEqual(project.batch?.succeeded, 2)

        // 5) 提取角色：名字 张三 取自分镜头行 [客厅][张三][怀表]
        XCTAssertTrue(try sendCommand(#"{"cmd":"extract","project":"\#(key)","kinds":["角色"]}"#).ok)
        await app.pipelineFlow.waitForAll(project: key)
        project = try XCTUnwrap(try status().projects.first { $0.id == key })
        XCTAssertEqual(project.imageCards, 1)
        XCTAssertEqual(project.batch?.kind, "extract")
        XCTAssertEqual(project.batch?.created, 1)
    }

    func testStopCancelsRunningTasksAndTheirPendingRequests() async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(PipelineAISettings(agentMode: true)), forKey: PipelineAISettingsStore.defaultsKey)
        let (key, _) = fixture(titles: ["第一集", "第二集"])
        defer { app.removePipelineArchive(for: key) }
        XCTAssertTrue(try sendCommand(#"{"cmd":"split","project":"\#(key)"}"#).ok)
        try await waitUntil("两个请求") { requestFiles().count == 2 }
        XCTAssertTrue(try sendCommand(#"{"cmd":"stop","project":"\#(key)"}"#).ok)
        await app.pipelineFlow.waitForAll(project: key)
        try await waitUntil("请求文件被收走") { requestFiles().isEmpty }
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.failures.count, 2, "都算「已停止」")
    }

    func testTheStatusFileReportsHowManySegmentsEachSplitHas() throws {
        let key = "agent-seg-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "段数", createdAt: Date(), updatedAt: Date())
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "甲", episodes: [
            Episode(title: "一", text: "x", splitText: "场景：A\n△x\n--- 00:00 - 00:30\n场景：A\n△y\n--- 00:30 - 01:00\n**结束。**"),
            Episode(title: "二", text: "x", splitText: "场景：A\n△x，没有时间标记"),
            Episode(title: "三", text: "x"),
        ]), for: key)
        defer { app.removePipelineArchive(for: key) }
        let episodes = try XCTUnwrap(try status().projects.first { $0.id == key }).episodes
        XCTAssertEqual(episodes.map(\.segments), [2, nil, nil], "末尾的「结束。」不算一段；没有时间标记 / 没分割 = 没有这个字段")
        XCTAssertEqual(episodes.map(\.split), [true, true, false])
    }

    /// 回归（2026-10-08）：接力开着时每秒生成一次状态，它跑在主线程上。第一版每集每秒都重新数字数、重新解析分割段数
    /// （正则 + 逐行处理），60 集 × 好几个项目时每秒占主线程上百毫秒，主页和缩略图卡片滑起来一跳一跳的。
    func testBuildingTheStatusStaysCheapOnAHeavyLibrary() throws {
        let segment = (0..<12).map { "场景：老城区 日 内\n△画面描述画面描述画面描述画面描述\n张三：这是一句台词这是一句台词这是一句台词\n--- 00:\(String(format: "%02d", $0 * 2)) - 00:\(String(format: "%02d", $0 * 2 + 30 - ($0 * 2) % 30))" }
            .joined(separator: "\n")
        var keys: [String] = []
        for p in 0..<8 {
            let key = "agent-heavy-\(p)-" + UUID().uuidString
            keys.append(key)
            app.projectMetas[key] = ProjectMeta(name: "大项目\(p)", createdAt: Date(), updatedAt: Date())
            let episodes = (0..<60).map { Episode(title: "第\($0 + 1)集", text: String(repeating: "原文原文原文原文。", count: 500), splitText: segment + "\n**结束。**") }
            app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "甲", episodes: episodes), for: key)
        }
        defer { keys.forEach { app.removePipelineArchive(for: $0) } }
        var items: [ImageGenItem] = []
        for i in 0..<6000 { items.append(ImageGenItem(projectKey: keys[i % keys.count], name: "n\(i)", prompt: "p\(i)")) }
        app.imageItems = items
        defer { app.imageItems.removeAll { keys.contains($0.projectKey) } }

        func millis(_ work: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent(); work(); return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        let cold = millis { bridge.tick() }
        let warm = (0..<5).map { _ in millis { bridge.tick() } }.max() ?? 0
        print("STATUS-COST cold=\(Int(cold))ms warm(max of 5)=\(Int(warm))ms")
        XCTAssertLessThan(warm, 15, "每秒一次的状态生成必须便宜：已经算过的集不重算")
    }

    func testTheStatusFileHasNoScriptTextAndIsRefreshedAsAHeartbeat() throws {
        let (key, _) = fixture(titles: ["第一集"])
        defer { app.removePipelineArchive(for: key) }
        let text = try String(contentsOf: { _ = try status(); return bridge.statusFile }(), encoding: .utf8)
        XCTAssertTrue(text.contains(key))
        XCTAssertFalse(text.contains("原文·第一集"), "只放进度，不放剧本正文")
        let before = try status().updatedAt
        bridge.tick(now: before.addingTimeInterval(1))
        XCTAssertEqual(try status().updatedAt, before, "内容没变时 8 秒内不重写")
        bridge.tick(now: before.addingTimeInterval(5))
        XCTAssertEqual(try status().updatedAt, before, "内容没变时 8 秒内不重写（2026-10-10 由 3 秒放宽：状态文件近 200KB，空闲时少写盘；智能体的在线口径是 15 秒）")
        bridge.tick(now: before.addingTimeInterval(9))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let after = try decoder.decode(AgentStatus.self, from: Data(contentsOf: bridge.statusFile)).updatedAt
        XCTAssertGreaterThan(after, before, "超过 8 秒刷新一次当心跳")
    }
}
