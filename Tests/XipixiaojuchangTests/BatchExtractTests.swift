import XCTest
@testable import Xipixiaojuchang

private actor ExtractCounter {
    var running = 0, peak = 0, systems: [String] = [], users: [String] = []
    func enter(system: String, user: String) { running += 1; peak = max(peak, running); systems.append(system); users.append(user) }
    func leave() { running -= 1 }
}

/// 场景提取 / 角色提取 / 道具提取（2026-10-07）。2026-10-09 起**先推理分镜、后提取**：名字取自分镜头行 `[场景][角色][道具]`，
/// 角色、道具去原文里找描述，场景去用到它的分镜里找；输出在生图页建成卡片。
@MainActor
final class BatchExtractTests: XCTestCase {
    private typealias Kind = PipelineFlow.ExtractionKind

    private let defaultHead = "[客厅][张三、李四][怀表]"
    private let suffix = "必须按照镜头描述和角色台词生成。电影写实风格，无字幕。"

    private func shotPrompt(_ head: String, _ n: Int = 1) -> String {
        "\(head)\n【角色初始站位与朝向】张三站在窗前。\n中景，镜头\(n)里的木质茶几。\n\(suffix)"
    }

    /// 每集：原文 + 各段分镜的头行（`heads` 为空 = 这一集还没推理分镜）
    private func fixture(_ app: AppModel, episodes: [(text: String, heads: [String])], whole: String? = nil) -> String {
        let key = "batch-extract-" + UUID().uuidString
        var result: [Episode] = []
        for (i, e) in episodes.enumerated() {
            var episode = Episode(title: "第\(i + 1)集", text: e.text, splitText: "分割" + e.text)
            let shots = e.heads.enumerated().map { offset, head in
                ShotDraft(projectKey: key, prompt: shotPrompt(head, offset + 1), numbering: ShotNumbering(a: i + 1, b: offset + 1))
            }
            app.shots.append(contentsOf: shots)
            episode.shotIDs = shots.isEmpty ? nil : shots.map(\.id)
            result.append(episode)
        }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: whole ?? episodes.map(\.text).joined(separator: "\n"), episodes: result), for: key)
        return key
    }
    /// 每集一段分镜、头行都是 `defaultHead`
    private func simple(_ app: AppModel, texts: [String], whole: String? = nil) -> String {
        fixture(app, episodes: texts.map { ($0, [defaultHead]) }, whole: whole)
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.imageItems.removeAll { $0.projectKey == key }
        app.shots.removeAll { $0.projectKey == key }
    }
    private func cards(_ app: AppModel, _ key: String) -> [ImageGenItem] { app.imageItems.filter { $0.projectKey == key } }

    /// 按系统提示词里带的规则标记，回一份对应的输出（名字和 `defaultHead` 对得上）
    private nonisolated static func reply(system: String) -> String {
        if system.contains("ROLE-RULE") { return "这个人是：\"张三\"，三十岁，穿灰色西装。\n这个人是：\"李四\"，二十岁，扎马尾。" }
        if system.contains("SCENE-RULE") { return "这个场景叫：\"客厅\"，现代，一间朝南的客厅。" }
        return "这个物品名称叫：\"怀表\"，铜制，表盖有划痕。"
    }
    private func run(_ app: AppModel, _ key: String, _ kind: Kind, _ indices: [Int], chat: @escaping SimplePipeline.Chat) async {
        app.pipelineFlow.batchExtract(app: app, project: key, kind: kind, episodeIndices: indices,
                                      prompt: "\(kind.rawValue == "角色" ? "ROLE" : kind.rawValue == "场景" ? "SCENE" : "PROP")-RULE", chat: chat)
        await app.pipelineFlow.waitForAll(project: key)
    }

    func testARoleRequestListsTheNamesFromTheHeadLinesAndCarriesTheSourceText() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [("第一集原文", ["[客厅][张三、李四][怀表]", "[院子][张三][怀表、钥匙]"]), ("第二集原文", ["[客厅][张三、王五][ ]"]), ("第三集原文", ["[院子][赵六][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.reply(system: system)
        })
        let users = await counter.users, systems = await counter.systems
        XCTAssertEqual(users.count, 1, "名字不多：一个请求")
        XCTAssertTrue(systems[0].contains("ROLE-RULE"))
        let message = users[0]
        XCTAssertTrue(message.contains("1. 张三（第1、2集出场）\n2. 李四（第1集出场）\n3. 王五（第2集出场）"), message)
        XCTAssertFalse(message.contains("赵六"), "没选第 3 集：它的名字不在名单里")
        XCTAssertFalse(message.contains("怀表"), "角色的请求里没有道具")
        XCTAssertTrue(message.hasSuffix("【原文（描述从这里找）】\n第1集\n第一集原文\n\n第2集\n第二集原文"), "角色去原文里找：选中各集的原文，每集前标第几集\n" + message)
        XCTAssertFalse(message.contains("分割第一集原文"), "读的是原文，不是时长分割")
        XCTAssertEqual(cards(app, key).map(\.name), ["张三", "李四"])
    }

    func testASceneRequestCarriesTheShotsThatUseItAndNotTheSourceText() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [("第一集原文", ["[客厅][张三][ ]", "[院子][张三][ ]"]), ("第二集原文", ["[客厅][李四][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .scene, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.reply(system: system)
        })
        let users = await counter.users
        let message = try XCTUnwrap(users.first)
        XCTAssertTrue(message.contains("1. 客厅（第1、2集出场）\n2. 院子（第1集出场）"), message)
        XCTAssertTrue(message.contains("■ 客厅（第1、2集，共 2 段分镜）\n〔第1集 第1段〕\n[客厅][张三][ ]\n【角色初始站位与朝向】"), message)
        XCTAssertTrue(message.contains("〔第2集 第1段〕\n[客厅][李四][ ]"), message)
        XCTAssertTrue(message.contains("■ 院子（第1集，共 1 段分镜）\n〔第1集 第2段〕"), message)
        XCTAssertFalse(message.contains(suffix), "统一后缀对场景没用，不带")
        XCTAssertFalse(message.contains("第一集原文"), "场景读分镜，不读原文")
    }

    func testOneButtonSendsOneRequestWithItsOwnPromptAndSharesOneProgress() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = simple(app, texts: ["第一集原文", "第二集原文", "第三集原文"])
        defer { cleanup(app, key) }
        await run(app, key, .scene, [0, 2], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.reply(system: system)
        })
        let systems = await counter.systems
        XCTAssertEqual(systems.count, 1, "点一个按钮、名字不多，只发一个请求")
        XCTAssertTrue(systems[0].contains("SCENE-RULE"))
        XCTAssertEqual(cards(app, key).map(\.type), [.scene])
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.kind, .extract)
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertEqual(state.created, 1)
        XCTAssertEqual(state.notes, ["对账：新建 1 个、变化 0 个、沿用 0 个"], "名字都对得上：只有对账那一行，没有别的提醒")
    }

    func testCardsAreAppendedAfterExistingOnesAndNamedAfterWhatWasExtracted() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        app.imageItems.append(ImageGenItem(projectKey: key, type: .scene, name: "图片1", prompt: "手动建的卡片"))
        await run(app, key, .role, [0], chat: { system, _ in Self.reply(system: system) })

        let items = cards(app, key)
        XCTAssertEqual(items.map(\.type), [.scene, .character, .character])
        XCTAssertEqual(items.map(\.name), ["图片1", "张三", "李四"], "提取出来的卡直接用识别出的名字，手动建的不动")
        XCTAssertEqual(items.first?.prompt, "手动建的卡片", "已有的卡片不动")
        XCTAssertTrue(items[1].prompt.contains("张三") && items[2].prompt.contains("李四"))
    }

    func testExtractedCardsCarryTheDefaultParametersFromSettingsButKeepTheirParsedType() async throws {
        let keys = ["defaultImageModel", "defaultImageType", "defaultImageAspect", "defaultImageQuality"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) } }
        let aspect = try XCTUnwrap(ImageAspect.allCases.last), quality = try XCTUnwrap(ImageQuality.allCases.last)
        UserDefaults.standard.set("my-image-model", forKey: "defaultImageModel")
        UserDefaults.standard.set(ImageSubjectType.prop.rawValue, forKey: "defaultImageType")   // 默认类型是道具，但提取出来的角色必须还是角色
        UserDefaults.standard.set(aspect.rawValue, forKey: "defaultImageAspect")
        UserDefaults.standard.set(quality.rawValue, forKey: "defaultImageQuality")

        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0], chat: { system, _ in Self.reply(system: system) })

        let items = cards(app, key)
        XCTAssertEqual(items.count, 2)
        for item in items {
            XCTAssertEqual(item.type, .character, "类型以提取出来的为准")
            XCTAssertEqual(item.model, "my-image-model", "新卡片带上设置里的默认模型")
            XCTAssertEqual(item.aspectRatio, aspect)
            XCTAssertEqual(item.quality, quality)
        }
    }

    func testDifferentKindsCanRunAtTheSameTimeAndShareOneProgress() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        let slow: SimplePipeline.Chat = { system, user in
            await counter.enter(system: system, user: user)
            try? await Task.sleep(for: .milliseconds(80))
            await counter.leave()
            return Self.reply(system: system)
        }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .scene, episodeIndices: [0], prompt: "SCENE-RULE", chat: slow)
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], prompt: "ROLE-RULE", chat: slow)
        let during = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(during.total, 2, "第二个按钮合进同一份进度")
        XCTAssertFalse(during.finished)
        await app.pipelineFlow.waitForAll(project: key)

        let peak = await counter.peak
        XCTAssertEqual(peak, 2, "两类同时在跑")
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 2)
        XCTAssertEqual(state.created, 3, "1 个场景 + 2 个角色")
        XCTAssertEqual(Set(cards(app, key).map(\.type)), [.scene, .character])
    }

    func testTheSameKindIsRefusedWhileItIsStillRunning() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        let slow: SimplePipeline.Chat = { system, user in
            await counter.enter(system: system, user: user)
            try? await Task.sleep(for: .milliseconds(80))
            await counter.leave()
            return ""
        }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .prop, episodeIndices: [0], prompt: "PROP-RULE", chat: slow)
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .prop, episodeIndices: [0], prompt: "PROP-RULE", chat: slow)
        await app.pipelineFlow.waitForAll(project: key)
        let users = await counter.users
        XCTAssertEqual(users.count, 1)
        XCTAssertEqual(try XCTUnwrap(app.pipelineFlow.batches[key]).total, 1)
    }

    func testExtractionIsRefusedWhileASplitOrInferenceBatchIsRunning() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, _ in
            try? await Task.sleep(for: .milliseconds(80)); return "分割结果"
        })
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .scene, episodeIndices: [0], prompt: "SCENE-RULE",
                                      chat: { _, _ in XCTFail("分割在跑，不该开提取"); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertEqual(app.pipelineFlow.batches[key]?.kind, .split)
        XCTAssertTrue(cards(app, key).isEmpty)
    }

    func testAFailureIsNamedByItsButton() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "AI 超时了" } }
        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        await run(app, key, .scene, [0], chat: { _, _ in throw Boom() })
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.failures, [.init(order: 0, label: "场景提取", message: "AI 超时了")])
        XCTAssertEqual(state.created, 0)
        XCTAssertTrue(cards(app, key).isEmpty)
    }

    func testEmptyOutputIsNotAnError() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        await run(app, key, .prop, [0], chat: { _, _ in "  " })
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertTrue(state.failures.isEmpty)
        XCTAssertEqual(state.created, 0)
    }

    func testWithoutEpisodesTheWholeScriptIsRead() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [], whole: "  整本剧本  ")
        defer { cleanup(app, key) }
        await run(app, key, .role, [], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return ""
        })
        let users = await counter.users
        XCTAssertEqual(users, ["整本剧本"], "没分集就没有分镜头行，读整篇剧本、一个请求")
    }

    func testEmptyScriptOrEmptySelectionStartsNothing() async throws {
        let app = AppModel()
        let blank = fixture(app, episodes: [], whole: "   ")
        let withEpisodes = simple(app, texts: ["原文"])
        defer { cleanup(app, blank); cleanup(app, withEpisodes) }
        app.pipelineFlow.batchExtract(app: app, project: blank, kind: .scene, episodeIndices: [], prompt: "x",
                                      chat: { _, _ in XCTFail("没有剧本不该请求"); return "" })
        app.pipelineFlow.batchExtract(app: app, project: withEpisodes, kind: .scene, episodeIndices: [], prompt: "x",
                                      chat: { _, _ in XCTFail("没选集不该请求"); return "" })
        XCTAssertNil(app.pipelineFlow.batches[blank])
        XCTAssertNil(app.pipelineFlow.batches[withEpisodes])
    }

    // MARK: 先推理分镜、后提取

    func testEpisodesWithoutAStoryboardAreReportedByNumber() {
        let app = AppModel()
        let key = fixture(app, episodes: [("甲", [defaultHead]), ("乙", []), ("丙", [])])
        defer { cleanup(app, key) }
        let archive = app.pipelineArchive(for: key)!
        XCTAssertEqual(PipelineFlow.episodesMissingStoryboard(app: app, project: key, archive: archive, episodeIndices: [2, 1, 0, 1, 9]), [1, 2])
        XCTAssertEqual(PipelineFlow.episodesMissingStoryboard(app: app, project: key, archive: archive, episodeIndices: [0]), [])
        XCTAssertEqual(PipelineFlow.describeEpisodes([1, 2]), "第 2、3 集")
        XCTAssertEqual(PipelineFlow.describeEpisodes(Array(0..<12)), "第 1、2、3、4、5、6、7、8 等 12 集")
        // 没分集：只有整篇剧本，没有「分镜」可言
        let whole = ProjectPipelineArchive(wholeScript: "  整本  ")
        XCTAssertEqual(PipelineFlow.episodesMissingStoryboard(app: app, project: key, archive: whole, episodeIndices: []), [])
    }

    func testSelectedEpisodesWithoutAStoryboardStopTheWholeRunAndNameThem() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [("甲", [defaultHead]), ("乙", []), ("丙", [])])
        defer { cleanup(app, key) }
        await run(app, key, .scene, [0, 1, 2], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return Self.reply(system: system)
        })
        let users = await counter.users
        XCTAssertTrue(users.isEmpty, "有集没推理分镜就整次不跑，不拿原文顶替、也不只提取一部分")
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.failures.count, 1)
        XCTAssertEqual(state.failures.first?.label, "场景提取")
        XCTAssertTrue(state.failures.first?.message.contains("第 2、3 集还没有推理分镜") == true, state.failures.first?.message ?? "")
        XCTAssertTrue(cards(app, key).isEmpty)
    }

    func testAKindWithNoNamesInTheHeadLinesSendsNothingAndSaysSo() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [("甲", ["[客厅][张三][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .prop, [0], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return "不该被问"
        })
        let users = await counter.users
        XCTAssertTrue(users.isEmpty)
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertTrue(state.finished)
        XCTAssertEqual(state.succeeded, 1)
        XCTAssertTrue(state.failures.isEmpty)
        XCTAssertEqual(state.notes, ["道具提取：选中的分镜头行里没有道具，没有发请求"])
    }

    func testManyNamesAreSplitIntoSeveralRequestsRunTogetherAndKeepTheirOrder() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let names = (1...45).map { "人物\($0)" }
        let key = fixture(app, episodes: [("原文", ["[客厅][\(names.joined(separator: "、"))][ ]"])])
        defer { cleanup(app, key) }
        // 每个请求回它名单里的第一个名字：能看出结果按批的顺序排
        await run(app, key, .role, [0], chat: { system, user in
            await counter.enter(system: system, user: user)
            try? await Task.sleep(for: .milliseconds(60))
            await counter.leave()
            let first = user.components(separatedBy: "\n").first { $0.hasPrefix("1. ") } ?? ""
            let name = first.dropFirst(3).prefix { $0 != "（" }
            return "这个人是：\"\(name)\"，描述。"
        })
        let users = await counter.users, peak = await counter.peak
        XCTAssertEqual(users.count, 3, "45 个名字，一批最多 20 个：20 + 20 + 5")
        XCTAssertLessThanOrEqual(peak, PipelineFlow.extractionConcurrency)
        XCTAssertGreaterThan(peak, 1, "几个请求是一起发的")
        XCTAssertEqual(cards(app, key).map(\.name), ["人物1", "人物21", "人物41"], "按批的先后建卡，不按谁先答完")
    }

    func testABatchThatFailsMakesNoCardsAtAll() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "第二批超时" } }
        let app = AppModel()
        let names = (1...25).map { "人物\($0)" }
        let key = fixture(app, episodes: [("原文", ["[客厅][\(names.joined(separator: "、"))][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0], chat: { _, user in
            if user.contains("人物21（") { throw Boom() }        // 第二批的名单：人物21~人物25
            return "这个人是：\"人物1\"，描述。"
        })
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.failures.map(\.message), ["第二批超时"])
        XCTAssertTrue(cards(app, key).isEmpty, "出错一律不建卡，免得重试后重复")
    }

    func testCardsWhoseNamesAreNotOnTheListAreReportedButStillCreated() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文"])
        defer { cleanup(app, key) }
        // 名单是 张三、李四；AI 回了 第1集的张三（对得上）和 王五（名单里没有），漏了 李四
        await run(app, key, .role, [0], chat: { _, _ in
            "这个人是：\"第1集的张三\"，三十岁。\n这个人是：\"王五\"，四十岁。"
        })
        XCTAssertEqual(cards(app, key).map(\.name), ["张三", "王五"], "卡照常建（「第1集的」拆成起始集）")
        let notes = try XCTUnwrap(app.pipelineFlow.batches[key]).notes
        XCTAssertEqual(notes.count, 3, "对账一行 + 名字核对两行：\(notes)")
        XCTAssertTrue(notes[0].contains("对账：新建 2 个"), notes[0])
        XCTAssertTrue(notes.contains { $0.contains("王五") && $0.contains("不在分镜头行的名单里") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("李四") && $0.contains("没有提取出来") }, "\(notes)")
    }

    // MARK: 变化版认基础版（出图时拿它的图当参考图）

    func testVariantCardsAreLinkedToTheirBaseAndTheReferenceLineIsTakenOutOfThePrompt() async throws {
        let app = AppModel()
        let key = fixture(app, episodes: [("原文一", ["[客厅][周承山][ ]"]), ("原文五", ["[客厅][周承山][ ]"]), ("原文九", ["[客厅][周承山十岁时期][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0, 1, 2], chat: { _, _ in
            """
            这个人是："第1集的周承山"，现代。
            描述：四十岁。
            这个人是："第5集的周承山"
            修改内容：改为六十岁的样子，换深色夹克、头发花白。
            保持不变：面部五官、痣。
            这个人是："周承山十岁时期"，现代。
            参考：周承山
            描述：十岁男孩。
            """
        })
        let items = cards(app, key)
        XCTAssertEqual(items.map(\.name), ["周承山", "周承山", "周承山十岁时期"], "名字只留基础名，不当重名加「 2」")
        XCTAssertEqual(items.map(\.fromEpisode), [1, 5, nil], "「第N集的」拆成起始集")
        XCTAssertNil(items[0].referenceCardID, "第一次出现的就是基础版")
        XCTAssertEqual(items[1].referenceCardID, items[0].id, "变化版（带「修改内容」）：代码直接认上一版")
        XCTAssertEqual(items[2].referenceCardID, items[0].id, "换了名字的：按 AI 写的「参考：周承山」找")
        XCTAssertFalse(items[2].prompt.contains("参考："), "这一行不是给生图模型看的：\(items[2].prompt)")
        XCTAssertTrue(items[2].prompt.contains("描述：十岁男孩。"))
        let state = try XCTUnwrap(app.pipelineFlow.batches[key])
        XCTAssertEqual(state.notes.count, 1, "\(state.notes)")
        XCTAssertTrue(state.notes[0].contains("对账：新建 2 个、变化 1 个"), state.notes[0])
    }

    /// 2026-10-17 提取对账：已有卡、却给了新起始集的"完整版"（没写「修改内容」）→ **不建卡**，进待确认。
    /// 项目82「第7集起」那种空卡就是它长出来的；描述不同不代表剧情要求换形态。
    func testAPlainBlockWithANewStartEpisodeIsNotCreatedAndGoesToPending() async throws {
        let app = AppModel()
        let key = fixture(app, episodes: [("原文一", ["[客厅][周承山][ ]"]), ("原文五", ["[客厅][周承山][ ]"])])
        defer { cleanup(app, key) }
        app.imageItems.append(ImageGenItem(projectKey: key, type: .character, name: "第1集的周承山", prompt: "这个人是：\"第1集的周承山\"，灰西装。"))
        await run(app, key, .role, [1], chat: { _, _ in "这个人是：\"第5集的周承山\"，六十岁。\n描述：六十岁，深色夹克。" })
        XCTAssertEqual(cards(app, key).count, 1, "只有预先那张：新的没有建")
        let notes = try XCTUnwrap(app.pipelineFlow.batches[key]).notes
        XCTAssertTrue(notes.contains { $0.contains("待确认") && $0.contains("周承山") && $0.contains("修改内容") }, "\(notes)")
    }

    // MARK: 提取对账（2026-10-17）：沿用 / 幂等

    func testASecondRunOfTheSameRangeCreatesNothingEvenIfTheModelRepeatsItself() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文一", "原文二"])
        defer { cleanup(app, key) }
        let reply = "这个人是：\"张三\"，灰西装。\n这个人是：\"李四\"，马尾。"
        await run(app, key, .role, [0, 1], chat: { _, _ in reply })
        XCTAssertEqual(cards(app, key).map(\.name), ["张三", "李四"])
        await run(app, key, .role, [0, 1], chat: { _, _ in reply })
        XCTAssertEqual(cards(app, key).map(\.name), ["张三", "李四"], "重复提取幂等：同一个版本槽不重复建")
        let notes = try XCTUnwrap(app.pipelineFlow.batches[key]).notes
        XCTAssertTrue(notes.contains { $0.contains("没有重复建") }, "\(notes)")
    }

    func testARunThatEchoesExistingNamesWithReusedLinesCreatesNothingAndReportsTheReconciliation() async throws {
        let app = AppModel()
        let key = simple(app, texts: ["原文一", "原文二"])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0, 1], chat: { _, _ in "这个人是：\"张三\"，灰西装。" })
        XCTAssertEqual(cards(app, key).count, 1)
        await run(app, key, .role, [0, 1], chat: { _, _ in "沿用：张三\n沿用：\"李四\"" })
        XCTAssertEqual(cards(app, key).count, 1, "沿用不建卡")
        let notes = try XCTUnwrap(app.pipelineFlow.batches[key]).notes
        XCTAssertTrue(notes.contains { $0.contains("沿用 2 个") }, "\(notes)")
    }

    func testAReferenceToANameThatHasNoCardIsReportedAndLeftUnlinked() async throws {
        let app = AppModel()
        let key = fixture(app, episodes: [("原文", ["[客厅][周承山十岁时期][ ]"])])
        defer { cleanup(app, key) }
        await run(app, key, .role, [0], chat: { _, _ in
            "这个人是：\"周承山十岁时期\"，现代。\n参考：周承山\n描述：十岁男孩。"
        })
        let item = try XCTUnwrap(cards(app, key).first)
        XCTAssertNil(item.referenceCardID)
        XCTAssertFalse(item.prompt.contains("参考："))
        let notes = try XCTUnwrap(app.pipelineFlow.batches[key]).notes
        XCTAssertTrue(notes.contains { $0.contains("周承山十岁时期") && $0.contains("没找到对应的卡") }, "\(notes)")
    }

    func testALaterRunLinksItsVariantToTheBaseThatAnEarlierRunMade() async throws {
        let app = AppModel()
        let key = fixture(app, episodes: [("原文一", ["[客厅][周承山][ ]"]), ("原文二", ["[客厅][周承山][ ]"])])
        defer { cleanup(app, key) }
        let base = ImageGenItem(projectKey: key, type: .character, name: "第1集的周承山", prompt: "这个人是：\"第1集的周承山\"")
        app.imageItems.append(base)
        await run(app, key, .role, [1], chat: { _, _ in
            "这个人是：\"第2集的周承山\"\n修改内容：上衣换成白色赛车服。\n保持不变：面部五官、发型。"
        })
        let variant = try XCTUnwrap(cards(app, key).first { $0.name == "周承山" && $0.fromEpisode == 2 }, "「第2集的」拆成起始集，名字只留基础名")
        XCTAssertEqual(variant.referenceCardID, base.id, "基础版是前一次提取建的")
    }

    // MARK: 分次提取：带上早于本次范围的已有素材（2026-10-09）

    private func card(_ key: String, _ type: ImageSubjectType, _ name: String, _ prompt: String = "") -> ImageGenItem {
        ImageGenItem(projectKey: key, type: type, name: name, prompt: prompt)
    }

    func testRosterHoldsSameKindRealNamedCardsOfTheWholeProject() {
        let key = "roster"
        let items = [
            card(key, .character, "第1集的张三", "这个人是：\"第1集的张三\"，现代背景。描述：三十岁，灰西装。电影写实风格，亚洲角色面容，纯白背景。"),
            card(key, .character, "第2集的李四", "这个人是：\"第2集的李四\"，二十岁。"),
            card(key, .character, "第3集的张三", "第 3 集换装，也在名册里（2026-10-17 对账起：全项目都带）"),
            card(key, .character, "第一集的王五", "中文数字的集号也认"),
            card(key, .character, "手动建的赵六", "没有前缀 = 全程有效"),
            card(key, .character, "图片7", "占位名不带"),
            card(key, .scene, "第1集的客厅", "别的类型不带"),
            card("other-project", .character, "第1集的外人", "别的项目不带"),
        ]
        let roster = PipelineFlow.existingRoster(kind: .role, items: items, project: key)
        XCTAssertEqual(roster.map { String($0.split(separator: "：", maxSplits: 1)[0]) },
                       ["张三（第1集起）", "李四（第2集起）", "张三（第3集起）", "王五（第1集起）", "手动建的赵六"],
                       "名册里名字只写基础名，版本写在括号里；全项目这一类都带，不限「早于本次范围」")
        XCTAssertEqual(PipelineFlow.existingRoster(kind: .scene, items: items, project: key).count, 1)
        XCTAssertEqual(PipelineFlow.existingCards(kind: .role, items: items, project: key).map(\.base),
                       ["张三", "李四", "张三", "王五", "手动建的赵六"], "基础名 = 去掉「第N集的」，没有前缀的就是原名")
    }

    func testRosterEntriesCarryTheCoreDescriptionWithoutTheFixedSuffix() {
        let prompt = "这个人是：\"第1集的张三\"，现代背景。\n描述：三十岁，灰西装。电影写实风格，亚洲角色面容，纯白背景。"
        XCTAssertEqual(PipelineFlow.rosterCore(of: prompt), "这个人是：\"第1集的张三\"，现代背景。 描述：三十岁，灰西装")
        let scene = "这个场景叫：\"客厅\"，现代，\"朝南的客厅\"。“电影写实风格，全景，平视。”"
        XCTAssertEqual(PipelineFlow.rosterCore(of: scene), "这个场景叫：\"客厅\"，现代，\"朝南的客厅")
        XCTAssertEqual(PipelineFlow.rosterCore(of: String(repeating: "长", count: 800)).count, 400, "没有固定后缀的词就截断，不会把整张卡的提示词都带上")
        XCTAssertEqual(PipelineFlow.rosterCore(of: "电影写实风格开头"), "电影写实风格开头", "核心为空就退回前面一段，不发空描述")
    }

    func testTheRosterCarriesExistingCardsRegardlessOfTheRange() async throws {
        let app = AppModel(), counter = ExtractCounter()
        let key = fixture(app, episodes: [("原文一", ["[客厅][张三][ ]"]), ("原文二", ["[客厅][张三][ ]"]),
                                          ("原文三", ["[客厅][张三、李四][ ]"]), ("原文四", ["[客厅][张三][ ]"])])
        defer { cleanup(app, key) }
        app.imageItems.append(card(key, .character, "第1集的张三", "这个人是：\"第1集的张三\"，灰西装。电影写实风格，白底。"))
        app.imageItems.append(card(key, .character, "第1集的路人甲", "名单里没有路人甲，不该出现在请求里"))
        app.imageItems.append(card(key, .scene, "第1集的客厅", "别的类型"))

        // 两次都回空（不建新卡），免得第一次建出来的没前缀的卡变成第二次的名册
        await run(app, key, .role, [2, 3], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return ""
        })
        await run(app, key, .role, [0, 1], chat: { system, user in
            await counter.enter(system: system, user: user); await counter.leave()
            return ""
        })
        let users = await counter.users
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].contains("1. 张三（第3、4集出场；已有）\n2. 李四（第3集出场）"), users[0])
        XCTAssertTrue(users[0].contains("【项目里已经提取过的角色（供对账和保持一致）】\n张三（第1集起）：这个人是：\"第1集的张三\"，灰西装"), users[0])
        XCTAssertFalse(users[0].contains("路人甲"), "只带名字在这一批名单里的已有卡")
        XCTAssertFalse(users[0].contains("客厅"), "只带这一类的已有素材")
        XCTAssertTrue(users[0].contains("名单里标「已有」的"), users[0])
        XCTAssertTrue(users[0].contains("沿用："), users[0])
        XCTAssertTrue(users[1].contains("；已有）"), "从第 1 集起提取也一样看得见已有卡（2026-10-17 对账起，重复提取才幂等）\n" + users[1])
        XCTAssertTrue(users[1].contains("项目里已经提取过"), users[1])
    }

    func testButtonOrderIsSceneRolePropAndEachHasItsOwnPromptSetting() {
        XCTAssertEqual(Kind.allCases.map(\.buttonTitle), ["场景提取", "角色提取", "道具提取"])
        XCTAssertEqual(Kind.scene.prompt, PipelinePromptStore.scenePrompt)
        XCTAssertEqual(Kind.role.prompt, PipelinePromptStore.rolePrompt)
        XCTAssertEqual(Kind.prop.prompt, PipelinePromptStore.propPrompt)
    }
}
