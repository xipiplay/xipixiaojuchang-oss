import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 优化：⌘N 新建（主页新建项目、项目里新增分镜 / 图片，剧本页没有）、⌘F 搜索。
@MainActor
final class MenuShortcutTests: XCTestCase {
    private func inProject(_ app: AppModel, page: ProjectPage, mode: AppModel.WorkspaceMode) {
        app.currentProjectKey = "shortcut-" + UUID().uuidString
        app.isInWorkspace = true
        app.projectPage = page
        app.workspaceMode = mode
    }

    func testNewItemMeansTheRightThingOnEachPage() {
        let app = AppModel()
        defer { app.isInWorkspace = false; app.currentProjectKey = nil }

        inProject(app, page: .production, mode: .video)
        XCTAssertTrue(app.canCreateNewItem)
        let shots = app.shots.count
        app.performNewItemShortcut()
        XCTAssertEqual(app.shots.count, shots + 1, "生视频页：新增一个分镜")

        app.workspaceMode = .image
        let cards = app.imageItems.count
        app.performNewItemShortcut()
        XCTAssertEqual(app.imageItems.count, cards + 1, "生图页：新增一张图片卡")

        app.projectPage = .script
        XCTAssertTrue(app.canCreateNewItem, "没导入剧本、只有分镜 = 自由创作：工作台就是生视频那一套，⌘N 新增分镜（2026-10-14）")
        app.currentPipelineArchive = ProjectPipelineArchive(wholeScript: "第1集\n剧本", episodes: [])
        defer { app.currentPipelineArchive = nil }
        XCTAssertFalse(app.canCreateNewItem, "剧本模式的工作台没有「新建」")
        let before = (app.shots.count, app.imageItems.count)
        app.performNewItemShortcut()
        XCTAssertEqual(app.shots.count, before.0); XCTAssertEqual(app.imageItems.count, before.1)
    }

    func testNewItemIsOffWhileAModalIsOpen() {
        let app = AppModel()
        app.activeModal = .settings
        defer { app.activeModal = nil }
        XCTAssertFalse(app.canCreateNewItem)
    }

    func testFindPostsTheNotificationThePagesListenFor() {
        let app = AppModel()
        let exp = expectation(forNotification: .focusPageSearch, object: nil)
        app.focusPageSearch()
        wait(for: [exp], timeout: 1)
    }
}
