import XCTest
@testable import Xipixiaojuchang

private actor Captured {
    var users: [String] = []
    func add(_ user: String) { users.append(user) }
}

/// 2026-10-11 提取素材的三处改动：头行名字去掉出场备注、场景按地点成批、项目「时代背景」每个请求都带
final class ExtractionNameRulesTests: XCTestCase {
    private func head(_ line: String) -> StoryboardNames.Head? { StoryboardNames.head(of: line + "\n【角色初始站位与朝向】站着。") }

    // MARK: ① 头行名字里的出场备注

    func testEntranceNotesAreDroppedFromHeadNamesEvenWhenTheyContainCommas() throws {
        let h = try XCTUnwrap(head("[蕴古斋·前柜 日 内][齐掌柜、老孙（中途进场）、宋文清（画外音，OS）、沈砚(离场)][货账（旧）、藤箱]"))
        XCTAssertEqual(h.scenes, ["蕴古斋·前柜"])
        XCTAssertEqual(h.roles, ["齐掌柜", "老孙", "宋文清", "沈砚"], "括号里的备注（含逗号）不进名字：\(h.roles)")
        XCTAssertEqual(h.props, ["货账（旧）", "藤箱"], "区分形态的括号不是出场备注，原样留着")
    }

    func testOnlyEntranceNotesAreStrippedNotAgeOrFormQualifiers() {
        XCTAssertEqual(StoryboardNames.strippingAnnotations("沈砚（少年）"), "沈砚（少年）")
        XCTAssertEqual(StoryboardNames.strippingAnnotations("老孙（中途进场）"), "老孙")
        XCTAssertEqual(StoryboardNames.strippingAnnotations("老孙(中途进场)"), "老孙", "半角括号一样")
        XCTAssertEqual(StoryboardNames.strippingAnnotations("甲（os）、乙（先走）"), "甲、乙")
        XCTAssertEqual(StoryboardNames.strippingAnnotations("没有括号"), "没有括号")
        XCTAssertEqual(StoryboardNames.cleanName("老孙（中途进场）"), "老孙")
    }

    // MARK: ② 场景按地点成批

    private func entry(_ name: String, evidence: Int = 50, shots: Int = 1) -> StoryboardNames.Entry {
        StoryboardNames.Entry(name: name, shots: (1...shots).map {
            StoryboardNames.Shot(episode: 1, segment: $0, prompt: "[\(name)][甲][乙]\n" + String(repeating: "景", count: evidence))
        })
    }

    func testTheLocationIsTheTextBeforeTheDot() {
        XCTAssertEqual(StoryboardNames.location(of: "蕴古斋·前柜"), "蕴古斋")
        XCTAssertNil(StoryboardNames.location(of: "老街"))
        XCTAssertNil(StoryboardNames.location(of: "·前柜"))
    }

    func testAreasOfOneLocationStayTogetherAndGroupsKeepTheirFirstAppearanceOrder() {
        let batches = StoryboardNames.sceneBatches([entry("蕴古斋·前柜"), entry("老街"), entry("蕴古斋·后院"), entry("沈家·卧房"), entry("蕴古斋·账房")])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].map(\.name), ["蕴古斋·前柜", "蕴古斋·后院", "蕴古斋·账房", "老街", "沈家·卧房"], "同一地点挨在一起，地点按第一次出现排")
    }

    func testALocationIsNotSplitAcrossABatchBoundaryWhenItFitsInTheNextBatch() {
        let singles = (1...11).map { entry("独立场景\($0)") }
        let place = [entry("蕴古斋·前柜"), entry("蕴古斋·后院"), entry("蕴古斋·账房")]
        let batches = StoryboardNames.sceneBatches(singles + place)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, 11, "前 11 个独立场景一批")
        XCTAssertEqual(batches[1].map(\.name), ["蕴古斋·前柜", "蕴古斋·后院", "蕴古斋·账房"], "这个地点整个进下一批，没有 1 个留在前一批、2 个去后一批")
        XCTAssertEqual(batches.flatMap { $0 }.count, 14, "一个都不丢")
    }

    func testALocationTooBigForOneBatchIsStillSplitAndNothingIsLost() {
        let many = (1...15).map { entry("大宅·区域\($0)") }
        let batches = StoryboardNames.sceneBatches(many)
        XCTAssertEqual(batches.map(\.count), [12, 3])
        XCTAssertEqual(batches.flatMap { $0 }.map(\.name), many.map(\.name), "顺序不变、一个不丢")
        // 证据太长：一批装不下也要拆
        let heavy = (1...5).map { entry("长宅·区域\($0)", evidence: 2900, shots: 4) }
        let heavyBatches = StoryboardNames.sceneBatches(heavy)
        XCTAssertGreaterThan(heavyBatches.count, 1)
        XCTAssertEqual(heavyBatches.flatMap { $0 }.map(\.name), heavy.map(\.name))
    }

    func testTheNamesWithoutADotBatchExactlyAsBefore() {
        let batches = StoryboardNames.sceneBatches((1...30).map { entry("场景\($0)") })
        XCTAssertEqual(batches.map(\.count), [12, 12, 6])
    }

    func testTheMessageCarriesTheOtherAreasOfTheSameLocationButNotOtherPlacesOrOtherKinds() {
        let existing = [StoryboardNames.Existing(base: "蕴古斋·前柜", line: "第1集的蕴古斋·前柜：蕴古斋是两进砖木古董铺，前柜进深较浅"),
                        StoryboardNames.Existing(base: "老街", line: "第1集的老街：青石板老街")]
        let scene = StoryboardNames.message(kind: .scene, entries: [entry("蕴古斋·后院")], existing: existing, source: "")
        XCTAssertTrue(scene.contains("蕴古斋是两进砖木古董铺"), "同一地点已经写过的总述要让它看到：\(scene)")
        XCTAssertFalse(scene.contains("青石板老街"), "别的地点的不带")
        XCTAssertFalse(scene.contains("蕴古斋·后院（第1集出场；已有）"), "名单里的名字本身没有已有卡，不能标成已有")
        let role = StoryboardNames.message(kind: .role, entries: [entry("蕴古斋·后院")], existing: existing, source: "原文")
        XCTAssertFalse(role.contains("蕴古斋是两进砖木古董铺"), "角色、道具不按地点带")
    }
}

@MainActor
final class EraBackgroundTests: XCTestCase {
    func testTheEraBlockIsOnlyAddedWhenSomethingIsFilledIn() {
        XCTAssertEqual(EraBackground.block(nil), "")
        XCTAssertEqual(EraBackground.block("  \n "), "")
        let block = EraBackground.prefixed("正文", era: " 民国背景 ")
        XCTAssertTrue(block.hasPrefix("【时代背景（用户指定：逐字照抄，所有条目用同一个说法）】\n民国背景\n\n"), block)
        XCTAssertTrue(block.hasSuffix("正文"))
    }

    func testTheEraIsSavedPerProjectAndClearedWhenEmptied() throws {
        let app = AppModel()
        let key = "era-" + UUID().uuidString
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: [Episode(title: "第1集", text: "x")]), for: key)
        defer { app.removePipelineArchive(for: key) }
        app.setEraBackground("  民国背景 ", project: key)
        XCTAssertEqual(app.pipelineArchive(for: key)?.eraBackground, "民国背景")
        app.setEraBackground("   ", project: key)
        XCTAssertNil(app.pipelineArchive(for: key)?.eraBackground, "清空 = 没填")
        app.setEraBackground("x", project: "没有存档的项目")           // 不崩
        let archive = ProjectPipelineArchive(episodes: [Episode(title: "第1集", text: "x")], eraBackground: "古代言情背景")
        let loaded = try JSONDecoder().decode(ProjectPipelineArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(loaded.eraBackground, "古代言情背景")
        let old = #"{"projectId":"\#(UUID().uuidString)","wholeScript":"x","episodes":[]}"#
        XCTAssertNil(try JSONDecoder().decode(ProjectPipelineArchive.self, from: Data(old.utf8)).eraBackground, "旧存档没有这个键")
    }

    func testEveryExtractionRequestCarriesTheEraAndNoneDoesWhenItIsEmpty() async throws {
        let app = AppModel()
        let key = "era-extract-" + UUID().uuidString
        let prompt = "[蕴古斋·前柜][张三、李四][怀表]\n【角色初始站位与朝向】张三站在柜后。\n中景，张三看着怀表。\n必须按照镜头描述和角色台词生成。"
        let ids = app.writeStoryboardCards(project: key, episodeNumber: 1, existing: [], before: [], after: [], prompts: [prompt])
        var episode = Episode(title: "第1集", text: "张三是个钟表匠。")
        episode.shotIDs = ids
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        defer { app.removePipelineArchive(for: key); app.shots.removeAll { $0.projectKey == key } }
        let seen = Captured()
        let chat: SimplePipeline.Chat = { _, user in await seen.add(user); return "" }

        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], chat: chat)
        await app.pipelineFlow.waitForAll(project: key)
        let without = await seen.users
        XCTAssertEqual(without.count, 1)
        XCTAssertFalse(without[0].contains("时代背景"), "没填就什么都不加")

        app.setEraBackground("民国背景", project: key)
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], note: "年龄写具体数字", chat: chat)
        await app.pipelineFlow.waitForAll(project: key)
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .scene, episodeIndices: [0], chat: chat)
        await app.pipelineFlow.waitForAll(project: key)
        let withEra = await seen.users
        XCTAssertEqual(withEra.count, 3)
        for user in withEra.dropFirst() {
            XCTAssertTrue(user.contains("【时代背景（用户指定：逐字照抄，所有条目用同一个说法）】\n民国背景"), user.prefix(300).description)
        }
        XCTAssertTrue(withEra[1].contains("年龄写具体数字"), "补充要求照旧带上")
    }
}
