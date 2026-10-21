import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 2026-10-15 用户：分镜网格滑着滑着顿一下。原因是视频生成中每 4 秒一次的进度更新让整个工作台状态重算、网格重画。
/// 现在进度变了、任务状态没变，工作台状态用上一次的（版本号不变，读它的地方都不重画）
@MainActor
final class WorkbenchBoardCacheTests: XCTestCase {
    private struct Probe: View {
        @Environment(\.workbenchBoard) private var board
        var body: some View {
            Probe.versions.append(board?.version ?? -1)
            return Color.clear
        }
        static var versions: [Int] = []
    }

    func testProgressTicksDontRecomputeTheBoard() throws {
        let key = "board-cache-" + UUID().uuidString
        let app = AppModel()
        var shot = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n镜头")
        let task = LocalTask(id: "t-\(UUID().uuidString)", model: "m", prompt: "p", duration: 5, phase: .inProgress,
                             createdAt: Date(), updatedAt: Date())
        shot.taskIDs = [task.id]; shot.taskID = task.id
        app.shots.append(shot)
        app.store.add(task)
        defer { app.shots.removeAll { $0.projectKey == key }; app.store.remove(id: task.id) }
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：客栈\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true; app.projectPage = .script

        Probe.versions = []
        let host = NSHostingView(rootView: WorkbenchBoardProvider { Probe() }.environment(app).frame(width: 200, height: 100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let first = try XCTUnwrap(Probe.versions.last)

        for p in [10.0, 20, 30] {
            app.store.updateProgress(id: task.id, progress: p)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(Probe.versions.last, first, "进度变了、状态没变：不重算")

        app.store.update(id: task.id, phase: .completed)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotEqual(Probe.versions.last, first, "状态变了（生成完）：重算")
    }
}
