import XCTest
@testable import Xipixiaojuchang

/// 2026-10-15 用户：重新推理出来的提示词算一个「待生成」版本，排在历史版本最后；只要一个，再推理就覆盖
@MainActor
final class PendingVersionTests: XCTestCase {
    private func setUp(_ app: AppModel) -> UUID {
        app.currentProjectKey = "pending-" + UUID().uuidString
        let id = app.addShot()
        let i = app.shots.firstIndex { $0.id == id }!
        for (n, t) in ["t1", "t2"].enumerated() {
            app.store.add(LocalTask(id: t, model: "m", prompt: "第\(n + 1)版提示词", duration: 5, phase: .completed,
                                    createdAt: Date(), updatedAt: Date()))
        }
        app.shots[i].taskIDs = ["t1", "t2"]
        app.shots[i].taskID = "t2"
        app.shots[i].prompt = "第2版提示词"
        return id
    }

    private func shot(_ app: AppModel, _ id: UUID) -> ShotDraft { app.shots.first { $0.id == id }! }

    func testReinferMakesAPendingVersionAndSwitchingKeepsIt() {
        let app = AppModel()
        defer { app.currentProjectKey = nil }
        let id = setUp(app)
        app.markShotReinferred(id)
        app.shots[app.shots.firstIndex { $0.id == id }!].prompt = "新推理的"
        XCTAssertTrue(shot(app, id).showsPendingVersion)
        XCTAssertNil(shot(app, id).taskID, "缩略图 / 大预览显示「待生成」")
        XCTAssertEqual(app.workbenchVideoState(shot(app, id)), .none, "工作台：这一版还没生成")

        app.applyVersion(shotID: id, taskID: "t1")
        XCTAssertEqual(shot(app, id).prompt, "第1版提示词")
        XCTAssertEqual(shot(app, id).pendingPrompt, "新推理的", "点了旧版本，新提示词收起来")
        XCTAssertTrue(shot(app, id).hasPendingVersion)
        XCTAssertEqual(app.workbenchVideoState(shot(app, id)), .completed)

        app.applyPendingVersion(shotID: id)
        XCTAssertEqual(shot(app, id).prompt, "新推理的", "点回「待生成」拿回来")
        XCTAssertTrue(shot(app, id).showsPendingVersion)
        XCTAssertNil(shot(app, id).pendingPrompt)
        XCTAssertEqual(shot(app, id).taskIDs, ["t1", "t2"], "历史版本一个不少")
    }

    func testReinferAgainOverwritesTheParkedOne() {
        let app = AppModel()
        defer { app.currentProjectKey = nil }
        let id = setUp(app)
        app.markShotReinferred(id)
        app.applyVersion(shotID: id, taskID: "t1")
        XCTAssertNotNil(shot(app, id).pendingPrompt)
        app.markShotReinferred(id)
        XCTAssertNil(shot(app, id).pendingPrompt, "只留一个：再推理就覆盖")
        XCTAssertTrue(shot(app, id).showsPendingVersion)
    }

    func testSubmittingTurnsItIntoARealVersion() {
        let app = AppModel()
        defer { app.currentProjectKey = nil }
        let id = setUp(app)
        app.markShotReinferred(id)
        app.submitShot(id)          // 没配模型：提交失败，但「待生成」已经交出去了
        XCTAssertFalse(shot(app, id).pendingIsCurrent)
        XCTAssertFalse(shot(app, id).hasPendingVersion)
    }

    func testCardsWithoutVideosDontGetOne() {
        let app = AppModel()
        app.currentProjectKey = "pending-" + UUID().uuidString
        defer { app.currentProjectKey = nil }
        let id = app.addShot()
        app.markShotReinferred(id)
        XCTAssertFalse(shot(app, id).hasPendingVersion, "没生成过的卡整张就是待生成，不多一个版本")
    }
}
