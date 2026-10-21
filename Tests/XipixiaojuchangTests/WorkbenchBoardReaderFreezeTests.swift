import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 工作台常驻之后（2026-10-12），藏着（在生图 / 生视频页）时分镜状态不跟着算；回到工作台那一拍算最新的。
/// 状态由 `WorkbenchBoardProvider` 整页算一次，各块的 `WorkbenchBoardReader` 直接拿
@MainActor
final class WorkbenchBoardReaderFreezeTests: XCTestCase {
    private final class Probe { var evaluations = 0; var lastShotCount = -1 }

    private func makeApp() -> (AppModel, String) {
        let app = AppModel()
        let key = "freeze-" + UUID().uuidString
        var episode = Episode(title: "第1集", text: "原文")
        let shot = ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n正文")
        app.shots.append(shot)
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：客栈\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        return (app, key)
    }

    private func host(_ app: AppModel, _ probe: Probe) -> NSWindow {
        let view = WorkbenchBoardProvider {
            WorkbenchBoardReader { board in
                let _ = { probe.evaluations += 1; probe.lastShotCount = board?.episodes.first?.shots.count ?? -1 }()
                Color.clear
            }
        }
        .environment(app)
        let host = NSHostingView(rootView: view.frame(width: 100, height: 100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return window
    }

    func testHiddenWorkbenchKeepsTheLastBoardAndRecomputesWhenShownAgain() {
        let (app, key) = makeApp()
        defer { app.shots.removeAll { $0.projectKey == key } }
        let probe = Probe()
        let window = host(app, probe)
        XCTAssertEqual(probe.lastShotCount, 1)

        app.projectPage = .production                      // 去了生视频页
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let before = probe.evaluations
        // 后台视频轮询之类：分镜数据一直在变
        for i in 0..<5 {
            if let index = app.shots.firstIndex(where: { $0.projectKey == key }) { app.shots[index].prompt = "[客栈][甲][ ]\n第\(i)版" }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(probe.evaluations, before, "藏着的时候不跟着分镜变化重算")

        app.projectPage = .script                          // 回到工作台
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(probe.evaluations, before, "回来那一拍重算")
        XCTAssertEqual(probe.lastShotCount, 1)
        _ = window
    }

    func testVisibleWorkbenchFollowsChanges() {
        let (app, key) = makeApp()
        defer { app.shots.removeAll { $0.projectKey == key } }
        let probe = Probe()
        let window = host(app, probe)
        let before = probe.evaluations
        if let index = app.shots.firstIndex(where: { $0.projectKey == key }) { app.shots[index].prompt = "[客栈][甲][ ]\n改了" }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(probe.evaluations, before, "看得见时照常跟着变")
        _ = window
    }
}
