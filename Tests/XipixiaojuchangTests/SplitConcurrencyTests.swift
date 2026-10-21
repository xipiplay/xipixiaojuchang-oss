import XCTest
@testable import Xipixiaojuchang

private actor Peak {
    var running = 0, peak = 0, started = 0
    func enter() { running += 1; started += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
}

/// 批量分割同时最多 10 集（2026-10-11 用户定）：多的排队，抽屉里显示「排队中」
final class AsyncGateTests: XCTestCase {
    func testOnlyTheLimitRunsAtOnceAndEveryoneFinishes() async throws {
        let gate = AsyncGate(limit: 3)
        let peak = Peak()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.acquire()
                    await peak.enter()
                    try? await Task.sleep(for: .milliseconds(30))
                    await peak.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
        let seen = await peak.peak, started = await peak.started
        XCTAssertEqual(seen, 3)
        XCTAssertEqual(started, 12)
    }

    func testTryAcquireDoesNotWaitAndAWaitingTaskThatIsCancelledGivesNothingBack() async throws {
        let gate = AsyncGate(limit: 1)
        let first = await gate.tryAcquire()
        let second = await gate.tryAcquire()
        XCTAssertTrue(first)
        XCTAssertFalse(second, "满了：不排队，直接说没有")

        let waiting = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        do { try await waiting.value; XCTFail("排队时被取消该抛错") } catch { XCTAssertTrue(error is CancellationError) }

        await gate.release()                                         // 放回那 1 个名额
        let again = await gate.tryAcquire()
        XCTAssertTrue(again, "被取消的那个没有占名额，也没有把名额吃掉")
    }
}

@MainActor
final class BatchSplitConcurrencyTests: XCTestCase {
    private func makeProject(_ app: AppModel, episodes: Int) -> String {
        let key = "split-gate-" + UUID().uuidString
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: (1...episodes).map {
            Episode(title: "第\($0)集", text: "场景：客厅\n张三：第\($0)集的台词。")
        }), for: key)
        return key
    }

    func testAtMostFiveEpisodesRunAtOnceTheRestWaitAndAllGetSplit() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: 25)
        defer { app.removePipelineArchive(for: key); for r in app.jobCenter.records where r.projectKey == key { app.jobCenter.removeRecord(id: r.id) } }
        let peak = Peak()
        let reply = "场景：客厅\n张三：你来了。\n--- 00:00 - 00:30"

        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: Array(0..<25), chat: { _, _ in
            await peak.enter()
            try await Task.sleep(for: .milliseconds(400))
            await peak.leave()
            return reply
        })
        try await Task.sleep(for: .milliseconds(150))
        let records = app.jobCenter.records.filter { $0.projectKey == key }
        XCTAssertEqual(records.filter { $0.state == .running }.count, PipelineFlow.splitConcurrency, "同时在跑的 = 上限")
        XCTAssertEqual(records.filter { $0.state == .waiting }.count, 25 - PipelineFlow.splitConcurrency, "其余的排队")
        XCTAssertTrue(records.filter { $0.state == .waiting }.allSatisfy { $0.note?.contains("排队中") == true })
        XCTAssertEqual(app.activeTaskCount, 0, "没进项目页时不数；排队的也算进行中，下一条断言再看")

        await app.pipelineFlow.waitForAll(project: key)
        let finalPeak = await peak.peak
        XCTAssertEqual(finalPeak, PipelineFlow.splitConcurrency, "最多同时 \(PipelineFlow.splitConcurrency) 个请求")
        let archive = try XCTUnwrap(app.pipelineArchive(for: key))
        XCTAssertEqual(archive.episodes.filter { ($0.splitText ?? "").contains("--- 00:00") }.count, 25, "25 集都分割完了")
        XCTAssertEqual(app.pipelineFlow.batches[key]?.succeeded, 25)
        XCTAssertTrue(app.jobCenter.records.filter { $0.projectKey == key }.allSatisfy { $0.state == .completed })
    }

    func testAQueuedEpisodeCanBeStoppedWithoutBlockingTheOthers() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: 13)
        defer { app.removePipelineArchive(for: key); for r in app.jobCenter.records where r.projectKey == key { app.jobCenter.removeRecord(id: r.id) } }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: Array(0..<13), chat: { _, _ in
            try await Task.sleep(for: .milliseconds(300))
            return "场景：客厅\n张三：你来了。\n--- 00:00 - 00:30"
        })
        try await Task.sleep(for: .milliseconds(100))
        let queued = try XCTUnwrap(app.jobCenter.records.first { $0.projectKey == key && $0.state == .waiting })
        app.pipelineFlow.cancel(project: key, episode: queued.episodeID, slot: queued.slot)
        await app.pipelineFlow.waitForAll(project: key)

        let states = Dictionary(grouping: app.jobCenter.records.filter { $0.projectKey == key }, by: \.state).mapValues(\.count)
        XCTAssertEqual(states[.stopped], 1, "排队时停掉的那一集：已停止")
        XCTAssertEqual(states[.completed], 12, "别的 12 集照常做完：\(states)")
    }

    /// 设置里每张服务商卡片可以改「同时请求数」（2026-10-12）：批量分割按它限流
    func testSplitConcurrencyFollowsTheProviderSetting() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: 9)
        defer { app.removePipelineArchive(for: key); for r in app.jobCenter.records where r.projectKey == key { app.jobCenter.removeRecord(id: r.id) } }
        let peak = Peak()
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: Array(0..<9), chat: { _, _ in
            await peak.enter()
            try await Task.sleep(for: .milliseconds(200))
            await peak.leave()
            return "场景：客厅\n张三：你来了。\n--- 00:00 - 00:30"
        }, concurrency: 2)
        try await Task.sleep(for: .milliseconds(80))
        let waiting = app.jobCenter.records.filter { $0.projectKey == key && $0.state == .waiting }
        XCTAssertEqual(waiting.count, 7)
        XCTAssertTrue(waiting.allSatisfy { $0.note?.contains("同时最多 2 集") == true }, "排队提示写的是设的数")
        await app.pipelineFlow.waitForAll(project: key)
        let finalPeak = await peak.peak
        XCTAssertEqual(finalPeak, 2, "最多同时 2 个请求")
    }

    func testConcurrencySettingIsClampedAndDefaultsToFive() {
        XCTAssertEqual(PipelineAISettings().requestConcurrency, 5, "旧配置没有这个键：默认 5")
        var settings = PipelineAISettings()
        settings.concurrency = 0
        XCTAssertEqual(settings.requestConcurrency, 1)
        settings.concurrency = 99
        XCTAssertEqual(settings.requestConcurrency, 10)
        let old = #"{"baseURL":"https://x","apiKey":"","model":"m"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(PipelineAISettings.self, from: old).concurrency, "老存档照样读得出来")
        let provider = PipelineProvider(name: "N", baseURL: "https://x", model: "m", concurrency: 3)
        XCTAssertEqual(provider.settings().requestConcurrency, 3, "卡片上设的数带到在用的配置里")
    }

    func testTheTextApiSessionAllowsEnoughConnectionsForAllTheConcurrentRequests() {
        let limit = PipelineAIService.defaultSession.configuration.httpMaximumConnectionsPerHost
        XCTAssertGreaterThanOrEqual(limit, PipelineAISettings.concurrencyRange.upperBound + PipelineFlow.extractionConcurrency * 3 + 1,
                                    "分割最多能设到 10 + 提取 3 类 × 3 + 推理分镜 1：同一个服务器别被系统默认的 6 个连接卡住")
    }
}
