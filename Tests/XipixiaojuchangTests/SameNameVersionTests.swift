import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户实测：重新提取年轻时的周承山，得到的卡叫「第一集的周承山 2」（重名自动加序号）；
/// 在分段详情里点「更换版本」，列表里却只有六十岁的那张——只差重名序号的同名卡也要算这个名字的版本。
@MainActor
final class SameNameVersionTests: XCTestCase {
    func testTheDuplicateNumberIsOnlyASingleDigitAfterASpace() {
        XCTAssertEqual(AssetVersionName.duplicateNumber("周承山 2"), 2)
        XCTAssertEqual(AssetVersionName.duplicateNumber("周承山 9"), 9)
        XCTAssertNil(AssetVersionName.duplicateNumber("周承山 1"), "软件从 2 起编号")
        XCTAssertNil(AssetVersionName.duplicateNumber("iPhone 15"), "两位数是真名字的一部分")
        XCTAssertNil(AssetVersionName.duplicateNumber("周承山2"), "要有空格")
        XCTAssertNil(AssetVersionName.duplicateNumber(" 2"), "前面得有名字")
        XCTAssertEqual(AssetVersionName.withoutDuplicateNumber("周承山 2"), "周承山")
        XCTAssertEqual(AssetVersionName.withoutDuplicateNumber("iPhone 15"), "iPhone 15")
        XCTAssertEqual(AssetVersionName.withoutDuplicateNumber("周承山"), "周承山")
    }

    func testMatchSaysExactSiblingOrUnrelated() {
        XCTAssertEqual(AssetVersionName.match("第一集的周承山", to: "周承山"), 2)
        XCTAssertEqual(AssetVersionName.match("第一集的周承山 2", to: "周承山"), 1)
        XCTAssertEqual(AssetVersionName.match("周承山", to: "周承山 2"), 1, "反过来也是同一个人")
        XCTAssertEqual(AssetVersionName.match("周承山 2", to: "周承山 2"), 2)
        XCTAssertEqual(AssetVersionName.match("周承山 2", to: "周承山 3"), 1)
        XCTAssertEqual(AssetVersionName.match("许曼", to: "周承山"), 0)
        XCTAssertEqual(AssetVersionName.match("周承山十岁时期", to: "周承山"), 0, "换了名字的变化版不在这一条里")
    }

    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "same-name-" + UUID().uuidString
        app.currentProjectKey = key
    }
    override func tearDown() async throws {
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
        app.shots.removeAll { $0.projectKey == key }
        app.currentProjectKey = nil
    }

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
    private func shot(_ id: UUID) -> ShotDraft { app.shots.first { $0.id == id }! }

    func testTheListOfVersionsIncludesTheCardThatOnlyDiffersByTheDuplicateNumber() {
        let old = addCard("第一集的周承山").card, young = addCard("第一集的周承山 2").card
        addCard("许曼 2")                                                    // 别的名字不进来
        let list = WorkbenchVersions.versions(kind: .role, name: "周承山", cards: app.imageItems)
        XCTAssertEqual(list.map(\.cardID), [old.id, young.id])
        XCTAssertEqual(list.map(\.label), ["第1集起", "第1集起（同名 2）"])
        XCTAssertEqual(list.map(\.cardName), ["第一集的周承山", "第一集的周承山 2"], "名字照原样列出，用户一眼分得清")
    }

    func testChoosingTheSiblingSwapsTheRefInPlaceAndThenItIsReadBackAsTheAttachedOne() {
        let old = addCard("第一集的周承山"), young = addCard("第一集的周承山 2")
        let s = addShot("[图1客厅][图2周承山][ ]", refs: [UUID(), old.lib!.id])
        XCTAssertEqual(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: shot(s.id), cards: app.imageItems, app: app), old.card.id)
        XCTAssertEqual(WorkbenchVersions.use(card: young.card, name: "周承山", shotID: s.id, app: app), .swapped)
        XCTAssertEqual(shot(s.id).imageRefs[1].libraryItemID, young.lib!.id)
        XCTAssertEqual(shot(s.id).prompt, s.prompt, "「图N」不动")
        XCTAssertEqual(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: shot(s.id), cards: app.imageItems, app: app), young.card.id,
                       "换完之后这一行读到的是「周承山 2」那张，不会一直显示「待应用」")
    }

    func testAttachingTheSiblingToANameThatIsNotMatchedYetFindsItInTheHeadLineByTheRowsName() {
        let young = addCard("第一集的周承山 2")
        let s = addShot("[客厅][周承山][ ]")
        XCTAssertEqual(WorkbenchVersions.use(card: young.card, name: "周承山", shotID: s.id, app: app), .attached)
        XCTAssertEqual(shot(s.id).imageRefs.map(\.libraryItemID), [young.lib!.id])
        XCTAssertTrue(shot(s.id).prompt.hasPrefix("[客厅][图1周承山]"), shot(s.id).prompt)
    }

    func testWhenTheHeadLineHasBothRowsEachCardGoesToItsOwnRow() {
        let old = addCard("周承山"), young = addCard("周承山 2")
        let s = addShot("[客厅][周承山、周承山 2][ ]")
        XCTAssertEqual(WorkbenchVersions.use(card: young.card, name: "周承山 2", shotID: s.id, app: app), .attached)
        XCTAssertEqual(WorkbenchVersions.use(card: old.card, name: "周承山", shotID: s.id, app: app), .attached)
        let after = shot(s.id)
        XCTAssertEqual(Set(after.imageRefs.map(\.libraryItemID)), [old.lib!.id, young.lib!.id])
        XCTAssertEqual(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: after, cards: app.imageItems, app: app), old.card.id)
        XCTAssertEqual(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山 2", shot: after, cards: app.imageItems, app: app), young.card.id)
    }

    func testARowNeverStealsTheImageThatBelongsToAnotherRowOfTheSameFamily() {
        let old = addCard("周承山"), young = addCard("周承山 2")
        // 行「周承山 2」已经挂好了它自己的图；行「周承山」还没挂
        let s = addShot("[客厅][周承山、图1周承山 2][ ]", refs: [young.lib!.id])
        XCTAssertNil(WorkbenchVersions.attachedCardID(kind: .role, name: "周承山", shot: s, cards: app.imageItems, app: app),
                     "「周承山 2」那张图是人家那一行的")
        XCTAssertEqual(WorkbenchVersions.use(card: old.card, name: "周承山", shotID: s.id, app: app), .attached)
        XCTAssertEqual(shot(s.id).imageRefs.count, 2, "新挂一张，没有把「周承山 2」的图换掉")
    }

    func testRemovingARowTakesAwayTheImageItShowsEvenWhenItIsTheSibling() throws {
        let young = addCard("第一集的周承山 2"), other = addCard("许曼")
        let s = addShot("[客厅][图1周承山、图2许曼][ ]", refs: [young.lib!.id, other.lib!.id])
        try WorkbenchMaterialEdit.remove(name: "周承山", shotID: s.id, app: app)
        XCTAssertEqual(shot(s.id).imageRefs.map(\.libraryItemID), [other.lib!.id])
        XCTAssertTrue(shot(s.id).prompt.hasPrefix("[客厅][图1许曼]"), shot(s.id).prompt)
    }

    func testAutoMatchingTheWholeLibraryNeverAddsASecondVersionOfAFamilyThatIsAlreadyAttached() {
        let old = addCard("周承山"), young = addCard("周承山 2")
        let s = addShot("[客厅][图1周承山][ ]", refs: [young.lib!.id])
        XCTAssertEqual(app.autoMatchMaterials(s.id, detectsDuration: false), 0, "已经挂着「周承山 2」，别再把「周承山」也挂上")
        XCTAssertEqual(shot(s.id).imageRefs.count, 1)
        _ = old
    }

    func testStatusReadsTheSiblingAsTheCardAndAsTheAttachedImage() {
        let young = addCard("第一集的周承山 2")
        var ep = Episode(title: "集", text: "原文", splitText: "分割")
        let s = addShot("[客厅][图1周承山][ ]", refs: [young.lib!.id])
        ep.shotIDs = [s.id]
        let board = WorkbenchStatus.board(.init(
            episodes: [ep], shots: [s.id: s], cards: app.imageItems.filter { $0.projectKey == key },
            libraryKeyword: { id in self.app.libraryItem(id)?.matchKeyword }, videoState: { _ in .none }))
        // 客厅 / 许曼这些没有卡：只看「周承山」这一行——有卡有图、也挂好了
        let names = board.episodes[0].shots[s.id]!.names
        XCTAssertEqual(names.first { $0.name == "周承山" }?.state, .ready)
        XCTAssertTrue(board.episodes[0].missingNames[.role]?.contains("周承山") != true, "只有「周承山 2」这张卡时，「周承山」也算有卡")
        XCTAssertTrue(board.episodes[0].unmatchedShotIDs.isEmpty, "挂着「周承山 2」的图 = 「周承山」这一行已经匹配好了，不会一直显示待匹配")
    }
}
