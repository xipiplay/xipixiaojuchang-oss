import XCTest
import AVFoundation
@testable import Xipixiaojuchang

/// 视频缩略图：悬停播放（有声、循环、停够一小会儿才播、滚动 / 离开就停）+ 双击弹大窗口（2026-10-08 用户定）。
@MainActor
final class ThumbVideoPlaybackTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/xipi-hover-test.mp4")      // 不需要真视频：这里只看状态机

    override func tearDown() async throws {
        ThumbVideoPlayback.shared.cursorTarget = nil
        ThumbVideoPlayback.shared.stop()
    }

    private func wait(_ ms: Int) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    func testHoverPlaysWithSoundOnlyAfterTheDwellAndStopsWhenTheMouseLeaves() async throws {
        let playback = ThumbVideoPlayback.shared
        let id = UUID()
        playback.hoverBegan(shotID: id, url: url)
        try await wait(120)
        XCTAssertNil(playback.playingShotID, "刚停下就播会让划过的每一格都动一下：要停够一小会儿")
        try await wait(450)
        XCTAssertEqual(playback.playingShotID, id)
        XCTAssertFalse(playback.player.isMuted, "悬停播放有声（2026-10-08 用户定）")
        playback.hoverEnded(shotID: id)
        XCTAssertNil(playback.playingShotID, "鼠标离开就停")
        XCTAssertNil(playback.player.currentItem)
    }

    func testLeavingBeforeTheDwellEndsNeverPlays() async throws {
        let playback = ThumbVideoPlayback.shared
        let id = UUID()
        playback.hoverBegan(shotID: id, url: url)
        try await wait(100)
        playback.hoverEnded(shotID: id)
        try await wait(600)
        XCTAssertNil(playback.playingShotID, "划过去不播")
    }

    func testMovingToAnotherCardStopsTheFirstAndPlaysTheSecond() async throws {
        let playback = ThumbVideoPlayback.shared
        let a = UUID(), b = UUID()
        playback.hoverBegan(shotID: a, url: url)
        try await wait(550)
        XCTAssertEqual(playback.playingShotID, a)
        playback.hoverEnded(shotID: a)
        playback.hoverBegan(shotID: b, url: url)
        XCTAssertNil(playback.playingShotID, "换格子：前一格立刻停，后一格要重新停够才播")
        try await wait(550)
        XCTAssertEqual(playback.playingShotID, b)
    }

    func testAnotherCardLeavingDoesNotStopThePlayingOne() async throws {
        let playback = ThumbVideoPlayback.shared
        let a = UUID()
        playback.hoverBegan(shotID: a, url: url)
        try await wait(550)
        playback.hoverEnded(shotID: UUID())          // 别的格子被回收 / 离开
        XCTAssertEqual(playback.playingShotID, a)
    }

    func testScrollingStopsPlaybackAndCancelsAPendingStart() async throws {
        let playback = ThumbVideoPlayback.shared
        let a = UUID(), b = UUID()
        playback.hoverBegan(shotID: a, url: url)
        try await wait(550)
        XCTAssertEqual(playback.playingShotID, a)
        playback.scrollBegan()
        XCTAssertNil(playback.playingShotID, "一开始滚动就停")

        playback.hoverBegan(shotID: b, url: url)
        try await wait(100)
        playback.scrollBegan()
        try await wait(600)
        XCTAssertNil(playback.playingShotID, "还没起播就滚动：起播取消")
    }

    /// 回归（2026-10-08）：滚动停下后光标没动，系统不会再补「进入」事件，悬停播放以前要把鼠标移走再移回来才触发
    func testAfterScrollingStopsThePlaybackResumesOnTheCardUnderTheStillCursor() async throws {
        let playback = ThumbVideoPlayback.shared
        let under = UUID()
        playback.cursorTarget = { (under, URL(fileURLWithPath: "/tmp/xipi-rehover.mp4")) }      // 光标一直压在这一格上，没动
        playback.scrollBegan()
        XCTAssertNil(playback.playingShotID, "滚动中不播")
        try await wait(200)
        XCTAssertNil(playback.playingShotID, "刚停下也要先停够一小会儿")
        try await wait(900)
        XCTAssertEqual(playback.playingShotID, under, "滚动停下后，光标下的那一格自动开始播放")
    }

    func testAfterScrollingNothingPlaysWhenTheCursorIsNotOnAPlayableCard() async throws {
        let playback = ThumbVideoPlayback.shared
        playback.cursorTarget = { nil }                 // 光标在空白处 / 工具条上 / 那一格没有视频
        playback.scrollBegan()
        try await wait(1000)
        XCTAssertNil(playback.playingShotID)
    }

    func testManyScrollEventsDoNotPileUpRestarts() async throws {
        let playback = ThumbVideoPlayback.shared
        var asked = 0
        playback.cursorTarget = { asked += 1; return nil }
        for _ in 0..<200 { playback.scrollBegan() }     // 触控板一次滚动会来几十上百个事件
        try await wait(700)
        XCTAssertEqual(asked, 1, "只在滚动停下后问一次光标下是哪一格")
    }

    // MARK: 双击 → 大窗口

    func testDoubleClickOpensTheLargePreviewOnlyWhenThereIsALocalVideo() throws {
        let app = AppModel()
        let key = "preview-" + UUID().uuidString
        func add(task id: String, path: String?) -> ShotDraft {
            var shot = ShotDraft(projectKey: key, prompt: "镜头", taskIDs: [id])
            shot.taskID = id
            app.shots.append(shot)
            var task = LocalTask(id: id, model: "m", prompt: "镜头", duration: 5, phase: .completed,
                                 createdAt: Date(), updatedAt: Date())
            task.localVideoPath = path
            app.store.add(task)
            return shot
        }
        let withoutFile = add(task: "no-file-" + key, path: "/tmp/不存在-\(UUID().uuidString).mp4")
        XCTAssertFalse(app.openShotPreview(withoutFile.id), "没有视频文件：双击什么都不做")
        XCTAssertNil(app.previewingShotID)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xipi-preview-\(UUID().uuidString).mp4")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let withFile = add(task: "has-file-" + key, path: file.path)

        ThumbVideoPlayback.shared.hoverBegan(shotID: withFile.id, url: file)
        XCTAssertTrue(app.openShotPreview(withFile.id))
        XCTAssertEqual(app.previewingShotID, withFile.id)
        XCTAssertNil(ThumbVideoPlayback.shared.playingShotID, "打开大窗口时格子里的悬停播放让位")
        XCTAssertFalse(app.openShotPreview(UUID()), "不存在的分镜")
    }
}
