import XCTest
@testable import Xipixiaojuchang

/// 随 skill 一起发的命令行助手 `skills/xipi-automation/xipi.py`：用真的 Python 进程和真的 `AgentBridge` 对一遍协议，
/// 保证「智能体照 skill 里写的做」和软件这边的文件格式是同一回事。
@MainActor
final class AgentHelperScriptTests: XCTestCase {
    private var root: URL!
    private var bridge: AgentBridge!
    private var savedShared: AgentBridge!
    private var app: AppModel!
    private let script = FileManager.default.currentDirectoryPath + "/skills/xipi-automation/xipi.py"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xipi-helper-tests-\(UUID().uuidString)", isDirectory: true)
        bridge = AgentBridge(root: root)
        savedShared = AgentBridge.shared
        AgentBridge.shared = bridge
        app = AppModel()
        bridge.start(app: app, poll: false)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script), "找不到 \(script)")
    }

    override func tearDown() async throws {
        bridge.stop()
        AgentBridge.shared = savedShared
        try? FileManager.default.removeItem(at: root)
    }

    /// 跑一次助手。`tick`：等它的时候让软件这边照常轮询（发命令要等软件受理）
    private func xipi(_ arguments: [String], tick: Bool = false) async throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script, "--dir", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        while process.isRunning {
            if tick { bridge.tick() }
            try await Task.sleep(for: .milliseconds(40))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func waitForRequest() async throws -> AgentRequest {
        for _ in 0..<250 {
            if let file = ((try? FileManager.default.contentsOfDirectory(at: bridge.requestsDirectory, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { $0.pathExtension == "json" }) {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(AgentRequest.self, from: Data(contentsOf: file))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("等不到请求文件")
    }

    func testASubAgentCanUnpackARequestAndAnswerItWithTheHelper() async throws {
        let longScript = String(repeating: "他说：“你来了。”——她点头。\n", count: 4000)        // 一整行很长的 JSON 也要拆得出来
        let task = Task { @MainActor in try await bridge.ask(system: "系统：只输出结果", user: longScript) }
        let request = try await waitForRequest()

        let pending = try await xipi(["pending"])
        XCTAssertEqual(pending.code, 0)
        bridge.tick()
        let listed = try await xipi(["pending"])
        XCTAssertTrue(listed.output.contains(request.id))

        let unpacked = try await xipi(["unpack", request.id])
        XCTAssertEqual(unpacked.code, 0, unpacked.output)
        let dir = bridge.workDirectory.appendingPathComponent(request.id)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.claimsDirectory.appendingPathComponent("\(request.id).json").path), "unpack = 领取：登记认领")
        bridge.tick()
        XCTAssertEqual(bridge.activity.state, .working, "有智能体领了请求：绿点")
        let claimed = try await xipi(["pending"])
        XCTAssertTrue(claimed.output.contains("已领"), claimed.output)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("system.txt"), encoding: .utf8), "系统：只输出结果")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("user.txt"), encoding: .utf8), longScript, "正文一字不差")

        try "【智能体的回答】\n第二行，带“引号”和 \"双引号\" 和 \\ 反斜杠".write(to: dir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        let answered = try await xipi(["answer", request.id])
        XCTAssertEqual(answered.code, 0, answered.output)
        bridge.tick()
        let reply = try await task.value
        XCTAssertEqual(reply, "【智能体的回答】\n第二行，带“引号”和 \"双引号\" 和 \\ 反斜杠", "特殊字符原样往返")
    }

    func testAnEmptyAnswerIsRefusedAndAFailureCanBeReported() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        let request = try await waitForRequest()
        _ = try await xipi(["unpack", request.id])
        let dir = bridge.workDirectory.appendingPathComponent(request.id)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "  \n".write(to: dir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        let empty = try await xipi(["answer", request.id])
        XCTAssertNotEqual(empty.code, 0, "空回答不写")

        let failed = try await xipi(["fail", request.id, "剧本被截断了"])
        XCTAssertEqual(failed.code, 0, failed.output)
        bridge.tick()
        do { _ = try await task.value; XCTFail("应该报错") } catch {
            XCTAssertEqual(error as? AgentBridgeError, .agentFailed("剧本被截断了"))
        }
    }

    func testACancelledRequestIsReportedAsCancelledAndNothingIsWritten() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        let request = try await waitForRequest()
        task.cancel()
        _ = await task.result
        let unpacked = try await xipi(["unpack", request.id])
        XCTAssertEqual(unpacked.code, 3)
        XCTAssertTrue(unpacked.output.contains("CANCELLED"))
        let answered = try await xipi(["answer", request.id, "/dev/null"])
        XCTAssertEqual(answered.code, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.responsesDirectory.appendingPathComponent("\(request.id).json").path))
    }

    /// 2026-10-11：智能体把 `15718ca6-…` 写成 `15718ca3-…`，工具找不到文件就报「已取消」，请求其实一直在等。
    /// id 和一个还在等回答的请求只差几个字符 = 写错了，要明说，不能报成取消
    func testAMistypedIdIsReportedAsATypoNotAsACancellation() async throws {
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        let request = try await waitForRequest()
        bridge.tick()                                          // 把还在等回答的请求写进状态文件
        let typo = String(request.id.dropLast()) + (request.id.last == "0" ? "1" : "0")
        for command in [["unpack", typo], ["answer", typo, "/dev/null"], ["fail", typo, "原因"]] {
            let result = try await xipi(command)
            XCTAssertEqual(result.code, 4, "\(command)：\(result.output)")
            XCTAssertTrue(result.output.contains("写错"), result.output)
            XCTAssertTrue(result.output.contains(request.id), "要给出最像的那个 id：\(result.output)")
            XCTAssertFalse(result.output.contains("CANCELLED"), result.output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.responsesDirectory.appendingPathComponent("\(typo).json").path))
        // 和任何等待中的请求都差很远的 id：照旧当取消处理
        let stranger = try await xipi(["unpack", UUID().uuidString.lowercased()])
        XCTAssertEqual(stranger.code, 3)
        XCTAssertTrue(stranger.output.contains("CANCELLED"))
        task.cancel()
        _ = await task.result
    }

    func testTheOrchestratorCanCheckSendCommandsAndReadStatus() async throws {
        bridge.tick()
        let check = try await xipi(["check"])
        XCTAssertEqual(check.code, 0, check.output)

        let pong = try await xipi(["cmd", #"{"cmd":"ping"}"#], tick: true)
        XCTAssertEqual(pong.code, 0, pong.output)
        XCTAssertTrue(pong.output.contains("\"ok\": true"), pong.output)

        let refused = try await xipi(["cmd", #"{"cmd":"split","project":"没有"}"#], tick: true)
        XCTAssertEqual(refused.code, 1, "被拒绝的命令退出码非 0")
        XCTAssertTrue(refused.output.contains("不存在"))

        let key = "helper-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "照骨局", createdAt: Date(), updatedAt: Date())
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "甲", episodes: [Episode(title: "第1集", text: "甲", splitText: "分割")]), for: key)
        defer { app.removePipelineArchive(for: key) }
        bridge.tick()
        let summary = try await xipi(["status", "--project", "照骨局"])
        XCTAssertEqual(summary.code, 0, summary.output)
        XCTAssertTrue(summary.output.contains("照骨局") && summary.output.contains("已分割 1"), summary.output)
        let raw = try await xipi(["status", "--json", "--project", key])
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.output.utf8)) as? [String: Any]
        XCTAssertEqual((parsed?["projects"] as? [[String: Any]])?.count, 1)
    }

    /// 回归（2026-10-08）：状态文件里没有值的字段整个不出现（Swift 不写 null）。不挂在某一集上的任务没有 episode / slot，
    /// 助手以前直接取 j["episode"] 崩了（KeyError），换平台的智能体只好自己改脚本。
    func testStatusSummaryCopesWithJobsThatHaveNoEpisodeAndFlagsSplitsWithoutTimeMarkers() async throws {
        bridge.chatOverride = { _, _ in #"[{"title":"第1集","text":"甲"},{"title":"第2集","text":"乙"}]"# }
        let key = "helper-job-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "盒饭", createdAt: Date(), updatedAt: Date())
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "甲\n乙"), for: key)
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.splitScript(app: app, project: key, chat: bridge.chatOverride)       // 这个任务不挂在某一集上
        await app.pipelineFlow.waitForAll(project: key)
        var archive = try XCTUnwrap(app.pipelineArchive(for: key))
        archive.episodes[0].splitText = "场景：客厅\n△画面\n--- 00:00 - 00:30\n**结束。**"      // 有标记（末尾的结束不算一段）
        archive.episodes[1].splitText = "场景：客厅\n△画面，忘了写时间标记"                       // 没有时间标记
        app.savePipelineArchive(archive, for: key)
        bridge.tick()

        let summary = try await xipi(["status", "--project", key])
        XCTAssertEqual(summary.code, 0, "不能崩：\(summary.output)")
        XCTAssertTrue(summary.output.contains("剧本分集"), summary.output)
        XCTAssertTrue(summary.output.contains("没有时间标记的集") && summary.output.contains("[2]"), "只点名第 2 集：\(summary.output)")
        XCTAssertFalse(summary.output.contains("[1, 2]"))
    }

    /// 用户在软件里手动跑别的剧本时，那些请求也会进收件箱：智能体只管自己被要求跑的项目
    func testPendingCanBeLimitedToOneProjectAndOthersAreOnlyCounted() async throws {
        let mine = "helper-mine-" + UUID().uuidString, theirs = "helper-theirs-" + UUID().uuidString
        app.projectMetas[mine] = ProjectMeta(name: "我的项目", createdAt: Date(), updatedAt: Date())
        app.projectMetas[theirs] = ProjectMeta(name: "用户手动导入的", createdAt: Date(), updatedAt: Date())
        let a = Task { @MainActor in
            try await AgentRequestContext.$current.withValue(AgentRequestContext(project: mine, title: "时长分割")) {
                try await bridge.ask(system: "s", user: "u")
            }
        }
        let b = Task { @MainActor in
            try await AgentRequestContext.$current.withValue(AgentRequestContext(project: theirs, title: "剧本分集")) {
                try await bridge.ask(system: "s", user: "u")
            }
        }
        for _ in 0..<250 where bridge.pendingRequests().count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(bridge.pendingRequests().count, 2)
        bridge.tick()
        defer { a.cancel(); b.cancel() }

        let filtered = try await xipi(["pending", "--project", "我的项目"])
        XCTAssertEqual(filtered.code, 0, filtered.output)
        XCTAssertTrue(filtered.output.contains("时长分割"), filtered.output)
        XCTAssertFalse(filtered.output.contains("剧本分集"), "别的项目的请求不列出来，免得被分配出去：\(filtered.output)")
        XCTAssertTrue(filtered.output.contains("另有 1 个其他项目的请求") && filtered.output.contains("用户手动导入的"), filtered.output)
        XCTAssertTrue(filtered.output.contains("不要分配"), filtered.output)

        let byID = try await xipi(["pending", "--project", mine])
        XCTAssertTrue(byID.output.contains("时长分割") && !byID.output.contains("剧本分集"), byID.output)
        let all = try await xipi(["pending"])
        XCTAssertTrue(all.output.contains("时长分割") && all.output.contains("剧本分集"), "不带 --project 仍是全部")
    }

    func testCheckFailsWhenTheAppIsNotRunningOrTheBridgeIsOff() async throws {
        bridge.stop()
        let off = try await xipi(["check"])
        XCTAssertEqual(off.code, 1)
        let missing = try await xipi(["--dir", root.appendingPathComponent("nowhere").path, "check"])
        XCTAssertEqual(missing.code, 1)
    }

    // MARK: 监听模式：xipi wait（用户在软件里点哪一步，智能体就接着做哪一步）

    func testWaitReturnsANewRequestClaimsItAndDoesNotHandItOutTwice() async throws {
        bridge.tick()
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        let request = try await waitForRequest()

        let first = try await xipi(["wait", "--timeout", "5"])
        XCTAssertEqual(first.code, 0, first.output)
        XCTAssertTrue(first.output.contains(request.id), "把请求列出来")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridge.claimsDirectory.appendingPathComponent("\(request.id).json").path), "替智能体登记认领")
        bridge.tick()
        XCTAssertEqual(bridge.activity.state, .working, "认领了：左栏图标变绿")

        let second = try await xipi(["wait", "--timeout", "2"])
        XCTAssertEqual(second.code, 4, "已经领走的不会再交出来：等到超时\(second.output)")
        XCTAssertTrue(second.output.contains("没有新的待回答请求"))

        // 领的人没干完（崩了 / 对话被关了）：认领超过期限，请求还在，就重新交出来
        let again = try await xipi(["wait", "--timeout", "5", "--reclaim-after", "0"])
        XCTAssertEqual(again.code, 0, again.output)
        XCTAssertTrue(again.output.contains(request.id))

        _ = try await xipi(["unpack", request.id])
        let dir = bridge.workDirectory.appendingPathComponent(request.id)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "回答".write(to: dir.appendingPathComponent("answer.txt"), atomically: true, encoding: .utf8)
        _ = try await xipi(["answer", request.id])
        bridge.tick()
        let reply = try await task.value
        XCTAssertEqual(reply, "回答")
    }

    /// 2026-10-11：一次点 50 集，主智能体不该一次领走 50 个再自己记着 46 个排队的 id。
    /// `--max-active N`：按收件目录里「已领未答」的真实数目算空位，只交出空位那么多个，先来的先做
    func testWaitHandsOutOnlyAsManyRequestsAsThereAreFreeSlots() async throws {
        bridge.tick()
        var tasks: [Task<String, Error>] = []
        for index in 1...5 {
            tasks.append(Task { @MainActor in try await bridge.ask(system: "s", user: "第\(index)集") })
            try await Task.sleep(for: .milliseconds(1100))               // createdAt 精确到秒，错开才有先后
        }
        for _ in 0..<100 {
            let count = ((try? FileManager.default.contentsOfDirectory(at: bridge.requestsDirectory, includingPropertiesForKeys: nil)) ?? []).count
            if count >= 5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        func ids(_ output: String) -> [String] {
            output.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }.filter { $0.count == 36 }
        }

        let first = try await xipi(["wait", "--timeout", "5", "--max-active", "2"])
        XCTAssertEqual(first.code, 0, first.output)
        let firstIDs = ids(first.output)
        XCTAssertEqual(firstIDs.count, 2, "5 个排着队，限 2 个：只交出 2 个\(first.output)")
        XCTAssertTrue(first.output.contains("还有 3 个在排队"), first.output)

        let full = try await xipi(["wait", "--timeout", "2", "--max-active", "2"])
        XCTAssertEqual(full.code, 4, "2 个都在做，没有空位：\(full.output)")
        XCTAssertTrue(full.output.contains("3 个在排队") && full.output.contains("没有空位"), full.output)

        // 做完一个（答案交给软件、请求文件被收走）：腾出一个空位，下一个才交出来
        let answerFile = root.appendingPathComponent("answer-\(UUID().uuidString).txt")
        try "回答".write(to: answerFile, atomically: true, encoding: .utf8)
        let answered = try await xipi(["answer", firstIDs[0], answerFile.path])
        XCTAssertEqual(answered.code, 0, answered.output)
        bridge.tick()
        let next = try await xipi(["wait", "--timeout", "5", "--max-active", "2"])
        XCTAssertEqual(next.code, 0, next.output)
        let nextIDs = ids(next.output)
        XCTAssertEqual(nextIDs.count, 1, "腾出 1 个空位就只交出 1 个：\(next.output)")
        XCTAssertFalse(firstIDs.contains(nextIDs[0]), "不会把已经领走的再交出来")

        // 不带 --max-active：和原来一样，没人领的全交出来
        let rest = try await xipi(["wait", "--timeout", "5"])
        XCTAssertEqual(ids(rest.output).count, 2, rest.output)
        for task in tasks { task.cancel() }
    }

    func testWaitCanPeekWithoutClaiming() async throws {
        bridge.tick()
        let task = Task { @MainActor in try await bridge.ask(system: "s", user: "u") }
        let request = try await waitForRequest()
        let peek = try await xipi(["wait", "--timeout", "5", "--no-claim"])
        XCTAssertEqual(peek.code, 0, peek.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.claimsDirectory.appendingPathComponent("\(request.id).json").path), "只看不认领")
        task.cancel()
        _ = await task.result
    }

    func testWaitTimesOutWithCode4WhenNothingIsPendingAndReportsOfflineWithCode1() async throws {
        bridge.tick()
        let idle = try await xipi(["wait", "--timeout", "2"])
        XCTAssertEqual(idle.code, 4, idle.output)
        // 软件没开 / 接力没开：没有状态文件
        try? FileManager.default.removeItem(at: bridge.statusFile)
        let offline = try await xipi(["wait", "--timeout", "2"])
        XCTAssertEqual(offline.code, 1, offline.output)
        XCTAssertTrue(offline.output.contains("外部智能体接力"), "告诉用户怎么打开")
    }

    func testWaitCanBeLimitedToOneProjectAndSeesEveryProjectByDefault() async throws {
        let a = "helper-wait-a-" + UUID().uuidString, b = "helper-wait-b-" + UUID().uuidString
        app.projectMetas[a] = ProjectMeta(name: "甲项目", createdAt: Date(), updatedAt: Date())
        app.projectMetas[b] = ProjectMeta(name: "乙项目", createdAt: Date(), updatedAt: Date())
        bridge.tick()
        let taskA = Task { @MainActor in
            try await AgentRequestContext.$current.withValue(AgentRequestContext(project: a, title: "时长分割")) {
                try await bridge.ask(system: "s", user: "u-a")
            }
        }
        _ = try await waitForRequest()
        let onlyB = try await xipi(["wait", "--timeout", "2", "--project", "乙项目"])
        XCTAssertEqual(onlyB.code, 4, "只等乙项目：甲项目的请求不是它的")
        let all = try await xipi(["wait", "--timeout", "5"])
        XCTAssertEqual(all.code, 0, "默认所有项目都接：用户在软件里点哪个项目的哪一步都做")
        XCTAssertTrue(all.output.contains("甲项目"), all.output)
        taskA.cancel()
        _ = await taskA.result
    }
}
