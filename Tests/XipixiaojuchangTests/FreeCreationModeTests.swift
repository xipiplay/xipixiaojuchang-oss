import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 软件分两种模式（2026-10-14 用户）：剧本模式 = 工作台；自由创作模式（没剧本、只有分镜）= 工作台这一页直接是生视频那一套
@MainActor
final class FreeCreationModeTests: XCTestCase {
    func testWhichModeAProjectIsIn() {
        let app = AppModel()
        let key = "free-" + UUID().uuidString
        app.currentProjectKey = key
        app.currentPipelineArchive = nil
        app.isInWorkspace = true
        app.projectPage = .script
        defer { app.shots = []; app.isInWorkspace = false; app.currentProjectKey = nil }
        XCTAssertFalse(app.isFreeCreation, "空项目：两种都还不是（工作台是「点击开始」）")
        XCTAssertTrue(app.isScriptPageVisible)

        app.shots = [ShotDraft(projectKey: key, prompt: "[老街][乙][ ]\n镜头")]
        XCTAssertTrue(app.isFreeCreation, "没剧本、有分镜：自由创作")
        XCTAssertFalse(app.isScriptPageVisible, "工作台本身藏着")
        XCTAssertTrue(app.isProductionWorkspaceVisible, "工作台这一页显示生视频那一套")
        XCTAssertTrue(app.canCreateNewItem, "⌘N 新增分镜照样能用")

        app.currentPipelineArchive = ProjectPipelineArchive(wholeScript: "第1集\n剧本", episodes: [])
        XCTAssertFalse(app.isFreeCreation, "导入了剧本：剧本模式（分镜进「其他分镜」）")
        XCTAssertTrue(app.isScriptPageVisible)
        XCTAssertFalse(app.isProductionWorkspaceVisible)
    }

    func testTheFreeCreationWorkbenchSitsOnTheVideoSide() async throws {
        let app = AppModel()
        let key = "free-root-" + UUID().uuidString
        app.currentProjectKey = key
        app.currentPipelineArchive = nil
        app.shots = [ShotDraft(projectKey: key, model: "m", prompt: "[老街][乙][ ]\n镜头", numbering: ShotNumbering(a: 1, b: 1))]
        app.isInWorkspace = true
        app.workspaceMode = .image
        app.projectPage = .script
        defer { app.shots = []; app.isInWorkspace = false; app.currentProjectKey = nil }
        let host = NSHostingView(rootView: RootView().environment(app).frame(width: 1160, height: 710))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 710), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        XCTAssertEqual(app.workspaceMode, .video, "自由创作的工作台固定在生视频那一侧")
    }
}
