import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户实测：从工作台点生图 / 生视频，失败了以后卡片还是「待生成」。
/// 视频：提交失败（还没拿到平台的任务号）时失败的任务只在任务抽屉里有一条，分镜自己不知道；
/// 工作台：缺图的名字出图中 / 出图失败，也要在卡片上看得出。
@MainActor
final class SubmitFailureStateTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "submit-failure-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
    }

    private func addShot() -> ShotDraft {
        let shot = ShotDraft(projectKey: key, prompt: "[客厅][周承山][ ]\n正文")
        app.shots.append(shot)
        return shot
    }
    private func failedTask(_ id: String) -> LocalTask {
        var task = LocalTask(id: id, model: "m", providerID: "p", prompt: "x", duration: 5, aspectRatio: .ratio16x9, resolution: .p720,
                             generateAudio: false, phase: .failed, createdAt: Date(), updatedAt: Date(), costFen: 0,
                             referenceImageURLs: nil, referenceVideoURLs: nil, referenceAudioURLs: nil, groupID: key)
        task.errorMessage = "组装请求失败"
        return task
    }
    private func shot(_ id: UUID) -> ShotDraft { app.shots.first { $0.id == id }! }

    func testAFailedSubmitBecomesTheCardsCurrentVersionSoItShowsFailedAndTheWorkbenchSeesIt() {
        let s = addShot()
        XCTAssertEqual(app.workbenchVideoState(s), .none)
        app.store.add(failedTask("pending-A"))
        app.recordSubmitFailure(shotID: s.id, taskID: "pending-A")
        let after = shot(s.id)
        XCTAssertEqual(after.taskID, "pending-A")
        XCTAssertEqual(after.taskIDs, ["pending-A"])
        XCTAssertEqual(after.taskID.flatMap { app.store.task(id: $0)?.phase }, .failed, "卡片读 shot.taskID 的任务：失败")
        XCTAssertEqual(app.workbenchVideoState(after), .failed)
        app.store.remove(id: "pending-A")
    }

    func testAShotThatAlreadyHasAFinishedVideoKeepsItAsTheCurrentVersion() {
        var s = addShot()
        var done = failedTask("real-1"); done.phase = .completed; done.errorMessage = nil
        app.store.add(done)
        s.taskID = "real-1"; s.taskIDs = ["real-1"]
        app.shots[app.shots.firstIndex { $0.id == s.id }!] = s
        app.store.add(failedTask("pending-B"))
        app.recordSubmitFailure(shotID: s.id, taskID: "pending-B")
        XCTAssertEqual(shot(s.id).taskID, "real-1", "有成功的视频就别被一次失败的重试盖掉")
        XCTAssertEqual(shot(s.id).taskIDs, ["real-1", "pending-B"], "失败的只记进历史")
        XCTAssertEqual(app.workbenchVideoState(shot(s.id)), .completed)
        app.store.remove(id: "real-1"); app.store.remove(id: "pending-B")
    }

    /// 2026-10-16 用户定：每次提交都是新的一版，之前失败的版本照样留着（原来再交一次就把上一条失败删掉，历史版本里的失败版本消失）
    func testSubmittingAgainKeepsEarlierFailuresAsTheirOwnVersions() {
        let s = addShot()
        var first = failedTask("pending-C")
        first.fileName = "1-1-1"
        app.store.add(first)
        app.recordSubmitFailure(shotID: s.id, taskID: "pending-C")
        // 没配模型 → 立刻又是一次失败（不走网络）
        app.submitShot(s.id)
        app.submitShot(s.id)
        let after = shot(s.id)
        XCTAssertEqual(after.taskIDs.count, 3, "三次提交三个版本：\(after.taskIDs)")
        XCTAssertEqual(after.taskIDs.first, "pending-C", "第一次的失败还在")
        XCTAssertNotNil(app.store.task(id: "pending-C"))
        let numbers = after.taskIDs.compactMap { app.store.task(id: $0)?.fileName?.split(separator: "-").last.flatMap { Int($0) } }
        XCTAssertEqual(numbers, [1, 2, 3], "版本号接着往下排，不重复用")
        XCTAssertEqual(after.taskID, after.taskIDs.last, "卡片显示最新那次（失败）")
        for id in after.taskIDs { app.store.remove(id: id) }
    }

    func testAMissingImageNameShowsRunningOrFailedInsteadOfAlwaysPendingImage() {
        func card(_ name: String, _ status: ImageGenStatus) -> ImageGenItem {
            var item = ImageGenItem(projectKey: key, type: .character, name: name, prompt: "p"); item.status = status; return item
        }
        // 场景和道具都有图，只剩角色没图
        var scene = ImageGenItem(projectKey: key, type: .scene, name: "客厅", prompt: "p")
        scene.results = [ImageGenResult(localPath: "/tmp/s.png", createdAt: Date())]; scene.status = .success
        let prompt = "[客厅][甲、乙、丙][无]\n正文"
        var shot = ShotDraft(projectKey: key, prompt: prompt)
        shot.model = "m"
        var ep = Episode(title: "集", text: "原文", splitText: "分割"); ep.shotIDs = [shot.id]
        let cards = [scene, card("甲", .generating), card("乙", .failed), card("丙", .pending)]
        let board = WorkbenchStatus.board(.init(episodes: [ep], shots: [shot.id: shot], cards: cards, libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        let status = board.episodes[0].shots[shot.id]!
        XCTAssertEqual(status.names.filter { $0.kind == .role }.map(\.activity), [.running, .failed, .idle])
        XCTAssertEqual(status.title, "出图中", "有在出的就先说出图中")
        XCTAssertEqual(board.episodes[0].imagesRunning, 1)
        XCTAssertEqual(board.episodes[0].imagesFailed, 1)
        XCTAssertTrue(board.episodes[0].hasFailure)
        XCTAssertEqual(board.episodes[0].detail, "3 张没有图 · 1 张出图中 · 1 张出图失败")

        let onlyFailed = WorkbenchStatus.board(.init(episodes: [ep], shots: [shot.id: shot], cards: [scene, card("甲", .failed), card("乙", .pending), card("丙", .pending)],
                                                     libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        XCTAssertEqual(onlyFailed.episodes[0].shots[shot.id]!.title, "出图失败")
        XCTAssertTrue(onlyFailed.episodes[0].shots[shot.id]!.isProblem)
        let plain = WorkbenchStatus.board(.init(episodes: [ep], shots: [shot.id: shot], cards: [scene, card("甲", .pending), card("乙", .pending), card("丙", .pending)],
                                                libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        XCTAssertEqual(plain.episodes[0].shots[shot.id]!.title, "待出图")
        XCTAssertFalse(plain.episodes[0].hasFailure)
    }
}
