import XCTest
@testable import Xipixiaojuchang

/// 工作台的「其他分镜」（2026-10-14 把生视频并进工作台）：不属于任何一集的分镜，按项目里的先后排；
/// 状态和集里的分镜同一套规则，挑版本只认「全程有效」的（没有集号可按）
@MainActor
final class WorkbenchOtherShotsTests: XCTestCase {
    func testOtherShotsAreThoseNoEpisodeListsInProjectOrder() throws {
        let app = AppModel()
        let key = "other-" + UUID().uuidString
        app.currentProjectKey = key
        let early = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n早期在生视频页做的")
        let inEpisode = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n第 1 集第 1 段")
        let staleOne = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n第 2 集（分割改过）")
        let late = ShotDraft(projectKey: key, prompt: "[客栈][乙][ ]\n后来手动新建的")
        app.shots = [early, inEpisode, staleOne, late]
        var base = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p")
        base.results = [ImageGenResult(localPath: "/tmp/other-a.png", createdAt: Date())]; base.status = .success
        var onlyLater = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "p")
        onlyLater.fromEpisode = 3
        onlyLater.results = [ImageGenResult(localPath: "/tmp/other-b.png", createdAt: Date())]; onlyLater.status = .success
        var scene = ImageGenItem(projectKey: key, type: .scene, name: "客栈", prompt: "p")
        scene.results = [ImageGenResult(localPath: "/tmp/other-s.png", createdAt: Date())]; scene.status = .success
        app.imageItems = [base, onlyLater, scene]
        var ep1 = Episode(title: "第1集", text: "原文")
        ep1.splitText = "=== [00:00-00:30] ===\n【场景】：客栈\n△ 段。\n"
        ep1.shotIDs = [inEpisode.id]
        var ep2 = Episode(title: "第2集", text: "原文")
        ep2.splitText = "=== [00:00-00:30] ===\n【场景】：客栈\n△ 段。\n=== [00:30-01:00] ===\n【场景】：客栈\n△ 段。\n"
        ep2.shotIDs = [staleOne.id]
        ep2.storyboardSplitSignature = "1|00:00 - 00:30"      // 分割改过：这一集回到待推理，但它的卡仍算这一集的，不进「其他分镜」
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [ep1, ep2]), for: key)
        defer { app.shots = []; app.imageItems = []; app.removePipelineArchive(for: key) }

        let board = app.workbenchBoard(project: key, archive: try XCTUnwrap(app.pipelineArchive(for: key)))
        XCTAssertEqual(board.otherShotIDs, [early.id, late.id], "按项目里的先后；属于某一集的（含分割改过的）不算")
        XCTAssertEqual(board.others[early.id]?.names.filter { $0.kind == .role }.map(\.state), [.ready], "甲有全程有效的那张")
        XCTAssertEqual(board.others[late.id]?.names.filter { $0.kind == .role }.map(\.state), [.missing], "乙只有第 3 集起的版本：没有集号可按，不挑")
        XCTAssertEqual(board.others[early.id]?.stage, .toMatch, "有图但还没挂上")
        XCTAssertNil(board.episodes[0].shots[early.id], "不混进哪一集")
    }

    func testAProjectWithOnlyShotsStillGetsABoard() throws {
        let app = AppModel()
        let key = "other-only-" + UUID().uuidString
        app.currentProjectKey = key
        let shot = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n镜头")
        app.shots = [shot]
        defer { app.shots = [] }
        let board = app.workbenchBoard(project: key, archive: ProjectPipelineArchive(wholeScript: "", episodes: []))
        XCTAssertEqual(board.otherShotIDs, [shot.id], "没导入剧本的老项目：所有分镜都在「其他分镜」里")
        XCTAssertTrue(board.episodes.isEmpty)
    }
}
