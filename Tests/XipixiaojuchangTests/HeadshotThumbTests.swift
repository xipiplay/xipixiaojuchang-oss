import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分镜卡片的角色头像从「左边大头照、右边三视图」的角色图里裁脸（2026-10-12）
@MainActor
final class HeadshotThumbTests: XCTestCase {
    func testLandscapeCharacterSheetCropsTheFaceFromTheLeftHeadshot() throws {
        let rect = try XCTUnwrap(HeadshotThumb.faceRect(imageSize: CGSize(width: 1672, height: 941)))
        XCTAssertEqual(rect.width, rect.height, "正方形")
        XCTAssertEqual(rect.height, 941 * 0.56, accuracy: 0.5)
        XCTAssertEqual(rect.midX, 1672 * 0.21, accuracy: 0.5, "脸在左边大头照里")
        XCTAssertLessThan(rect.maxX, 1672 * 0.47, "不伸进右边的三视图")
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
    }

    func testOtherShapesKeepTheOldCenterCrop() {
        XCTAssertNil(HeadshotThumb.faceRect(imageSize: CGSize(width: 900, height: 1200)), "竖的半身照：不按大头照裁")
        XCTAssertNil(HeadshotThumb.faceRect(imageSize: CGSize(width: 1000, height: 1000)), "方图也不裁")
        XCTAssertNil(HeadshotThumb.faceRect(imageSize: CGSize(width: 100, height: 0)))
    }
}
