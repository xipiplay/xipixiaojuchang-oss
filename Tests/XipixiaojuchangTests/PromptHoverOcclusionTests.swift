import AppKit
import SwiftUI
import XCTest
@testable import Xipixiaojuchang

/// 提示词框的悬停预览不能穿透盖在上面的弹窗（2026-10-28 用户录屏：段落详情上叠开生图弹窗，弹出了后面「主持人」的放大图）
@MainActor
final class PromptHoverOcclusionTests: XCTestCase {
    /// 和段落详情 / 生图弹窗里一样的提示词框：真的 PromptEditor（滚动模式）+ 底色 + 输入框外框
    private func host(covered: Bool) -> (NSWindow, PromptTextView) {
        let size = CGSize(width: 600, height: 400)
        let root = ZStack {
            PromptEditor(text: .constant(String(repeating: "提示词正文\n", count: 40)), isEditable: true, scrollable: true, clickToEdit: true)
                .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
                .inputChrome(focused: false, radius: 14)
            if covered {
                AppModal(handlesEsc: false, onClose: {}) {
                    Text("编辑提示词").frame(width: 400, height: 300)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, Self.find(in: window.contentView!)!)
    }

    private static func find(in view: NSView) -> PromptTextView? {
        if let tv = view as? PromptTextView { return tv }
        for sub in view.subviews { if let tv = find(in: sub) { return tv } }
        return nil
    }

    /// 文字框正中（窗口坐标）：没盖着时就落在它身上；盖着时落在弹窗的空白处
    private func middle(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    func testUncoveredTextViewIsTopmost() {
        let (window, textView) = host(covered: false)
        defer { window.orderOut(nil) }
        XCTAssertTrue(textView.isTopmost(atWindowPoint: middle(of: textView)))
    }

    func testModalCoveringTextViewBlocksHover() {
        let (window, textView) = host(covered: true)
        defer { window.orderOut(nil) }
        XCTAssertFalse(textView.isTopmost(atWindowPoint: middle(of: textView)), "弹窗盖着：不算鼠标在提示词框上")
        XCTAssertFalse(textView.isTopmost(atWindowPoint: NSPoint(x: 20, y: 20)), "弹窗外的遮罩也盖着")
    }
}
