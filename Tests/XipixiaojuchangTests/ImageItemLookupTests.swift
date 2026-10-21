import XCTest
@testable import Xipixiaojuchang

/// 2026-10-15 用户：项目有了素材后打开 / 关闭很卡——工作台每张段卡按 id 在所有项目的生图卡里从头找。
/// 改成下标缓存（`AppModel.imageItem(_:)`）：换顺序、删卡、原地改都要查得对
@MainActor
final class ImageItemLookupTests: XCTestCase {
    func testLookupStaysCorrectAfterReorderDeleteAndEdit() {
        let app = AppModel()
        let items = (0..<5).map { ImageGenItem(projectKey: "lookup", name: "n\($0)", prompt: "p\($0)") }
        app.imageItems = items
        XCTAssertEqual(app.imageItem(items[3].id)?.name, "n3")

        app.imageItems.reverse()                                  // 换顺序（条数不变，缓存没作废）
        XCTAssertEqual(app.imageItem(items[3].id)?.name, "n3")
        XCTAssertEqual(app.imageItem(items[0].id)?.name, "n0")

        app.imageItems.removeAll { $0.id == items[2].id }          // 删卡
        XCTAssertNil(app.imageItem(items[2].id))
        XCTAssertEqual(app.imageItem(items[4].id)?.name, "n4")

        if let i = app.imageItems.firstIndex(where: { $0.id == items[1].id }) { app.imageItems[i].name = "改过" }   // 原地改
        XCTAssertEqual(app.imageItem(items[1].id)?.name, "改过")
        XCTAssertNil(app.imageItem(UUID()))
    }
}
