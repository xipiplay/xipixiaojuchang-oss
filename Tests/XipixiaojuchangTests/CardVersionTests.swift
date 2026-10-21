import XCTest
@testable import Xipixiaojuchang

/// 名字与形态分离 第 1 步（2026-10-14）：卡名只放基础名，阶段 / 起始集存成卡上的字段；
/// 旧卡「第N集的X」读进来就拆开；选版本、匹配、找基础版按字段，不再解析名字
@MainActor
final class CardVersionTests: XCTestCase {
    private func card(_ name: String, type: ImageSubjectType = .character, from: Int? = nil, stage: String? = nil,
                      project: String = "cv", withImage: Bool = false) -> ImageGenItem {
        var item = ImageGenItem(projectKey: project, type: type, name: name, prompt: "p")
        item.fromEpisode = from
        item.stage = stage
        if withImage { item.results = [ImageGenResult(localPath: "/tmp/cv-\(UUID().uuidString).png", createdAt: Date())] }
        return item
    }

    // MARK: 旧数据

    func testOldCardsSplitTheEpisodePrefixWhenLoaded() throws {
        let old = ImageGenItem(projectKey: "cv", type: .character, name: "第三集的沈惊澜", prompt: "p")
        let decoded = try JSONDecoder().decode(ImageGenItem.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.name, "沈惊澜")
        XCTAssertEqual(decoded.fromEpisode, 3)
        XCTAssertNil(decoded.stage)

        let plain = try JSONDecoder().decode(ImageGenItem.self, from: JSONEncoder().encode(card("周承山四十岁时期")))
        XCTAssertEqual(plain.name, "周承山四十岁时期", "没有固定格式的老名字原样留着，不去猜")
        XCTAssertNil(plain.fromEpisode)
    }

    func testStageAndEpisodeSurviveSaving() throws {
        let saved = try JSONDecoder().decode(ImageGenItem.self, from: JSONEncoder().encode(card("周承山", from: 3, stage: "四十岁")))
        XCTAssertEqual(saved.stage, "四十岁")
        XCTAssertEqual(saved.fromEpisode, 3)
        XCTAssertEqual(saved.displayName, "周承山 · 四十岁 · 第3集起")
        XCTAssertEqual(card("周承山").displayName, "周承山", "没有阶段 / 起始集就只是名字")
    }

    // MARK: 新建卡

    func testExtractedCardsKeepOnlyTheBaseNameAndDoNotCountVersionsAsDuplicates() {
        let app = AppModel()
        let key = "cv-append-" + UUID().uuidString
        defer { app.imageItems.removeAll { $0.projectKey == key } }
        let parsed = [ImagePromptParser.Parsed(type: .character, name: "第1集的周承山", prompt: "a"),
                      ImagePromptParser.Parsed(type: .character, name: "第3集的周承山", prompt: "b")]
        let first = app.appendParsedImageCards(parsed, projectKey: key)
        XCTAssertEqual(first.map(\.name), ["周承山", "周承山"], "两个版本，不是重名")
        XCTAssertEqual(first.map(\.fromEpisode), [1, 3])
        let again = app.appendParsedImageCards([parsed[0]], projectKey: key)
        XCTAssertEqual(again.map(\.name), ["周承山 2"], "同一个版本又提取一次才算重名")
        XCTAssertEqual(again.first?.fromEpisode, 1)
    }

    func testSubmittingWithTheOldPrefixInThePromptKeepsTheCleanName() {
        var variant = card("沈惊澜", from: 3)
        variant.prompt = "这个人是：\"第3集的沈惊澜\"，基于\"第1集的沈惊澜\"修改。"
        let base = card("沈惊澜", from: 1)
        CardVersion.syncNameFromPrompt(&variant, others: [base, variant])
        XCTAssertEqual(variant.name, "沈惊澜", "提示词里的前缀不会把名字改回去，也不当成和第 1 集那张重名")
        XCTAssertEqual(variant.fromEpisode, 3)

        var fresh = card("图片1")
        fresh.prompt = "这个人是：\"第5集的许曼\""
        CardVersion.syncNameFromPrompt(&fresh, others: [fresh])
        XCTAssertEqual(fresh.name, "许曼")
        XCTAssertEqual(fresh.fromEpisode, 5, "卡上还没有起始集：用提示词里的")
    }

    // MARK: 选版本

    func testVersionsArePickedByTheEpisodeFieldAndOtherStagesStayOut() {
        let base = card("周承山", withImage: true)
        let later = card("周承山", from: 24, withImage: true)
        let young = card("周承山", from: 1, stage: "四十岁", withImage: true)
        let cards = [later, young, base]
        XCTAssertEqual(CardUsage.cardInForce(kind: .role, name: "周承山", episode: 5, cards: cards)?.id, base.id)
        XCTAssertEqual(CardUsage.cardInForce(kind: .role, name: "周承山", episode: 30, cards: cards)?.id, later.id)
        XCTAssertEqual(CardUsage.cardInForce(kind: .role, name: "周承山", stage: "四十岁", episode: 30, cards: cards)?.id, young.id)

        let versions = WorkbenchVersions.versions(kind: .role, name: "周承山", cards: cards)
        XCTAssertEqual(versions.map(\.cardID), [base.id, later.id], "主时间线的列表里没有四十岁那张")
        XCTAssertEqual(versions.map(\.label), ["基础版", "第24集起"])
        XCTAssertEqual(WorkbenchVersions.versions(kind: .role, name: "周承山", stage: "四十岁", cards: cards).map(\.label), ["四十岁 · 第1集起"])
    }

    func testBoardUsesTheEpisodeFieldToo() throws {
        let key = "cv-board"
        let base = card("周承山", project: key, withImage: true)
        let later = card("周承山", from: 2, project: key, withImage: true)
        let young = card("周承山", stage: "四十岁", project: key, withImage: true)
        var shots: [UUID: ShotDraft] = [:]
        var episodes: [Episode] = []
        for number in 1...2 {
            let shot = ShotDraft(projectKey: key, prompt: "[ ][周承山][ ]\n镜头")
            shots[shot.id] = shot
            var episode = Episode(title: "第\(number)集", text: "原文")
            episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：周承山\n【道具】：无\n【本段在场】：周承山\n△ 甲。\n"
            episode.shotIDs = [shot.id]
            episodes.append(episode)
        }
        let board = WorkbenchStatus.board(.init(episodes: episodes, shots: shots, cards: [young, later, base],
                                                libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        XCTAssertEqual(board.episodes.count, 2)
        for episode in board.episodes {
            XCTAssertTrue(episode.missingNames.isEmpty, "两集都找得到卡：\(episode.missingNames)")
        }
        let shotIDs = episodes.map { $0.shotIDs?.first ?? UUID() }
        XCTAssertEqual(CardUsage.entries(for: later, cards: [young, later, base], shots: Array(shots.values),
                                         archive: ProjectPipelineArchive(wholeScript: "", episodes: episodes)) { _ in "" }.map(\.shotID),
                       [shotIDs[1]], "第 2 集起的那张只用在第 2 集")
    }

    // MARK: 基础版

    func testAVariantReferencesTheMostRecentEarlierVersionInTheSameStage() {
        let first = card("周承山", from: 1), mid = card("周承山", from: 8), late = card("周承山", from: 24)
        let otherStage = card("周承山", from: 20, stage: "四十岁")
        let all = [late, otherStage, mid, first]
        XCTAssertEqual(ReferenceLinks.base(for: late, referenceName: nil, among: all)?.id, mid.id, "上一版，别的阶段的不算")
        XCTAssertNil(ReferenceLinks.base(for: first, referenceName: nil, among: all))
        let staged = card("周承山", stage: "少年")
        XCTAssertEqual(ReferenceLinks.base(for: staged, referenceName: "周承山", among: all + [staged])?.id, first.id,
                       "「参考：周承山」找主时间线最早的那张")
    }

    // MARK: 匹配（整个素材库里找）

    func testWholeLibraryMatchUsesTheSourceCardsVersionAndSkipsOtherStages() throws {
        let app = AppModel()
        let key = "cv-match-" + UUID().uuidString
        app.currentProjectKey = key
        let base = card("周承山", project: key, withImage: true)
        let later = card("周承山", from: 5, project: key, withImage: true)
        let young = card("周承山", stage: "四十岁", project: key, withImage: true)
        app.imageItems.append(contentsOf: [base, later, young])
        func lib(for card: ImageGenItem, _ name: String) -> Xipixiaojuchang.LibraryItem {
            var item = Xipixiaojuchang.LibraryItem(kind: .image, localPath: card.results[0].localPath, name: name, projectKey: key)
            item.uploadState = .uploaded; item.remoteURL = "https://fake.test/\(card.id).png"
            item.source = .imageGenerated; item.imageGenItemID = card.id; item.imageGenResultID = card.results[0].id
            return item
        }
        // 入库名里都没有「第N集的」：起始集要从来源卡上看
        let youngLib = lib(for: young, "角色-周承山-2"), laterLib = lib(for: later, "角色-周承山-1"), baseLib = lib(for: base, "角色-周承山")
        app.library.append(contentsOf: [youngLib, laterLib, baseLib])
        var shot = ShotDraft(projectKey: key, prompt: "[ ][周承山][ ]\n镜头")
        shot.numbering = ShotNumbering(a: 6, b: 1)
        app.shots.append(shot)
        defer {
            app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key }
            app.library.removeAll { $0.projectKey == key }
        }
        XCTAssertEqual(app.autoMatchMaterials(shot.id), 1)
        let after = try XCTUnwrap(app.shots.first { $0.id == shot.id })
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [laterLib.id], "第 6 集用第 5 集起那一版；四十岁那张不顶主时间线")
    }

    // MARK: 第 2 步：提取输出里的版本信息不留在提示词里

    func testNewFormatLinesBecomeFieldsAndLeaveThePrompt() {
        let raw = ImagePromptParser.Parsed(type: .character, name: "沈惊澜",
                                           prompt: "这个人是：\"沈惊澜\"\n起始集：3\n修改内容：上身改为月白色上衣。\n保持不变：面部五官。")
        let p = CardVersion.takeVersionLines(raw)
        XCTAssertEqual(p.name, "沈惊澜")
        XCTAssertEqual(p.fromEpisode, 3)
        XCTAssertNil(p.stage)
        XCTAssertEqual(p.prompt, "这个人是：\"沈惊澜\"\n修改内容：上身改为月白色上衣。\n保持不变：面部五官。")

        let staged = CardVersion.takeVersionLines(ImagePromptParser.Parsed(type: .character, name: "周承山",
            prompt: "这个人是：\"周承山\"\n阶段：四十岁\n起始集：第1集\n描述：一个40岁左右的男性。"))
        XCTAssertEqual(staged.stage, "四十岁")
        XCTAssertEqual(staged.fromEpisode, 1, "「第1集」这种写法也认")
        XCTAssertEqual(staged.prompt, "这个人是：\"周承山\"\n描述：一个40岁左右的男性。")
    }

    func testOldFormatIsCleanedToo() {
        let raw = ImagePromptParser.Parsed(type: .character, name: "第3集的沈惊澜",
            prompt: "这个人是：\"第3集的沈惊澜\"，基于\"第1集的沈惊澜\"修改。\n修改内容：上身改为月白色上衣。")
        let p = CardVersion.takeVersionLines(raw)
        XCTAssertEqual(p.name, "沈惊澜")
        XCTAssertEqual(p.fromEpisode, 3)
        XCTAssertEqual(p.prompt, "这个人是：\"沈惊澜\"。\n修改内容：上身改为月白色上衣。", "生图模型看不到集数和「基于…修改」")

        let scene = CardVersion.takeVersionLines(ImagePromptParser.Parsed(type: .scene, name: "第1集的蕴古斋·前柜",
            prompt: "这个场景叫：\"第1集的蕴古斋·前柜\"，民国背景，一间老当铺的前柜。描述里提到第一集的旧物也不动。"))
        XCTAssertEqual(scene.name, "蕴古斋·前柜")
        XCTAssertEqual(scene.prompt, "这个场景叫：\"蕴古斋·前柜\"，民国背景，一间老当铺的前柜。描述里提到第一集的旧物也不动。")
    }

    func testOnlyWholeLinesCount() {
        let raw = ImagePromptParser.Parsed(type: .prop, name: "怀表",
            prompt: "这个物品名称叫：\"怀表\"，表盖内侧刻着「阶段：一」三个字。\n描述：起始集：这几个字在正文里不算。")
        let p = CardVersion.takeVersionLines(raw)
        XCTAssertNil(p.stage)
        XCTAssertNil(p.fromEpisode)
        XCTAssertEqual(p.prompt, raw.prompt, "只有整行以「起始集：」「阶段：」开头的才拿走")
    }

    func testExtractedCardsGetTheFieldsAndACleanPrompt() {
        let app = AppModel()
        let key = "cv-lines-" + UUID().uuidString
        defer { app.imageItems.removeAll { $0.projectKey == key } }
        let cards = app.appendParsedImageCards(ImagePromptParser.parse("这个人是：\"沈惊澜\"\n起始集：3\n描述：二十四岁女性。"), projectKey: key)
        XCTAssertEqual(cards.first?.name, "沈惊澜")
        XCTAssertEqual(cards.first?.fromEpisode, 3)
        XCTAssertEqual(cards.first?.prompt, "这个人是：\"沈惊澜\"\n描述：二十四岁女性。")
    }
}
