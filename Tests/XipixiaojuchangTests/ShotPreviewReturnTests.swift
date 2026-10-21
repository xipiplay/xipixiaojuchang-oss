import XCTest
@testable import Xipixiaojuchang

/// 2026-10-15 用户：大预览点「编辑分镜」→ 二级页面在大图之上，关掉二级页面还是大图
@MainActor
final class ShotPreviewReturnTests: XCTestCase {
    func testClosingTheDetailBringsThePreviewBack() {
        let app = AppModel()
        app.currentProjectKey = "return-" + UUID().uuidString
        defer { app.currentProjectKey = nil }
        let id = app.addShot()
        XCTAssertTrue(app.shots.contains { $0.id == id })
        var opened = 0
        app.shotPreviewReturn = (id, { opened += 1 })
        app.reopenShotPreviewAfterSegmentDetail()
        XCTAssertEqual(app.previewingShotID, id)
        XCTAssertNotNil(app.shotPreviewEditSegment, "放回来的大预览还有「编辑分镜」")
        app.shotPreviewEditSegment?()
        XCTAssertEqual(opened, 1)
        XCTAssertNil(app.shotPreviewReturn, "只放回一次")
        app.previewingShotID = nil
        app.reopenShotPreviewAfterSegmentDetail()
        XCTAssertNil(app.previewingShotID, "普通打开的二级页面关掉不弹大预览")
    }

    func testDeletedShotIsNotBroughtBack() {
        let app = AppModel()
        app.shotPreviewReturn = (UUID(), {})
        app.reopenShotPreviewAfterSegmentDetail()
        XCTAssertNil(app.previewingShotID)
        XCTAssertNil(app.shotPreviewReturn)
    }
}
