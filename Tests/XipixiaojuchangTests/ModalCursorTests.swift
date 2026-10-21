import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-10 用户：编辑提示词弹窗里只读的地方，鼠标变成了插入竖线。
/// 原因：AppKit 的指针区域不被弹窗的遮罩挡住，页头的搜索框（编辑中的输入框自带竖线指针）在默认窗口里正好落在弹窗标题行的底下。
/// 弹窗开着时后面的输入框一律禁用（禁用的输入框没有竖线指针），关掉弹窗再恢复。
@MainActor
final class ModalCursorTests: XCTestCase {
    /// 窗口里看得见的输入框（藏在窗口外面的——比如没打开的素材库抽屉里的搜索框——鼠标够不着，不算）
    private func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ v: NSView) {
            if let field = v as? NSTextField, field.isEditable, field.convert(field.bounds, to: nil).intersects(view.bounds) { found.append(field) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    func testIdleSearchBoxesAreJustTextSoNothingBehindAModalCanLeakAnInsertionCursor() async throws {
        let app = AppModel()
        let key = "modal-cursor-" + UUID().uuidString
        app.currentProjectKey = key
        app.isInWorkspace = true
        defer { app.shots.removeAll { $0.projectKey == key }; app.isInWorkspace = false; app.currentProjectKey = nil; app.activeModal = nil }
        let shot = ShotDraft(projectKey: key, model: "m", prompt: "[颁奖台][周承山][怀表]\n中景。", numbering: ShotNumbering(a: 1, b: 1))
        app.shots = [shot]
        app.timelineShotID = shot.id
        app.workspaceMode = .video
        app.projectPage = .production
        let host = NSHostingView(rootView: RootView().environment(app).frame(width: 1160, height: 710))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 710), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async throws { for _ in 0..<8 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() } }

        try await settle()
        XCTAssertTrue(textFields(in: host).isEmpty, "平时页头的搜索框是一行字，没有输入框（也就没有插入竖线的指针区域）")

        let refreshesBefore = PointerRegions.refreshCount
        app.activeModal = .editVideoPrompt(shotID: shot.id)
        try await settle()
        XCTAssertEqual(PointerRegions.refreshCount, refreshesBefore + 1, "弹窗一打开就让窗口重算指针区域")
        XCTAssertTrue(textFields(in: host).isEmpty, "弹窗开着：后面没有输入框，不会在弹窗上漏出竖线指针")

        app.activeModal = nil
        try await settle()
        XCTAssertEqual(PointerRegions.refreshCount, refreshesBefore + 2, "关掉也重算")
    }
}

/// 搜索框平时是文字，点一下变成输入框并拿到焦点，失去焦点变回文字
@MainActor
final class QuietSearchFieldTests: XCTestCase {
    @Observable final class Model { var text = ""; var wantsFocus = false }
    struct Wrapper: View {
        @Bindable var model: Model
        @FocusState private var focused: Bool
        var body: some View {
            QuietSearchField(placeholder: "搜索", text: $model.text, focus: $focused)
                .frame(width: 200, height: 30)
                .onChange(of: model.wantsFocus) { _, new in focused = new }
        }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        func walk(_ v: NSView) { if let f = v as? NSTextField, f.isEditable { found.append(f) }; v.subviews.forEach(walk) }
        walk(view)
        return found
    }

    func testItIsPlainTextUntilItGetsFocusAndTurnsBackWhenFocusIsLost() async throws {
        let model = Model()
        let host = NSHostingView(rootView: Wrapper(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func settle() async throws { for _ in 0..<5 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() } }
        try await settle()
        XCTAssertTrue(fields(in: host).isEmpty, "平时没有输入框")

        // 点一下（合成一对鼠标按下 / 抬起）
        let point = NSPoint(x: 40, y: 15)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        try await settle()
        XCTAssertEqual(fields(in: host).count, 1, "点一下：变成真正的输入框")

        model.text = "第三集"
        window.makeFirstResponder(nil)                    // 点了别处 / 焦点离开
        try await settle()
        XCTAssertTrue(fields(in: host).isEmpty, "失去焦点：变回文字")
        XCTAssertEqual(model.text, "第三集", "搜的字还在")
    }
}
