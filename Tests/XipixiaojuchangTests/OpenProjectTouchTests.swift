import XCTest
@testable import Xipixiaojuchang

/// 打开项目一定会更新「更新时间」，主页按更新时间排序时它排到前面（2026-10-12 用户：打开又关掉，卡片没排到前面）。
/// 原来挂在翻页动画的 completion 上，completion 有时不来；现在按时间写，不依赖动画
@MainActor
final class OpenProjectTouchTests: XCTestCase {
    func testOpeningAProjectAlwaysBumpsItsUpdateTime() {
        let app = AppModel()
        let key = "touch-" + UUID().uuidString
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        app.projectMetas[key] = ProjectMeta(name: "测试项目", createdAt: old, updatedAt: old)
        defer { app.projectMetas[key] = nil }

        app.openProject(key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        let updated = try! XCTUnwrap(app.projectMetas[key]).updatedAt
        XCTAssertGreaterThan(updated, Date().addingTimeInterval(-5), "打开后更新时间是刚才")
    }
}

/// 回主页：淡出后拆掉当前项目；但在拆之前又打开了别的项目，就不能把新项目解绑（2026-10-12）
@MainActor
final class GoHomeUnbindTests: XCTestCase {
    func testGoingHomeUnbindsTheProjectAfterTheFade() {
        let app = AppModel()
        let key = "home-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "测试项目", createdAt: Date(), updatedAt: Date())
        defer { app.projectMetas[key] = nil }
        app.openProject(key)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        app.goHome()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(app.currentProjectKey, "淡出后拆掉")
    }

    func testReopeningRightAfterGoingHomeKeepsTheNewProjectBound() {
        let app = AppModel()
        let first = "home-a-" + UUID().uuidString, second = "home-b-" + UUID().uuidString
        for key in [first, second] { app.projectMetas[key] = ProjectMeta(name: key, createdAt: Date(), updatedAt: Date()) }
        defer { app.projectMetas[first] = nil; app.projectMetas[second] = nil }
        app.openProject(first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        app.goHome()
        app.openProject(second)                       // 淡出还没拆完就打开了另一个
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertEqual(app.currentProjectKey, second, "迟到的「拆旧内容」不能把新打开的项目解绑")
        XCTAssertTrue(app.isInWorkspace)
    }
}
