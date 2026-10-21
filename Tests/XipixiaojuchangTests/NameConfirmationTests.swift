import XCTest
@testable import Xipixiaojuchang

/// 名字确认（2026-10-07 P3-2 第 2 步，用户按推荐定的口径）：
/// 对应 / 新建 / 忽略三选一；确认一次整个项目生效；记成别名 / 忽略名单，以后各集自动对上。
@MainActor
final class NameConfirmationTests: XCTestCase {
    private func setting(_ name: String, _ kind: SettingKind = .prop, aliases: [String] = []) -> SettingRecord {
        var s = SettingRecord(id: UUID(), kind: kind, name: name)
        s.aliases = aliases
        return s
    }

    // MARK: 建议

    func testSuggestionMatchesByContainmentAndPrefersTheLongestName() {
        let settings = [setting("饭盒"), setting("半块蒸蛋"), setting("搪瓷水碗"), setting("碗"), setting("林知夏", .character)]
        XCTAssertEqual(NameConfirmation.suggest(for: "热饭饭盒", settings: settings), .alias(settingName: "饭盒"))
        XCTAssertEqual(NameConfirmation.suggest(for: "蒸蛋", settings: settings), .alias(settingName: "半块蒸蛋"))
        XCTAssertEqual(NameConfirmation.suggest(for: "水碗", settings: settings), .alias(settingName: "搪瓷水碗"))
        XCTAssertEqual(NameConfirmation.suggest(for: "搪瓷水碗架", settings: settings), .alias(settingName: "搪瓷水碗"), "两个都包含时取更长的")
        XCTAssertEqual(NameConfirmation.suggest(for: "围裙", settings: settings), .create(kind: .prop, description: ""))
        XCTAssertEqual(NameConfirmation.suggest(for: "床", settings: [setting("床头灯")]), .create(kind: .prop, description: ""),
                       "只有一个字的名字不做包含匹配（太容易误配）")
    }

    func testNewSettingKindIsGuessedFromTheScript() {
        let texts = ["场景：巷子 黄昏 外\n[林知远]（画外音）：姐\n△ 她端起水碗", "[周长安]：手放下。\n场景: 院内 夜 内"]
        XCTAssertEqual(NameConfirmation.inferKind(of: "巷子", in: texts), .scene)
        XCTAssertEqual(NameConfirmation.inferKind(of: "院内", in: texts), .scene, "半角冒号也认")
        XCTAssertEqual(NameConfirmation.inferKind(of: "林知远", in: texts), .character)
        XCTAssertEqual(NameConfirmation.inferKind(of: "周长安", in: texts), .character)
        XCTAssertEqual(NameConfirmation.inferKind(of: "水碗", in: texts), .prop, "只在动作行里出现：当道具")
        XCTAssertEqual(NameConfirmation.suggest(for: "巷子", settings: [], texts: texts), .create(kind: .scene, description: ""))
        XCTAssertEqual(NameConfirmation.suggest(for: "巷子", settings: []), .create(kind: .prop, description: ""), "没有原文就当道具")
    }

    func testSuggestionIgnoresImportedAndUntypedSettings() {
        let settings = [setting("饭盒", .imported), setting("饭盒", .other)]
        XCTAssertEqual(NameConfirmation.suggest(for: "热饭饭盒", settings: settings), .create(kind: .prop, description: ""))
    }

    // MARK: 规则

    func testNormalizeMapsAliasesDropsIgnoredAndKeepsOrder() {
        var rules = NameRules()
        rules.aliases = ["热饭饭盒": "饭盒", "打翻的饭盒": "饭盒"]
        rules.ignored = ["床"]
        XCTAssertEqual(rules.normalize(["巷子", "热饭饭盒", "床", "打翻的饭盒", "林知夏"]), ["巷子", "饭盒", "林知夏"])
        XCTAssertFalse(rules.keepsExtractedAsset(named: "床"))
        XCTAssertFalse(rules.keepsExtractedAsset(named: "热饭饭盒"), "已经是别名：用已有设定，不再新建")
        XCTAssertTrue(rules.keepsExtractedAsset(named: "围裙"))
    }

    func testRulesAreReadFromTheDocument() {
        var doc = ProjectDocument(id: "P", name: "项目", createdAt: Date(), updatedAt: Date())
        doc.settings = [setting("饭盒", aliases: ["热饭饭盒", "饭盒"])]
        doc.ignoredNames = ["床"]
        let rules = NameRules(doc: doc)
        XCTAssertEqual(rules.aliases, ["热饭饭盒": "饭盒"], "和设定同名的别名没有意义，不算")
        XCTAssertEqual(rules.ignored, ["床"])
        XCTAssertEqual(NameRules(doc: nil), NameRules())
    }

    // MARK: 应用到一集

    private func work(_ segments: [[String]]) -> SimpleEpisodeWork {
        var w = SimpleEpisodeWork(id: UUID(), sourceKey: "k")
        w.segments = segments.map { SimplePipelineSegment(text: "原文", assetNames: $0) }
        return w
    }

    func testAliasRewritesNamesInEverySegmentWithoutDuplicates() {
        var w = work([["热饭饭盒", "林知夏"], ["饭盒", "热饭饭盒"], ["林知夏"]])
        XCTAssertTrue(NameConfirmation.apply([NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒"))], to: &w))
        XCTAssertEqual(w.segments.map(\.assetNames), [["饭盒", "林知夏"], ["饭盒"], ["林知夏"]])
        XCTAssertFalse(NameConfirmation.apply([NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒"))], to: &w), "再确认一次：没有可改的")
    }

    func testIgnoreRemovesTheNameEverywhere() {
        var w = work([["床", "林知夏"], ["床"]])
        XCTAssertTrue(NameConfirmation.apply([NameDecision(name: "床", choice: .ignore)], to: &w))
        XCTAssertEqual(w.segments.map(\.assetNames), [["林知夏"], []])
    }

    func testCreateAddsAnAssetOnlyToEpisodesThatUseTheName() {
        var used = work([["蒸蛋"]])
        var unused = work([["别的"]])
        let decision = NameDecision(name: "蒸蛋", choice: .create(kind: .prop, description: "  浅黄色蒸蛋  "))
        XCTAssertTrue(NameConfirmation.apply([decision], to: &used))
        XCTAssertFalse(NameConfirmation.apply([decision], to: &unused))
        XCTAssertEqual(used.assets.map(\.name), ["蒸蛋"])
        XCTAssertEqual(used.assets[0].kind, "道具")
        XCTAssertEqual(used.assets[0].description, "浅黄色蒸蛋", "描述去掉首尾空白")
        XCTAssertTrue(unused.assets.isEmpty)
        XCTAssertFalse(NameConfirmation.apply([decision], to: &used), "已经有了不重复建")
        // 描述可以留空
        var empty = work([["围裙"]])
        XCTAssertTrue(NameConfirmation.apply([NameDecision(name: "围裙", choice: .create(kind: .prop, description: ""))], to: &empty))
        XCTAssertEqual(empty.assets[0].description, "")
    }

    // MARK: 记进项目文件

    func testRecordAddsAliasToTheSettingAndIgnoredNamesToTheProject() {
        var doc = ProjectDocument(id: "P", name: "项目", createdAt: Date(), updatedAt: Date())
        doc.settings = [setting("饭盒")]
        let decisions = [NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒")),
                         NameDecision(name: "床", choice: .ignore),
                         NameDecision(name: "蒸蛋", choice: .create(kind: .prop, description: "")),
                         NameDecision(name: "不存在", choice: .alias(settingName: "没有这个设定"))]
        XCTAssertTrue(NameConfirmation.record(decisions, in: &doc))
        XCTAssertEqual(doc.settings[0].aliases, ["热饭饭盒"])
        XCTAssertEqual(doc.ignoredNames, ["床"])
        XCTAssertFalse(NameConfirmation.record(decisions, in: &doc), "重复确认不再改动")
        XCTAssertEqual(doc.settings[0].aliases, ["热饭饭盒"])
    }

    // MARK: 整条链路（AppModel）

    private struct Fixture { let app: AppModel; let key: String }

    /// 两集都写着「热饭饭盒」「床」「蒸蛋」，设定里有「饭盒」
    private func fixture() -> Fixture {
        let app = AppModel()
        let key = "names-" + UUID().uuidString
        let e1 = Episode(title: "第1集", text: "甲"), e2 = Episode(title: "第2集", text: "乙")
        func work(_ ep: Episode, names: [[String]]) -> SimpleEpisodeWork {
            var w = SimpleEpisodeWork(id: ep.id, sourceKey: SimplePipeline.key(ep.text))
            w.assets = [SimplePipelineAsset(kind: "道具", name: "饭盒", description: "白色饭盒")]
            w.assetsExtracted = true
            w.segments = names.map { SimplePipelineSegment(text: ep.text, assetNames: $0) }
            return w
        }
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(
            wholeScript: "全文", episodes: [e1, e2],
            simpleWorks: [work(e1, names: [["饭盒", "热饭饭盒", "床"]]), work(e2, names: [["热饭饭盒", "蒸蛋"], ["床"]])]), for: key)
        return Fixture(app: app, key: key)
    }

    private func unresolved(_ f: Fixture) throws -> [String] {
        let doc = try XCTUnwrap(f.app.workbenchDocument(for: f.key))
        return doc.episodes.filter { !$0.isFree }.flatMap(\.segments).flatMap(\.unresolvedNames)
    }

    func testConfirmingOnceFixesTheWholeProjectAndSurvivesLaterSaves() throws {
        let f = fixture()
        XCTAssertEqual(try unresolved(f).sorted(), ["床", "床", "热饭饭盒", "热饭饭盒", "蒸蛋"])

        try f.app.applyNameDecisions([
            NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒")),
            NameDecision(name: "床", choice: .ignore),
            NameDecision(name: "蒸蛋", choice: .create(kind: .prop, description: "浅黄色蒸蛋")),
        ], projectKey: f.key)

        XCTAssertEqual(try unresolved(f), [], "两集里同名的都处理了")
        var doc = try XCTUnwrap(f.app.workbenchDocument(for: f.key))
        XCTAssertTrue(doc.settings.contains { $0.name == "蒸蛋" && $0.description == "浅黄色蒸蛋" }, "新建的设定出现了")
        XCTAssertEqual(f.app.nameRules(for: f.key).aliases, ["热饭饭盒": "饭盒"])
        XCTAssertEqual(f.app.nameRules(for: f.key).ignored, ["床"])

        // 重点回归：存一次盘、再换算，确认过的结果不能变回「对不上」（别名要先带回、再解析名字）
        f.app.saveProjectsNow()
        XCTAssertEqual(try unresolved(f), [])
        doc = try XCTUnwrap(f.app.workbenchDocument(for: f.key))
        XCTAssertEqual(doc.settings.first { $0.name == "饭盒" }?.aliases, ["热饭饭盒"])
        XCTAssertEqual(doc.ignoredNames, ["床"])
    }

    func testAliasStillResolvesWhenTheNameComesBackFromAnotherSource() throws {
        // 名字没被改写（比如旧页面又写回了「热饭饭盒」）：只靠别名也要能对上
        let f = fixture()
        try f.app.applyNameDecisions([NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒"))], projectKey: f.key)
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var w = SimplePipeline.work(in: archive, index: 0)
        w.segments[0].assetNames.append("热饭饭盒")
        SimplePipeline.save(w, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)
        let doc = try XCTUnwrap(f.app.workbenchDocument(for: f.key))
        XCTAssertFalse(doc.episodes.flatMap(\.segments).flatMap(\.unresolvedNames).contains("热饭饭盒"))
    }

    func testApplyWithoutScriptFailsCleanly() {
        let app = AppModel()
        XCTAssertThrowsError(try app.applyNameDecisions([NameDecision(name: "x", choice: .ignore)], projectKey: "没有剧本的项目"))
        XCTAssertNoThrow(try app.applyNameDecisions([], projectKey: "没有剧本的项目"), "没有要处理的就什么都不做")
    }

    // MARK: 以后各集自动对上（入库时）

    func testNewlySplitSegmentsUseTheConfirmedNames() async throws {
        let f = fixture()
        try f.app.applyNameDecisions([NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒")),
                                      NameDecision(name: "床", choice: .ignore)], projectKey: f.key)
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let episodeID = archive.episodes[1].id
        let reply = #"{"segments":[{"text":"新分出来的一段","assets":["热饭饭盒","床","林知夏","饭盒"]}]}"#
        f.app.pipelineFlow.splitDuration(app: f.app, project: f.key, episodeIndex: 1, chat: { _, _ in reply })
        await f.app.pipelineFlow.waitForJob(project: f.key, episode: episodeID)
        let after = SimplePipeline.work(in: try XCTUnwrap(f.app.pipelineArchive(for: f.key)), index: 1)
        XCTAssertEqual(after.segments.first?.assetNames, ["饭盒", "林知夏"], "别名换成设定名、忽略的去掉、去重保序")
    }

    func testExtractionDoesNotRecreateConfirmedNames() async throws {
        let f = fixture()
        try f.app.applyNameDecisions([NameDecision(name: "热饭饭盒", choice: .alias(settingName: "饭盒")),
                                      NameDecision(name: "床", choice: .ignore)], projectKey: f.key)
        let episodeID = try XCTUnwrap(f.app.pipelineArchive(for: f.key)).episodes[1].id
        let reply = #"{"assets":[{"kind":"道具","name":"热饭饭盒","description":"一个盒子"},{"kind":"道具","name":"床","description":"一张床"},{"kind":"道具","name":"围裙","description":"蓝围裙"}]}"#
        f.app.pipelineFlow.extract(app: f.app, project: f.key, episodeIndex: 1, chat: { _, _ in reply })
        await f.app.pipelineFlow.waitForJob(project: f.key, episode: episodeID)
        let assets = SimplePipeline.work(in: try XCTUnwrap(f.app.pipelineArchive(for: f.key)), index: 1).assets.map(\.name)
        XCTAssertTrue(assets.contains("围裙"))
        XCTAssertFalse(assets.contains("热饭饭盒"))
        XCTAssertFalse(assets.contains("床"))
    }
}
