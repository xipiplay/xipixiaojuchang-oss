import XCTest
import AppKit
@testable import Xipixiaojuchang

/// 点输入框以外的地方，输入框放手、竖条消失；点在输入框里面不受影响（2026-10-07 用户实测的 bug）。
@MainActor
final class InputFocusGuardTests: XCTestCase {
    private var window: NSWindow!
    private var field: NSTextField!
    private var other: NSTextField!
    private var empty: NSView!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        field = NSTextField(frame: NSRect(x: 20, y: 240, width: 200, height: 24))
        other = NSTextField(frame: NSRect(x: 20, y: 200, width: 200, height: 24))
        empty = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        [field, other, empty].forEach { content.addSubview($0) }
        window.makeKeyAndOrderFront(nil)
    }
    override func tearDown() {
        window.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func startEditing(_ f: NSTextField) {
        XCTAssertTrue(window.makeFirstResponder(f))
        XCTAssertTrue(window.firstResponder is NSTextView, "进入编辑：first responder 是输入框的 field editor")
    }

    func testClickingEmptySpaceEndsEditing() {
        startEditing(field)
        XCTAssertTrue(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 200, y: 50)))
        XCTAssertFalse(window.firstResponder is NSTextView, "竖条不再闪")
    }

    func testClickingInsideTheSameFieldKeepsEditing() {
        startEditing(field)
        XCTAssertFalse(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 60, y: 250)))
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    func testClickingAnotherFieldDoesNotFightItsFocus() {
        startEditing(field)
        // 点在另一个输入框上：先放手，随后这一下点击本身会让另一个输入框拿到焦点（这里手动模拟那一步）
        XCTAssertTrue(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 60, y: 210)))
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    func testNothingHappensWhenNothingIsBeingEdited() {
        window.makeFirstResponder(nil)      // 窗口一打开会自动把第一个输入框设成焦点，先放掉
        XCTAssertFalse(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 200, y: 50)))
    }

    func testPlainTextViewsLikeTheEditorsAreTheirOwnEditingArea() {
        let textView = NSTextView(frame: NSRect(x: 20, y: 130, width: 200, height: 60))
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertFalse(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 100, y: 160)), "点在文本框里面：继续编辑")
        XCTAssertTrue(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: 300, y: 20)), "点在外面：放手")
        XCTAssertFalse(window.firstResponder === textView)
    }
}
