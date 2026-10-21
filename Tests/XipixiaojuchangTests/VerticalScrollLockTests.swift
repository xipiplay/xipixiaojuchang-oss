import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-10 用户：设置弹窗右边的内容能左右滑。日志实锤：内容没有变宽（宽度 = 可见宽度），是 SwiftUI 滚动区在竖向滚动区上做了横向橡皮筋，
/// 横向位置在 −66 ~ +59 之间摆。`VerticalScrollLock` 把滚动区的横向位置永远拉回 0。
///
/// 测试用自己搭的 AppKit 滚动区（clip view 不限位，和橡皮筋一样能被推到界外），因为 SwiftUI 的 ScrollView 在测试里没法复现那个橡皮筋。
@MainActor
final class VerticalScrollLockTests: XCTestCase {
    /// 不限位的 clip view：谁把它推到哪儿它就停在哪儿（模拟橡皮筋中间的那些帧）
    private final class FreeClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
    }

    /// 和真实的 clip view 一样：改位置的**过程中**先发通知（那一刻读到的还是旧位置），然后才真的改。
    /// 没有重入保护的话，锁里的 `snapBack → setBoundsOrigin → 通知 → snapBack …` 会无限递归、栈溢出闪退（真实发生过）
    private final class LaggyClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: self)
            super.setBoundsOrigin(newOrigin)
        }
    }

    private func makeScroll(locked: Bool, laggy: Bool = false) -> (NSWindow, NSScrollView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let clip: NSClipView = laggy ? LaggyClipView(frame: scroll.contentView.frame) : FreeClipView(frame: scroll.contentView.frame)
        scroll.contentView = clip
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        if locked { doc.addSubview(VerticalScrollLock.Probe(frame: NSRect(x: 0, y: 0, width: 1, height: 1))) }
        scroll.documentView = doc
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        return (window, scroll)
    }

    private func push(_ scroll: NSScrollView, toX x: CGFloat, y: CGFloat? = nil) -> NSPoint {
        var bounds = scroll.contentView.bounds
        bounds.origin.x = x
        if let y { bounds.origin.y = y }
        scroll.contentView.bounds = bounds
        return scroll.contentView.bounds.origin
    }

    func testTheLockPullsTheHorizontalPositionBackToZeroOnBothSidesInTheSameTurn() {
        let (unlockedWindow, unlocked) = makeScroll(locked: false)
        defer { unlockedWindow.close() }
        XCTAssertEqual(push(unlocked, toX: -40).x, -40, accuracy: 0.01, "对照：没锁的时候被推到哪就停在哪")

        for pushed in [CGFloat(-66), -9, 9, 59] {
            let (window, scroll) = makeScroll(locked: true)
            defer { window.close() }
            XCTAssertEqual(push(scroll, toX: pushed).x, 0, accuracy: 0.01, "锁了之后推到 \(pushed) 也会在同一轮里回到 0")
        }
    }

    func testPullingBackDoesNotRecurseWhenTheNotificationComesBeforeThePositionChanges() {
        let (window, scroll) = makeScroll(locked: true, laggy: true)
        defer { window.close() }
        scroll.contentView.postsBoundsChangedNotifications = true
        // 推到界外：锁里 setBoundsOrigin 会再发一次通知——不能递归
        var bounds = scroll.contentView.bounds
        bounds.origin.x = 40
        scroll.contentView.bounds = bounds
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, accuracy: 0.01, "没闪退，而且回到了 0")
    }

    func testTheLockLeavesVerticalScrollingAlone() {
        let (window, scroll) = makeScroll(locked: true)
        defer { window.close() }
        XCTAssertEqual(push(scroll, toX: 30, y: 120).y, 120, accuracy: 0.01, "竖向位置不动")
    }

    func testTheLockAlsoTurnsOffHorizontalElasticityAndScroller() {
        let (window, scroll) = makeScroll(locked: true)
        defer { window.close() }
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        XCTAssertFalse(scroll.hasHorizontalScroller)
    }

    /// 真正挂在 SwiftUI 的 ScrollView 里也能找到外面的滚动区并接上
    func testItAttachesInsideARealSwiftUIScrollView() async throws {
        let host = NSHostingView(rootView: ScrollView { VStack { Color.blue.frame(height: 600) }.background(VerticalScrollLock()) }.frame(width: 400, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let scroll = try XCTUnwrap(all(host).compactMap { $0 as? NSScrollView }.first)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertTrue(scroll.contentView.postsBoundsChangedNotifications, "挂上了：开始监听横向位置")
    }
}
