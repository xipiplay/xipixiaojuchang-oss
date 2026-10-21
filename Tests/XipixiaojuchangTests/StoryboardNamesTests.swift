import XCTest
@testable import Xipixiaojuchang

/// 提取素材的名字取自分镜头行（2026-10-09）：从头行收集名字、挑证据、分批、拼消息、核对结果——不碰 AI 的那部分。
final class StoryboardNamesTests: XCTestCase {
    private typealias Names = StoryboardNames

    // MARK: 头行 → 名字

    func testHeadLineSplitsEachGroupIntoNames() throws {
        let head = try XCTUnwrap(Names.head(of: "[蕴古斋前柜][沈惊澜、谢玄寂，老掌柜][怀表,玉佩；账本]\n【角色初始站位与朝向】……"))
        XCTAssertEqual(head.scenes, ["蕴古斋前柜"])
        XCTAssertEqual(head.roles, ["沈惊澜", "谢玄寂", "老掌柜"])
        XCTAssertEqual(head.props, ["怀表", "玉佩", "账本"])
    }

    func testHeadLineNamesLoseTheMaterialTokensThatMatchingInserted() throws {
        // 匹配素材会在名字前插「图N」；再提取时读到的名字不能带着它
        let head = try XCTUnwrap(Names.head(of: "[图1蕴古斋前柜][图2沈惊澜、图3谢玄寂][视频1怀表]"))
        XCTAssertEqual(head.scenes, ["蕴古斋前柜"])
        XCTAssertEqual(head.roles, ["沈惊澜", "谢玄寂"])
        XCTAssertEqual(head.props, ["怀表"])
    }

    func testPlaceholdersAndBlankGroupsAreNotNames() throws {
        let head = try XCTUnwrap(Names.head(of: "[客厅][张三、无][无]"))
        XCTAssertEqual(head.roles, ["张三"])
        XCTAssertEqual(head.props, [])
        XCTAssertEqual(try XCTUnwrap(Names.head(of: "[客厅][ ][ ]")).props, [])
        XCTAssertEqual(try XCTUnwrap(Names.head(of: "[客厅][张三、张三][怀表、怀表]")).roles, ["张三"], "同一个名字写两遍只算一个")
    }

    func testSceneNamesDropTheTimeAndInteriorMarkers() throws {
        XCTAssertEqual(try XCTUnwrap(Names.head(of: "[蕴古斋前柜 日 内][张三][ ]")).scenes, ["蕴古斋前柜"])
        XCTAssertEqual(try XCTUnwrap(Names.head(of: "[客厅、阳台][张三][ ]")).scenes, ["客厅", "阳台"], "一段跨两个空间：两个场景")
        XCTAssertEqual(try XCTUnwrap(Names.head(of: "[日][张三][ ]")).scenes, ["日"], "只剩标记就原样留着，不凭空丢名字")
    }

    func testOnlyTheFirstNonBlankLineIsTheHeadLine() {
        XCTAssertNotNil(Names.head(of: "\n  \n[客厅][张三][怀表]\n正文"))
        XCTAssertNil(Names.head(of: "正文里有 [客厅][张三][怀表]"), "头行必须是第一行")
        XCTAssertNil(Names.head(of: "[客厅][张三]\n只有两组"))
        XCTAssertNil(Names.head(of: ""))
    }

    // MARK: 收集

    func testCollectKeepsFirstSeenOrderMergesShotsAndSeparatesKinds() {
        let collected = Names.collect([
            (episode: 2, prompts: ["[院子][李四][钥匙]", ""]),                                   // 空串 = 卡被删了，段号不错位
            (episode: 1, prompts: ["[客厅][张三、李四][怀表]", "[客厅][张三][ ]", "[院子][张三][怀表]"]),
        ])
        XCTAssertEqual(collected[.scene]?.map(\.name), ["客厅", "院子"], "按集号升序、段序、头行里的先后")
        XCTAssertEqual(collected[.role]?.map(\.name), ["张三", "李四"])
        XCTAssertEqual(collected[.prop]?.map(\.name), ["怀表", "钥匙"])
        let living = collected[.scene]?[0]
        XCTAssertEqual(living?.shots.map { "\($0.episode)-\($0.segment)" }, ["1-1", "1-2"])
        XCTAssertEqual(living?.episodes, [1])
        let lee = collected[.role]?[1]
        XCTAssertEqual(lee?.shots.map { "\($0.episode)-\($0.segment)" }, ["1-1", "2-1"])
        XCTAssertEqual(lee?.episodes, [1, 2])
    }

    func testCollectOfNothingIsEmptyForEveryKind() {
        let collected = Names.collect([])
        for kind in PipelineFlow.ExtractionKind.allCases { XCTAssertEqual(collected[kind]?.count, 0) }
    }

    // MARK: 证据

    private func entry(_ name: String, shots: Int) -> Names.Entry {
        Names.Entry(name: name, shots: (1...shots).map { Names.Shot(episode: $0, segment: 1, prompt: "[\(name)][甲][乙]\n第 \($0) 段") })
    }

    func testSceneShotsAreSpreadEvenlyIncludingTheFirstAndTheLast() {
        XCTAssertEqual(Names.sceneShots(of: entry("A", shots: 3)).map(\.episode), [1, 2, 3], "不多就全带")
        XCTAssertEqual(Names.sceneShots(of: entry("A", shots: 4)).map(\.episode), [1, 2, 3, 4])
        XCTAssertEqual(Names.sceneShots(of: entry("A", shots: 100)).map(\.episode), [1, 34, 67, 100], "多了均匀挑，首尾都有：场景后来有变化也看得到")
        XCTAssertEqual(Names.sceneShots(of: entry("A", shots: 9), limit: 1).map(\.episode), [1])
    }

    func testEvidenceTextDropsTheSuffixLineAndTheMaterialTokensAndCapsTheLength() {
        let prompt = "[图1客厅][图2张三][ ]\n【角色初始站位与朝向】张三站着。\n中景，茶几。\n必须按照镜头描述和角色台词生成。电影写实风格。"
        XCTAssertEqual(Names.evidenceText(of: prompt), "[客厅][张三][ ]\n【角色初始站位与朝向】张三站着。\n中景，茶几。")
        let long = "[客厅][张三][ ]\n" + String(repeating: "长", count: 5000)
        let text = Names.evidenceText(of: long)
        XCTAssertEqual(text.count, Names.shotCharacterLimit + 2)
        XCTAssertTrue(text.hasSuffix("……"))
    }

    // MARK: 分批

    func testNameBatchesHoldAtMostTwentyNamesInTheirOriginalOrder() {
        let entries = (1...45).map { entry("人物\($0)", shots: 1) }
        let batches = Names.nameBatches(entries)
        XCTAssertEqual(batches.map(\.count), [20, 20, 5])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.name), entries.map(\.name))
        XCTAssertEqual(Names.nameBatches([]).count, 0)
    }

    func testSceneBatchesRespectBothTheNameLimitAndTheEvidenceBudget() {
        XCTAssertEqual(Names.sceneBatches((1...30).map { entry("场景\($0)", shots: 1) }).map(\.count), [12, 12, 6], "名字最多 12 个一批")
        // 每个场景 4 段、每段 3000 字 ≈ 12000 字：预算 40000，一批放 3 个
        let heavy = (1...7).map { name -> Names.Entry in
            Names.Entry(name: "大场景\(name)", shots: (1...4).map { Names.Shot(episode: $0, segment: 1, prompt: "[大场景\(name)][甲][乙]\n" + String(repeating: "景", count: 3500)) })
        }
        let batches = Names.sceneBatches(heavy)
        XCTAssertEqual(batches.map(\.count), [3, 3, 1])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.name), heavy.map(\.name))
        // 一个场景自己就超预算：也单独成一批，不丢
        let giant = Names.Entry(name: "巨大场景", shots: (1...4).map { Names.Shot(episode: $0, segment: 1, prompt: "[巨][甲][乙]\n" + String(repeating: "景", count: 20000)) })
        XCTAssertEqual(Names.sceneBatches([giant]).map(\.count), [1])
    }

    // MARK: 消息

    func testRoleMessageListsNamesRulesAndTheSourceAndMarksExistingOnes() {
        let entries = [Names.Entry(name: "张三", shots: [.init(episode: 1, segment: 1, prompt: "x"), .init(episode: 3, segment: 2, prompt: "x")]),
                       Names.Entry(name: "李四", shots: [.init(episode: 3, segment: 1, prompt: "x")])]
        let existing = [Names.Existing(base: "张三", line: "第1集的张三：灰西装"), Names.Existing(base: "路人甲", line: "第1集的路人甲：无关")]
        let message = Names.message(kind: .role, entries: entries, existing: existing, source: "第1集\n原文")
        XCTAssertTrue(message.hasPrefix("【要提取的角色——名称已经定好，来自分镜头行 [场景][角色][道具]】\n只为下面这些名字写，名字一字不改"), message)
        XCTAssertTrue(message.contains("1. 张三（第1、3集出场；已有）\n2. 李四（第3集出场）"), message)
        XCTAssertTrue(message.contains("角色的描述从下面的原文里找"), message)
        XCTAssertTrue(message.contains("单独写一行「参考：周承山」"), "换了名字的变化版要让 AI 写参考行\n" + message)
        XCTAssertTrue(message.contains("【项目里已经提取过的角色（供对账和保持一致）】\n第1集的张三：灰西装\n名单里标「已有」的：本次原文里没有变化的，不要输出完整块，只单独写一行「沿用：<名字>」"), message)
        XCTAssertFalse(message.contains("路人甲"), "不在名单里的已有卡不带")
        XCTAssertTrue(message.hasSuffix("【原文（描述从这里找）】\n第1集\n原文"), message)
    }

    func testMessageWithoutExistingCardsHasNoRosterSection() {
        let message = Names.message(kind: .prop, entries: [entry("怀表", shots: 1)], existing: [], source: "第1集\n原文")
        XCTAssertFalse(message.contains("前面各集已经提取过的"))
        XCTAssertFalse(message.contains("沿用："), "没有已有的卡：不带对账/沿用那一段")
        XCTAssertFalse(message.contains("；已有）"), "没有已有的卡：名单里不标")
        XCTAssertTrue(message.contains("1. 怀表（第1集出场）"))
    }

    func testSceneMessageTellsTheModelToWriteOnlyTheSpaceAndCarriesTheShots() {
        let message = Names.message(kind: .scene, entries: [entry("客厅", shots: 2)], existing: [], source: "不该出现")
        XCTAssertTrue(message.contains("只写场景本身（空间结构、陈设、固定设施、材质、光线和时间），分镜里的人物、动作、台词、运镜都不要写"), message)
        XCTAssertTrue(message.contains("【各场景用到它的分镜（场景描述从这里找）】\n■ 客厅（第1、2集，共 2 段分镜）\n〔第1集 第1段〕\n[客厅][甲][乙]\n第 1 段\n〔第2集 第1段〕"), message)
        XCTAssertFalse(message.contains("不该出现"))
    }

    func testEpisodeListIsShortenedWhenLong() {
        XCTAssertEqual(Names.episodeList([1, 2, 5]), "第1、2、5集")
        XCTAssertEqual(Names.episodeList(Array(1...12)), "第1、2、3、4、5、6等 12 集")
    }

    func testSourceIsTheSelectedEpisodesInOrderAndShrinksToTheNamesEpisodesWhenHuge() {
        let episodes = [(episode: 1, text: "甲"), (episode: 2, text: "  乙\n"), (episode: 3, text: "  "), (episode: 4, text: "丁")]
        XCTAssertEqual(Names.source(episodes: episodes, for: []), "第1集\n甲\n\n第2集\n乙\n\n第4集\n丁", "空的集不带")
        let huge = [(episode: 1, text: String(repeating: "长", count: 150_000)), (episode: 2, text: String(repeating: "文", count: 150_000)),
                    (episode: 3, text: "短")]
        let only2 = Names.Entry(name: "张三", shots: [.init(episode: 2, segment: 1, prompt: "x")])
        let shrunk = Names.source(episodes: huge, for: [only2])
        XCTAssertTrue(shrunk.hasPrefix("第2集\n文"), "超过预算：只带这一批名字出现过的那几集")
        XCTAssertFalse(shrunk.contains("长"))
        XCTAssertFalse(shrunk.contains("第3集"))
    }

    // MARK: 核对

    func testReconcileReportsForeignNamesAndMissingOnesButIgnoresVersionPrefixesAndExistingCards() {
        let entries = [entry("张三", shots: 1), entry("李四", shots: 1), entry("王五", shots: 1)]
        func parsed(_ names: [String]) -> [ImagePromptParser.Parsed] { names.map { .init(type: .character, name: $0, prompt: "p") } }
        XCTAssertEqual(Names.reconcile(kind: .role, entries: entries, existing: [], parsed: parsed(["第1集的张三", "李四", "第8集的王五"])), [],
                       "「第N集的」前缀不算改名")
        let notes = Names.reconcile(kind: .role, entries: entries, existing: ["王五"], parsed: parsed(["张三", "赵六", "未命名"]))
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0], "角色提取：有 2 张卡的名字不在分镜头行的名单里（赵六、未命名），匹配素材时挂不上图，需要改成头行里的名字")
        XCTAssertEqual(notes[1], "角色提取：名单里有 1 个名字没有提取出来（李四）", "王五本来就有卡，没写不算漏")
    }
}
