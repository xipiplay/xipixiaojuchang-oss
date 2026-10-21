import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 2026-10-15 用户：编辑提示词弹窗整个搬进二级页面。嵌着的那份点外面就存（不回滚），别处改了提示词要跟上
@MainActor
final class InlinePromptEditorTests: XCTestCase {
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    func testEditingInlineSavesOnBlurAndFollowsOutsideChanges() throws {
        let key = "inline-" + UUID().uuidString
        let app = AppModel()
        app.currentProjectKey = key
        let id = app.addShot()
        let i = try XCTUnwrap(app.shots.firstIndex { $0.id == id })
        app.shots[i].prompt = "镜头1：甲推门进来。"
        defer { app.shots.removeAll { $0.projectKey == key }; app.currentProjectKey = nil }

        let host = NSHostingView(rootView: EditPromptSheet(shot: app.shots[i], onClose: {}, inline: true)
            .environment(app).frame(width: 480, height: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let editor = try XCTUnwrap(views(PromptTextView.self, in: host).first)
        editor.beginEditing()
        XCTAssertTrue(window.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("又退了出去。", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.makeFirstResponder(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(app.shots.first { $0.id == id }?.prompt, "镜头1：甲推门进来。又退了出去。", "点外面就存")

        // 别处改了（重新推理、换回别的版本）：没在打字时跟上
        app.updateShotPrompt(id, prompt: "镜头1：乙坐下。")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(views(PromptTextView.self, in: host).first?.string, "镜头1：乙坐下。")
    }
}
