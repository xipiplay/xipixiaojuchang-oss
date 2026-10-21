import XCTest
@testable import Xipixiaojuchang

private actor Messages {
    var users: [String] = []
    func add(_ user: String) { users.append(user) }
}

/// 分段命名（2026-10-11）：分割只管切，名字由单独的一步写在每一段的最上面
final class SegmentNamingTextTests: XCTestCase {
    private let headStyle = """
    === [00:00-00:30] ===
    △ 周承山站在后台
    [许曼]（挡住他）：你怎么又拿了冠军？
    === [00:30-01:00] ===
    [周承山]（抬眼）：我要求重新调查。
    """
    private let tailStyle = "场景：后台 夜 内\n[许曼]：你来了。\n--- 00:00 - 00:30\n[周承山]：嗯。\n--- 00:30 - 01:00"

    private func head(_ scene: String, _ roles: String = "甲", _ props: String = "无", _ present: String? = nil) -> SegmentNaming.Head {
        .init(scene: scene, roles: roles, props: props, present: present ?? roles)
    }

    // MARK: 头行 / 正文

    func testSplitHeadSeparatesTheFourNameLinesFromTheBodyWhereverTheyAre() {
        let text = "【场景】：后台 夜 内\n【角色】：周承山、许曼\n△ 走进后台\n[许曼]：你好\n【道具】：无\n【本段在场】：周承山"
        let parts = SplitSegments.splitHead(text)
        XCTAssertEqual(parts.head, "【场景】：后台 夜 内\n【角色】：周承山、许曼\n【道具】：无\n【本段在场】：周承山")
        XCTAssertEqual(parts.body, "△ 走进后台\n[许曼]：你好")
        XCTAssertEqual(SplitSegments.splitHead("△ 只有正文").head, "")
    }

    func testANamedSplitNeedsASceneOnEverySegmentAndAnUnnamedOneHasNone() {
        XCTAssertFalse(SplitSegments.isNamed(headStyle), "分割只管切之后的样子：一行头行都没有")
        XCTAssertFalse(SplitSegments.isNamed(""))
        XCTAssertTrue(SplitSegments.isNamed(tailStyle), "旧的分割自己带着场景行（后面的段沿用）也算")
        let silent = "=== [00:00-00:30] ===\n【场景】：老街 夜 外\n【角色】：无\n△ 风吹过\n=== [00:30-01:00] ===\n△ 灯灭了"
        XCTAssertTrue(SplitSegments.isNamed(silent), "没人的段（角色：无）也是已命名，不能永远显示待命名")
    }

    // MARK: 一段里有两个场景（放宽「换场必断段」，2026-10-11）

    func testASegmentCanCarryTwoScenesAndTheNextOneContinuesFromTheLastOne() {
        let text = """
        === [00:00-00:30] ===
        【场景】：颁奖礼·后台 夜 内、颁奖礼·颁奖台 夜 内
        【角色】：周承山四十岁时期、许曼、记者
        【道具】：奖杯
        【本段在场】：周承山四十岁时期、许曼
        △ 周承山走向前台
        === [00:30-01:00] ===
        【本段在场】：周承山四十岁时期、记者
        [记者]：您现在最想说什么？
        === [01:00-01:30] ===
        【场景】：江城赛车场·外围工作区 日 外
        【角色】：周承山
        △ 周承山坐在塑料凳上
        """
        let segments = SplitSegments.parse(text)
        XCTAssertEqual(segments.map(\.scene), ["颁奖礼·后台", "颁奖礼·颁奖台", "江城赛车场·外围工作区"], "scene = 这一段的第一个；没写的段接着上一段最后那个")
        XCTAssertEqual(segments[0].allScenes, ["颁奖礼·后台", "颁奖礼·颁奖台"])
        XCTAssertEqual(segments[1].allScenes, ["颁奖礼·颁奖台"])
        XCTAssertTrue(SplitSegments.isNamed(text))
        XCTAssertEqual(SplitSegments.sceneNames("A 日 内、B 夜 外，A 日 内"), ["A", "B"], "去掉日夜内外、同一个名字只留一个")
        // 之前各集用过的名字：两个场景都算
        let names = SegmentNaming.existingNames(in: [Episode(title: "第1集", text: "一", splitText: text), Episode(title: "第2集", text: "二")], before: 1)
        XCTAssertEqual(names.scenes, ["颁奖礼·后台", "颁奖礼·颁奖台", "江城赛车场·外围工作区"])
        // 只重推理这一段时补上的头行：两个场景都带
        var bare = segments[0]; bare.text = "△ 周承山走向前台"
        XCTAssertTrue(SplitSegments.standaloneText(for: bare, style: .head).contains("【场景】：颁奖礼·后台、颁奖礼·颁奖台"))
    }

    func testTwoScenesInOneNamingReplySurviveTheWholeRoundTrip() throws {
        let raw = "第1段\n【场景】：后台 夜 内、颁奖台 夜 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n\n第2段\n【场景】：颁奖台 夜 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲"
        let heads = try SegmentNaming.parse(raw, expected: 2)
        let merged = try XCTUnwrap(SegmentNaming.merge(heads, into: headStyle))
        let segments = SplitSegments.parse(merged)
        XCTAssertEqual(segments[0].allScenes, ["后台", "颁奖台"])
        XCTAssertEqual(segments[1].allScenes, ["颁奖台"])
    }

    // MARK: 读 AI 的回复

    func testParseReadsEachSegmentsFourLines() throws {
        let raw = """
        第1段
        【场景】：颁奖礼·后台 夜 内
        【角色】：周承山四十岁时期、许曼
        【道具】：复检申请副本
        【本段在场】：周承山四十岁时期、许曼

        第2段
        【场景】：江城赛车场·外围工作区 日 外
        【角色】：周承山
        【道具】：无
        【本段在场】：周承山
        """
        let heads = try SegmentNaming.parse(raw, expected: 2)
        XCTAssertEqual(heads.count, 2)
        XCTAssertEqual(heads[0], head("颁奖礼·后台 夜 内", "周承山四十岁时期、许曼", "复检申请副本"))
        XCTAssertEqual(heads[1].scene, "江城赛车场·外围工作区 日 外")
        XCTAssertEqual(heads[0].lines, ["【场景】：颁奖礼·后台 夜 内", "【角色】：周承山四十岁时期、许曼", "【道具】：复检申请副本", "【本段在场】：周承山四十岁时期、许曼"])
    }

    func testParseToleratesMarkdownNoiseAndCodeFences() throws {
        let raw = """
        ```
        **第1段**
        - **【场景】**：客厅 日 内
        - 【角色】：甲、乙
        - 【道具】：怀表
        - 【本段在场】：甲
        ```
        """
        let heads = try SegmentNaming.parse(raw, expected: 1)
        XCTAssertEqual(heads, [head("客厅 日 内", "甲、乙", "怀表", "甲")])
    }

    func testParseFillsWhatTheModelLeftOutAndRefusesWhatItCannotGuess() throws {
        // 没写场景：沿用上一段；没写在场：用角色；没写道具：无
        let raw = "第1段\n【场景】：客厅 日 内\n【角色】：甲、乙\n\n第2段\n【角色】：乙"
        let heads = try SegmentNaming.parse(raw, expected: 2)
        XCTAssertEqual(heads[1], head("客厅 日 内", "乙", "无", "乙"))
        // 第一段就没有场景：没法猜
        XCTAssertThrowsError(try SegmentNaming.parse("第1段\n【角色】：甲", expected: 1)) {
            XCTAssertTrue($0.localizedDescription.contains("第 1 段"), $0.localizedDescription)
        }
    }

    func testParseRefusesTheWrongNumberOfSegmentsOrNoSegmentsAtAll() {
        let two = "第1段\n【场景】：甲 日 内\n第2段\n【场景】：乙 日 内"
        XCTAssertThrowsError(try SegmentNaming.parse(two, expected: 3)) {
            XCTAssertTrue($0.localizedDescription.contains("这一集有 3 段"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try SegmentNaming.parse("第2段\n【场景】：甲 日 内\n第1段\n【场景】：乙 日 内", expected: 2), "段号乱序")
        XCTAssertThrowsError(try SegmentNaming.parse("好的，我明白了。", expected: 1)) {
            XCTAssertTrue($0.localizedDescription.contains("没有识别到分段"), $0.localizedDescription)
        }
    }

    // MARK: 写回

    func testMergePutsTheNamesAtTheTopOfEachSegmentInBothMarkerStyles() throws {
        let heads = [head("后台 夜 内", "周承山、许曼", "无", "周承山、许曼"), head("后台 夜 内", "周承山", "无", "周承山")]
        for text in [headStyle, tailStyle] {
            let merged = try XCTUnwrap(SegmentNaming.merge(heads, into: text))
            let segments = SplitSegments.parse(merged)
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments.map(\.scene), ["后台", "后台"])
            XCTAssertEqual(segments[0].roles, ["周承山", "许曼"])
            XCTAssertEqual(segments[1].roles, ["周承山"])
            // 头行在这一段文字的最上面，正文还在，时间标号还在
            XCTAssertTrue(segments[0].text.hasPrefix("【场景】：后台 夜 内\n【角色】：周承山、许曼\n【道具】：无\n【本段在场】：周承山、许曼"), segments[0].text)
            XCTAssertEqual(StoryboardInference.expectedBlockCount(in: merged), 2)
            XCTAssertEqual(segments.map(\.timeRange), ["00:00–00:30", "00:30–01:00"])
        }
        XCTAssertTrue(try XCTUnwrap(SegmentNaming.merge(heads, into: headStyle)).contains("[许曼]（挡住他）：你怎么又拿了冠军？"))
    }

    func testMergeReplacesOldHeadLinesAndRunningItTwiceChangesNothing() throws {
        let heads = [head("新场景 日 内"), head("新场景 日 内")]
        let once = try XCTUnwrap(SegmentNaming.merge(heads, into: tailStyle))
        XCTAssertFalse(once.contains("场景：后台"), "旧的场景行没了，不重复")
        XCTAssertEqual(once.components(separatedBy: "【场景】").count - 1, 2)
        XCTAssertEqual(SegmentNaming.merge(heads, into: once), once, "再命名一次，结果一样")
        XCTAssertNil(SegmentNaming.merge([head("甲 日 内")], into: headStyle), "段数对不上不写")
    }

    func testCombineJoinsTheTwoCellsAndSkipsEmptyOnes() {
        XCTAssertEqual(SegmentNaming.combine(head: "【场景】：甲", body: "△ 开门"), "【场景】：甲\n△ 开门")
        XCTAssertEqual(SegmentNaming.combine(head: "  ", body: "△ 开门"), "△ 开门")
        XCTAssertEqual(SegmentNaming.combine(head: "【场景】：甲", body: ""), "【场景】：甲")
    }

    // MARK: 带前面各集的名字

    func testExistingNamesComeOnlyFromEarlierEpisodesThatAreNamed() {
        let named = Episode(title: "第1集", text: "一", splitText: "【场景】：颁奖礼·后台 夜 内\n【角色】：周承山四十岁时期、许曼\n【道具】：奖杯\n【本段在场】：周承山四十岁时期\n△ 走\n--- 00:00 - 00:30")
        let unnamed = Episode(title: "第2集", text: "二", splitText: "△ 只有正文\n--- 00:00 - 00:30")
        let later = Episode(title: "第4集", text: "四", splitText: "【场景】：别处 日 内\n【角色】：路人乙\n△ x\n--- 00:00 - 00:30")
        let episodes = [named, unnamed, Episode(title: "第3集", text: "三"), later]
        let names = SegmentNaming.existingNames(in: episodes, before: 2)
        XCTAssertEqual(names.scenes, ["颁奖礼·后台"])
        XCTAssertEqual(names.roles, ["周承山四十岁时期"], "在场的才算（本段在场优先）")
        XCTAssertEqual(names.props, ["奖杯"])
        XCTAssertTrue(SegmentNaming.existingNames(in: episodes, before: 0).isEmpty)
        XCTAssertEqual(SegmentNaming.existingNames(in: episodes, before: 3).scenes, ["颁奖礼·后台"], "后面的集（第 4 集）不带")
    }

    func testTheRequestCarriesTheNamesTheOriginalAndEachSegmentsBodyWithoutOldHeadLines() {
        var episode = Episode(title: "第2集", text: "二十年前，周承山四十岁。", splitText: tailStyle)
        episode.splitText = "【场景】：旧场景 日 内\n【角色】：旧角色\n△ 走进\n--- 00:00 - 00:30\n△ 离开\n--- 00:30 - 01:00"
        let names = SegmentNaming.Names(scenes: ["颁奖礼·后台"], roles: ["周承山"], props: [])
        let message = SegmentNaming.userMessage(episode: episode, names: names, note: "周承山二十年前按四十岁时期")
        XCTAssertTrue(message.hasPrefix(RerunNote.opening + "\n周承山二十年前按四十岁时期\n"), message)
        XCTAssertTrue(message.contains("场景：颁奖礼·后台"))
        XCTAssertTrue(message.contains("角色：周承山"))
        XCTAssertTrue(message.contains("道具：（还没有）"))
        XCTAssertTrue(message.contains("二十年前，周承山四十岁。"), "原文也带上（判断年龄阶段用）")
        XCTAssertTrue(message.contains("第1段\n△ 走进"))
        XCTAssertTrue(message.contains("第2段\n△ 离开"))
        XCTAssertFalse(message.contains("旧场景"), "旧的头行不给 AI 看，免得它照抄")
    }

    // MARK: 设置

    func testSavedPromptsFromBeforeNamingStillLoad() throws {
        let old = #"{"split":"","segments":"我改过的分割","role":"我改过的角色","sceneProp":"","scene":"","prop":"","storyboard":"我改过的分镜"}"#
        let loaded = try JSONDecoder().decode(PipelinePromptSettings.self, from: Data(old.utf8))
        XCTAssertEqual(loaded.segments, "我改过的分割", "老存档里没有 naming 这一项，不能把整份都读丢")
        XCTAssertEqual(loaded.storyboard, "我改过的分镜")
        XCTAssertEqual(loaded.naming, "")
        XCTAssertEqual(PipelinePromptStore.effective(loaded.naming, fallback: PipelinePromptStore.namingDefault), PipelinePromptStore.namingDefault)
        XCTAssertTrue(PipelinePromptStore.namingDefault.contains("【本段在场】"), "内置的命名提示词在 Resources/Prompts/分段命名.txt")
    }
}

/// 一集一集串行命名，每一集带着前面各集已经用过的名字
@MainActor
final class SegmentNamingFlowTests: XCTestCase {
    private func makeProject(_ app: AppModel, episodes: [Episode]) -> String {
        let key = "naming-" + UUID().uuidString
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: episodes), for: key)
        return key
    }
    private func plain(_ title: String, text: String = "原文") -> Episode {
        Episode(title: title, text: text, splitText: "[甲]：你好。\n--- 00:00 - 00:30\n[乙]：再见。\n--- 00:30 - 01:00")
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        for record in app.jobCenter.records where record.projectKey == key { app.jobCenter.removeRecord(id: record.id) }
    }
    nonisolated private static func reply(scene: String, roles: String = "甲、乙") -> String {
        "第1段\n【场景】：\(scene)\n【角色】：\(roles)\n【道具】：无\n【本段在场】：\(roles)\n\n第2段\n【场景】：\(scene)\n【角色】：\(roles)\n【道具】：无\n【本段在场】：\(roles)"
    }

    func testEpisodesAreNamedInOrderAndTheSecondOneSeesTheFirstOnesNames() async throws {
        let app = AppModel(), captured = Messages()
        let key = makeProject(app, episodes: [plain("第1集"), plain("第2集")])
        defer { cleanup(app, key) }
        app.pipelineFlow.batchName(app: app, project: key, episodeIndices: [1, 0], chat: { _, user in
            await captured.add(user)
            return Self.reply(scene: "颁奖礼·后台 夜 内")
        })
        await app.pipelineFlow.waitForAll(project: key)

        let users = await captured.users
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].contains("场景：（还没有）"), "第 1 集：前面没有名字")
        XCTAssertTrue(users[1].contains("场景：颁奖礼·后台"), "第 2 集：带着第 1 集写好的名字")
        let archive = try XCTUnwrap(app.pipelineArchive(for: key))
        for episode in archive.episodes {
            XCTAssertTrue(SplitSegments.isNamed(episode.splitText ?? ""))
            XCTAssertEqual(SplitSegments.parse(episode.splitText ?? "").map(\.scene), ["颁奖礼·后台", "颁奖礼·后台"])
        }
        XCTAssertEqual(app.pipelineFlow.batches[key]?.succeeded, 2)
        XCTAssertEqual(app.pipelineFlow.batches[key]?.kind, .naming)
        XCTAssertTrue(app.jobCenter.records.filter { $0.projectKey == key && $0.title == "分段命名" }.allSatisfy { $0.state == .completed })
    }

    func testABadReplyLeavesTheEpisodeAloneAndStopsTheRest() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: [plain("第1集"), plain("第2集"), plain("第3集")])
        defer { cleanup(app, key) }
        let before = try XCTUnwrap(app.pipelineArchive(for: key)).episodes.map(\.splitText)
        app.pipelineFlow.batchName(app: app, project: key, episodeIndices: [0, 1, 2], chat: { _, user in
            user.contains("场景：（还没有）") ? Self.reply(scene: "客厅 日 内") : "好的，我明白了。"      // 第 2 集起 AI 开始说废话
        })
        await app.pipelineFlow.waitForAll(project: key)

        let archive = try XCTUnwrap(app.pipelineArchive(for: key))
        XCTAssertTrue(SplitSegments.isNamed(archive.episodes[0].splitText ?? ""), "第 1 集写好了，保留")
        XCTAssertEqual(archive.episodes[1].splitText, before[1], "第 2 集失败：文字一个字没动")
        XCTAssertEqual(archive.episodes[2].splitText, before[2])
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertEqual(state.failures.map(\.label), ["第 2 集"])
        XCTAssertEqual(state.skipped, 1, "停在第 2 集，第 3 集没轮到")
        XCTAssertTrue(state.failures[0].message.contains("没有识别到分段"), state.failures[0].message)
    }

    func testAnEpisodeWithoutASplitIsRefusedWithAClearReason() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: [Episode(title: "第1集", text: "原文")])
        defer { cleanup(app, key) }
        app.pipelineFlow.batchName(app: app, project: key, episodeIndices: [0], chat: { _, _ in XCTFail("没有分割不该发请求"); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertTrue(app.pipelineFlow.batches[key]?.failures.first?.message.contains("先点「分割」") == true)
    }

    func testStoryboardInferenceWaitsForTheNames() async throws {
        let app = AppModel()
        let key = makeProject(app, episodes: [plain("第1集")])
        defer { cleanup(app, key) }
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: { _, _ in XCTFail("没命名不该推理"); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        let failure = app.pipelineFlow.batches[key]?.failures.first?.message ?? ""
        XCTAssertTrue(failure.contains("还没有命名") && failure.contains("「命名」"), failure)
    }

    func testTheExternalCommandsKnowTheNewStep() throws {
        let app = AppModel()
        let key = makeProject(app, episodes: [plain("第1集")])
        defer { cleanup(app, key) }
        let infer = try JSONDecoder().decode(AgentCommand.self, from: Data(#"{"cmd":"infer","project":"\#(key)","episodes":[1],"approved":true}"#.utf8))
        let refused = AgentCommandRunner.run(infer, app: app, chat: { _, _ in "" })
        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message.contains("先发 name"), refused.message)

        let name = try JSONDecoder().decode(AgentCommand.self, from: Data(#"{"cmd":"name","project":"\#(key)","episodes":[1]}"#.utf8))
        let accepted = AgentCommandRunner.run(name, app: app, chat: { _, _ in Self.reply(scene: "客厅 日 内") })
        XCTAssertTrue(accepted.ok, accepted.message)
        XCTAssertTrue(accepted.message.contains("分段命名"))
    }
}
