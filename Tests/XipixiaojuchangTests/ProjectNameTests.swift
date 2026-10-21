import XCTest
@testable import Xipixiaojuchang

/// 项目名去重（2026-10-06 P0）。
///
/// 背景：缓存目录按项目名命名，主页「导入剧本」曾允许同名项目 → 两个项目共用一个目录，
/// 删其中一个会把另一个的图片和视频一起删掉。新建项目时必须避开已占用的名字。
final class ProjectNameTests: XCTestCase {
    func testFreeNameIsKept() {
        XCTAssertEqual(AppModel.uniqueProjectName("蛇女", taken: ["别的项目"]), "蛇女")
    }

    func testTakenNameGetsNextNumber() {
        XCTAssertEqual(AppModel.uniqueProjectName("蛇女", taken: ["蛇女"]), "蛇女 2")
        XCTAssertEqual(AppModel.uniqueProjectName("蛇女", taken: ["蛇女", "蛇女 2", "蛇女 3"]), "蛇女 4")
    }

    func testLongNameStaysWithinLimit() {
        let long = String(repeating: "长", count: 40)
        let first = AppModel.uniqueProjectName(long, taken: [])
        XCTAssertEqual(first.count, 30)
        let second = AppModel.uniqueProjectName(long, taken: [first])
        XCTAssertEqual(second.count, 30)
        XCTAssertTrue(second.hasSuffix(" 2"))
        XCTAssertNotEqual(first, second)
    }
}
