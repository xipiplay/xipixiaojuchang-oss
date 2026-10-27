import AppKit
import SwiftUI
import XCTest
@testable import Xipixiaojuchang

/// 点弹窗空白处不能关掉弹窗（2026-10-28 用户录屏：点生图弹窗空白处，弹窗被关掉）：
/// 面板空白处要落在 `PanelEventSinkView` 上，面板外面才落到遮罩挡板，面板里的控件照常由 SwiftUI 接
@MainActor
final class ModalBlankClickTests: XCTestCase {
    private func hit(_ window: NSWindow, _ x: CGFloat, _ y: CGFloat) -> NSView? {
        let content = window.contentView!
        return content.hitTest(content.superview!.convert(NSPoint(x: x, y: y), from: nil))
    }

    func testBlankPanelAreaIsCaughtByPanel() {
        for glass in [true, false] {
            let size = CGSize(width: 800, height: 600)
            // 面板 400×300 居中：x 200…600，y 150…450；按钮在正中
            let root = Color.gray
                .appModal(isPresented: .constant(true), width: 400, height: 300, handlesEsc: false) {
                    VStack {
                        HStack { Text("编辑提示词"); Spacer() }
                        Spacer()
                        Button("按钮") {}
                        Spacer()
                    }
                }
                .environment(\.glassEffectEnabled, glass)
                .frame(width: size.width, height: size.height)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: root)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            defer { window.orderOut(nil) }

            XCTAssertTrue(hit(window, 550, 400) is PanelEventSinkView, "玻璃=\(glass)：面板右上空白处由面板接住")
            XCTAssertTrue(hit(window, 250, 200) is PanelEventSinkView, "玻璃=\(glass)：面板左下空白处由面板接住")
            XCTAssertTrue(hit(window, 50, 50) is OverlayEventShieldView, "玻璃=\(glass)：面板外面照样落到遮罩（点外面关弹窗）")
            XCTAssertFalse(hit(window, 400, 300) is PanelEventSinkView, "玻璃=\(glass)：按钮不被底层挡住")
        }
    }

    /// 面板里的提示词框（AppKit 文本框）照样在最上面：能点进去编辑、悬停预览也还在
    func testPromptEditorInPanelStaysOnTop() throws {
        let size = CGSize(width: 800, height: 600)
        let root = Color.gray
            .appModal(isPresented: .constant(true), width: 400, height: 300, handlesEsc: false) {
                PromptEditor(text: .constant(String(repeating: "提示词\n", count: 30)), isEditable: true, scrollable: true, clickToEdit: true)
                    .padding(20)
            }
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        defer { window.orderOut(nil) }
        let textView = try XCTUnwrap(Self.find(in: window.contentView!))
        XCTAssertTrue(hit(window, 400, 300) === textView)
        XCTAssertTrue(textView.isTopmost(atWindowPoint: NSPoint(x: 400, y: 300)))
    }

    private static func find(in view: NSView) -> PromptTextView? {
        if let tv = view as? PromptTextView { return tv }
        for sub in view.subviews { if let tv = find(in: sub) { return tv } }
        return nil
    }
}
