import XCTest
@testable import Xipixiaojuchang

/// 变化版自动带基础版的图当参考图（2026-10-09）：认关联（提取时）+ 出图前挂图（点生成时）。
@MainActor
final class ReferenceLinksTests: XCTestCase {
    private let project = "ref-links"

    private func card(_ name: String, type: ImageSubjectType = .character, project: String? = nil,
                      prompt: String = "这个人是：\"x\"\n描述：三十岁") -> ImageGenItem {
        ImageGenItem(projectKey: project ?? self.project, type: type, name: name, prompt: prompt)
    }

    // MARK: 「参考：…」那一行

    func testTheReferenceLineIsReadAndTakenOutOfThePrompt() {
        let prompt = "这个人是：\"周承山十岁时期\"，古代背景。\n参考：周承山\n描述：十岁男孩，瘦小。"
        let split = ReferenceLinks.splitReferenceLine(prompt)
        XCTAssertEqual(split.name, "周承山")
        XCTAssertEqual(split.prompt, "这个人是：\"周承山十岁时期\"，古代背景。\n描述：十岁男孩，瘦小。", "这一行不是给生图模型看的")
    }

    func testReferenceLineToleratesBulletsQuotesAndHalfWidthColons() {
        XCTAssertEqual(ReferenceLinks.splitReferenceLine("a\n- 参考: 「周承山」。\nb").name, "周承山")
        XCTAssertEqual(ReferenceLinks.splitReferenceLine("a\n  参考 ： “周承山” \nb").name, "周承山")
        XCTAssertEqual(ReferenceLinks.splitReferenceLine("a\n参考：周承山\n参考：别人\nb").prompt, "a\nb", "多写的也一并去掉，取第一个")
        XCTAssertEqual(ReferenceLinks.splitReferenceLine("a\n参考：周承山\n参考：别人\nb").name, "周承山")
    }

    func testOnlyAWholeLineStartingWithCankaoColonCounts() {
        let prompt = "这个人是：\"甲\"\n描述：穿着参考：古装的男人，参考图1的样子。\n参考图：不是这个格式"
        let split = ReferenceLinks.splitReferenceLine(prompt)
        XCTAssertNil(split.name)
        XCTAssertEqual(split.prompt, prompt, "描述里出现「参考」两个字不能被误当成关联")
        XCTAssertNil(ReferenceLinks.splitReferenceLine("a\n参考：\nb").name, "只有「参考：」没有名字：不算")
        XCTAssertEqual(ReferenceLinks.splitReferenceLine("a\n参考：\nb").prompt, "a\nb")
    }

    // MARK: 认基础版

    /// 2026-10-14 用户定：变化版只写「改了什么」，是在上一版的基础上改的 → 参考图取起始集更早的**最近一版**（原来取最早一版）
    func testAVersionPrefixedCardPointsAtTheMostRecentEarlierVersionOfTheSameBaseName() {
        let first = card("第1集的周承山"), mid = card("第8集的周承山"), late = card("第24集的周承山")
        let other = card("第1集的沈惊澜")
        let all = [late, mid, first, other]            // 列表顺序打乱：看集号，不看位置
        XCTAssertEqual(ReferenceLinks.base(for: late, referenceName: nil, among: all)?.id, mid.id, "上一版")
        XCTAssertEqual(ReferenceLinks.base(for: mid, referenceName: nil, among: all)?.id, first.id)
        XCTAssertNil(ReferenceLinks.base(for: first, referenceName: nil, among: all), "最早的一张自己就是基础版")
    }

    func testAPlainCardNamedWithoutPrefixIsTheBaseOfLaterPrefixedOnes() {
        let plain = card("周承山"), later = card("第12集的周承山")
        XCTAssertEqual(ReferenceLinks.base(for: later, referenceName: nil, among: [later, plain])?.id, plain.id, "没有前缀 = 全程有效，算最早")
        XCTAssertNil(ReferenceLinks.base(for: plain, referenceName: nil, among: [later, plain]), "没有前缀、AI 也没写参考：不是变化版")
    }

    func testAnExplicitReferenceFindsTheEarliestCardOfThatBaseName() {
        let first = card("第1集的周承山"), later = card("第24集的周承山")
        let young = card("周承山十岁时期")
        XCTAssertEqual(ReferenceLinks.base(for: young, referenceName: "周承山", among: [later, first, young])?.id, first.id)
        XCTAssertEqual(ReferenceLinks.base(for: young, referenceName: "第24集的周承山", among: [later, first, young])?.id, first.id,
                       "写成带前缀的名字也按基础名找")
        XCTAssertNil(ReferenceLinks.base(for: young, referenceName: "不存在", among: [later, first, young]))
    }

    func testNamesThatMerelyContainAnotherNameAreNeverGuessedAsVariants() {
        let son = card("沈砚"), father = card("沈砚之父")
        XCTAssertNil(ReferenceLinks.base(for: father, referenceName: nil, among: [son, father]), "子串不算关联：猜错比没有更糟")
        XCTAssertNil(ReferenceLinks.base(for: son, referenceName: nil, among: [son, father]))
    }

    func testOnlySameProjectAndSameTypeCardsAreCandidates() {
        let mine = card("周承山十岁时期")
        let otherType = card("第1集的周承山", type: .prop)
        let otherProject = card("第1集的周承山", project: "别的项目")
        XCTAssertNil(ReferenceLinks.base(for: mine, referenceName: "周承山", among: [mine, otherType, otherProject]))
        let right = card("第1集的周承山")
        XCTAssertEqual(ReferenceLinks.base(for: mine, referenceName: "周承山", among: [mine, otherType, otherProject, right])?.id, right.id)
    }

    // MARK: 一批新卡

    func testAssignLinksTheVariantsOfAFreshBatchAndLeavesBasesAlone() {
        let a1 = card("第1集的周承山"), a24 = card("第24集的周承山"), young = card("周承山十岁时期"), lone = card("赵六")
        let result = ReferenceLinks.assign(cards: [a1, a24, young, lone], referenceNames: [nil, nil, "周承山", nil], items: [a1, a24, young, lone])
        XCTAssertEqual(result.links, [a24.id: a1.id, young.id: a1.id])
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testAnUnresolvableReferenceIsReportedAndLinksNothing() {
        let young = card("周承山十岁时期")
        let result = ReferenceLinks.assign(cards: [young], referenceNames: ["周承山"], items: [young])
        XCTAssertTrue(result.links.isEmpty)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.notes[0].contains("周承山十岁时期") && result.notes[0].contains("参考：周承山"), result.notes[0])
    }

    func testALinkThatWouldCloseACircleIsDropped() {
        // 两张换了名字的卡互相写了对方：出图会互相等，一个都不连
        var a = card("甲时期"), b = card("乙时期")
        a.referenceCardID = nil
        b.referenceCardID = a.id           // b 已经指向 a
        XCTAssertTrue(ReferenceLinks.wouldCycle(card: a.id, base: b.id, links: [b.id: a.id]))
        XCTAssertFalse(ReferenceLinks.wouldCycle(card: b.id, base: a.id, links: [:]))
        let result = ReferenceLinks.assign(cards: [a], referenceNames: ["乙时期"], items: [a, b])
        XCTAssertTrue(result.links.isEmpty, "a → b 会绕回 a：不连")
    }

    // MARK: 提示词里补一句

    func testThePromptGetsTheReferenceSentenceBeforeTheDescriptionLine() {
        XCTAssertEqual(ReferenceLinks.promptWithReferenceLine("这个人是：\"周承山\"，古代背景。\n描述：四十岁，鬓角白发。", token: 1),
                       "这个人是：\"周承山\"，古代背景。\n根据图1参考生成。\n描述：四十岁，鬓角白发。")
        XCTAssertEqual(ReferenceLinks.promptWithReferenceLine("这个人是：\"周承山\"\n四十岁，鬓角白发。", token: 2),
                       "这个人是：\"周承山\"\n根据图2参考生成。\n四十岁，鬓角白发。", "没有「描述」行就放在第一行后面")
        XCTAssertEqual(ReferenceLinks.promptWithReferenceLine("一行字", token: 1), "一行字\n根据图1参考生成。")
        XCTAssertEqual(ReferenceLinks.promptWithReferenceLine("", token: 1), "根据图1参考生成。")
    }

    func testThePromptIsLeftAloneWhenItAlreadyHasTheSentence() {
        let prompt = "这个人是：\"周承山\"\n根据图1参考生成。\n描述：四十岁"
        XCTAssertEqual(ReferenceLinks.promptWithReferenceLine(prompt, token: 1), prompt, "反复生成不会越补越多")
    }

    // MARK: 数据

    func testTheLinkSurvivesSavingAndOldDataWithoutItStillLoads() throws {
        var item = card("第24集的周承山")
        item.referenceCardID = UUID()
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(ImageGenItem.self, from: data).referenceCardID, item.referenceCardID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "referenceCardID")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(ImageGenItem.self, from: old).referenceCardID, "旧数据没有这个字段：不能整个解码失败")
    }
}

/// 点「生成」之前：变化版把基础版的图挂成参考图（`AppModel.prepareBaseReference`）。
/// 素材库条目都是预先放好的（带 `imageGenResultID`），不走真实入库和上传。
@MainActor
final class BaseReferenceGenerationTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "base-ref-" + UUID().uuidString
        AppModel.baseReferencePollInterval = .milliseconds(10)
    }
    override func tearDown() async throws {
        AppModel.baseReferencePollInterval = .milliseconds(250)
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
    }

    /// 一张出过图的基础版（成功、一个结果、结果已入库）。返回 (卡片, 结果 ID, 素材库条目 ID)
    @discardableResult
    private func addBase(_ name: String = "第1集的周承山", withImage: Bool = true) -> (ImageGenItem, UUID?, UUID?) {
        var item = ImageGenItem(projectKey: key, type: .character, name: name, prompt: "这个人是：\"\(name)\"\n描述：三十岁")
        var resultID: UUID?, libraryID: UUID?
        if withImage {
            let result = ImageGenResult(localPath: nil, createdAt: Date())
            item.results = [result]
            item.status = .success
            resultID = result.id
            var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-\(name)", projectKey: key)
            lib.imageGenResultID = result.id
            app.library.append(lib)
            libraryID = lib.id
        }
        app.imageItems.append(item)
        return (item, resultID, libraryID)
    }

    private func addVariant(of base: ImageGenItem, name: String = "第24集的周承山",
                            prompt: String = "这个人是：\"第24集的周承山\"，古代背景。\n描述：四十岁，鬓角白发。") -> ImageGenItem {
        var item = ImageGenItem(projectKey: key, type: .character, name: name, prompt: prompt)
        item.referenceCardID = base.id
        item.status = .queued
        app.imageItems.append(item)
        return item
    }

    private func current(_ id: UUID) -> ImageGenItem { app.imageItems.first { $0.id == id }! }

    func testTheBaseImageBecomesImageOneAndThePromptSaysSo() async {
        let (base, _, libraryID) = addBase()
        let variant = addVariant(of: base)
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertTrue(ok)
        let after = current(variant.id)
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [libraryID!])
        XCTAssertEqual(after.imageRefs.first?.role, .referenceImage)
        XCTAssertEqual(after.prompt, "这个人是：\"第24集的周承山\"，古代背景。\n根据图1参考生成。\n描述：四十岁，鬓角白发。")
        XCTAssertEqual(after.status, .queued, "挂图不改状态，后面照常往下生成")
        XCTAssertEqual(after.referenceCardID, base.id)
    }

    func testDoingItTwiceChangesNothingTheSecondTime() async {
        let (base, _, _) = addBase()
        let variant = addVariant(of: base)
        _ = await app.prepareBaseReference(for: variant.id)
        let once = current(variant.id)
        _ = await app.prepareBaseReference(for: variant.id)
        let twice = current(variant.id)
        XCTAssertEqual(twice.imageRefs, once.imageRefs, "不会重复挂")
        XCTAssertEqual(twice.prompt, once.prompt, "提示词里不会重复补那一句")
    }

    // MARK: 2026-10-11：软件不再替用户把基础版入库

    /// 「全部生成」：基础版和变化版同时点的。基础版一生成好，变化版**不能**接着把它刚生成的那一版自动入库——
    /// 用户还没看过。等用户自己入库一版，变化版才继续。
    func testAVariantSubmittedTogetherWaitsForTheUserToSaveAVersionAndNeverSavesItItself() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(40))

        // 基础版第一版生成好了（没入库）
        let first = ImageGenResult(localPath: nil, createdAt: Date())
        let j = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[j].results = [first]
        app.imageItems[j].status = .success
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(app.library.filter { $0.projectKey == key }.count, 0, "软件不替用户入库")
        XCTAssertEqual(current(variant.id).status, .queued, "还在排队，不失败、不往下走")
        XCTAssertTrue(current(variant.id).imageRefs.isEmpty)
        XCTAssertEqual(current(variant.id).errorMessage, "等「第1集的周承山」入库一版定妆图后自动继续", "卡片上写明在等什么")

        // 用户看过以后自己入库了这一版
        var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-第1集的周承山", projectKey: key)
        lib.imageGenResultID = first.id
        app.library.append(lib)
        let ok = await task.value
        XCTAssertTrue(ok)
        let after = current(variant.id)
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [lib.id], "用的是用户入库的那一版")
        XCTAssertNil(after.errorMessage, "等的提示清掉了")
        XCTAssertTrue(after.prompt.contains("根据图1参考生成。"), after.prompt)
    }

    func testRerollingTheBaseWhileTheVariantWaitsKeepsItWaitingForTheVersionTheUserSaves() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(30))                  // 让它先看到「基础版正在做」
        let first = ImageGenResult(localPath: nil, createdAt: Date()), second = ImageGenResult(localPath: nil, createdAt: Date())
        let j = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[j].results = [first]; app.imageItems[j].status = .success
        try await Task.sleep(for: .milliseconds(40))
        app.imageItems[j].status = .generating                       // 用户不满意，重新出一版
        try await Task.sleep(for: .milliseconds(40))
        app.imageItems[j].results.append(second); app.imageItems[j].status = .success
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(current(variant.id).status, .queued)
        XCTAssertTrue(current(variant.id).imageRefs.isEmpty)
        // 用户只入库了第二版
        var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-第1集的周承山-2", projectKey: key)
        lib.imageGenResultID = second.id
        app.library.append(lib)
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertEqual(current(variant.id).imageRefs.map(\.libraryItemID), [lib.id])
    }

    func testABaseFinishedLongAgoAndNeverSavedStopsTheVariantAtOnceWithAClearReason() async {
        let (base, _, libraryID) = addBase()
        app.library.removeAll { $0.id == libraryID }                        // 做完了，但没入库
        let variant = addVariant(of: base)
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertFalse(ok, "不挂着等：点的时候基础版就已经做完了")
        let after = current(variant.id)
        XCTAssertEqual(after.status, .failed)
        XCTAssertEqual(after.errorMessage, "「第1集的周承山」还没有入库的版本：先在它那里选好一版，点「保存到素材库」，再生成这一张。")
        XCTAssertEqual(app.library.filter { $0.projectKey == key }.count, 0, "更不会自动入库")
        XCTAssertEqual(after.referenceCardID, base.id, "关联保留：入库以后再点生成就行")
    }

    func testWhenTheShownVersionIsNotSavedTheNewestSavedVersionIsUsed() async {
        let (base, firstResult, firstLib) = addBase()
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].results.append(ImageGenResult(localPath: nil, createdAt: Date()))   // 最新一版没入库
        let variant = addVariant(of: base)
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(current(variant.id).imageRefs.map(\.libraryItemID), [firstLib!], "用入库过的那一版，不去入库最新的")
        XCTAssertEqual(app.library.filter { $0.projectKey == key }.count, 1)
        _ = firstResult
    }

    func testStoppingWhileWaitingForTheUserToSaveMarksTheVariantStopped() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(30))                  // 让它先看到「基础版正在做」
        let result = ImageGenResult(localPath: nil, createdAt: Date())
        let j = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[j].results = [result]; app.imageItems[j].status = .success
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(current(variant.id).status, .failed)
        XCTAssertEqual(current(variant.id).errorMessage, "已停止")
    }

    func testADeletedBaseWhileTheVariantWaitsDropsTheLinkAndLetsItGenerate() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(40))
        app.imageItems.removeAll { $0.id == base.id }
        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertNil(current(variant.id).referenceCardID)
    }

    func testTheSelectedResultIsTheOneUsedNotJustTheLatest() async {
        let (base, firstResult, firstLib) = addBase()
        // 基础版又出了一版，但用户挑的是第一版
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].results.append(ImageGenResult(localPath: nil, createdAt: Date()))
        app.imageItems[i].selectedResultID = firstResult
        let variant = addVariant(of: base)
        _ = await app.prepareBaseReference(for: variant.id)
        XCTAssertEqual(current(variant.id).imageRefs.map(\.libraryItemID), [firstLib!], "挑中的那张，没挑才是最新")
    }

    func testRegeneratingTheBaseSwapsTheReferenceInPlaceAndKeepsTheNumber() async {
        let (base, _, _) = addBase()
        let variant = addVariant(of: base)
        _ = await app.prepareBaseReference(for: variant.id)
        let before = current(variant.id)
        // 基础版重新出了图，用户用的是新的这张
        let newResult = ImageGenResult(localPath: nil, createdAt: Date())
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].results.append(newResult)
        app.imageItems[i].selectedResultID = newResult.id
        var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-第1集的周承山-1", projectKey: key)
        lib.imageGenResultID = newResult.id
        app.library.append(lib)

        _ = await app.prepareBaseReference(for: variant.id)
        let after = current(variant.id)
        XCTAssertEqual(after.imageRefs.count, 1, "换掉，不是再加一张")
        XCTAssertEqual(after.imageRefs[0].libraryItemID, lib.id)
        XCTAssertEqual(after.imageRefs[0].id, before.imageRefs[0].id)
        XCTAssertEqual(after.prompt, before.prompt, "图号不变，提示词不用动")
    }

    func testAnotherReferenceTheUserAddedKeepsItsNumberAndTheBaseGoesAfterIt() async {
        let (base, _, libraryID) = addBase()
        var lib = LibraryItem(kind: .image, localPath: nil, name: "道具-怀表", projectKey: key)
        lib.imageGenResultID = nil
        app.library.append(lib)
        var variant = addVariant(of: base)
        let i = app.imageItems.firstIndex { $0.id == variant.id }!
        app.imageItems[i].imageRefs = [MaterialRef(libraryItemID: lib.id, role: .referenceImage)]
        variant = current(variant.id)
        _ = await app.prepareBaseReference(for: variant.id)
        let after = current(variant.id)
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [lib.id, libraryID!])
        XCTAssertTrue(after.prompt.contains("根据图2参考生成。"), after.prompt)
    }

    func testABaseWithoutAnImageStopsTheRequestAndNamesWhoToGenerateFirst() async {
        let (base, _, _) = addBase(withImage: false)
        let variant = addVariant(of: base)
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertFalse(ok)
        let after = current(variant.id)
        XCTAssertEqual(after.status, .failed)
        XCTAssertEqual(after.errorMessage, "要先给「第1集的周承山」出图：这一张要拿它当参考图。先生成它，再生成这一张。")
        XCTAssertTrue(after.imageRefs.isEmpty)
        XCTAssertEqual(after.prompt, "这个人是：\"第24集的周承山\"，古代背景。\n描述：四十岁，鬓角白发。", "没挂上图就不补那一句")
        XCTAssertEqual(after.referenceCardID, base.id, "关联保留：基础版出了图以后再点生成就行")
    }

    func testAFailedBaseWhoseImageWasNeverSavedCountsAsNoImage() async {
        let (base, _, libraryID) = addBase()
        app.library.removeAll { $0.id == libraryID }                       // 这张图没入库
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .failed                                  // 最近一次重新生成失败了
        let variant = addVariant(of: base)
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertFalse(ok, "失败状态的卡不能入库，也就没有可挂的图")
        XCTAssertEqual(current(variant.id).status, .failed)
    }

    func testGeneratingAVariantWhoseBaseHasNoImageSendsNothing() async {
        let (base, _, _) = addBase(withImage: false)
        let variant = addVariant(of: base)
        await app.generateImageItem(variant.id)          // 没配渠道也没关系：在发请求之前就该停下
        let after = current(variant.id)
        XCTAssertEqual(after.status, .failed)
        XCTAssertTrue(after.errorMessage?.contains("要先给「第1集的周承山」出图") == true, after.errorMessage ?? "")
        XCTAssertTrue(after.results.isEmpty)
    }

    func testAVariantWaitsForABaseThatIsStillGeneratingThenGoesAhead() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating            // 「全部生成」：基础版和变化版是同时点的
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(current(variant.id).status, .queued, "基础版没做完：变化版在排队，不失败")
        XCTAssertTrue(current(variant.id).imageRefs.isEmpty)

        // 基础版出图了
        let result = ImageGenResult(localPath: nil, createdAt: Date())
        var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-第1集的周承山", projectKey: key)
        lib.imageGenResultID = result.id
        app.library.append(lib)
        let j = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[j].results = [result]
        app.imageItems[j].status = .success

        let ok = await task.value
        XCTAssertTrue(ok)
        XCTAssertEqual(current(variant.id).imageRefs.map(\.libraryItemID), [lib.id])
    }

    func testStoppingWhileWaitingForTheBaseMarksTheVariantStopped() async throws {
        let (base, _, _) = addBase(withImage: false)
        let i = app.imageItems.firstIndex { $0.id == base.id }!
        app.imageItems[i].status = .generating
        let variant = addVariant(of: base)
        let task = Task { await self.app.prepareBaseReference(for: variant.id) }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(current(variant.id).status, .failed)
        XCTAssertEqual(current(variant.id).errorMessage, "已停止")
    }

    func testADeletedBaseDropsTheLinkAndTheVariantGeneratesAsAPlainCard() async {
        let (base, _, _) = addBase()
        let variant = addVariant(of: base)
        app.imageItems.removeAll { $0.id == base.id }
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertTrue(ok)
        XCTAssertNil(current(variant.id).referenceCardID)
        XCTAssertTrue(current(variant.id).imageRefs.isEmpty)
    }

    func testACardWithoutALinkIsUntouched() async {
        addBase()
        var plain = ImageGenItem(projectKey: key, type: .character, name: "赵六", prompt: "这个人是：\"赵六\"")
        plain.status = .queued
        app.imageItems.append(plain)
        let ok = await app.prepareBaseReference(for: plain.id)
        XCTAssertTrue(ok)
        XCTAssertEqual(current(plain.id), plain)
    }

    func testRemovingTheBaseImageFromTheVariantCancelsTheLinkButRemovingAnotherOneDoesNot() async {
        let (base, _, _) = addBase()
        var other = LibraryItem(kind: .image, localPath: nil, name: "道具-怀表", projectKey: key)
        other.imageGenResultID = nil
        app.library.append(other)
        let variant = addVariant(of: base)
        let i = app.imageItems.firstIndex { $0.id == variant.id }!
        app.imageItems[i].imageRefs = [MaterialRef(libraryItemID: other.id, role: .referenceImage)]
        _ = await app.prepareBaseReference(for: variant.id)
        let refs = current(variant.id).imageRefs
        XCTAssertEqual(refs.count, 2)

        app.removeImageItemMaterial(itemID: variant.id, refID: refs[0].id)          // 删的是别的图
        XCTAssertEqual(current(variant.id).referenceCardID, base.id, "删别的参考图，关联还在")

        let baseRef = current(variant.id).imageRefs[0]
        app.removeImageItemMaterial(itemID: variant.id, refID: baseRef.id)          // 删的是基础版的图
        XCTAssertNil(current(variant.id).referenceCardID, "不想要基础版的图：关联取消，不然下次生成又挂回来")
        let ok = await app.prepareBaseReference(for: variant.id)
        XCTAssertTrue(ok)
        XCTAssertTrue(current(variant.id).imageRefs.isEmpty)
    }
}
