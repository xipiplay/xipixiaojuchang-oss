import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 生图 / 生视频页「编辑提示词」弹窗里的编辑框（PromptEditor）：一开始就必须是 TextKit 1
/// （2026-10-09：默认的 TextKit 2 在代码碰到 layoutManager 的那一刻会中途降级，文字消失到滚动才回来）
@MainActor
final class PromptEditorEngineTests: XCTestCase {
    private func textView(scrollable: Bool) async throws -> (NSTextView, NSWindow) {
        var text = "镜头从图1的背后推进，图1回头。"
        let binding = Binding<String>(get: { text }, set: { text = $0 })
        // 真有一张缩略图，「图1」才会被换成内嵌的缩略图附件
        let image = NSImage(size: NSSize(width: 64, height: 36)); image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); image.unlockFocus()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-slot-\(UUID().uuidString).png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        let slots = [SlotItem(token: "图1", name: "林知夏", thumbnailURL: url, remoteThumbnailURL: nil)]
        let editor = PromptEditor(text: binding, slots: slots, scrollable: scrollable)
        let host = NSHostingView(rootView: editor.frame(width: 560, height: 220))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        func find(_ v: NSView) -> NSTextView? {
            if let t = v as? NSTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        return (try XCTUnwrap(find(host)), window)
    }

    func testTheModalEditorIsTextKit1FromTheStartAndStaysSoWhenLayoutManagerIsTouched() async throws {
        let (tv, window) = try await textView(scrollable: true)
        defer { window.close() }
        XCTAssertNil(tv.textLayoutManager, "一开始就是 TextKit 1，不会在悬停 / 输入 @ 时中途降级")
        _ = tv.layoutManager
        XCTAssertNil(tv.textLayoutManager)
        XCTAssertEqual(tv.string.contains("\u{FFFC}"), true, "「图1」还是被换成了缩略图附件的占位字符")
    }

    func testEditingAlwaysMarksTheWholeEditorForRedrawAndScrollersDontTakeWidth() async throws {
        let (tv, window) = try await textView(scrollable: true)
        defer { window.close() }
        let scroll = try XCTUnwrap(tv.enclosingScrollView)
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "叠加式滚动条（和剧本页那个文本框一样），不占宽度")
        XCTAssertTrue(scroll.autohidesScrollers)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        XCTAssertEqual(tv.layoutManager?.allowsNonContiguousLayout, false)
        // 改字之后整个文本框都要被标脏（「句号后敲回车，下一行没画出来」那类现象的兜底）
        let promptView = try XCTUnwrap(tv as? PromptTextView)
        let before = promptView.forcedRedrawCount
        promptView.insertNewline(nil)
        XCTAssertEqual(promptView.forcedRedrawCount, before + 1, "敲回车：改字后整块重画一次")
        promptView.insertText("字", replacementRange: promptView.selectedRange())
        XCTAssertEqual(promptView.forcedRedrawCount, before + 2, "打字也一样")
        promptView.deleteBackward(nil)
        XCTAssertEqual(promptView.forcedRedrawCount, before + 3, "删字也一样（删一个回车后那一行又隐藏的情况）")
    }

    func testTheCardEditorIsTextKit1Too() async throws {
        let (tv, window) = try await textView(scrollable: false)
        defer { window.close() }
        XCTAssertNil(tv.textLayoutManager)
    }
}

/// 2026-10-09 用户：「在编辑提示词弹窗里改提示词，有时文字不显示，滑一下才正常」。
/// 真实复现：缩略图后面打的字是黑色 12 号（缩略图附件字符自己没有字体和颜色，光标停在它后面时新字继承了「没有属性」），
/// 暗色主题下黑字压深色底，看着就是没显示。现在每个字符都必须带着字体和颜色。
@MainActor
final class PromptEditorAttributeTests: XCTestCase {
    @Observable final class TextModel { var text: String; init(_ text: String) { self.text = text } }
    struct Wrapper: View {
        @Bindable var model: TextModel
        let slots: [SlotItem]
        var body: some View { PromptEditor(text: $model.text, slots: slots, scrollable: true).frame(width: 520, height: 200) }
    }

    private func thumbnail() throws -> URL {
        let image = NSImage(size: NSSize(width: 64, height: 36)); image.lockFocus(); NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 64, height: 36).fill(); image.unlockFocus()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-attr-\(UUID().uuidString).png")
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func open(_ model: TextModel, slots: [SlotItem]) async throws -> (PromptTextView, NSWindow) {
        let host = NSHostingView(rootView: Wrapper(model: model, slots: slots))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        func find(_ v: NSView) -> PromptTextView? {
            if let t = v as? PromptTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        let tv = try XCTUnwrap(find(host))
        window.makeFirstResponder(tv)
        return (tv, window)
    }

    private func assertNewTextLooksRight(_ tv: PromptTextView, from index: Int, file: StaticString = #filePath, line: UInt = #line) {
        let storage = tv.textStorage!
        for i in index..<storage.length {
            let attrs = storage.attributes(at: i, effectiveRange: nil)
            XCTAssertEqual(attrs[.foregroundColor] as? NSColor, NSColor.textColor, "第 \(i) 个字没有文字颜色", file: file, line: line)
            XCTAssertEqual((attrs[.font] as? NSFont)?.pointSize, 14, "第 \(i) 个字不是 14 号", file: file, line: line)
        }
    }

    func testTextTypedRightAfterAThumbnailKeepsTheColorAndSize() async throws {
        let (tv, window) = try await open(TextModel("镜头从"), slots: [SlotItem(token: "图1", name: "林知夏", thumbnailURL: try thumbnail(), remoteThumbnailURL: nil)])
        defer { window.close() }
        // 以前的写法：附件字符不带任何属性（NSAttributedString(attachment:)）
        let image = NSImage(size: NSSize(width: 64, height: 36))
        let raw = NSAttributedString(attachment: SlotAttachment(token: "图1", image: image))
        tv.textStorage?.replaceCharacters(in: NSRange(location: (tv.string as NSString).length, length: 0), with: raw)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))   // 光标落在缩略图后面
        let before = (tv.string as NSString).length
        tv.insertText("，回头说话", replacementRange: NSRange(location: before, length: 0))
        assertNewTextLooksRight(tv, from: 0)
        XCTAssertEqual(tv.typingAttributes[.foregroundColor] as? NSColor, NSColor.textColor)
        XCTAssertEqual((tv.typingAttributes[.font] as? NSFont)?.pointSize, 14)
    }

    func testPastedTextAndUndoAlsoKeepTheAttributes() async throws {
        let (tv, window) = try await open(TextModel("开头"), slots: [])
        defer { window.close() }
        // 程序替换整段文字（自动匹配 / 恢复内容这类）：没带属性的纯字符串
        tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 2), with: "整段换成没有属性的字符串")
        assertNewTextLooksRight(tv, from: 0)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("前面加一句。", replacementRange: NSRange(location: 0, length: 0))
        assertNewTextLooksRight(tv, from: 0)
    }

    func testEveryCharacterOfTheInitialTextAlreadyCarriesFontAndColor() async throws {
        let (tv, window) = try await open(TextModel("镜头从图1的背后推进，图1回头。"),
                                          slots: [SlotItem(token: "图1", name: "林知夏", thumbnailURL: try thumbnail(), remoteThumbnailURL: nil)])
        defer { window.close() }
        XCTAssertEqual(tv.string.filter { $0 == "\u{FFFC}" }.count, 2, "两处「图1」都换成了缩略图附件")
        assertNewTextLooksRight(tv, from: 0)
    }

    func testASecondMentionOfTheSameMaterialBecomesAThumbnailToo() async throws {
        // 图1 缩略图在缓存里没有 → 走异步补图路径（以前只补第一处，第二处一直是纯文字「图1」）
        let (tv, window) = try await open(TextModel("镜头从图1的背后推进，图1回头。"),
                                          slots: [SlotItem(token: "图1", name: "林知夏", thumbnailURL: try thumbnail(), remoteThumbnailURL: nil)])
        defer { window.close() }
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(tv.string.filter { $0 == "\u{FFFC}" }.count, 2, tv.string)
        let coordinator = try XCTUnwrap(tv.delegate as? PromptEditor.Coordinator)
        XCTAssertEqual(coordinator.plainText(), "镜头从图1的背后推进，图1回头。", "还原成纯文本不变")
    }

    func testTokenOneDoesNotEatTheStartOfTokenTen() async throws {
        let (tv, window) = try await open(TextModel("图1和图10和图12"),
                                          slots: [SlotItem(token: "图1", name: "甲", thumbnailURL: try thumbnail(), remoteThumbnailURL: nil)])
        defer { window.close() }
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(tv.string.filter { $0 == "\u{FFFC}" }.count, 1, "只有真正的「图1」换成缩略图：\(tv.string)")
        XCTAssertTrue(tv.string.contains("图10") && tv.string.contains("图12"), tv.string)
    }

    func testReplacingTheTextFromOutsideResetsWhichTokensAreTracked() async throws {
        let model = TextModel("镜头图1和图2")
        let (tv, window) = try await open(model, slots: [])
        defer { window.close() }
        let coordinator = try XCTUnwrap(tv.delegate as? PromptEditor.Coordinator)
        XCTAssertEqual(coordinator.trackedTokens, ["图1", "图2"])
        model.text = "镜头图1"            // 外部（自动匹配 / 清空素材 / 重编号回灌）换了正文
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(80)) }
        XCTAssertEqual(tv.string, "镜头图1")
        XCTAssertEqual(coordinator.trackedTokens, ["图1"], "基线跟着外部那次变化重置，否则下次用户改字会把它当成「删了缩略图」")
    }
}

/// 2026-10-10 用户：「编辑提示词弹窗在修改之后，里边的提示词开始左右滑动」（用的是妙控鼠标，能左右划）。
/// 提示词框只许上下滚：横向永远贴着左边。
@MainActor
final class PromptEditorVerticalOnlyTests: XCTestCase {
    func testTheClipViewNeverLetsTheContentMoveSideways() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scroll.contentView = VerticalOnlyClipView()
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 800))      // 比可见区域宽
        scroll.documentView = doc
        scroll.contentView.scroll(to: NSPoint(x: 120, y: 60))
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, "横向被钉在左边")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 60, "上下照常滚")
    }

    func testTheModalEditorUsesIt() async throws {
        var text = "镜头从图1的背后推进。"
        let binding = Binding<String>(get: { text }, set: { text = $0 })
        let host = NSHostingView(rootView: PromptEditor(text: binding, slots: [], scrollable: true).frame(width: 560, height: 220))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        defer { window.close() }
        func findScroll(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = findScroll(sub) { return s } }
            return nil
        }
        let scroll = try XCTUnwrap(findScroll(host))
        XCTAssertTrue(scroll.contentView is VerticalOnlyClipView)
        XCTAssertTrue(scroll.usesPredominantAxisScrolling)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
    }
}

/// 2026-10-10 用户：编辑提示词弹窗里没点进去的时候，鼠标滑过提示词框就变成插入竖线——要和剧本页的原文 / 时长分割框一样：
/// 平时只读（箭头），点一下才编辑（竖线），点别处回到只读。
@MainActor
final class PromptEditorClickToEditTests: XCTestCase {
    private func make(clickToEdit: Bool) async throws -> (PromptTextView, NSScrollView, NSWindow, () -> String) {
        var text = "镜头从图1的背后推进。"
        let binding = Binding<String>(get: { text }, set: { text = $0 })
        let host = NSHostingView(rootView: PromptEditor(text: binding, slots: [], isEditable: true, scrollable: true, clickToEdit: clickToEdit).frame(width: 560, height: 220))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        func find(_ v: NSView) -> PromptTextView? {
            if let t = v as? PromptTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        let tv = try XCTUnwrap(find(host))
        return (tv, try XCTUnwrap(tv.enclosingScrollView), window, { text })
    }

    func testItStartsReadOnlyWithAnArrowAndEntersEditingOnClick() async throws {
        let (tv, scroll, window, text) = try await make(clickToEdit: true)
        defer { window.close() }
        XCTAssertFalse(tv.isEditable)
        XCTAssertFalse(tv.isSelectable, "只读且不可选中：鼠标滑过不会变成插入竖线")
        XCTAssertFalse(tv.acceptsFirstResponder, "只读时不抢焦点")
        XCTAssertFalse(scroll.contentView.documentCursor === NSCursor.iBeam, "指针区域里没有插入竖线")

        tv.beginEditing()                                                // 点一下
        XCTAssertTrue(tv.isEditable && tv.isSelectable)
        XCTAssertTrue(window.firstResponder === tv)
        XCTAssertTrue(scroll.contentView.documentCursor === NSCursor.iBeam, "编辑中：竖线")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("新", replacementRange: tv.selectedRange())
        XCTAssertTrue(text().hasPrefix("新"), "编辑中能正常打字、写回绑定的文字")

        XCTAssertTrue(window.makeFirstResponder(nil))                     // 点别处
        XCTAssertFalse(tv.isEditable)
        XCTAssertFalse(tv.isSelectable, "焦点离开：回到只读")
        XCTAssertFalse(scroll.contentView.documentCursor === NSCursor.iBeam)
        XCTAssertTrue(text().hasPrefix("新"), "文字还在")
    }

    func testAnEditorThatIsNotClickToEditBehavesAsBefore() async throws {
        let (tv, _, window, _) = try await make(clickToEdit: false)
        defer { window.close() }
        XCTAssertTrue(tv.isEditable && tv.isSelectable)
        XCTAssertTrue(tv.acceptsFirstResponder)
    }
}
