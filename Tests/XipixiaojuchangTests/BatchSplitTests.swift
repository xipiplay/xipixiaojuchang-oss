import XCTest
@testable import Xipixiaojuchang

private actor Counter {
    var running = 0, peak = 0, prompts: [String] = [], systems: [String] = []
    func enter(_ prompt: String, system: String = "") { running += 1; peak = max(peak, running); prompts.append(prompt); systems.append(system) }
    func leave() { running -= 1 }
}

/// 批量分割（2026-10-07）：每集用「分割（时长）」提示词整理原文，结果存进 `splitText`，原文不动；选中的集同时跑。
@MainActor
final class BatchSplitTests: XCTestCase {
    private func fixture(_ app: AppModel, texts: [String]) -> (String, [Episode]) {
        let key = "batch-split-" + UUID().uuidString
        let episodes = texts.enumerated().map { Episode(title: "第\($0.offset + 1)集", text: $0.element) }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: texts.joined(separator: "\n"), episodes: episodes), for: key)
        return (key, episodes)
    }

    private func waitForAll(_ app: AppModel, key: String, episodes: [Episode]) async {
        for e in episodes { await app.pipelineFlow.waitForJob(project: key, episode: e.id) }
    }

    func testSplitResultIsStoredNextToTheOriginalWithoutTouchingIt() async throws {
        let app = AppModel(), counter = Counter()
        let (key, episodes) = fixture(app, texts: ["原文一", "原文二"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0, 1], chat: { system, user in
            await counter.enter(user)
            return "分割后：" + user + "\n--- 00:00 - 00:30"
        })
        await waitForAll(app, key: key, episodes: episodes)

        let saved = try XCTUnwrap(app.pipelineArchive(for: key)).episodes
        XCTAssertEqual(saved.map(\.text), ["原文一", "原文二"], "原文不动")
        XCTAssertEqual(saved.map(\.splitText), ["分割后：原文一\n--- 00:00 - 00:30", "分割后：原文二\n--- 00:00 - 00:30"])
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 2)
        XCTAssertTrue(state.failures.isEmpty)
    }

    func testSystemPromptIsTheSplitPromptAndTheUserMessageIsTheEpisodeText() async throws {
        let app = AppModel(), counter = Counter()
        let (key, episodes) = fixture(app, texts: ["这一集的原文"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { system, user in
            await counter.enter(user, system: system); await counter.leave()
            return "结果"
        })
        await waitForAll(app, key: key, episodes: episodes)
        let users = await counter.prompts, systems = await counter.systems
        XCTAssertEqual(users, ["这一集的原文"], "只发原文，不夹带别的")
        XCTAssertTrue(try XCTUnwrap(systems.first).contains(PipelinePromptStore.segmentPrompt.prefix(40)), "用的是设置里的「分割（时长）」提示词")
    }

    func testSelectedEpisodesAllStartAtTheSameTimeAndOthersAreLeftAlone() async throws {
        let app = AppModel(), counter = Counter()
        let (key, episodes) = fixture(app, texts: ["一", "二", "三", "四"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [1, 2, 3], chat: { _, user in
            await counter.enter(user)
            try? await Task.sleep(for: .milliseconds(60))      // 让它们有机会重叠
            await counter.leave()
            return "分：" + user
        })
        await waitForAll(app, key: key, episodes: episodes)
        let peak = await counter.peak
        XCTAssertEqual(peak, 3, "选中的 3 集同时在跑")
        let saved = try XCTUnwrap(app.pipelineArchive(for: key)).episodes
        XCTAssertNil(saved[0].splitText, "没选的第 1 集不动")
        XCTAssertEqual(saved[1...].compactMap(\.splitText), ["分：二", "分：三", "分：四"])
    }

    func testOneEpisodeFailingDoesNotStopTheOthersAndIsReportedByEpisodeNumber() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "AI 超时了" } }
        let app = AppModel()
        let (key, episodes) = fixture(app, texts: ["好一", "坏二", "好三"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0, 1, 2], chat: { _, user in
            if user.contains("坏") { throw Boom() }
            return "分：" + user
        })
        await waitForAll(app, key: key, episodes: episodes)
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 2)
        XCTAssertEqual(state.failures, [.init(order: 2, label: "第 2 集", message: "AI 超时了")])
        let saved = try XCTUnwrap(app.pipelineArchive(for: key)).episodes
        XCTAssertEqual(saved.map(\.splitText), ["分：好一", nil, "分：好三"])
    }

    func testAnEmptyReplyIsAFailureAndCodeFencesAreStripped() async throws {
        let app = AppModel()
        let (key, episodes) = fixture(app, texts: ["空的", "带围栏的"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0, 1], chat: { _, user in
            user.contains("空") ? "  \n " : "```\n场景：甲 日 内\n--- 00:00 - 00:30\n```"
        })
        await waitForAll(app, key: key, episodes: episodes)
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.failures.map(\.order), [1])
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[1].splitText, "场景：甲 日 内\n--- 00:00 - 00:30")
    }

    func testRerunningReplacesTheEarlierSplitAndAnEpisodeAlreadyRunningIsReportedNotStarted() async throws {
        let app = AppModel()
        let (key, episodes) = fixture(app, texts: ["原文"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, _ in "第一次" })
        await waitForAll(app, key: key, episodes: episodes)
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, _ in "第二次" })
        await waitForAll(app, key: key, episodes: episodes)
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[0].splitText, "第二次", "再点一次：换成新结果")

        // 上一轮还没跑完时不开新的一轮
        let gate = Counter()
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, _ in
            await gate.enter("x"); try? await Task.sleep(for: .milliseconds(80)); await gate.leave(); return "第三次"
        })
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, _ in "不该用到" })
        await waitForAll(app, key: key, episodes: episodes)
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[0].splitText, "第三次")
    }

    func testUnfencedOnlyStripsAWrappingFence() {
        XCTAssertEqual(SimplePipeline.unfenced("  普通文本\n"), "普通文本")
        XCTAssertEqual(SimplePipeline.unfenced("```text\n里面的内容\n```"), "里面的内容")
        XCTAssertEqual(SimplePipeline.unfenced("前文\n```\n代码\n```\n后文"), "前文\n```\n代码\n```\n后文", "中间有围栏不动")
    }
}
