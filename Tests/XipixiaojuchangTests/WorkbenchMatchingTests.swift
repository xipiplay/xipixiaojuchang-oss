import XCTest
@testable import Xipixiaojuchang

/// 匹配素材（2026-10-07）：提示词方括号行里的名字前写「图N」，并把选中的图挂进分镜卡；
/// 设定没图时的补图（本集用到但没被提取到的设定也要能出图）。
@MainActor
final class WorkbenchMatchingTests: XCTestCase {
    private struct Fixture {
        let app: AppModel
        let key: String
        let episode: Episode
        var segmentID: UUID
    }

    /// 一集一段：场景「客栈」、角色「甲」都有图（图和素材库条目都建好），提示词开头有 `[场景][角色]` 方括号行
    private func fixture(prompt: String = "[客栈][甲]\n甲走进客栈。") -> Fixture {
        let app = AppModel()
        let key = "match-" + UUID().uuidString
        app.currentProjectKey = key
        let episode = Episode(title: "第1集", text: "甲走进客栈。")
        var archive = ProjectPipelineArchive(wholeScript: "全文", episodes: [episode])
        var work = SimplePipeline.work(in: archive, index: 0)
        work.assetsExtracted = true
        work.assets = [SimplePipelineAsset(kind: "场景", name: "客栈", description: "木头客栈"),
                       SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣少女")]
        var segment = SimplePipelineSegment(text: "甲走进客栈。", assetNames: ["客栈", "甲"], prompt: prompt)
        segment.endPositions = "甲站在柜台前"
        segment.continuityKey = "keep-me"
        work.segments = [segment]
        SimplePipeline.save(work, to: &archive)
        app.savePipelineArchive(archive, for: key)
        for asset in work.assets { addImage(app, key: key, asset: asset) }
        return Fixture(app: app, key: key, episode: episode, segmentID: segment.id)
    }

    /// 给一个素材加生图卡片（一个成功的结果）和对应的素材库条目，返回 (结果 ID, 素材库条目 ID)
    @discardableResult
    private func addImage(_ app: AppModel, key: String, asset: SimplePipelineAsset, suffix: String = "") -> (UUID, UUID) {
        let type = ImageSubjectType.from(kind: asset.kind)
        let result = ImageGenResult(localPath: nil, createdAt: Date())
        if let i = app.imageItems.firstIndex(where: { $0.projectKey == key && $0.name == asset.name }) {
            app.imageItems[i].results.append(result)
            app.imageItems[i].selectedResultID = result.id
        } else {
            var item = ImageGenItem(projectKey: key, type: type, name: asset.name, prompt: asset.description)
            item.results = [result]
            item.status = .success
            app.imageItems.append(item)
        }
        var lib = LibraryItem(kind: .image, localPath: nil, name: "\(type!.namePrefix)-\(asset.name)\(suffix)", projectKey: key)
        lib.imageGenResultID = result.id
        app.library.append(lib)
        return (result.id, lib.id)
    }

    private func card(_ f: Fixture) throws -> ShotDraft {
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let id = try XCTUnwrap(SimplePipeline.work(in: archive, index: 0).segments[0].shotID)
        return try XCTUnwrap(f.app.shots.first { $0.id == id })
    }

    private func names(_ f: Fixture, _ shot: ShotDraft) -> [String] {
        shot.imageRefs.compactMap { f.app.libraryItem($0.libraryItemID)?.matchKeyword }
    }

    // MARK: 匹配

    func testMatchingInsertsNumbersBeforeNamesInTheBracketLineAndAttachesTheImages() throws {
        let f = fixture()
        let status = try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let shot = try card(f)
        XCTAssertEqual(shot.prompt, "[图1客栈][图2甲]\n甲走进客栈。", "场景图排最前，名字前写「图N」；正文里的同名词不动")
        XCTAssertEqual(names(f, shot), ["客栈", "甲"], "参考图的顺序 = 提示词里的图号")
        XCTAssertEqual(status.matched, ["客栈", "甲"])
        XCTAssertTrue(status.unmatched.isEmpty && status.noImage.isEmpty)
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let segment = SimplePipeline.work(in: archive, index: 0).segments[0]
        XCTAssertEqual(segment.prompt, shot.prompt, "带「图N」的提示词写回剧本")
        XCTAssertEqual(segment.shotID, shot.id)
        XCTAssertEqual(segment.continuityKey, "keep-me", "只是加了引用，承接指纹不动")
    }

    func testMatchingTwiceChangesNothing() throws {
        let f = fixture()
        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let first = try card(f)
        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let second = try card(f)
        XCTAssertEqual(second.prompt, first.prompt)
        XCTAssertEqual(second.imageRefs, first.imageRefs)
        XCTAssertEqual(f.app.shots.filter { $0.projectKey == f.key }.count, 1, "不会重复建卡")
    }

    func testRepickingThePortraitSwapsTheReferenceInPlaceAndKeepsTheNumber() throws {
        let f = fixture()
        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let before = try card(f)
        // 「甲」又出了一版，用户挑了它
        let asset = SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣少女")
        let (_, newLib) = addImage(f.app, key: f.key, asset: asset, suffix: "-1")
        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let after = try card(f)
        XCTAssertEqual(after.prompt, before.prompt, "图号不变")
        XCTAssertEqual(after.imageRefs.count, 2)
        XCTAssertEqual(after.imageRefs[1].libraryItemID, newLib, "第 2 张图换成选中的那一版")
        XCTAssertEqual(after.imageRefs[1].id, before.imageRefs[1].id)
    }

    func testRedoingInferenceThenMatchingAgainRebuildsTheNumbersWithoutDuplicates() throws {
        let f = fixture()
        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        // 重新推理：新提示词（没有「图N」）同时写进剧本和分镜卡
        let fresh = "[客栈][甲]\n新的开场，甲推门。"
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        work.segments[0].prompt = fresh
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)
        f.app.updateShotPrompt(try card(f).id, prompt: fresh)

        try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let shot = try card(f)
        XCTAssertEqual(shot.prompt, "[图1客栈][图2甲]\n新的开场，甲推门。")
        XCTAssertEqual(shot.imageRefs.count, 2, "旧引用先对账去掉、再重新挂，不会叠成 4 张")
    }

    func testNamesOutsideTheBracketLineAreNotMatchedAndAreReported() throws {
        let f = fixture(prompt: "甲走进客栈，没有方括号行。")
        let status = try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        let shot = try card(f)
        XCTAssertEqual(shot.prompt, "甲走进客栈，没有方括号行。", "正文里的名字不插「图N」")
        XCTAssertTrue(shot.imageRefs.isEmpty)
        XCTAssertEqual(Set(status.unmatched), ["客栈", "甲"], "有图但没对上的要报出来")
    }

    func testAUsedSettingWithoutAnImageIsReportedAsMissingAndTheRestStillMatch() throws {
        let f = fixture(prompt: "[客栈][甲、乙]\n甲和乙走进客栈。")
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        work.assets.append(SimplePipelineAsset(kind: "角色", name: "乙", description: "蓝衣少年"))
        work.segments[0].assetNames.append("乙")
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)
        let status = try WorkbenchMatching.prepare(segmentID: f.segmentID, episodeID: f.episode.id, doc: nil, app: f.app)
        XCTAssertEqual(status.noImage, ["乙"])
        XCTAssertEqual(status.matched, ["客栈", "甲"])
    }

    func testPrepareEpisodeSkipsSegmentsWithoutPromptAndReturnsStatusPerSegment() throws {
        let f = fixture()
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        work.segments.append(SimplePipelineSegment(text: "没有提示词的一段", assetNames: []))
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)
        let result = try WorkbenchMatching.prepareEpisode(episodeID: f.episode.id, app: f.app)
        XCTAssertEqual(Array(result.keys), [f.segmentID])
        XCTAssertEqual(f.app.shots.filter { $0.projectKey == f.key }.count, 1, "没有提示词的段不建卡")
    }

    // MARK: 提交时也会对一遍

    func testSubmittingASegmentMatchesItFirstSoTheCardCarriesTheNumbers() throws {
        let f = fixture()
        f.app.saveChannel(ModelChannel(name: "测试渠道", baseURL: "http://x", apiKey: "k",
                                       models: [ChannelModel(name: "视频模型", capability: .video)]))
        defer { UserDefaults.standard.removeObject(forKey: "modelChannels") }
        let doc = try XCTUnwrap(f.app.workbenchDocument(for: f.key))
        let episode = try XCTUnwrap(doc.episodes.first { $0.id == f.episode.id })
        var params = WorkbenchActions.defaultParams(f.app)
        params.model = "视频模型"
        try WorkbenchActions.submit(segment: episode.segments[0], episode: episode, params: params, app: f.app)
        let shot = try card(f)
        XCTAssertEqual(shot.prompt, "[图1客栈][图2甲]\n甲走进客栈。")
        XCTAssertEqual(shot.imageRefs.count, 2)
        XCTAssertEqual(shot.model, "视频模型")
        XCTAssertEqual(f.app.shots.filter { $0.projectKey == f.key }.count, 1)
    }

    // MARK: 没有图的设定

    func testSettingsUsedBySegmentsButNotExtractedAreStillOffered() throws {
        let f = fixture()
        // 「监护仪」是项目里的一个道具设定（有生图卡片、还没出图），段落里写了它，但本集这次没提取到
        var item = ImageGenItem(projectKey: f.key, type: .prop, name: "监护仪", prompt: "台式医疗监护仪")
        item.status = .pending
        f.app.imageItems.append(item)
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        work.segments[0].assetNames.append("监护仪")
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)

        let doc = f.app.workbenchDocument(for: f.key)
        let missing = WorkbenchImages.assetsWithoutImage(work: work, doc: doc, project: f.key, app: f.app)
        XCTAssertEqual(missing.map(\.name), ["监护仪"], "本集提取到的客栈、甲都有图了；段落里用到的监护仪还没有")
        XCTAssertEqual(missing.first?.kind, "道具")
        XCTAssertEqual(missing.first?.description, "台式医疗监护仪")
    }

    // MARK: 生出来的图要挂回设定（2026-10-07 实测：图生出来了，设定里还是空的）

    /// 两集的项目：第 1 集段落里写了「监护仪」，但「监护仪」这个素材是第 2 集提取的（所以设定存在，却没有图）
    private func twoEpisodeFixture() throws -> (app: AppModel, key: String, first: Episode) {
        let app = AppModel()
        let key = "adopt-" + UUID().uuidString
        app.currentProjectKey = key
        let first = Episode(title: "第1集", text: "监护仪响了。")
        let second = Episode(title: "第2集", text: "护士看着监护仪。")
        var archive = ProjectPipelineArchive(wholeScript: "全文", episodes: [first, second])
        var w1 = SimplePipeline.work(in: archive, index: 0)
        w1.assetsExtracted = true
        w1.segments = [SimplePipelineSegment(text: "监护仪响了。", assetNames: ["监护仪"], prompt: "[监护仪]\n监护仪响了。")]
        SimplePipeline.save(w1, to: &archive)
        var w2 = SimplePipeline.work(in: archive, index: 1)
        w2.assetsExtracted = true
        w2.assets = [SimplePipelineAsset(kind: "道具", name: "监护仪", description: "台式医疗监护仪")]
        SimplePipeline.save(w2, to: &archive)
        app.savePipelineArchive(archive, for: key)
        return (app, key, first)
    }

    private func monitors(_ app: AppModel, _ key: String) throws -> [SettingRecord] {
        try XCTUnwrap(app.workbenchDocument(for: key)).settings.filter { $0.name == "监护仪" }
    }

    func testAnUnlinkedImageCardBecomesASecondSettingUntilItIsAdopted() throws {
        let (app, key, _) = try twoEpisodeFixture()
        // 之前（缺图面板刚做出来时）生的图：卡片建好了、出了图，但没挂到任何素材上
        var item = ImageGenItem(projectKey: key, type: .prop, name: "监护仪", prompt: "台式医疗监护仪")
        item.results = [ImageGenResult(localPath: nil, createdAt: Date())]
        item.status = .success
        app.imageItems.append(item)
        let before = try monitors(app, key)
        XCTAssertEqual(before.count, 2, "旧表现：图在一个新设定上，段落引用的设定还是空的")
        XCTAssertEqual(before.filter { $0.portrait == nil }.count, 1)

        XCTAssertTrue(WorkbenchImages.adoptUsedSettings(project: key, episodeIndex: 0, app: app))
        let after = try monitors(app, key)
        XCTAssertEqual(after.count, 1, "挂上之后并成一个设定")
        XCTAssertNotNil(after[0].portrait, "图在段落引用的那个设定上")
        XCTAssertFalse(WorkbenchImages.adoptUsedSettings(project: key, episodeIndex: 0, app: app), "已经挂好的不再动")
    }

    func testGeneratingForASettingDefinedElsewhereLinksTheCardToTheEpisode() throws {
        let (app, key, _) = try twoEpisodeFixture()
        app.saveChannel(ModelChannel(name: "测试渠道", baseURL: "http://x", apiKey: "k",
                                     models: [ChannelModel(name: "图片模型", capability: .image)]))
        defer { UserDefaults.standard.removeObject(forKey: "modelChannels") }
        let asset = SimplePipelineAsset(kind: "道具", name: "监护仪", description: "台式医疗监护仪")
        let cards = try WorkbenchImages.prepareCards(for: [asset], project: key, episodeIndex: 0, app: app)
        let id = try XCTUnwrap(cards.first?.itemID)
        // 假装生成完了
        let i = try XCTUnwrap(app.imageItems.firstIndex { $0.id == id })
        app.imageItems[i].results = [ImageGenResult(localPath: nil, createdAt: Date())]
        app.imageItems[i].status = .success
        let settings = try monitors(app, key)
        XCTAssertEqual(settings.count, 1, "不会另冒出一个同名设定")
        XCTAssertNotNil(settings[0].portrait)
        let work = SimplePipeline.work(in: try XCTUnwrap(app.pipelineArchive(for: key)), index: 0)
        XCTAssertEqual(work.assets.first { $0.name == "监护仪" }?.imageItemID, id, "本集素材里记了这个设定和它的卡片")
    }
}
