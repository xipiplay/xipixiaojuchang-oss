import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 设置里的提示词编辑框（2026-10-09）：TextKit 1、不做引号替换、能把 TXT 拖进来整条替换（⌘Z 可撤销）
@MainActor
final class PromptTextEditorTests: XCTestCase {
    private final class Box: @unchecked Sendable { var text: String; init(_ text: String) { self.text = text } }

    /// 把编辑框放进一个真窗口，返回它的 NSTextView
    private func makeEditor(_ box: Box, drops: DropLog = DropLog()) async throws -> (PromptNSTextView, NSWindow) {
        let binding = Binding<String>(get: { box.text }, set: { box.text = $0 })
        let editor = PromptTextEditor(text: binding, onDropResult: { drops.results.append($0) })
        let host = NSHostingView(rootView: editor.frame(width: 500, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        func find(_ v: NSView) -> PromptNSTextView? {
            if let t = v as? PromptNSTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        return (try XCTUnwrap(find(host)), window)
    }
    private final class DropLog { var results: [Result<(name: String, count: Int), PromptTextDropError>] = [] }

    private func tempFile(_ name: String, data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testItUsesTextKit1AndDoesNotRewriteQuotesOrDashes() async throws {
        let box = Box("初始")
        let (textView, window) = try await makeEditor(box)
        defer { window.close() }
        XCTAssertNil(textView.textLayoutManager, "TextKit 1：长提示词滚动不跳")
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isRichText)
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertEqual(scroll.scrollerStyle, .overlay, "叠加式滚动条：不会因为接了鼠标就占一条宽度、让文字换行位置左右挪")
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        XCTAssertEqual(textView.string, "初始")
    }

    func testTypingAndReplacingWriteBackToTheBinding() async throws {
        let box = Box("原来的提示词")
        let (textView, window) = try await makeEditor(box)
        defer { window.close() }
        textView.replaceAll(with: "换成这一条")
        XCTAssertEqual(box.text, "换成这一条")
        XCTAssertEqual(textView.string, "换成这一条")
        textView.insertText("，再接一句", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(box.text, "换成这一条，再接一句")
    }

    func testDroppingATxtReplacesEverythingAndCanBeUndone() async throws {
        let box = Box("原来的提示词，改了半天")
        let drops = DropLog()
        let (textView, window) = try await makeEditor(box, drops: drops)
        defer { window.close() }
        let url = try tempFile("提取场景.txt", data: Data("拖进来的\n提示词".utf8))
        XCTAssertTrue(textView.acceptDroppedFile(url))
        XCTAssertEqual(textView.string, "拖进来的\n提示词")
        XCTAssertEqual(box.text, "拖进来的\n提示词", "写回了绑定，保存才存得进去")
        XCTAssertEqual(drops.results.count, 1)
        if case .success(let file)? = drops.results.first { XCTAssertEqual(file.name, "提取场景.txt"); XCTAssertEqual(file.count, 8) } else { XCTFail("应当成功") }
        // ⌘Z
        let undo = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undo.canUndo)
        undo.undo()
        XCTAssertEqual(textView.string, "原来的提示词，改了半天", "拖错了文件可以撤销回来")
        XCTAssertEqual(box.text, "原来的提示词，改了半天")
    }

    func testDroppingATxtReadsGBKFilesToo() async throws {
        let box = Box("")
        let (textView, window) = try await makeEditor(box)
        defer { window.close() }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let url = try tempFile("gbk.txt", data: try XCTUnwrap("角色提取规则：场景叫「客厅」".data(using: gb)))
        XCTAssertTrue(textView.acceptDroppedFile(url))
        XCTAssertEqual(box.text, "角色提取规则：场景叫「客厅」")
    }

    func testAnEmptyOrUnreadableFileLeavesTheTextAloneAndSaysWhy() async throws {
        let box = Box("别丢")
        let drops = DropLog()
        let (textView, window) = try await makeEditor(box, drops: drops)
        defer { window.close() }
        XCTAssertFalse(textView.acceptDroppedFile(try tempFile("空.txt", data: Data("  \n ".utf8))))
        XCTAssertFalse(textView.acceptDroppedFile(try tempFile("乱码.txt", data: Data([0xFF, 0xFE, 0x00, 0xD8, 0x00]))))
        XCTAssertEqual(box.text, "别丢")
        XCTAssertEqual(textView.string, "别丢")
        XCTAssertEqual(drops.results.count, 2)
        for r in drops.results { if case .failure(let e) = r { XCTAssertTrue(e.message.contains("读不出")) } else { XCTFail("应当失败") } }
    }

    func testOnlyTextFilesAreTakenOverFromADrag() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("prompt-drop-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let txt = try tempFile("a.txt", data: Data("x".utf8))
        let png = try tempFile("b.png", data: Data([0]))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([png as NSURL, txt as NSURL]))
        XCTAssertEqual(PromptNSTextView.droppedTextFile(board)?.lastPathComponent, "a.txt", "多个文件取第一个文本文件")
        board.clearContents()
        XCTAssertTrue(board.writeObjects([png as NSURL]))
        XCTAssertNil(PromptNSTextView.droppedTextFile(board), "图片不接管，走 NSTextView 原来的行为")
        board.clearContents()
        board.setString("只是一段文字", forType: .string)
        XCTAssertNil(PromptNSTextView.droppedTextFile(board))
    }
}

/// 左边那七条：顺序是流程顺序，「改过」= 和内置默认不一样
final class PipelinePromptsEditorItemTests: XCTestCase {
    func testItemsFollowTheFlowOrderAndMapToTheRightFields() {
        typealias Item = PipelinePromptsEditor.Item
        XCTAssertEqual(Item.allCases.map(\.title), ["分集", "分割（时长）", "分段命名", "提取角色", "提取场景", "提取道具", "推理分镜"])
        var settings = PipelinePromptSettings()
        for (i, item) in Item.allCases.enumerated() { settings[keyPath: item.keyPath] = "内容\(i)" }
        XCTAssertEqual([settings.split, settings.segments, settings.naming, settings.role, settings.scene, settings.prop, settings.storyboard],
                       (0..<7).map { "内容\($0)" })
        XCTAssertEqual(Item.scene.fallback, PipelinePromptStore.sceneDefault)
        XCTAssertEqual(Item.storyboard.fallback, PipelinePromptStore.shotsDefault)
    }

    func testModifiedMeansDifferentFromTheBuiltInDefaultIgnoringOuterWhitespace() {
        typealias Item = PipelinePromptsEditor.Item
        var settings = PipelinePromptsEditor.defaultSettings
        XCTAssertTrue(Item.allCases.allSatisfy { !$0.isModified(in: settings) }, "全是默认 = 都没改")
        settings.scene = "\n  " + PipelinePromptStore.sceneDefault + "  \n"
        XCTAssertFalse(Item.scene.isModified(in: settings), "前后多的空白不算改")
        settings.scene = "我自己改的场景提取"
        settings.role = ""
        XCTAssertTrue(Item.scene.isModified(in: settings))
        XCTAssertTrue(Item.role.isModified(in: settings), "清空 = 和默认不一样（保存时空文本会回到跟随默认）")
        XCTAssertFalse(Item.prop.isModified(in: settings))
    }
}
