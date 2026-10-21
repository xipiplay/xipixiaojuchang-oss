import XCTest
@testable import Xipixiaojuchang

/// 缩略图双击（看大图 / 播放）只认滚动区看得见的那一块，不认顶栏、页头、悬浮底栏（2026-10-07 用户实测的 bug）。
final class DoubleClickRegionTests: XCTestCase {
    /// 窗口 1000×700（SwiftUI .global，左上原点）：顶栏 0–38，页头 38–82，滚动区 82–700，底栏胶囊在底部居中
    private let viewport = CGRect(x: 52, y: 82, width: 600, height: 618)
    private let toolbar = CGRect(x: 250, y: 640, width: 200, height: 48)

    private func ok(_ x: CGFloat, _ y: CGFloat) -> Bool {
        DoubleClickRegion.isOnVisibleGrid(viewport: viewport, toolbar: toolbar, point: CGPoint(x: x, y: y))
    }

    func testClickInsideTheVisibleGridCounts() {
        XCTAssertTrue(ok(300, 300))
        XCTAssertTrue(ok(60, 90), "靠边的格子也算")
    }

    func testTheTopBarAndTheHeaderAboveTheGridDoNotCount() {
        XCTAssertFalse(ok(300, 20), "顶栏（项目名那一行）")
        XCTAssertFalse(ok(300, 60), "页头（筛选 / 搜索那一行）")
    }

    func testTheFloatingToolbarDoesNotCountEvenThoughItSitsOnTopOfTheGrid() {
        XCTAssertFalse(ok(300, 660), "底栏胶囊")
        XCTAssertTrue(ok(100, 660), "胶囊旁边的空白还是格子")
    }

    func testOutsideTheGridHorizontallyDoesNotCount() {
        XCTAssertFalse(ok(20, 300), "左栏")
        XCTAssertFalse(ok(800, 300), "右边的详情栏")
    }

    func testAnUnmeasuredViewportNeverCounts() {
        XCTAssertFalse(DoubleClickRegion.isOnVisibleGrid(viewport: .zero, toolbar: .zero, point: CGPoint(x: 10, y: 10)))
    }

    func testWindowPointsAreFlippedToTopLeftOrigin() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        // 窗口坐标里 y=680（靠近顶部）→ 左上原点里 y≈20（顶栏）
        let p = DoubleClickRegion.global(NSPoint(x: 300, y: 680), in: window)
        XCTAssertEqual(p.x, 300)
        XCTAssertEqual(p.y, (window.contentView?.bounds.height ?? 700) - 680, accuracy: 0.01)
        XCTAssertLessThan(p.y, 82, "顶部那一行不会落进滚动区")
    }
}
