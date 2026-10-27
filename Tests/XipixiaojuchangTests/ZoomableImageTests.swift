import AppKit
import SwiftUI
import XCTest
@testable import Xipixiaojuchang

/// 看大图的缩放 / 拖动（2026-10-28）
@MainActor
final class ZoomableImageTests: XCTestCase {
    /// 横图 2000×1000 放进 800×600：适配后 800×400，上下各留 100
    private func state() -> ZoomPanState { ZoomPanState(imageSize: CGSize(width: 2000, height: 1000), viewSize: CGSize(width: 800, height: 600)) }

    func testFitsAndCenters() {
        let s = state()
        XCTAssertFalse(s.isZoomed)
        XCTAssertEqual(s.imageRect, CGRect(x: 0, y: 100, width: 800, height: 400))
    }

    func testZoomKeepsPointUnderCursor() {
        var s = state()
        let p = CGPoint(x: 600, y: 350)
        let before = CGPoint(x: (p.x - s.imageRect.minX) / s.imageRect.width, y: (p.y - s.imageRect.minY) / s.imageRect.height)
        s.zoom(by: 2, at: p)
        XCTAssertEqual(s.scale, 2)
        let after = CGPoint(x: (p.x - s.imageRect.minX) / s.imageRect.width, y: (p.y - s.imageRect.minY) / s.imageRect.height)
        XCTAssertEqual(before.x, after.x, accuracy: 0.0001, "光标下面那块图不动")
        XCTAssertEqual(before.y, after.y, accuracy: 0.0001)
    }

    func testScaleLimits() {
        var s = state()
        s.zoom(by: 0.5, at: .zero)
        XCTAssertEqual(s.scale, 1, "最小 = 适配窗口")
        XCTAssertEqual(s.imageRect, CGRect(x: 0, y: 100, width: 800, height: 400))
        s.zoom(by: 100, at: CGPoint(x: 400, y: 300))
        XCTAssertEqual(s.scale, ZoomPanState.maxScale, "最大 8 倍")
    }

    func testPanStaysInsideImage() {
        var s = state()
        s.pan(dx: 300, dy: 300)
        XCTAssertEqual(s.offset, .zero, "没放大拖不动")
        s.zoom(by: 2, at: CGPoint(x: 400, y: 300))   // 1600×800：横向可拖 ±400，纵向 ±100
        s.pan(dx: 10_000, dy: -10_000)
        XCTAssertEqual(s.imageRect.minX, 0, "拖到头：左边贴边，不露空白")
        XCTAssertEqual(s.imageRect.maxY, 600)
        s.pan(dx: -10_000, dy: 10_000)
        XCTAssertEqual(s.imageRect.maxX, 800)
        XCTAssertEqual(s.imageRect.minY, 0)
    }

    func testShortSideStaysCentered() {
        var s = state()
        s.zoom(by: 1.2, at: CGPoint(x: 700, y: 500))   // 960×480：高仍小于 600 → 纵向居中
        XCTAssertEqual(s.imageRect.midY, 300, accuracy: 0.0001)
    }

    func testDoubleClickToggles() {
        var s = state()
        s.toggle(at: CGPoint(x: 200, y: 300))
        XCTAssertEqual(s.scale, ZoomPanState.doubleClickScale)
        s.toggle(at: CGPoint(x: 200, y: 300))
        XCTAssertFalse(s.isZoomed)
        XCTAssertEqual(s.offset, .zero, "再双击还原")
    }

    func testResizeReclamps() {
        var s = state()
        s.zoom(by: 2, at: CGPoint(x: 0, y: 0))
        XCTAssertEqual(s.imageRect.minX, 0, "放大后拖到最左")
        s.resize(to: CGSize(width: 400, height: 600))   // 窗口变窄：适配 400×200，2 倍 800×400，偏移收回来
        XCTAssertEqual(s.imageRect.minX, 0, accuracy: 0.0001, "左边仍贴边，不露空白")
        XCTAssertEqual(s.imageRect.midY, 300, accuracy: 0.0001, "高还装得下：纵向居中")
    }

    func testNewImageResetsZoom() {
        let view = ZoomableImageNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.image = NSImage(size: NSSize(width: 2000, height: 1000))
        view.zoom(by: 2, at: CGPoint(x: 400, y: 300))
        XCTAssertTrue(view.state.isZoomed)
        view.image = NSImage(size: NSSize(width: 500, height: 500))
        XCTAssertFalse(view.state.isZoomed, "换图回到适配窗口")
        XCTAssertEqual(view.state.imageRect, CGRect(x: 100, y: 0, width: 600, height: 600))
    }

    /// 离屏画一张放大 3 倍的（XIPI_SHOT 给了路径才写图，人工核对用）
    func testRenderZoomed() throws {
        guard let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] else { return }
        let image = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { r in
            NSGradient(colors: [.systemPink, .systemBlue])?.draw(in: r, angle: 30)
            for i in 0..<16 { NSColor.white.setFill(); NSRect(x: CGFloat(i) * 100 + 45, y: 0, width: 10, height: r.height).fill() }
            ("缩放测试" as NSString).draw(at: NSPoint(x: 700, y: 430), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.white])
            return true
        }
        let view = ZoomableImageNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.image = image
        for (name, zoom) in [("适配", 1.0), ("放大3倍", 3.0)] {
            if zoom > 1 { view.zoom(by: zoom, at: CGPoint(x: 400, y: 300)) }
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: "-\(name).png")))
        }
    }
}

/// 妙控鼠标 / 触控板的滑动是精确滑动（2026-10-28）：大图里也要缩放；嵌在页面里没放大时交还页面
@MainActor
final class ZoomableImageScrollTests: XCTestCase {
    private func preciseScroll(_ dy: Int32) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    private func view(wheelZooms: Bool) -> ZoomableImageNSView {
        let view = ZoomableImageNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.wheelZooms = wheelZooms
        view.image = NSImage(size: NSSize(width: 2000, height: 1000))
        return view
    }

    func testPreciseScrollZoomsInPreview() throws {
        let v = view(wheelZooms: true)
        let event = try preciseScroll(40)
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        v.scrollWheel(with: event)
        XCTAssertTrue(v.state.isZoomed, "精确滑动（妙控鼠标）在大图里也缩放")
        v.scrollWheel(with: try preciseScroll(-400))
        XCTAssertFalse(v.state.isZoomed, "反方向滑回适配")
    }

    func testPreciseScrollPassesThroughWhenEmbedded() throws {
        let v = view(wheelZooms: false)
        v.scrollWheel(with: try preciseScroll(40))
        XCTAssertFalse(v.state.isZoomed, "嵌在页面里：滑动留给页面")
    }

    func testZoomFactorDirection() {
        XCTAssertGreaterThan(ZoomableImageNSView.zoomFactor(deltaY: 1, precise: false), 1)
        XCTAssertLessThan(ZoomableImageNSView.zoomFactor(deltaY: -10, precise: true), 1)
    }
}
