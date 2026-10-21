import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 二级页面「历史版本」里失败的版本（2026-10-16 用户：点不了；录屏：点了橙框不动，像没点进去）：
/// 和别的版本一样能设为当前版本——左边换成它的提示词和参数，右边预览写失败原因；行上也写失败原因
@MainActor
final class SegmentVersionFailedTests: XCTestCase {
    private func setUp(_ app: AppModel) -> (ShotDraft, String, String) {
        let key = "ver-" + UUID().uuidString
        let now = Date()
        let good = "task_good_" + UUID().uuidString.prefix(6), bad = "task_bad_" + UUID().uuidString.prefix(6)
        var okTask = LocalTask(id: good, model: "m", prompt: "第一版提示词", duration: 10, phase: .completed, createdAt: now, updatedAt: now)
        okTask.fileName = "1-1-1"
        var failedTask = LocalTask(id: bad, model: "m2", prompt: "第二版提示词（交上去失败了）", duration: 30, phase: .failed, createdAt: now, updatedAt: now)
        failedTask.fileName = "1-1-2"
        failedTask.errorMessage = "该档只支持图片参考, 不支持音频参考"
        app.store.add(okTask); app.store.add(failedTask)
        var shot = ShotDraft(projectKey: key, prompt: "现在的提示词")
        shot.taskIDs = [good, bad]
        shot.taskID = good
        app.shots.append(shot)
        return (shot, good, bad)
    }

    func testFailedVersionBecomesCurrentWithItsPrompt() {
        let app = AppModel()
        let (shot, _, bad) = setUp(app)
        app.applyVersion(shotID: shot.id, taskID: bad)        // 面板里点失败那一行走的就是它（和别的版本一样）
        let after = app.shots.first { $0.id == shot.id }!
        XCTAssertEqual(after.prompt, "第二版提示词（交上去失败了）", "左边是失败那一版的提示词，可以直接改了重交")
        XCTAssertEqual(after.duration, 30)
        XCTAssertEqual(after.model, "m2")
        XCTAssertEqual(after.taskID, bad, "当前版本切到失败那一版（橙框跟过去，预览写失败原因）")
    }

    func testPanelShowsFailureReason() throws {
        let app = AppModel()
        let (shot, _, _) = setUp(app)
        let host = NSHostingView(rootView: SegmentVersionPanel(shotID: shot.id, onClose: {}).environment(app)
            .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark).frame(width: 430, height: 260))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 430, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let out = ProcessInfo.processInfo.environment["XIPI_SHOT"], let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}

/// 所有历史版本列表的版本号同一个口径（2026-10-16 用户：工作台和生视频侧对不上）：按文件名，不按排第几个
final class VersionNumberTests: XCTestCase {
    func testVersionNumberFollowsFileNameEvenWithGaps() {
        let now = Date()
        func task(_ id: String, _ file: String?) -> LocalTask {
            var t = LocalTask(id: id, model: "m", prompt: "p", duration: 5, phase: .completed, createdAt: now, updatedAt: now)
            t.fileName = file
            return t
        }
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(task("c", "1-6-3").versionNumber(in: ids), 3)
        XCTAssertEqual(task("d", "1-6-6").versionNumber(in: ids), 6, "中间缺了 4、5：还是第 6 版，不是第 4 个")
        XCTAssertEqual(task("b", nil).versionNumber(in: ids), 2, "老任务没有文件名：退回排第几个")
    }
}
