import XCTest
@testable import Xipixiaojuchang

/// 工作台「本段素材」里加 / 删名字，就是改分镜头行本身（2026-10-09）。
final class HeadLineEditTests: XCTestCase {
    private func add(_ name: String, _ kind: PipelineFlow.ExtractionKind, _ prompt: String) throws -> String {
        try HeadLineEdit.adding(name, kind: kind, to: prompt)
    }

    func testAddingAppendsToTheRightGroupAndLeavesTheRestAlone() throws {
        let body = "\n【角色初始站位与朝向】甲站着。\n中景。"
        XCTAssertEqual(try add("乙", .role, "[客厅][甲][ ]" + body), "[客厅][甲、乙][ ]" + body)
        XCTAssertEqual(try add("怀表", .prop, "[客厅][甲][ ]" + body), "[客厅][甲][怀表]" + body, "空的一组（只有一个空格）直接写名字")
        XCTAssertEqual(try add("院子", .scene, "[][甲][]" + body), "[院子][甲][]" + body)
        XCTAssertEqual(try add("丙", .role, "[客厅][甲、乙][怀表]" + body), "[客厅][甲、乙、丙][怀表]" + body)
    }

    func testAddingKeepsTheMaterialTokensOnTheOtherItems() throws {
        XCTAssertEqual(try add("丙", .role, "[图1客厅][图2甲、图3乙][ ]\n正文"), "[图1客厅][图2甲、图3乙、丙][ ]\n正文")
    }

    func testAddingRefusesBadOrDuplicateNamesAndBadHeadLines() {
        XCTAssertThrowsError(try add("  ", .role, "[客厅][甲][ ]"))
        XCTAssertThrowsError(try add("乙、丙", .role, "[客厅][甲][ ]"), "一次只能加一个名字")
        XCTAssertThrowsError(try add("乙]", .role, "[客厅][甲][ ]"))
        XCTAssertThrowsError(try add(String(repeating: "长", count: 31), .role, "[客厅][甲][ ]"))
        XCTAssertThrowsError(try add("甲", .role, "[客厅][甲][ ]"), "头行里已经有了")
        XCTAssertThrowsError(try add("甲", .prop, "[客厅][图2甲][ ]"), "别的组里有同名的也算重复（带「图N」也认）")
        XCTAssertThrowsError(try add("乙", .role, "正文第一行不是头行\n[客厅][甲][ ]"))
    }

    func testRemovingTakesTheNameOutOfItsGroupWithItsSeparator() throws {
        XCTAssertEqual(try HeadLineEdit.removing("甲", from: "[客厅][甲、乙、丙][ ]\n正文"), "[客厅][乙、丙][ ]\n正文")
        XCTAssertEqual(try HeadLineEdit.removing("乙", from: "[客厅][甲、乙、丙][ ]"), "[客厅][甲、丙][ ]")
        XCTAssertEqual(try HeadLineEdit.removing("丙", from: "[客厅][甲、乙、丙][ ]"), "[客厅][甲、乙][ ]", "删最后一项：前面多出来的顿号也不要")
        XCTAssertEqual(try HeadLineEdit.removing("怀表", from: "[客厅][甲][怀表]"), "[客厅][甲][]", "删到空：留一对空括号，头行格式还在")
        XCTAssertEqual(try HeadLineEdit.removing("甲", from: "[客厅][甲，乙][ ]"), "[客厅][乙][ ]", "逗号也认")
    }

    func testRemovingFindsTheNameThroughTokensAndSceneMarkers() throws {
        XCTAssertEqual(try HeadLineEdit.removing("乙", from: "[图1客厅][图2甲、图3乙][ ]"), "[图1客厅][图2甲][ ]", "名字前的「图N」跟着这一项走")
        XCTAssertEqual(try HeadLineEdit.removing("蕴古斋前柜", from: "[蕴古斋前柜 日 内][甲][ ]"), "[][甲][ ]", "场景后面的「日 内」不影响认名字")
        XCTAssertThrowsError(try HeadLineEdit.removing("不存在", from: "[客厅][甲][ ]"))
        XCTAssertThrowsError(try HeadLineEdit.removing("甲", from: "没有头行"))
    }

    func testTheHeadLineStillParsesAfterEveryEdit() throws {
        var prompt = "[客厅][甲][ ]\n正文"
        prompt = try add("乙", .role, prompt)
        prompt = try add("怀表", .prop, prompt)
        prompt = try HeadLineEdit.removing("甲", from: prompt)
        let head = try XCTUnwrap(StoryboardNames.head(of: prompt))
        XCTAssertEqual(head.scenes, ["客厅"])
        XCTAssertEqual(head.roles, ["乙"])
        XCTAssertEqual(head.props, ["怀表"])
    }
}

@MainActor
final class WorkbenchMaterialEditTests: XCTestCase {
    private var app: AppModel!
    private var key: String!
    override func setUp() async throws { app = AppModel(); key = "mat-edit-" + UUID().uuidString; app.currentProjectKey = key }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
        app.currentProjectKey = nil
    }

    func testAddingWritesTheHeadLineOfThatShotOnly() throws {
        let a = ShotDraft(projectKey: key, prompt: "[客厅][甲][ ]\n正文")
        let b = ShotDraft(projectKey: key, prompt: "[客厅][甲][ ]\n正文")
        app.shots = [a, b]
        try WorkbenchMaterialEdit.add(name: "乙", kind: .role, shotID: a.id, app: app)
        XCTAssertEqual(app.shots.first { $0.id == a.id }!.prompt, "[客厅][甲、乙][ ]\n正文")
        XCTAssertEqual(app.shots.first { $0.id == b.id }!.prompt, "[客厅][甲][ ]\n正文", "别的分镜不动")
    }

    func testRemovingAlsoDropsTheAttachedImageAndRenumbersTheRest() throws {
        let sceneLib = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "场景-客厅", projectKey: key)
        let roleA = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-甲", projectKey: key)
        let roleB = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-乙", projectKey: key)
        app.library = [sceneLib, roleA, roleB]
        var shot = ShotDraft(projectKey: key, prompt: "[图1客厅][图2甲、图3乙][ ]\n图2甲站着，图3乙坐着。")
        shot.imageRefs = [sceneLib, roleA, roleB].map { MaterialRef(libraryItemID: $0.id, role: .referenceImage) }
        app.shots = [shot]
        try WorkbenchMaterialEdit.remove(name: "甲", shotID: shot.id, app: app)
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [sceneLib.id, roleB.id], "甲的参考图去掉了")
        XCTAssertEqual(after.prompt, "[图1客厅][图2乙][ ]\n甲站着，图2乙坐着。", "「图2」（甲）清掉，原来的「图3」（乙）前移成「图2」")
    }

    func testARemovalThatCannotEditTheHeadLineChangesNothingAtAll() {
        let lib = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-甲", projectKey: key)
        app.library = [lib]
        var shot = ShotDraft(projectKey: key, prompt: "没有头行，图1甲站着。")
        shot.imageRefs = [MaterialRef(libraryItemID: lib.id, role: .referenceImage)]
        app.shots = [shot]
        XCTAssertThrowsError(try WorkbenchMaterialEdit.remove(name: "甲", shotID: shot.id, app: app))
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.imageRefs.count, 1, "头行改不动：参考图也不去掉")
        XCTAssertEqual(after.prompt, shot.prompt)
    }
}
