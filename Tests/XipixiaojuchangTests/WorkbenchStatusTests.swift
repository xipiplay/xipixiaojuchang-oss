import XCTest
@testable import Xipixiaojuchang

/// 工作台（2026-10-09）：每一集的「下一步」和底部胶囊的进度，全部从现有数据算出来。
@MainActor
final class WorkbenchStatusTests: XCTestCase {
    private typealias Status = WorkbenchStatus
    private let key = "wb-status"

    private func shot(_ head: String, refs: [UUID] = []) -> ShotDraft {
        var shot = ShotDraft(projectKey: key, prompt: head + "\n【角色初始站位与朝向】甲站着。\n中景，镜头。")
        shot.imageRefs = refs.map { MaterialRef(libraryItemID: $0, role: .referenceImage) }
        return shot
    }
    private func card(_ name: String, _ type: ImageSubjectType, image: Bool = false, reference: UUID? = nil) -> ImageGenItem {
        var item = ImageGenItem(projectKey: key, type: type, name: name, prompt: "p")
        if image { item.results = [ImageGenResult(localPath: nil, createdAt: Date())]; item.status = .success }
        item.referenceCardID = reference
        return item
    }
    /// `named`：分割文本里各段有没有场景头行（2026-10-11 分段命名：分割只管切，名字由「命名」那一步写）
    private func episode(split: Bool = true, named: Bool = true, shots: [ShotDraft] = []) -> Episode {
        let text = named ? "【场景】：客厅 日 内\n【角色】：张三\n甲说话。\n--- 00:00 - 00:30" : "分割"
        var e = Episode(title: "集", text: "原文", splitText: split ? text : nil)
        e.shotIDs = shots.isEmpty ? nil : shots.map(\.id)
        return e
    }
    private func board(_ episodes: [Episode], shots: [ShotDraft], cards: [ImageGenItem] = [],
                       keywords: [UUID: String] = [:], libraryCard: [UUID: UUID] = [:], video: [UUID: Status.VideoState] = [:]) -> Status.Board {
        Status.board(.init(episodes: episodes, shots: Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0) }), cards: cards,
                           libraryKeyword: { keywords[$0] }, videoState: { video[$0.id] ?? .none },
                           libraryCardID: { libraryCard[$0] }))
    }

    func testTheNextStepIsTheFirstUnfinishedOneInPipelineOrder() {
        let head = "[客厅][张三][怀表]"
        // 没分割 → 没分镜 → 缺卡 → 没图 → 没匹配 → 没视频
        XCTAssertEqual(board([episode(split: false)], shots: []).episodes[0].stage, .toSplit)
        XCTAssertEqual(board([episode(named: false)], shots: []).episodes[0].stage, .toName, "分割了、各段还没名字：先命名")
        XCTAssertEqual(board([episode()], shots: []).episodes[0].stage, .toInfer)
        let s = shot(head)
        let missing = board([episode(shots: [s])], shots: [s], cards: [card("客厅", .scene)]).episodes[0]
        XCTAssertEqual(missing.stage, .toExtract)
        XCTAssertEqual(missing.detail, "缺 2 张卡")
        XCTAssertEqual(missing.line, "待提取素材 · 缺 2 张卡")
        XCTAssertEqual(missing.missingNames[.role], ["张三"])
        XCTAssertEqual(missing.missingNames[.prop], ["怀表"])
        let noImages = [card("客厅", .scene), card("张三", .character), card("怀表", .prop)]
        let toDraw = board([episode(shots: [s])], shots: [s], cards: noImages).episodes[0]
        XCTAssertEqual(toDraw.stage, .toGenerateImages)
        XCTAssertEqual(toDraw.detail, "3 张没有图")
        XCTAssertEqual(toDraw.cardsToGenerate.count, 3)
    }

    func testWithImagesTheStepIsMatchingUntilTheRefsCoverTheNames() {
        let sceneLib = UUID(), roleLib = UUID()
        let cards = [card("客厅", .scene, image: true), card("张三", .character, image: true)]
        let bare = shot("[客厅][张三][ ]")
        let partial = shot("[客厅][张三][ ]", refs: [sceneLib])
        let full = shot("[客厅][张三][ ]", refs: [sceneLib, roleLib])
        let keywords = [sceneLib: "客厅", roleLib: "第1集的张三"]       // 带「第N集的」前缀的素材也算是「张三」
        let unmatched = board([episode(shots: [bare, partial, full])], shots: [bare, partial, full], cards: cards, keywords: keywords).episodes[0]
        XCTAssertEqual(unmatched.stage, .toMatch)
        XCTAssertEqual(unmatched.detail, "已匹配 1/3 段")
        XCTAssertEqual(unmatched.unmatchedShotIDs, [bare.id, partial.id])
        let matched = board([episode(shots: [full])], shots: [full], cards: cards, keywords: keywords).episodes[0]
        XCTAssertEqual(matched.stage, .toGenerateVideo)
        XCTAssertTrue(matched.unmatchedShotIDs.isEmpty)
    }

    func testVideoStatesDecideTheLastSteps() {
        let a = shot("[客厅][ ][ ]"), b = shot("[客厅][ ][ ]"), c = shot("[客厅][ ][ ]")
        let cards = [card("客厅", .scene, image: true)]
        let lib = UUID()
        let refs = [a, b, c].map { s -> ShotDraft in var s = s; s.imageRefs = [MaterialRef(libraryItemID: lib, role: .referenceImage)]; return s }
        let keywords = [lib: "客厅"]
        func stage(_ states: [Status.VideoState]) -> Status.EpisodeStatus {
            let video = Dictionary(uniqueKeysWithValues: zip(refs.map(\.id), states))
            return board([episode(shots: refs)], shots: refs, cards: cards, keywords: keywords, video: video).episodes[0]
        }
        XCTAssertEqual(stage([.none, .none, .none]).stage, .toGenerateVideo)
        let running = stage([.completed, .running, .none])
        XCTAssertEqual(running.stage, .generatingVideo)
        XCTAssertEqual(running.detail, "已完成 1/3 段")
        let failed = stage([.completed, .failed, .none])
        XCTAssertEqual(failed.stage, .toGenerateVideo)
        XCTAssertTrue(failed.hasFailure)
        XCTAssertEqual(failed.detail, "已完成 1/3 段 · 1 段失败")
        XCTAssertEqual(failed.shotsToSubmit, [refs[1].id, refs[2].id], "失败的和还没有的可以提交，完成的不重复")
        XCTAssertEqual(stage([.completed, .completed, .completed]).stage, .done)
    }

    func testEachNameUsesTheVersionThatIsInForceForThatEpisode() {
        // 只有「第5集的周承山」：第 1 集用到「周承山」时还没有这张卡（不能拿后面的版本顶替）
        let s2 = shot("[客厅][周承山][ ]"), s6 = shot("[客厅][周承山][ ]")
        let cards = [card("客厅", .scene, image: true), card("第5集的周承山", .character, image: true)]
        let result = board([episode(shots: [s2]), episode(), episode(), episode(), episode(), episode(shots: [s6])], shots: [s2, s6], cards: cards)
        XCTAssertEqual(result.episodes[0].missingNames[.role], ["周承山"], "第 1 集用到「周承山」时，最早的版本是第 5 集：不能拿后面的版本顶替")
        XCTAssertNil(result.episodes[5].missingNames[.role], "第 6 集：第 5 集起的版本生效")
    }

    func testAVariantsBaseGoesFirstInTheListOfCardsToDrawEvenFromAnotherEpisode() {
        let base = card("第1集的周承山", .character)
        let variant = card("第24集的周承山", .character, reference: base.id)
        let scene = card("客厅", .scene, image: true)
        let s = shot("[客厅][周承山][ ]")
        let eps = (0..<24).map { $0 == 23 ? episode(shots: [s]) : episode() }
        let result = board(eps, shots: [s], cards: [scene, variant, base])
        XCTAssertEqual(result.episodes[23].cardsToGenerate, [base.id, variant.id], "基础版先出图，变化版才能拿它当参考图")
        XCTAssertEqual(result.episodes[23].stage, .toGenerateImages)
    }

    func testTotalsCountProjectWideProgressForEachCapsuleStep() {
        let s1 = shot("[客厅][张三][ ]"), s2 = shot("[院子][张三][ ]")
        let cards = [card("客厅", .scene, image: true), card("张三", .character)]
        let result = board([episode(shots: [s1]), episode(shots: [s2]), episode(split: false)], shots: [s1, s2], cards: cards)
        XCTAssertEqual(result.totals.split, .init(done: 2, total: 3))
        XCTAssertEqual(result.totals.infer, .init(done: 2, total: 3))
        XCTAssertEqual(result.totals.names[.scene], .init(done: 1, total: 2), "客厅有卡、院子没有")
        XCTAssertEqual(result.totals.names[.role], .init(done: 1, total: 1))
        XCTAssertEqual(result.totals.names[.prop], .init(done: 0, total: 0))
        XCTAssertEqual(result.totals.images, .init(done: 1, total: 2), "用到的卡里：客厅有图、张三没有")
        XCTAssertEqual(result.totals.match, .init(done: 0, total: 2), "还有名字没卡 / 没图的分镜，算不上匹配好")
        XCTAssertEqual(result.totals.video, .init(done: 0, total: 2))
    }

    func testMatchingMarksFromPreviousMatchingAreStillReadAsNames() {
        // 匹配会在头行名字前插「图N」：再算状态时要认得出名字
        let s = shot("[图1客厅][图2张三][ ]")
        let result = board([episode(shots: [s])], shots: [s], cards: [card("客厅", .scene, image: true), card("张三", .character, image: true)])
        XCTAssertNil(result.episodes[0].missingNames[.scene])
        XCTAssertEqual(result.episodes[0].stage, .toMatch, "名字都有卡有图，只是这条分镜的参考图里没有")
    }

    func testEachShotHasItsOwnNameStatesAndNextStep() {
        // 第 1 段：场景有图、角色有卡没图、道具没卡；第 2 段：名字都齐、没挂图；第 3 段：挂好了、视频生成中
        let lib = UUID()
        let a = shot("[客厅][张三][怀表]")
        let b = shot("[客厅][ ][ ]")
        var c = shot("[客厅][ ][ ]"); c.imageRefs = [MaterialRef(libraryItemID: lib, role: .referenceImage)]
        let cards = [card("客厅", .scene, image: true), card("张三", .character)]
        let result = board([episode(shots: [a, b, c])], shots: [a, b, c], cards: cards, keywords: [lib: "客厅"],
                           video: [c.id: .running]).episodes[0]
        let first = result.shots[a.id]
        XCTAssertEqual(first?.names.map(\.name), ["客厅", "张三", "怀表"], "头行里的先后：场景、角色、道具")
        XCTAssertEqual(first?.names.map(\.state), [.ready, .noImage, .missing])
        XCTAssertEqual(first?.stage, .toExtract, "有名字没卡：先提取")
        XCTAssertEqual(result.shots[b.id]?.stage, .toMatch, "只有场景一个名字、有图、还没挂")
        XCTAssertEqual(result.shots[c.id]?.stage, .generatingVideo)
        XCTAssertEqual(result.shots[c.id]?.video, .running)
    }

    func testAnEpisodeWithBlankShotCardsCountsAsNotInferred() {
        var blank = ShotDraft(projectKey: key, prompt: "  \n ")
        blank.imageRefs = []
        let result = board([episode(shots: [blank])], shots: [blank])
        XCTAssertEqual(result.episodes[0].stage, .toInfer)
        XCTAssertEqual(result.totals.infer.done, 0)
    }

    func testNamingProgressCountsTheEpisodesWhoseSegmentsAllHaveAScene() {
        let result = board([episode(split: false), episode(named: false), episode(), episode()], shots: [])
        XCTAssertEqual(result.totals.naming, .init(done: 2, total: 4))
        XCTAssertEqual(result.totals.split, .init(done: 3, total: 4))
        XCTAssertEqual(result.episodes.map(\.stage), [.toSplit, .toName, .toInfer, .toInfer])
        XCTAssertEqual(Status.Stage.toName.title, "待命名")
    }

    func testAnEpisodeThatAlreadyHasShotsDoesNotGoBackToNaming() {
        let s = shot("[客厅][张三][ ]")
        let result = board([episode(named: false, shots: [s])], shots: [s])
        XCTAssertNotEqual(result.episodes[0].stage, .toName, "已经推理过分镜的集，下一步不退回命名")
    }

    /// 2026-10-17 用户（项目82）：同名两张卡——第6集起的出过图、第7集起的是空卡；第7集这一段手动挂了第6集那张的图。
    /// 之前状态只按「按集号选的默认卡」算：显示「待出图」，自动匹配也跳过。现在按「挂着的优先」解析。
    func testASegmentAttachedToAnEarlierVersionIsReadyInsteadOfWaitingForTheLaterEmptyCard() {
        let early = card("第6集的驾驶训练区", .scene, image: true)
        let late = card("第7集的驾驶训练区", .scene, image: false)
        let lib = UUID()
        let attached = shot("[驾驶训练区][ ][ ]", refs: [lib])
        let episodes = (0..<7).map { $0 == 6 ? episode(shots: [attached]) : episode() }
        let result = board(episodes, shots: [attached], cards: [early, late], libraryCard: [lib: early.id]).episodes[6]
        XCTAssertEqual(result.shots[attached.id]?.names.first?.state, .ready, "挂着第6集那张的图：这一段算有图，不再等第7集的空卡")
        XCTAssertTrue(result.cardsToGenerate.isEmpty, "没有还要出的卡")
        XCTAssertTrue(result.unmatchedShotIDs.isEmpty, "挂着的那张就是解析结果：算已匹配")
        XCTAssertEqual(result.shots[attached.id]?.stage, .toGenerateVideo, "这一段直接进到生成视频")
        XCTAssertEqual(result.stage, .toGenerateVideo, "整集也不该再停在第7集空卡的「待出图」上")
    }

    /// 同一对同名卡，但这一段没挂图：还是等第7集那张卡出图——不因为第6集有图就悄悄退回旧形态（边界见 memory 里的讨论）
    func testWithoutAnAttachmentTheLaterEmptyVersionStillWaitsForItsOwnImage() {
        let early = card("第6集的驾驶训练区", .scene, image: true)
        let late = card("第7集的驾驶训练区", .scene, image: false)
        let bare = shot("[驾驶训练区][ ][ ]")
        let episodes = (0..<7).map { $0 == 6 ? episode(shots: [bare]) : episode() }
        let result = board(episodes, shots: [bare], cards: [early, late]).episodes[6]
        XCTAssertEqual(result.shots[bare.id]?.names.first?.state, .noImage)
        XCTAssertEqual(result.cardsToGenerate, [late.id], "要出的还是第7集那张空卡")
        XCTAssertEqual(result.stage, .toGenerateImages)
    }
}

@MainActor
final class WorkbenchBatchTests: XCTestCase {
    private func setup() -> (AppModel, String) {
        let app = AppModel()
        let key = "wb-batch-" + UUID().uuidString
        app.currentProjectKey = key
        return (app, key)
    }

    func testCardsToDrawSkipBusyAndBlankOnesKeepOrderAndDoNotRepeatAcrossEpisodes() {
        let (app, key) = setup()
        defer { app.imageItems.removeAll { $0.projectKey == key }; app.currentProjectKey = nil }
        let a = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p")
        var busy = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "p"); busy.status = .generating
        let blank = ImageGenItem(projectKey: key, type: .character, name: "丙", prompt: "  ")
        let d = ImageGenItem(projectKey: key, type: .scene, name: "丁", prompt: "p")
        app.imageItems = [a, busy, blank, d]
        var one = WorkbenchStatus.EpisodeStatus(); one.cardsToGenerate = [a.id, busy.id, blank.id]
        var two = WorkbenchStatus.EpisodeStatus(); two.cardsToGenerate = [a.id, d.id]
        let board = WorkbenchStatus.Board(episodes: [one, two])
        XCTAssertEqual(WorkbenchBatch.cardsToGenerate(board: board, indices: [1, 0], app: app).map(\.name), ["甲", "丁"], "按集序、去重，忙着的和没提示词的跳过")
        XCTAssertEqual(WorkbenchBatch.cardsToGenerate(board: board, indices: [1], app: app).map(\.name), ["甲", "丁"])
        XCTAssertEqual(WorkbenchBatch.cardsToGenerate(board: board, indices: [9], app: app).count, 0, "集号越界不崩")
    }

    func testShotsInScopeFollowTheSelectedEpisodesInOrder() {
        let s1 = UUID(), s2 = UUID(), s3 = UUID()
        var one = WorkbenchStatus.EpisodeStatus(); one.shotIDs = [s1, s2]
        var two = WorkbenchStatus.EpisodeStatus(); two.shotIDs = [s3]
        let board = WorkbenchStatus.Board(episodes: [one, two])
        XCTAssertEqual(WorkbenchBatch.shotsInScope(board: board, indices: [1, 0, 0]), [s1, s2, s3])
        XCTAssertEqual(WorkbenchBatch.shotsInScope(board: board, indices: [1]), [s3])
    }

    /// 2026-10-17 用户（项目82）：自动匹配用的是「这一段现在用的那张」（挂着的优先）——
    /// 挂着第6集出的图时，不再被第7集的同名空卡滤掉（原来 `ready` 只看按集号选的默认卡）。
    func testMatchPlanKeepsTheCardTheShotIsAttachedToInsteadOfTheLaterEmptyVersion() {
        let (app, key) = setup()
        defer { app.imageItems.removeAll { $0.projectKey == key }; app.shots.removeAll { $0.projectKey == key }
                app.library.removeAll { $0.projectKey == key }; app.currentProjectKey = nil }
        var early = ImageGenItem(projectKey: key, type: .scene, name: "第6集的驾驶训练区", prompt: "p")
        let result = ImageGenResult(localPath: "/tmp/drive.png", createdAt: Date())
        early.results = [result]; early.status = .success
        let late = ImageGenItem(projectKey: key, type: .scene, name: "第7集的驾驶训练区", prompt: "p")
        app.imageItems = [early, late]
        var item = LibraryItem(kind: .image, localPath: nil, name: "场景-驾驶训练区", projectKey: key)
        item.imageGenResultID = result.id; item.imageGenItemID = early.id
        app.library = [item]
        var attached = ShotDraft(projectKey: key, prompt: "[驾驶训练区][ ][ ]\n正文")
        attached.imageRefs = [MaterialRef(libraryItemID: item.id, role: .referenceImage)]
        app.shots = [attached]
        var episode = Episode(title: "第7集", text: "原文", splitText: "【场景】：驾驶训练区\n【角色】：甲\n甲说话。\n--- 00:00 - 00:30")
        episode.shotIDs = [attached.id]
        let episodes = (0..<6).map { _ in Episode(title: "集", text: "", splitText: nil) } + [episode]
        let board = app.workbenchBoard(project: key, archive: ProjectPipelineArchive(wholeScript: "全文", episodes: episodes))
        let plan = WorkbenchBatch.matchPlan(board: board, indices: [6], app: app)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.selections.map(\.cardID), [early.id], "选的是挂着的那张，不是第7集的空卡")
        XCTAssertEqual(plan.first?.withoutImage, 0)
    }
}

/// 工作台第 3 步：一段分镜里每个素材名的版本列表，和「更换版本」。
@MainActor
final class WorkbenchVersionsTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "wb-versions-" + UUID().uuidString
        app.currentProjectKey = key
    }
    override func tearDown() async throws {
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
        app.shots.removeAll { $0.projectKey == key }
        app.currentProjectKey = nil
    }

    /// 一张出过图的角色卡，图已入库（预先放好，不走真实入库和上传）
    @discardableResult
    private func addCard(_ name: String, image: Bool = true) -> (card: ImageGenItem, lib: Xipixiaojuchang.LibraryItem?) {
        var card = ImageGenItem(projectKey: key, type: .character, name: name, prompt: "p")
        var lib: Xipixiaojuchang.LibraryItem?
        if image {
            let result = ImageGenResult(localPath: "/tmp/\(name).png", createdAt: Date())
            card.results = [result]; card.status = .success
            var item = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-\(name)", projectKey: key)
            item.imageGenResultID = result.id
            app.library.append(item); lib = item
        }
        app.imageItems.append(card)
        return (card, lib)
    }
    private func addShot(_ head: String, refs: [UUID] = []) -> ShotDraft {
        var shot = ShotDraft(projectKey: key, prompt: head + "\n正文")
        shot.imageRefs = refs.map { MaterialRef(libraryItemID: $0, role: .referenceImage) }
        app.shots.append(shot)
        return shot
    }

    func testVersionsOfANameAreListedByEffectiveEpisodeWithTheirLabels() {
        let late = addCard("第24集的周承山").card, plain = addCard("周承山").card, mid = addCard("第8集的周承山", image: false).card
        addCard("沈砚")                                            // 别的名字不进来
        let list = WorkbenchVersions.versions(kind: .role, name: "周承山", cards: app.imageItems)
        XCTAssertEqual(list.map(\.cardID), [plain.id, mid.id, late.id])
        XCTAssertEqual(list.map(\.label), ["基础版", "第8集起", "第24集起"])
        XCTAssertEqual(list.map(\.hasImage), [true, false, true])
        XCTAssertEqual(list[0].imagePath, "/tmp/周承山.png")
    }

    func testTheCurrentVersionIsTheAttachedOneElseTheOneInForceForThatEpisode() {
        let first = addCard("第1集的周承山"), late = addCard("第24集的周承山")
        let attached = addShot("[客厅][周承山][ ]", refs: [late.lib!.id])
        let bare = addShot("[客厅][周承山][ ]")
        XCTAssertEqual(WorkbenchVersions.currentCardID(kind: .role, name: "周承山", shot: attached, episode: 2, cards: app.imageItems, app: app), late.card.id,
                       "挂着哪张就是哪张，不管集号")
        XCTAssertEqual(WorkbenchVersions.currentCardID(kind: .role, name: "周承山", shot: bare, episode: 30, cards: app.imageItems, app: app), late.card.id)
        XCTAssertEqual(WorkbenchVersions.currentCardID(kind: .role, name: "周承山", shot: bare, episode: 5, cards: app.imageItems, app: app), first.card.id)
    }

    func testSwappingReplacesTheRefInPlaceAndKeepsItsNumberAndThePrompt() {
        let first = addCard("第1集的周承山"), late = addCard("第24集的周承山")
        let other = addCard("沈砚")
        let shot = addShot("[图1客厅][图2周承山、图3沈砚][ ]", refs: [UUID(), first.lib!.id, other.lib!.id])
        let before = app.shots.first { $0.id == shot.id }!
        let outcome = WorkbenchVersions.use(card: late.card, name: "周承山", shotID: shot.id, app: app)
        XCTAssertEqual(outcome, .swapped)
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [before.imageRefs[0].libraryItemID, late.lib!.id, other.lib!.id], "只换第 2 张")
        XCTAssertEqual(after.imageRefs[1].id, before.imageRefs[1].id)
        XCTAssertEqual(after.prompt, before.prompt, "「图N」不动")
    }

    func testAttachingAVersionForANameThatIsNotMatchedYetInsertsItsTokenIntoTheHeadLine() {
        let card = addCard("周承山")
        let shot = addShot("[客厅][周承山][ ]")
        XCTAssertEqual(WorkbenchVersions.use(card: card.card, name: "周承山", shotID: shot.id, app: app), .attached)
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [card.lib!.id])
        XCTAssertTrue(after.prompt.hasPrefix("[客厅][图1周承山]"), after.prompt)
    }

    func testAVersionWithoutAnImageOrANameMissingFromTheHeadLineChangesNothing() {
        let noImage = addCard("第9集的周承山", image: false).card
        let ok = addCard("路人")
        let shot = addShot("[客厅][周承山][ ]")
        XCTAssertEqual(WorkbenchVersions.use(card: noImage, name: "周承山", shotID: shot.id, app: app), .noImage)
        XCTAssertEqual(WorkbenchVersions.use(card: ok.card, name: "路人", shotID: shot.id, app: app), .notInHeadLine, "头行里没有这个名字：不挂")
        XCTAssertTrue(app.shots.first { $0.id == shot.id }!.imageRefs.isEmpty)
    }

    func testApplyingTheChosenVersionsSwapsTheAttachedOnesAttachesTheRestAndReportsWhatWasSkipped() {
        let first = addCard("第1集的周承山"), late = addCard("第24集的周承山")
        let scene = addCard("客厅")
        let noImage = addCard("乙", image: false)
        let shot = addShot("[图1客厅][图2周承山、乙、丙][ ]", refs: [UUID(), first.lib!.id])     // 第 2 个参考图 = 周承山（第 1 集的）
        // 周承山：换成第 24 集起的；客厅：选中的（没挂过，头行里名字前没有图号标记的情况另测）；乙：选中的版本没有图；丙：没选
        let report = WorkbenchVersions.apply(
            selections: [(.role, "周承山", late.card.id), (.role, "乙", noImage.card.id), (.role, "丙", nil)],
            shotID: shot.id, cards: app.imageItems, app: app)
        XCTAssertEqual(report, .init(applied: 1, noImage: 2, notInHeadLine: 0))
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs[1].libraryItemID, late.lib!.id, "周承山原位换成第 24 集起的")
        XCTAssertEqual(after.imageRefs.count, 2, "没图的、没选的都没挂")
        _ = scene
    }

    func testApplyingNeverTouchesNamesThatWereNotSelected() {
        let a = addCard("甲"), b = addCard("乙")
        let shot = addShot("[客厅][甲、乙][ ]")
        WorkbenchVersions.apply(selections: [(.role, "甲", a.card.id)], shotID: shot.id, cards: app.imageItems, app: app)
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [a.lib!.id], "只挂了选中的甲，乙没动")
        XCTAssertTrue(after.prompt.hasPrefix("[客厅][图1甲、乙]"), after.prompt)
        _ = b
    }

    func testSegmentImagePlanSplitsFreshFromAlreadyGeneratedAndCountsWhatCannotBeGenerated() {
        let done = addCard("甲").card                                   // 已经有图（前面的段生成过）
        let fresh = addCard("乙", image: false).card
        var busy = ImageGenItem(projectKey: key, type: .character, name: "丙", prompt: "p"); busy.status = .generating
        app.imageItems.append(busy)
        let plan = WorkbenchBatch.segmentImagePlan(cardIDs: [done.id, fresh.id, busy.id, nil, fresh.id], app: app, modelConfigured: { _ in true })
        XCTAssertEqual(plan.fresh, [fresh.id], "同一张卡选了两次只算一次")
        XCTAssertEqual(plan.withImage, [done.id])
        XCTAssertEqual(plan.busy, 1, "正在出图的跳过")
        XCTAssertEqual(plan.noCard, 1, "还没有卡的那一行")
        XCTAssertFalse(plan.blocked)
    }

    func testSegmentImagePlanIsBlockedByAMissingPromptOrAStaleModel() {
        let empty = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "  ")
        app.imageItems.append(empty)
        let other = addCard("乙", image: false).card
        let plan = WorkbenchBatch.segmentImagePlan(cardIDs: [empty.id, other.id], app: app, modelConfigured: { $0.id != other.id })
        XCTAssertEqual(plan.noPrompt, 1)
        XCTAssertEqual(plan.modelIssue, 1)
        XCTAssertTrue(plan.blocked, "有一个不满足就整批拦住，和生图页的批量提交一样")
    }

    func testCardsWhoseShownImageIsNotInTheLibraryYetAreListedBeforeApplying() {
        let inLibrary = addCard("甲").card                              // 图已经在素材库里
        var fresh = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "p")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString).png")
        try? Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        fresh.results = [ImageGenResult(localPath: file.path, createdAt: Date())]; fresh.status = .success
        app.imageItems.append(fresh)
        let noImage = addCard("丙", image: false).card
        XCTAssertEqual(WorkbenchBatch.notInLibrary(cardIDs: [inLibrary.id, fresh.id, noImage.id, nil, fresh.id], app: app), [fresh.id],
                       "只有出过图、还没入库的；同一张卡只算一次")
    }

    func testSuggestionsGroupVersionsSkipPlaceholdersAndFilterByKindAndQuery() {
        addCard("第1集的周承山"); addCard("第24集的周承山", image: false); addCard("周承山十岁时期"); addCard("沈砚", image: false)
        let scene = ImageGenItem(projectKey: key, type: .scene, name: "蕴古斋前柜", prompt: "p")
        let placeholder = ImageGenItem(projectKey: key, type: .character, name: "图片7", prompt: "p")
        let untyped = ImageGenItem(projectKey: key, type: nil, name: "没类型", prompt: "p")
        app.imageItems.append(contentsOf: [scene, placeholder, untyped])
        let all = WorkbenchVersions.suggestions(cards: app.imageItems)
        XCTAssertEqual(all.map(\.name), ["蕴古斋前柜", "周承山", "周承山十岁时期", "沈砚"], "场景在前、角色在后；占位名和没类型的不进来")
        let zhou = try! XCTUnwrap(all.first { $0.name == "周承山" })
        XCTAssertEqual(zhou.versions, 2)
        XCTAssertTrue(zhou.hasImage, "有一个版本出过图就算有图")
        XCTAssertFalse(try! XCTUnwrap(all.first { $0.name == "沈砚" }).hasImage)
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .role, query: "").map(\.name), ["周承山", "周承山十岁时期", "沈砚"], "没搜索词：这一类全列出来")
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .role, query: "砚").map(\.name), ["沈砚"])
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .role, query: "周承山").map(\.name), ["周承山", "周承山十岁时期"])
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .role, query: "十岁").map(\.name), ["周承山十岁时期"], "包含就行，不用从头开始")
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .scene, query: "周").map(\.name), [], "别的类型的卡不混进来")
        XCTAssertEqual(WorkbenchVersions.filter(all, kind: .prop, query: "").map(\.name), [])
    }

    func testTheAttachedVersionIsReadFromTheRefsOnlyWhileTheCurrentOneFallsBackToTheEpisodeRule() {
        let first = addCard("第1集的周承山"), late = addCard("第24集的周承山")
        let bare = addShot("[客厅][周承山][ ]")
        XCTAssertNil(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: bare, cards: app.imageItems, app: app))
        XCTAssertEqual(WorkbenchVersions.currentCardID(kind: .role, name: "周承山", shot: bare, episode: 30, cards: app.imageItems, app: app), late.card.id)
        let attached = addShot("[客厅][周承山][ ]", refs: [first.lib!.id])
        XCTAssertEqual(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: attached, cards: app.imageItems, app: app), first.card.id)
    }
}

/// 工作台按段详情里的「重新推理」：只发这一段、只改这一段的分镜卡。
@MainActor
final class InferSegmentTests: XCTestCase {
    private actor Capture { var users: [String] = []; func add(_ u: String) { users.append(u) } }

    private func fixture(_ app: AppModel) -> (key: String, shots: [ShotDraft]) {
        let key = "infer-seg-" + UUID().uuidString
        let split = "场景：客厅 日 内\n甲说话。\n--- 00:00 - 00:30\n乙说话。\n--- 00:30 - 01:00\n丙说话。\n--- 01:00 - 01:30"
        let shots = (1...3).map { i in ShotDraft(projectKey: key, prompt: "[客厅][人\(i)][ ]\n原来的提示词\(i)。", numbering: ShotNumbering(a: 1, b: i)) }
        app.shots.append(contentsOf: shots)
        var episode = Episode(title: "第1集", text: "原文", splitText: split)
        episode.shotIDs = shots.map(\.id)
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        return (key, shots)
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.shots.removeAll { $0.projectKey == key }
    }
    private func prompt(_ app: AppModel, _ id: UUID) -> String { app.shots.first { $0.id == id }!.prompt }

    func testOnlyThatSegmentIsSentAndOnlyThatShotChangesAndItsOldRefsAreCleared() async throws {
        let app = AppModel(), capture = Capture()
        let (key, shots) = fixture(app)
        defer { cleanup(app, key) }
        // 第 2 段的分镜卡原来挂着一张参考图，提示词里写着「图1」
        var withRef = shots[1]; withRef.prompt = "[客厅][图1人2][ ]\n原来的提示词2。"
        withRef.imageRefs = [MaterialRef(libraryItemID: UUID(), role: .referenceImage)]
        app.shots[app.shots.firstIndex { $0.id == withRef.id }!] = withRef

        let started = app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 2, chat: { _, user in
            await capture.add(user)
            return "[客厅][新人][ ]\n全新的提示词。"
        })
        XCTAssertTrue(started)
        await app.pipelineFlow.waitForAll(project: key)

        let users = await capture.users
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].contains("乙说话。") && users[0].contains("--- 00:30 - 01:00"), "只发这一段，带它自己的时间标号\n" + users[0])
        XCTAssertFalse(users[0].contains("甲说话。") || users[0].contains("丙说话。"), "别的段不发")
        XCTAssertTrue(users[0].contains("[客厅][人1][ ]"), "带上前一段的分镜提示词承接站位")
        XCTAssertEqual(prompt(app, shots[1].id), "[客厅][新人][ ]\n全新的提示词。")
        XCTAssertEqual(prompt(app, shots[0].id), shots[0].prompt, "别的段的分镜卡不动")
        XCTAssertEqual(prompt(app, shots[2].id), shots[2].prompt)
        XCTAssertTrue(app.shots.first { $0.id == shots[1].id }!.imageRefs.isEmpty, "新提示词里没有旧的「图N」：挂着的参考图跟着清掉，要点「应用素材」重新挂")
    }

    func testAReplyWithTheWrongNumberOfBlocksChangesNothing() async throws {
        let app = AppModel()
        let (key, shots) = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 1, chat: { _, _ in
            "[客厅][甲][ ]\n一块\n[客厅][乙][ ]\n又一块"
        })
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertEqual(prompt(app, shots[0].id), shots[0].prompt)
        XCTAssertEqual(app.pipelineFlow.jobs.values.filter { $0.failed }.count, 1, "失败要看得见")
    }

    func testItDoesNotStartWithoutAShotCardOrWhileABatchRuns() async throws {
        let app = AppModel()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        XCTAssertFalse(app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 9, chat: { _, _ in "" }), "没有这一段")
        var archive = try XCTUnwrap(app.pipelineArchive(for: key))
        archive.episodes[0].shotIDs = nil
        app.savePipelineArchive(archive, for: key)
        XCTAssertFalse(app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 1, chat: { _, _ in "" }), "这一段还没有分镜卡：先做「分镜」")
    }
}
