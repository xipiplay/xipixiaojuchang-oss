import XCTest
import SwiftUI
import AppKit
import Observation
@testable import Xipixiaojuchang

@Observable private final class EditorDriver {
    var text = "第一行的文字比较长一些\n第二行\n第三行"
    var editing = false
    var ended = 0
}
private struct EditorHarness: View {
    let driver: EditorDriver
    var body: some View {
        ScriptTextEditor(text: Bindable(driver).text, isEditing: Bindable(driver).editing, onEndEditing: { driver.ended += 1 })
            .frame(width: 320, height: 160)
            .help(driver.editing ? "编辑中" : "")      // 像真页面一样在 body 里读 editing，页面改它时才会重新走 updateNSView
    }
}

/// 剧本页的文本框（2026-10-07）：平时只读（鼠标滑过不变插入竖线），点一下进入编辑，点外面回到只读并存盘。
/// 上一版靠「按位置找 TextEditor 底下的 NSTextView」，会误找到别的页面里位置重叠的文本框——这版文本框是我们自己建的，拿着它本身。
@MainActor
final class ScriptTextEditorTests: XCTestCase {
    private func makeWindow(_ drivers: [EditorDriver], frame: NSRect = NSRect(x: 200, y: 200, width: 320, height: 200)) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = container
        for driver in drivers {
            let host = NSHostingView(rootView: EditorHarness(driver: driver))
            host.frame = NSRect(x: 0, y: 20, width: 320, height: 160)      // 几个编辑器位置完全重叠（像常驻在窗口里的别的页面）
            container.addSubview(host)
        }
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// 等 SwiftUI 把改动落到 AppKit 视图上（窗口不在前台时它不一定自己及时刷新）
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
        window.update()                                                 // 窗口每轮事件结束时的维护：这里才会重算指针区域
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
    }

    /// SwiftUI 要等一会儿才把文本框建出来
    private func textViews(in window: NSWindow) -> [ScriptTextView] {
        var views: [ScriptTextView] = []
        func find(_ v: NSView) { if let t = v as? ScriptTextView { views.append(t) }; v.subviews.forEach(find) }
        if let root = window.contentView { find(root) }
        return views
    }

    func testItStartsReadOnlyAndDoesNotGrabFocus() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        let tv = try XCTUnwrap(views.first)
        XCTAssertFalse(tv.isEditable)
        XCTAssertFalse(tv.isSelectable, "只读且不可选中：鼠标滑过不变成插入竖线")
        XCTAssertFalse(tv.acceptsFirstResponder, "只读时不抢焦点")
        XCTAssertEqual(tv.string, driver.text)
    }

    func testClickingWhileReadOnlyStartsEditingAndPlacesTheCaretThere() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        let tv = try XCTUnwrap(views.first)

        let local = NSPoint(x: tv.bounds.width * 0.5, y: 8)
        let inWindow = tv.convert(local, to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseUp), atStart: false)          // mouseDown 会等 mouseUp 才返回
        tv.mouseDown(with: mouse(.leftMouseDown))

        XCTAssertTrue(driver.editing, "点一下：进入编辑")
        XCTAssertTrue(tv.isEditable)
        XCTAssertTrue(window.firstResponder === tv)
        XCTAssertGreaterThan(tv.selectedRange().location, 0, "光标落在点的位置，不是开头")
    }

    func testClickingElsewhereLeavesEditingAndSaves() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        let tv = try XCTUnwrap(views.first)
        tv.coordinator?.beginEditing(in: tv)
        XCTAssertTrue(driver.editing)

        let other = NSTextField(frame: NSRect(x: 4, y: 0, width: 80, height: 20))
        window.contentView?.addSubview(other)
        XCTAssertTrue(window.makeFirstResponder(other))               // 点到了别处 / 别的输入框
        XCTAssertFalse(driver.editing, "回到只读")
        XCTAssertEqual(driver.ended, 1, "通知页面存盘，正好一次")
        XCTAssertFalse(tv.isEditable)
    }

    func testTypingWritesBackToTheBinding() async throws {
        let driver = EditorDriver()
        driver.text = ""
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        let tv = try XCTUnwrap(views.first)
        tv.coordinator?.beginEditing(in: tv)
        tv.insertText("场景：客厅 -- \"台词\"", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(driver.text, "场景：客厅 -- \"台词\"", "原样写回：不换成破折号、不换成智能引号")
    }

    func testThePageCanEndEditingFromOutside() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        let tv = try XCTUnwrap(views.first)
        tv.coordinator?.beginEditing(in: tv)
        XCTAssertTrue(window.firstResponder === tv)
        try await settle(window)                                        // 先让页面渲染一次「编辑中」，再改回去（否则 SwiftUI 看不出变化，不会再调 update）
        XCTAssertTrue(driver.editing)

        driver.editing = false                                          // 换集 / 打开弹窗：页面要求回到只读
        try await settle(window)
        XCTAssertFalse(window.firstResponder === tv, "放掉焦点")
        XCTAssertFalse(tv.isEditable)
    }

    /// （在测试进程里窗口不是前台，AppKit 不会真去重算指针区域，这里只能验证「我们有要求重算」；实测只改 isEditable 时 AppKit 一次都不重算）
    /// 点进编辑后指针区域没重算 → 指针一直是箭头（滚一下才变）；回到只读后旧的竖线区域还在 → 弹窗盖上来时漏出竖线
    func testSwitchingModeRebuildsTheCursorRects() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await settle(window)
        let tv = try XCTUnwrap(textViews(in: window).first)

        let beforeEditing = tv.cursorRectRefreshes
        tv.coordinator?.beginEditing(in: tv)
        try await settle(window)
        XCTAssertGreaterThan(tv.cursorRectRefreshes, beforeEditing, "进入编辑：重算指针区域，竖线才会出现")

        let beforeLeaving = tv.cursorRectRefreshes
        driver.editing = false
        try await settle(window)
        XCTAssertFalse(tv.isEditable)
        XCTAssertGreaterThan(tv.cursorRectRefreshes, beforeLeaving, "回到只读：重算指针区域，旧的竖线区域才会去掉")
    }

    /// 滚动跳行：TextKit 2 只估总高度，边滚边修正 → 内容跳。用 TextKit 1：总高度一开始就是准的，滚动过程中不变
    func testScrollingDoesNotChangeTheDocumentHeight() async throws {
        let driver = EditorDriver()
        driver.text = (0..<600).map { i in
            switch i % 4 {
            case 0: ""
            case 1: "场景\(i)：客厅 日 内"
            case 2: String(repeating: "他", count: 40 + (i * 7) % 120)
            default: String(repeating: "台词", count: 2 + (i * 5) % 30)
            }
        }.joined(separator: "\n")
        let window = makeWindow([driver])
        defer { window.close() }
        try await settle(window)
        let tv = try XCTUnwrap(textViews(in: window).first)
        let scroll = try XCTUnwrap(tv.enclosingScrollView)
        XCTAssertNil(tv.textLayoutManager, "用 TextKit 1")
        tv.coordinator?.beginEditing(in: tv)
        try await settle(window)

        let before = tv.frame.height
        XCTAssertGreaterThan(before, 5000)
        var y: CGFloat = 0
        while y < before {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.displayIfNeeded()
            XCTAssertEqual(tv.frame.height, before, accuracy: 0.5, "滚到 \(Int(y)) 时总高度变了：内容会跳")
            y += 400
        }
    }

    func testAnExternalTextChangeShowsUp() async throws {
        let driver = EditorDriver()
        let window = makeWindow([driver])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let views = textViews(in: window)
        driver.text = "换了一集：新的文字"
        try await settle(window)
        XCTAssertEqual(try XCTUnwrap(views.first).string, "换了一集：新的文字")
    }

    /// 上一版的 bug：点一下，进入编辑的是别的（位置重叠的）文本框
    func testSeveralOverlappingEditorsNeverAffectEachOther() async throws {
        let a = EditorDriver(), b = EditorDriver()
        let window = makeWindow([a, b])
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let views = textViews(in: window)
        XCTAssertEqual(views.count, 2)

        views[0].coordinator?.beginEditing(in: views[0])
        XCTAssertTrue(a.editing)
        XCTAssertFalse(b.editing, "另一个位置完全重叠的编辑器没被碰")
        XCTAssertFalse(views[1].isEditable)
        XCTAssertTrue(window.firstResponder === views[0])
    }
}
