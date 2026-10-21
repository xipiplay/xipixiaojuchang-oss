import XCTest
@testable import Xipixiaojuchang

private actor InferCounter {
    var running = 0, peak = 0, systems: [String] = [], users: [String] = []
    func enter(system: String, user: String) { running += 1; peak = max(peak, running); systems.append(system); users.append(user) }
    func leave() { running -= 1 }
}

/// 推理分镜（2026-10-07）：一集一集（串行）读「时长分割」，每个 30 秒段建一张生视频卡「分镜 集号-段号」；
/// 同场景时把上一集最后一段带给下一集，接着写站位。
@MainActor
final class BatchInferTests: XCTestCase {
    private nonisolated static let suffix = "必须按照镜头描述和角色台词生成。电影写实风格，无字幕，无音乐，角色说中文。"

    /// 一段 30 秒的分镜输出（头行 + 站位 + 镜头 + 后缀）
    private nonisolated static func block(scene: String = "客厅", tag: String) -> String {
        "[\(scene)][张三、李四][怀表]\n【角色初始站位与朝向】\(tag)：张三站在画面左侧。轴线锁定：画面左＝张三一侧。\n中景，\(tag)的镜头。\n\(suffix)"
    }
    private nonisolated static func output(scene: String = "客厅", tags: [String]) -> String {
        tags.map { block(scene: scene, tag: $0) }.joined(separator: "\n")
    }
    /// 一集的「时长分割」：n 段，每段以时间标号收尾
    private func splitText(scene: String = "客厅 日 内", segments n: Int) -> String {
        (0..<n).map { i in "场景：\(scene)\n△ 画面\(i)\n[张三]：台词\(i)\n--- 0\(i):00 - 0\(i):30" }.joined(separator: "\n")
    }

    private func fixture(_ app: AppModel, splits: [String?]) -> (String, [Episode]) {
        let key = "batch-infer-" + UUID().uuidString
        let episodes = splits.enumerated().map { Episode(title: "第\($0.offset + 1)集", text: "原文\($0.offset + 1)", splitText: $0.element) }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: episodes), for: key)
        return (key, episodes)
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.shots.removeAll { $0.projectKey == key }
    }
    private func run(_ app: AppModel, _ key: String, _ indices: [Int], chat: @escaping SimplePipeline.Chat) async {
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: indices, chat: chat)
        await app.pipelineFlow.waitForAll(project: key)
    }
    private func titles(_ app: AppModel, _ key: String) -> [String] {
        app.shots.filter { $0.projectKey == key }.map { app.numbering(of: $0).title }
    }

    // MARK: 流程与建卡

    func testEpisodesRunOneByOneAndEachSegmentBecomesACardNumberedEpisodeDashSegment() async throws {
        let app = AppModel(), counter = InferCounter()
        let (key, _) = fixture(app, splits: [splitText(segments: 2), splitText(segments: 3)])
        defer { cleanup(app, key) }
        await run(app, key, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user)
            try? await Task.sleep(for: .milliseconds(30))
            await counter.leave()
            let n = user.contains("画面2") ? 3 : 2
            return Self.output(tags: (1...n).map { "段\($0)" })
        })

        let peak = await counter.peak, systems = await counter.systems
        XCTAssertEqual(peak, 1, "一集一集跑，不并发")
        XCTAssertTrue(systems.allSatisfy { $0.contains(PipelinePromptStore.shotsPrompt.prefix(40)) }, "用的是设置里的分镜提示词")
        XCTAssertEqual(titles(app, key), ["分镜1-1", "分镜1-2", "分镜2-1", "分镜2-2", "分镜2-3"])
        let shots = app.shots.filter { $0.projectKey == key }
        XCTAssertEqual(shots.map { app.numbering(of: $0).filePrefix }, ["1-1", "1-2", "2-1", "2-2", "2-3"], "文件名前缀 集号-段号，版本号接在后面")
        XCTAssertTrue(shots[0].prompt.contains("段1的镜头") && shots[0].prompt.hasPrefix("[客厅]"))
        let saved = try XCTUnwrap(app.pipelineArchive(for: key)).episodes
        XCTAssertEqual(saved.map { $0.shotIDs?.count }, [2, 3])
        XCTAssertEqual(saved[1].shotIDs, Array(shots[2...]).map(\.id))
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.kind, .infer)
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 2)
        XCTAssertEqual(state.created, 5)
        XCTAssertTrue(state.failures.isEmpty)
    }

    func testFirstEpisodeGetsTheMarkerNoteAndItsSplitTextAndNothingElse() async throws {
        let app = AppModel(), counter = InferCounter()
        let text = splitText(segments: 1)
        let (key, _) = fixture(app, splits: [text])
        defer { cleanup(app, key) }
        await run(app, key, [0], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.output(tags: ["甲"])
        })
        let users = await counter.users
        XCTAssertEqual(users, [StoryboardInference.scriptSection(text)])
        XCTAssertTrue(users[0].hasSuffix("【本集剧本（按它输出分镜）】\n" + text), "这一集的时长分割原样放在最后")
        XCTAssertTrue(users[0].hasPrefix("【时间标号说明】下面的本集剧本一共 1 段。"))
        XCTAssertFalse(users[0].contains("上一集"), "第一集没有上一集，也没有承接说明")
    }

    /// 2026-10-09：智能体老把「内容 + 标号」读成「标号 + 内容」，最后一个标号后面「没有内容」就报失败
    func testTheMarkerNoteSaysWhereTheMarkerSitsHowManyBlocksAndNotToMerge() {
        let text = splitText(segments: 5)
        let note = StoryboardInference.scriptSection(text)
        XCTAssertTrue(note.contains("一共 5 段"))
        XCTAssertTrue(note.contains("写在它上面那一段的末尾"))
        XCTAssertTrue(note.contains("不是下一段的标题"))
        XCTAssertTrue(note.contains("最后一个标号后面没有内容是正常的"))
        XCTAssertTrue(note.contains("恰好 5 块"))
        XCTAssertTrue(note.contains("每个 30 秒段单独一块，不得合并"))
        XCTAssertTrue(note.hasSuffix(text))
        // 带上一集结尾时说明也在，并且在【本集剧本】前面
        let withPrevious = StoryboardInference.userMessage(splitText: text, previousPrompt: "[客厅 日 内][张三][手机]\n站位")
        XCTAssertTrue(withPrevious.contains("【承接说明】"))
        XCTAssertLessThan(try! XCTUnwrap(withPrevious.range(of: "【时间标号说明】")).lowerBound,
                          try! XCTUnwrap(withPrevious.range(of: "【本集剧本（按它输出分镜）】")).lowerBound)
    }

    func testNoMarkersMeansNoNoteBecauseThereIsNothingToCount() {
        let text = "场景：客厅 日 内\n△ 画面\n[张三]：台词"
        XCTAssertEqual(StoryboardInference.scriptSection(text), "【本集剧本（按它输出分镜）】\n" + text)
    }

    func testCountMismatchMessageSaysWhetherBlocksAreMissingOrExtra() {
        let fewer = StoryboardInference.countMismatchMessage(got: 4, expected: 5)
        XCTAssertTrue(fewer.contains("只写了 4 块") && fewer.contains("有 5 段") && fewer.contains("少了 1 块"), fewer)
        XCTAssertTrue(fewer.contains("并成了一块"), "常见原因是合并，不再一口咬定是截断")
        let more = StoryboardInference.countMismatchMessage(got: 6, expected: 5)
        XCTAssertTrue(more.contains("写了 6 块") && more.contains("多了 1 块") && more.contains("恰好 5 块"), more)
    }

    // MARK: 衔接

    func testSameSceneEpisodeReceivesThePreviousLastBlockWithoutTheSuffixLine() async throws {
        let app = AppModel(), counter = InferCounter()
        let (key, _) = fixture(app, splits: [splitText(scene: "客厅 日 内", segments: 2), splitText(scene: "客厅 日 内", segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.output(tags: user.contains("画面1") ? ["一甲", "一乙"] : ["二甲"])
        })
        let users = await counter.users
        XCTAssertEqual(users.count, 2)
        XCTAssertFalse(users[0].contains("上一集"), "第一集没有上一集")
        XCTAssertTrue(users[1].contains("一乙：张三站在画面左侧"), "带的是上一集的最后一段")
        XCTAssertFalse(users[1].contains("一甲：张三站在画面左侧"), "不是第一段")
        XCTAssertFalse(users[1].contains("必须按照镜头描述和角色台词生成"), "后缀那一行不带")
        XCTAssertTrue(users[1].contains("【承接说明】"))
        XCTAssertTrue(users[1].hasSuffix(splitText(scene: "客厅 日 内", segments: 1)), "这一集的时长分割原样放在最后")
    }

    func testClearlyDifferentSceneGetsNoHandoff() async throws {
        let app = AppModel(), counter = InferCounter()
        let second = splitText(scene: "码头 夜 外", segments: 1)
        let (key, _) = fixture(app, splits: [splitText(scene: "客厅 日 内", segments: 1), second])
        defer { cleanup(app, key) }
        await run(app, key, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.output(scene: user.contains("码头") ? "码头" : "客厅", tags: ["段"])
        })
        let users = await counter.users
        XCTAssertEqual(users[1], StoryboardInference.scriptSection(second), "场景明显不同：不带上一集的结尾（只有时间标号说明 + 这一集）")
        XCTAssertFalse(users[1].contains("上一集最后一段"))
    }

    func testHandoffReadsTheCardAsTheUserLastEditedIt() async throws {
        let app = AppModel(), counter = InferCounter()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), splitText(segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["原来的"]) })
        let card = try XCTUnwrap(app.shots.first { $0.projectKey == key })
        app.updateShotPrompt(card.id, prompt: "[客厅][张三][怀表]\n用户改过：张三已经坐到了沙发上。")

        await run(app, key, [1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.output(tags: ["二"])
        })
        let users = await counter.users
        XCTAssertTrue(users[0].contains("用户改过：张三已经坐到了沙发上"), "只跑第 2 集时，也从第 1 集现在的卡读结尾站位")
        XCTAssertFalse(users[0].contains("原来的"))
    }

    func testNoHandoffWhenThePreviousEpisodeWasNeverInferred() async throws {
        let app = AppModel(), counter = InferCounter()
        let text = splitText(segments: 1)
        let (key, _) = fixture(app, splits: [text, text])
        defer { cleanup(app, key) }
        await run(app, key, [1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.output(tags: ["二"])
        })
        let users = await counter.users
        XCTAssertEqual(users, [StoryboardInference.scriptSection(text)], "上一集没推理过：没有承接，只有时间标号说明 + 这一集")
        XCTAssertEqual(titles(app, key), ["分镜2-1"], "编号跟集号走，不是按建出来的先后")
    }

    func testSceneComparisonIgnoresDayNightAndInteriorExteriorMarks() {
        XCTAssertFalse(StoryboardInference.clearlyDifferentScene(previousPrompt: "[蕴古斋前柜][a][b]\n…", splitText: "场景：蕴古斋前柜 日 内\n△x"))
        XCTAssertFalse(StoryboardInference.clearlyDifferentScene(previousPrompt: "[蕴古斋前柜 日内][a][b]\n…", splitText: "场景：蕴古斋前柜 夜 内\n△x"))
        XCTAssertTrue(StoryboardInference.clearlyDifferentScene(previousPrompt: "[蕴古斋前柜][a][b]\n…", splitText: "场景：城西码头 夜 外\n△x"))
        XCTAssertFalse(StoryboardInference.clearlyDifferentScene(previousPrompt: "[蕴古斋前柜][a][b]\n…", splitText: "△没有场景行"), "认不出来就当可能相同，交给 AI")
    }

    // MARK: 切段与核对

    func testBlocksAreCutAtTheThreeBracketHeaderAndPrefaceAndSeparatorsAreDropped() {
        let raw = "好的，以下是分镜：\n```\n" + Self.output(tags: ["甲", "乙"]) + "\n---\n```"
        let blocks = StoryboardInference.blocks(from: raw)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks[0].hasPrefix("[客厅][张三、李四][怀表]"))
        XCTAssertTrue(blocks[1].hasSuffix(Self.suffix), "段末的分隔线去掉，后缀行保留")
        XCTAssertFalse(blocks[0].contains("以下是分镜"))
        XCTAssertEqual(StoryboardInference.blocks(from: "没有头行的一段话"), [])
    }

    func testExpectedBlockCountFollowsTheTimeMarkers() {
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: splitText(segments: 3)), 3)
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: "场景：A\n△x\n--- 00:00 - 00:30\n场景：A\n△y"), 2, "最后一段没写标号也算一段")
        XCTAssertNil(StoryboardInference.expectedBlockCount(in: "场景：A\n△x"), "一个标号都没有就不核对")
        for ending in ["**结束。**", "（完）", "—— 本集完 ——", "END", "End.", "【全剧终】", "未完待续……"] {
            XCTAssertEqual(StoryboardInference.expectedBlockCount(in: splitText(segments: 3) + "\n" + ending), 3,
                           "最后一个标号之后的收尾标记「\(ending)」不算一段")
        }
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: splitText(segments: 3) + "\n场景：B\n△最后一段没写标号"), 4, "真正的内容照旧算一段")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: splitText(segments: 2) + "\n**结束。**\n"), 2)
    }

    // MARK: 失败

    func testWrongSegmentCountFailsTheEpisodeCreatesNoCardsAndStopsTheChain() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), splitText(segments: 3), splitText(segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [0, 1, 2], chat: { _, user in
            Self.output(tags: user.contains("画面2") ? ["只有一段"] : ["甲"])      // 第 2 集该有 3 段，只回了 1 段
        })
        XCTAssertEqual(titles(app, key), ["分镜1-1"], "第 1 集的卡保留；第 2 集失败不建卡；第 3 集没跑")
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertEqual(state.failures.map(\.label), ["第 2 集"])
        XCTAssertTrue(try XCTUnwrap(state.failures.first).message.contains("3 段"))
        XCTAssertEqual(state.skipped, 1)
        XCTAssertNil(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[1].shotIDs)
    }

    func testEpisodeWithoutSplitTextStopsTheChainWithAClearReason() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), nil, splitText(segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [0, 1, 2], chat: { _, _ in Self.output(tags: ["甲"]) })
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.failures, [.init(order: 2, label: "第 2 集", message: "这一集还没有时长分割，先点「批量分割」")])
        XCTAssertEqual(state.skipped, 1)
        XCTAssertEqual(titles(app, key), ["分镜1-1"])
    }

    func testStoppingFromTheTaskDrawerStopsTheChainAndKeepsFinishedCards() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), splitText(segments: 1), splitText(segments: 1)])
        defer { cleanup(app, key) }
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0, 1, 2], chat: { _, user in
            if user.contains("画面0") && user.contains("[张三]：台词0") && !user.contains("上一集") { return Self.output(tags: ["甲"]) }
            try await Task.sleep(for: .seconds(5))          // 第 2 集卡住，等被停止
            return Self.output(tags: ["乙"])
        })
        for _ in 0..<200 where app.shots.filter({ $0.projectKey == key }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        app.pipelineFlow.cancel(project: key, episode: nil, slot: "infer")
        for _ in 0..<300 where app.pipelineFlow.batches[key]?.finished != true { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(titles(app, key), ["分镜1-1"])
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertEqual(state.failures.map(\.message), ["已停止"])
        XCTAssertEqual(state.skipped, 1)
    }

    func testANewRunIsRefusedWhileOneIsStillRunning() async throws {
        let app = AppModel(), counter = InferCounter()
        let (key, _) = fixture(app, splits: [splitText(segments: 1)])
        defer { cleanup(app, key) }
        let slow: SimplePipeline.Chat = { system, user in
            await counter.enter(system: system, user: user)
            try? await Task.sleep(for: .milliseconds(80))
            await counter.leave()
            return Self.output(tags: ["甲"])
        }
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: slow)
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: slow)
        await app.pipelineFlow.waitForAll(project: key)
        let users = await counter.users
        XCTAssertEqual(users.count, 1)
    }

    // MARK: 重推与卡片位置

    func testRerunOverwritesPromptsByPositionAndKeepsCardsIDsAndNumbers() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 2)])
        defer { cleanup(app, key) }
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["旧一", "旧二"]) })
        let before = app.shots.filter { $0.projectKey == key }.map(\.id)

        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["新一", "新二"]) })
        let after = app.shots.filter { $0.projectKey == key }
        XCTAssertEqual(after.map(\.id), before, "同一批卡，不是新建")
        XCTAssertTrue(after[0].prompt.contains("新一") && after[1].prompt.contains("新二"))
        XCTAssertEqual(titles(app, key), ["分镜1-1", "分镜1-2"])
    }

    func testRerunWithMoreSegmentsAppendsAndWithFewerLeavesTheExtraCardsInPlace() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 2)])
        defer { cleanup(app, key) }
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["一", "二"]) })

        // 用户把时长分割改成 3 段再推：追加第 3 张
        var archive = try XCTUnwrap(app.pipelineArchive(for: key))
        archive.episodes[0].splitText = splitText(segments: 3)
        app.savePipelineArchive(archive, for: key)
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["一", "二", "三"]) })
        XCTAssertEqual(titles(app, key), ["分镜1-1", "分镜1-2", "分镜1-3"])

        // 又改回 1 段：多出来的两张卡留着（不删、不重排），只是不再属于这一集
        archive = try XCTUnwrap(app.pipelineArchive(for: key))
        archive.episodes[0].splitText = splitText(segments: 1)
        app.savePipelineArchive(archive, for: key)
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["只剩一段"]) })
        XCTAssertEqual(titles(app, key), ["分镜1-1", "分镜1-2", "分镜1-3"])
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[0].shotIDs?.count, 1)
        XCTAssertTrue(try XCTUnwrap(app.shots.first { $0.projectKey == key }).prompt.contains("只剩一段"))
    }

    func testANumberAlreadyTakenByAnotherCardIsNotOverwrittenOrReused() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), splitText(segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["一"]) })
        // 手动在末尾新增一张分镜：编号接着排成 2-1
        let manual = app.addShot(projectKey: key)
        XCTAssertEqual(app.numbering(of: try XCTUnwrap(app.shots.first { $0.id == manual })), ShotNumbering(a: 2, b: 1))

        await run(app, key, [1], chat: { _, _ in Self.output(tags: ["二"]) })
        let numbers = app.shots.filter { $0.projectKey == key }.map { app.numbering(of: $0).filePrefix }
        XCTAssertEqual(Set(numbers).count, numbers.count, "文件名前缀不能重复，否则会静默覆盖已生成的视频")
        XCTAssertEqual(Set(numbers), ["1-1", "2-1", "2-2"], "新卡改用这一集下一个空的段号")
        XCTAssertEqual(try XCTUnwrap(app.shots.first { $0.id == manual }).prompt, "", "手动建的卡不被覆盖")
    }

    func testCardsAreInsertedInEpisodeOrderEvenWhenEpisodesAreInferredOutOfOrder() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, splits: [splitText(segments: 1), splitText(segments: 1), splitText(segments: 1)])
        defer { cleanup(app, key) }
        await run(app, key, [2], chat: { _, _ in Self.output(tags: ["三"]) })
        await run(app, key, [0], chat: { _, _ in Self.output(tags: ["一"]) })
        await run(app, key, [1], chat: { _, _ in Self.output(tags: ["二"]) })
        XCTAssertEqual(titles(app, key), ["分镜1-1", "分镜2-1", "分镜3-1"])
    }
}

/// 2026-10-10 用户：任务抽屉里推理分镜显示的是整部剧本，要和分割一样每一集一行。
@MainActor
final class BatchInferJobRowsTests: XCTestCase {
    private func block(_ tag: String) -> String {
        "[客厅][张三][怀表]\n【角色初始站位与朝向】\(tag)：张三站在画面左侧。轴线锁定：画面左＝张三一侧。\n中景，\(tag)的镜头。\n必须按照镜头描述和角色台词生成。电影写实风格，无字幕，无音乐，角色说中文。"
    }

    func testEachEpisodeGetsItsOwnRowAndTheWholeBatchRowIsHiddenOnceItIsDone() async throws {
        let app = AppModel()
        let key = "infer-rows-" + UUID().uuidString
        let split = "场景：客厅 日 内\n△ 画面\n[张三]：台词\n--- 00:00 - 00:30"
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: (1...3).map {
            Episode(title: "第\($0)集", text: "原文\($0)", splitText: split)
        }), for: key)
        defer { app.removePipelineArchive(for: key); app.shots.removeAll { $0.projectKey == key } }
        let block = block("段1")

        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0, 1, 2], chat: { _, _ in block })
        await app.pipelineFlow.waitForAll(project: key)

        let records = app.jobCenter.records.filter { $0.projectKey == key && $0.title == "推理分镜" }
        let perEpisode = records.filter { $0.episodeID != nil }
        XCTAssertEqual(perEpisode.count, 3, "每一集一行")
        XCTAssertTrue(perEpisode.allSatisfy { $0.state == .completed })
        XCTAssertTrue(perEpisode.allSatisfy { $0.slot == "infer" }, "每一集那一行的「停止」要能停掉整批")
        let archive = try XCTUnwrap(app.pipelineArchive(for: key))
        XCTAssertEqual(Set(perEpisode.compactMap(\.episodeID)), Set(archive.episodes.map(\.id)))
        let driver = try XCTUnwrap(records.first { $0.episodeID == nil })
        XCTAssertEqual(driver.state, .completed)
        XCTAssertTrue(JobCenter.hidesBatchDriver(driver, among: app.jobCenter.records), "整批那一行不显示，每一集一行就够了")
        var running = driver; running.state = .running
        XCTAssertTrue(JobCenter.hidesBatchDriver(running, among: app.jobCenter.records), "跑着的时候也不显示（「停止」在每一集那一行上）")
        let legacy = JobRecord(id: "legacy", kind: .ai, projectKey: key, title: "推理分镜", episodeID: nil, slot: "infer",
                               state: .failed, note: "旧版的失败原因", createdAt: driver.createdAt.addingTimeInterval(-3600),
                               updatedAt: driver.createdAt.addingTimeInterval(-3500))
        XCTAssertFalse(JobCenter.hidesBatchDriver(legacy, among: app.jobCenter.records), "旧版留下的整批行没有每一集的行，照常显示")
        let other = JobRecord(id: "other", kind: .ai, projectKey: key + "x", title: "推理分镜", episodeID: nil, slot: "infer",
                              state: .running, note: nil, createdAt: driver.createdAt, updatedAt: driver.updatedAt)
        XCTAssertFalse(JobCenter.hidesBatchDriver(other, among: app.jobCenter.records), "别的项目的每一集行不算")
        app.jobCenter.removeRecord(id: driver.id)
        for r in perEpisode { app.jobCenter.removeRecord(id: r.id) }
    }

    func testAFailedEpisodeRowKeepsItsReason() async throws {
        let app = AppModel()
        let key = "infer-rows-fail-" + UUID().uuidString
        let split = "场景：客厅 日 内\n△ 画面\n[张三]：台词\n--- 00:00 - 00:30"
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: (1...2).map {
            Episode(title: "第\($0)集", text: "原文\($0)", splitText: split)
        }), for: key)
        defer { app.removePipelineArchive(for: key); app.shots.removeAll { $0.projectKey == key } }
        let good = block("段1")
        let counter = InferCounter()

        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user)
            await counter.leave()
            return await counter.users.count == 1 ? good : "我不会"        // 第二集：回复里没有分镜
        })
        await app.pipelineFlow.waitForAll(project: key)

        let perEpisode = app.jobCenter.records.filter { $0.projectKey == key && $0.title == "推理分镜" && $0.episodeID != nil }
            .sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(perEpisode.map(\.state), [.completed, .failed])
        XCTAssertTrue(perEpisode[1].note?.contains("没有识别到分镜") == true, perEpisode[1].note ?? "")
        for r in app.jobCenter.records where r.projectKey == key { app.jobCenter.removeRecord(id: r.id) }
    }

    /// 左栏任务图标的数字：一批推理分镜只算一个（正在做的那一集），不把整批那一行也算上
    func testSidebarBadgeCountsOneBatchOnce() {
        let app = AppModel()
        let key = "infer-badge-" + UUID().uuidString
        app.currentProjectKey = key
        defer { for r in app.jobCenter.records where r.projectKey == key { app.jobCenter.removeRecord(id: r.id) } }
        XCTAssertEqual(app.activeTaskCount, 0)
        let driver = app.jobCenter.aiStarted(projectKey: key, episodeID: nil, title: "推理分镜", slot: "infer")
        XCTAssertEqual(app.activeTaskCount, 1, "刚起步、还没建每一集的行时，整批那一行是唯一看得到的")
        let episode = app.jobCenter.aiStarted(projectKey: key, episodeID: UUID(), title: "推理分镜", slot: "infer")
        XCTAssertEqual(app.activeTaskCount, 1, "建了这一集的行以后，一批只算一个")
        app.jobCenter.aiFinished(episode, state: .completed, note: nil)
        app.jobCenter.aiFinished(driver, state: .completed, note: nil)
        XCTAssertEqual(app.activeTaskCount, 0)
    }
}
