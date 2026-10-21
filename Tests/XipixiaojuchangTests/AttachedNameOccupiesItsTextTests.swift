import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户项目：第 1 段头行被改成 `[图1年度图6赛车颁奖礼后台]`，还多挂了一张「赛车」道具图。
/// 场景「年度赛车颁奖礼后台」先挂好了，之后再匹配一次：它已经挂着、不再是候选，它那一段文字也没人占着，
/// 库里更短的「赛车」就在它里面匹配上了。已经挂着图的名字，它那一项文字要算占着。
@MainActor
final class AttachedNameOccupiesItsTextTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "occupied-" + UUID().uuidString
        app.currentProjectKey = key
    }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
        app.currentProjectKey = nil
    }

    private func lib(_ name: String) -> Xipixiaojuchang.LibraryItem {
        let item = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: name, projectKey: key)
        app.library.append(item)
        return item
    }
    private func head(_ id: UUID) -> String { app.shots.first { $0.id == id }!.prompt.components(separatedBy: "\n")[0] }

    func testASecondMatchingDoesNotMatchAShorterNameInsideAnAlreadyAttachedOne() {
        let scene = lib("场景-第1集的年度赛车颁奖礼后台"), car = lib("道具-第1集的赛车"), role = lib("角色-第一集的周承山")
        let shot = ShotDraft(projectKey: key, prompt: "[年度赛车颁奖礼后台][许曼、周承山][复检申请副本]\n正文", numbering: ShotNumbering(a: 1, b: 1))
        app.shots.append(shot)
        XCTAssertEqual(app.autoMatchMaterials(shot.id, candidates: [scene], detectsDuration: false), 1)
        XCTAssertEqual(head(shot.id), "[图1年度赛车颁奖礼后台][许曼、周承山][复检申请副本]")
        // 再整库匹配一次：只该多出周承山，「赛车」不能在场景名中间插进去
        XCTAssertEqual(app.autoMatchMaterials(shot.id, detectsDuration: false), 1)
        XCTAssertEqual(head(shot.id), "[图1年度赛车颁奖礼后台][许曼、图2周承山][复检申请副本]")
        let refs = app.shots.first { $0.id == shot.id }!.imageRefs.map(\.libraryItemID)
        XCTAssertEqual(refs, [scene.id, role.id])
        XCTAssertFalse(refs.contains(car.id), "没有多挂赛车那张图")
    }

    func testAShortNameThatIsReallyListedOnItsOwnStillMatchesItsOwnItem() {
        let scene = lib("场景-第1集的年度赛车颁奖礼后台"), car = lib("道具-第1集的赛车")
        let shot = ShotDraft(projectKey: key, prompt: "[年度赛车颁奖礼后台][周承山][赛车]\n正文", numbering: ShotNumbering(a: 1, b: 1))
        app.shots.append(shot)
        XCTAssertEqual(app.autoMatchMaterials(shot.id, candidates: [scene], detectsDuration: false), 1)
        XCTAssertEqual(app.autoMatchMaterials(shot.id, candidates: [car], detectsDuration: false), 1, "头行里单独列了「赛车」：它自己那一项要匹配上")
        XCTAssertEqual(head(shot.id), "[图1年度赛车颁奖礼后台][周承山][图2赛车]")
    }

    func testMatchingEverythingInOneGoStillWorksAsBefore() {
        _ = lib("场景-第1集的年度赛车颁奖礼后台"); _ = lib("道具-第1集的赛车"); _ = lib("角色-第一集的周承山")
        let shot = ShotDraft(projectKey: key, prompt: "[年度赛车颁奖礼后台][周承山][赛车]\n正文", numbering: ShotNumbering(a: 1, b: 1))
        app.shots.append(shot)
        XCTAssertEqual(app.autoMatchMaterials(shot.id, detectsDuration: false), 3)
        XCTAssertEqual(head(shot.id), "[图1年度赛车颁奖礼后台][图2周承山][图3赛车]")
    }
}
