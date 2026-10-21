import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10：「编辑提示词」弹窗里点外面 / Esc 关掉 = 取消；提交生成 = 保存。
/// 取消只撤销弹窗里能改的几样（提示词、素材、参数），不整条换回去——弹窗开着时视频可能刚好生成完、图刚好出完，那些不能被弄丢。
@MainActor
final class EditPromptRollbackTests: XCTestCase {
    func testClosingAShotDialogWithoutSubmittingUndoesPromptRefsAndParamsButKeepsNewVersions() {
        let app = AppModel()
        let key = "rollback-shot-" + UUID().uuidString
        defer { app.shots.removeAll { $0.projectKey == key } }
        var shot = ShotDraft(projectKey: key, model: "old-model", prompt: "原来的提示词", duration: 5, aspectRatio: .ratio16x9, resolution: .p720)
        shot.imageRefs = [MaterialRef(libraryItemID: UUID(), role: .referenceImage)]
        shot.paramsDirty = false
        app.shots.append(shot)
        let backup = shot                                              // 打开弹窗时的备份

        // 弹窗里改了：提示词、参考图、参数
        app.shots[0].prompt = "改过的提示词"
        app.shots[0].imageRefs = []
        app.shots[0].model = "new-model"
        app.shots[0].duration = 12
        app.shots[0].resolution = .p1080
        app.shots[0].paramsDirty = true
        // 同时后台有一个视频生成完了
        app.shots[0].taskID = "task-done"
        app.shots[0].taskIDs = ["task-done"]

        app.rollbackShotEdits(to: backup)
        let after = app.shots[0]
        XCTAssertEqual(after.prompt, "原来的提示词")
        XCTAssertEqual(after.imageRefs, backup.imageRefs)
        XCTAssertEqual(after.model, "old-model")
        XCTAssertEqual(after.duration, 5)
        XCTAssertEqual(after.resolution, .p720)
        XCTAssertFalse(after.paramsDirty)
        XCTAssertEqual(after.taskID, "task-done", "弹窗开着时生成完的视频不能被撤销掉")
        XCTAssertEqual(after.taskIDs, ["task-done"])
    }

    func testClosingAnImageDialogWithoutSubmittingUndoesPromptRefsAndParamsButKeepsNewResults() {
        let app = AppModel()
        let key = "rollback-image-" + UUID().uuidString
        defer { app.imageItems.removeAll { $0.projectKey == key } }
        var item = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "原来的提示词")
        item.model = "old"
        let backup = item
        app.imageItems.append(item)

        app.imageItems[0].prompt = "改过的"
        app.imageItems[0].model = "new"
        app.imageItems[0].type = .scene
        app.imageItems[0].aspectRatio = .ratio9x16
        app.imageItems[0].quality = .k4
        app.imageItems[0].paramsDirty = true
        app.imageItems[0].imageRefs = [MaterialRef(libraryItemID: UUID(), role: .referenceImage)]
        // 同时有一张图生成好了
        let result = ImageGenResult(localPath: "/tmp/new.png", createdAt: Date())
        app.imageItems[0].results = [result]
        app.imageItems[0].status = .success

        app.rollbackImageItemEdits(to: backup)
        let after = app.imageItems[0]
        XCTAssertEqual(after.prompt, "原来的提示词")
        XCTAssertEqual(after.model, "old")
        XCTAssertEqual(after.type, .character)
        XCTAssertEqual(after.aspectRatio, backup.aspectRatio)
        XCTAssertEqual(after.quality, backup.quality)
        XCTAssertTrue(after.imageRefs.isEmpty)
        XCTAssertFalse(after.paramsDirty)
        XCTAssertEqual(after.results.map(\.id), [result.id], "弹窗开着时生成好的图不能被撤销掉")
        XCTAssertEqual(after.status, .success)
    }

    func testRollingBackADeletedCardDoesNothing() {
        let app = AppModel()
        let ghost = ShotDraft(projectKey: "gone-" + UUID().uuidString, prompt: "x")
        app.rollbackShotEdits(to: ghost)                              // 卡已经被删了：不崩、不凭空建出来
        XCTAssertFalse(app.shots.contains { $0.id == ghost.id })
        let ghostImage = ImageGenItem(projectKey: "gone", type: nil, name: "x", prompt: "x")
        app.rollbackImageItemEdits(to: ghostImage)
        XCTAssertFalse(app.imageItems.contains { $0.id == ghostImage.id })
    }

    /// 2026-10-14 用户：工作台开关生图编辑提示词弹窗卡。没改就关掉不能写生图卡——一写，工作台整页状态、藏在后面的生图页都跟着重算
    func testClosingAnUnchangedImageDialogWritesNothing() {
        let app = AppModel()
        let card = ImageGenItem(projectKey: "rb-" + UUID().uuidString, type: .character, name: "甲", prompt: "原来的提示词")
        app.imageItems = [card]
        final class Box: @unchecked Sendable { var changed = false }
        let box = Box()
        withObservationTracking { _ = app.imageItems } onChange: { box.changed = true }
        app.rollbackImageItemEdits(to: card)
        XCTAssertFalse(box.changed, "什么都没改：不写、不存盘")
    }
}
