import XCTest
@testable import Xipixiaojuchang

/// 名字与形态分离 第 3 步（2026-10-14）：分镜头行只写基础名，这一段用哪个阶段写在分割文本的【阶段】行；
/// 工作台状态、选版本、匹配、提取名单按（名字, 阶段）认卡
@MainActor
final class StageNameTests: XCTestCase {
    private let split = """
    === [00:00-00:30] ===
    【场景】：赛车场·看台 夜 外
    【角色】：周承山、许曼
    【阶段】：周承山=四十岁
    【道具】：无
    【本段在场】：周承山、许曼
    △ 四十岁的周承山冲过终点。
    === [00:30-01:00] ===
    【场景】：周家·客厅 日 内
    【角色】：周承山
    【道具】：无
    【本段在场】：周承山
    △ 周承山坐在沙发上。
    """

    // MARK: 解析

    func testTheStageLineIsReadAsPairsAndKeptOutOfTheBody() {
        let segments = SplitSegments.parse(split)
        XCTAssertEqual(segments.map(\.stages), [["周承山": "四十岁"], [:]])
        XCTAssertEqual(segments[0].roles, ["周承山", "许曼"], "【阶段】不当成说话人")
        let parts = SplitSegments.splitHead(segments[0].text)
        XCTAssertTrue(parts.head.contains("【阶段】：周承山=四十岁"), "名字格里看得到、改得了【阶段】")
        XCTAssertEqual(parts.body, "△ 四十岁的周承山冲过终点。")
        XCTAssertEqual(SplitSegments.stagePairs(in: "周承山=四十岁、许曼＝二十岁、无"), ["周承山": "四十岁", "许曼": "二十岁"])
        XCTAssertTrue(SplitSegments.parse("=== [00:00-00:30] ===\n【场景】：A\n阶段：正文里的一句话\n").first?.stages.isEmpty ?? false,
                      "不带【】的「阶段：」是正文")
    }

    func testNamingReadsAndWritesTheStageLineOnlyWhenNeeded() throws {
        let reply = """
        第1段
        【场景】：赛车场·看台 夜 外
        【角色】：周承山、许曼
        【阶段】：周承山=四十岁
        【道具】：无
        【本段在场】：周承山、许曼

        第2段
        【场景】：周家·客厅 日 内
        【角色】：周承山
        【阶段】：无
        【道具】：无
        【本段在场】：周承山
        """
        let heads = try SegmentNaming.parse(reply, expected: 2)
        XCTAssertEqual(heads.map(\.stages), ["周承山=四十岁", ""])
        XCTAssertTrue(heads[0].lines.contains("【阶段】：周承山=四十岁"))
        XCTAssertFalse(heads[1].lines.contains { $0.hasPrefix("【阶段】") }, "都在主时间线：不写这一行")

        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = split
        let names = SegmentNaming.existingNames(in: [episode], before: 1)
        XCTAssertEqual(names.stages, ["周承山=四十岁"], "后面各集命名时沿用同一个阶段写法")
        XCTAssertTrue(SegmentNaming.userMessage(episode: episode, names: names).contains("阶段：周承山=四十岁"))
    }

    func testLogicalNames() {
        XCTAssertEqual(StageName.compose("周承山", stage: "四十岁"), "周承山（四十岁）")
        XCTAssertEqual(StageName.compose("周承山", stage: " "), "周承山")
        XCTAssertEqual(StageName.split("周承山（四十岁）").name, "周承山")
        XCTAssertEqual(StageName.split("周承山（四十岁）").stage, "四十岁")
        XCTAssertNil(StageName.split("周承山").stage)
        XCTAssertEqual(StageName.logical("周承山", stages: ["周承山": "四十岁"]), "周承山（四十岁）")
        XCTAssertEqual(StageName.logical("许曼", stages: ["周承山": "四十岁"]), "许曼")

        var staged = ImageGenItem(projectKey: "s", type: .character, name: "周承山", prompt: "")
        staged.stage = "四十岁"
        let main = ImageGenItem(projectKey: "s", type: .character, name: "周承山", prompt: "")
        let legacy = ImageGenItem(projectKey: "s", type: .character, name: "沈砚（少年）", prompt: "")
        XCTAssertEqual(StageName.match(card: staged, logical: "周承山（四十岁）"), 2)
        XCTAssertEqual(StageName.match(card: staged, logical: "周承山"), 0, "主时间线的名字不用别的阶段的卡")
        XCTAssertEqual(StageName.match(card: main, logical: "周承山（四十岁）"), 0)
        XCTAssertEqual(StageName.match(card: legacy, logical: "沈砚（少年）"), 2, "旧卡就叫「沈砚（少年）」的照样认")
    }

    // MARK: 工作台

    private struct Fixture {
        let app: AppModel
        let key: String
        let shots: [ShotDraft]
        let main: ImageGenItem
        let staged: ImageGenItem
        let mainLib: Xipixiaojuchang.LibraryItem
        let stagedLib: Xipixiaojuchang.LibraryItem
    }

    private func fixture() -> Fixture {
        let app = AppModel()
        let key = "stage-" + UUID().uuidString
        app.currentProjectKey = key
        func card(_ stage: String?) -> ImageGenItem {
            var item = ImageGenItem(projectKey: key, type: .character, name: "周承山", prompt: "这个人是：\"周承山\"")
            item.stage = stage
            item.results = [ImageGenResult(localPath: "/tmp/stage-\(UUID().uuidString).png", createdAt: Date())]
            item.status = .success
            return item
        }
        let main = card(nil), staged = card("四十岁")
        func lib(_ card: ImageGenItem, _ name: String) -> Xipixiaojuchang.LibraryItem {
            var item = Xipixiaojuchang.LibraryItem(kind: .image, localPath: card.results[0].localPath, name: name, projectKey: key)
            item.uploadState = .uploaded; item.remoteURL = "https://fake.test/\(card.id).png"
            item.source = .imageGenerated; item.imageGenItemID = card.id; item.imageGenResultID = card.results[0].id
            return item
        }
        let mainLib = lib(main, "角色-周承山"), stagedLib = lib(staged, "角色-周承山-1")
        app.imageItems.append(contentsOf: [main, staged])
        app.library.append(contentsOf: [mainLib, stagedLib])
        let shots = [ShotDraft(projectKey: key, prompt: "[赛车场·看台][周承山][ ]\n镜头一"),
                     ShotDraft(projectKey: key, prompt: "[周家·客厅][周承山][ ]\n镜头二")]
        app.shots.append(contentsOf: shots)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = split
        episode.shotIDs = shots.map(\.id)
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        return Fixture(app: app, key: key, shots: shots, main: main, staged: staged, mainLib: mainLib, stagedLib: stagedLib)
    }

    private func cleanup(_ f: Fixture) {
        f.app.shots.removeAll { $0.projectKey == f.key }; f.app.imageItems.removeAll { $0.projectKey == f.key }
        f.app.library.removeAll { $0.projectKey == f.key }; f.app.removePipelineArchive(for: f.key)
    }

    private func board(_ f: Fixture) throws -> WorkbenchStatus.Board {
        f.app.workbenchBoard(project: f.key, archive: try XCTUnwrap(f.app.pipelineArchive(for: f.key)))
    }

    func testEachSegmentUsesTheCardOfItsOwnStage() throws {
        let f = fixture(); defer { cleanup(f) }
        let status = try XCTUnwrap(board(f).episodes.first)
        XCTAssertEqual(status.shots[f.shots[0].id]?.names.filter { $0.kind == .role }.map(\.name), ["周承山（四十岁）"], "工作台里显示是哪个阶段")
        XCTAssertEqual(status.shots[f.shots[1].id]?.names.filter { $0.kind == .role }.map(\.name), ["周承山"])

        let plan = WorkbenchBatch.matchPlan(board: try board(f), indices: [0], app: f.app)
        XCTAssertEqual(plan.map { $0.selections.map(\.cardID) }, [[f.staged.id], [f.main.id]])
        let report = WorkbenchBatch.match(plan, app: f.app)
        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(f.app.shots.first { $0.id == f.shots[0].id }?.imageRefs.map(\.libraryItemID), [f.stagedLib.id])
        XCTAssertEqual(f.app.shots.first { $0.id == f.shots[1].id }?.imageRefs.map(\.libraryItemID), [f.mainLib.id])
        XCTAssertTrue(try XCTUnwrap(board(f).episodes.first).unmatchedShotIDs.isEmpty, "两段都算挂好了")
        XCTAssertEqual(f.app.shots.first { $0.id == f.shots[0].id }?.prompt.components(separatedBy: "\n").first,
                       "[赛车场·看台][图1周承山][ ]", "提示词里只有基础名")
    }

    func testAnImageOfTheWrongStageIsSwappedInPlace() throws {
        let f = fixture(); defer { cleanup(f) }
        // 先在主时间线挂好（这一段还没标【阶段】时挂的）
        let index = try XCTUnwrap(f.app.shots.firstIndex { $0.id == f.shots[0].id })
        f.app.shots[index].prompt = "[赛车场·看台][图1周承山][ ]\n镜头一"
        f.app.shots[index].imageRefs = [MaterialRef(libraryItemID: f.mainLib.id, role: .referenceImage)]
        XCTAssertTrue(try XCTUnwrap(board(f).episodes.first).unmatchedShotIDs.contains(f.shots[0].id), "挂的是别的阶段的图，不算挂好")

        let plan = WorkbenchBatch.matchPlan(board: try board(f), indices: [0], app: f.app)
        WorkbenchBatch.match(plan, app: f.app)
        let after = try XCTUnwrap(f.app.shots.first { $0.id == f.shots[0].id })
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [f.stagedLib.id], "原位换成四十岁那张")
        XCTAssertEqual(after.prompt.components(separatedBy: "\n").first, "[赛车场·看台][图1周承山][ ]", "编号不变、不多插")
    }

    func testUsageAndVersionsFollowTheStage() throws {
        let f = fixture(); defer { cleanup(f) }
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        func usage(_ card: ImageGenItem) -> [UUID] {
            CardUsage.entries(for: card, cards: f.app.currentImageItems, shots: f.app.currentShots, archive: archive) { _ in "" }.map(\.shotID)
        }
        XCTAssertEqual(usage(f.staged), [f.shots[0].id])
        XCTAssertEqual(usage(f.main), [f.shots[1].id])
        XCTAssertEqual(WorkbenchVersions.versions(kind: .role, name: "周承山（四十岁）", cards: f.app.currentImageItems).map(\.cardID), [f.staged.id])
        XCTAssertEqual(CardUsage.cardInForce(kind: .role, name: "周承山（四十岁）", episode: 1, cards: f.app.currentImageItems)?.id, f.staged.id)
    }

    func testRemovingAStagedNameRemovesTheBaseNameFromTheHeadLine() throws {
        let f = fixture(); defer { cleanup(f) }
        WorkbenchBatch.match(WorkbenchBatch.matchPlan(board: try board(f), indices: [0], app: f.app), app: f.app)
        try WorkbenchMaterialEdit.remove(name: "周承山（四十岁）", shotID: f.shots[0].id, app: f.app)
        let after = try XCTUnwrap(f.app.shots.first { $0.id == f.shots[0].id })
        XCTAssertTrue(after.imageRefs.isEmpty)
        XCTAssertFalse(after.prompt.components(separatedBy: "\n")[0].contains("周承山"), after.prompt)
    }

    // MARK: 提取

    func testExtractionListsTheStageAndTheCardCarriesIt() throws {
        let f = fixture(); defer { cleanup(f) }
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let plan = PipelineFlow.extractionPlan(app: f.app, project: f.key, archive: archive, kind: .role, episodeIndices: [0])
        XCTAssertEqual(plan.entries.map(\.name), ["周承山（四十岁）", "周承山"])
        let message = try XCTUnwrap(plan.messages.first)
        XCTAssertTrue(message.contains("1. 周承山（阶段：四十岁；第1集出场"), message)
        XCTAssertTrue(message.contains("2. 周承山（第1集出场"), message)

        let parsed = ImagePromptParser.parse("这个人是：\"周承山\"\n阶段：四十岁\n起始集：1\n描述：四十岁男性。")
        let cards = f.app.appendParsedImageCards(parsed, projectKey: f.key)
        XCTAssertEqual(cards.first?.stage, "四十岁")
        XCTAssertEqual(cards.first?.prompt, "这个人是：\"周承山\"\n描述：四十岁男性。")
        let made = cards.map { ImagePromptParser.Parsed(type: .character, name: $0.baseName, prompt: $0.prompt, stage: $0.stage) }
        let notes = StoryboardNames.reconcile(kind: .role, entries: plan.entries, existing: plan.existing, parsed: made)
        XCTAssertFalse(notes.contains { $0.contains("不在分镜头行的名单里") }, "\(notes)")
    }

    /// 2026-10-14 用户实测：新项目提取角色，面板把「许曼」（第 1 集标了阶段「青年」）显示成「已有卡」、默认不勾。
    /// 面板名单和缺卡判断要用同一套名字：阶段版是单独一项，没卡就是「没有卡」
    func testThePanelListAndTheMissingCheckAgreeOnStagedNames() throws {
        let f = fixture(); defer { cleanup(f) }
        f.app.imageItems.removeAll { $0.id == f.staged.id }      // 只有主时间线那张
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let entries = PipelineFlow.extractionEntries(app: f.app, project: f.key, archive: archive, kind: .role, episodeIndices: [0])
        XCTAssertEqual(entries.map(\.name), ["周承山（四十岁）", "周承山"])
        let missing = Set(try board(f).episodes[0].missingNames[.role] ?? [])
        XCTAssertEqual(entries.filter { missing.contains($0.name) }.map(\.name), ["周承山（四十岁）"], "阶段版没卡、主时间线有卡")
        let plan = PipelineFlow.extractionPlan(app: f.app, project: f.key, archive: archive, kind: .role, episodeIndices: [0],
                                               names: ["周承山（四十岁）"])
        XCTAssertEqual(plan.entries.map(\.name), ["周承山（四十岁）"], "面板勾的名字，提取时认得出来")
    }

    func testAStagesFirstVersionReferencesTheMainTimeline() {
        var main = ImageGenItem(projectKey: "s", type: .character, name: "周承山", prompt: "")
        main.fromEpisode = 1
        var later = main; later.id = UUID(); later.fromEpisode = 9
        var staged = ImageGenItem(projectKey: "s", type: .character, name: "周承山", prompt: "")
        staged.stage = "四十岁"; staged.fromEpisode = 2
        XCTAssertEqual(ReferenceLinks.base(for: staged, referenceName: nil, among: [later, main, staged])?.id, main.id,
                       "固定特征跟主时间线最早那张一致")
        var stagedLater = staged; stagedLater.id = UUID(); stagedLater.fromEpisode = 5
        XCTAssertEqual(ReferenceLinks.base(for: stagedLater, referenceName: nil, among: [main, staged, stagedLater])?.id, staged.id,
                       "同一阶段的变化版：上一版")
    }
}
