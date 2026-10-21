import SwiftUI
import AppKit

/// 设置里编辑提示词规则用的文本框（2026-10-09）。
///
/// 为什么不用 `TextEditor`：
/// - 长提示词（分镜那条一万多字）在 TextKit 2 里滚动时「边滚边估高度」，内容会跳；这里和剧本页的 `ScriptTextEditor` 一样用 TextKit 1，一开始就排完全文，高度是准的。
/// - 滚动条固定成**叠加式**（`.overlay`、自动隐藏）：系统设置「显示滚动条：自动」时，接鼠标会给每个文本框加一条常驻滚动条，
///   文字宽度跟着变、换行位置左右挪；叠加式不占宽度。
/// - 提示词里有大量引号、破折号：关掉智能引号 / 破折号替换 / 自动更正，免得输入的 `"` 被悄悄换成弯引号；粘贴一律纯文本。
/// 这个文本框一直可编辑（不像剧本页那个「点一下才进入编辑」）：它在设置弹窗里，上面没有别的浮层会盖住它。
///
/// **支持把 TXT（或 .md）文件拖进来**（2026-10-09 用户要求）：整条提示词换成文件内容（兼容 UTF-8 / GB18030 / UTF-16）。
/// 走文本框自己的「替换」，所以**可以按 ⌘Z 撤销**；拖的不是文本文件就还是 NSTextView 原来的行为。
struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// 焦点进出（外面据此画聚焦描边）
    var onFocusChange: (Bool) -> Void = { _ in }
    /// 有文本文件正拖在上面（外面据此画高亮 + 提示）
    var onDropTargetChange: (Bool) -> Void = { _ in }
    /// 拖入的结果：成功给「文件名 + 字数」，失败给原因
    var onDropResult: (Result<(name: String, count: Int), PromptTextDropError>) -> Void = { _ in }

    static let fontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 4

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptNSTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // NSTextView 对拖进来的文件，纯文本模式下只会插入文件路径：自己接管，见 `PromptNSTextView.performDragOperation`
        textView.registerForDraggedTypes(textView.registeredDraggedTypes + [.fileURL])
        Self.style(textView)
        Self.setText(text, in: textView)

        let scroll = NSScrollView()
        // 横向钉在 0（只关回弹拦不住妙控鼠标横划，2026-10-16 用户：输入框都能左右滑），见 `VerticalOnlyClipView`
        scroll.contentView = VerticalOnlyClipView()
        scroll.usesPredominantAxisScrolling = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? PromptNSTextView else { return }
        // 输入法拼音组合期间不替换文本（会打断组合、光标跳到末尾）
        if textView.string != text, !textView.hasMarkedText() { Self.setText(text, in: textView) }
    }

    private static var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraphStyle]
    }

    private static func style(_ textView: NSTextView) {
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = attributes
    }

    /// 换文本（外面点「恢复默认」/ 换了一条）：保留还在范围内的光标位置
    static func setText(_ text: String, in textView: NSTextView) {
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        textView.typingAttributes = attributes
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextEditor
        weak var textView: PromptNSTextView?
        init(_ parent: PromptTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, parent.text != textView.string else { return }
            parent.text = textView.string
        }
    }
}

final class PromptNSTextView: NSTextView {
    weak var coordinator: PromptTextEditor.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { notifyFocus(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { notifyFocus(false) }
        return ok
    }

    /// 粘贴一律纯文本：从网页 / 聊天窗口复制来的带格式文字不能把字体、颜色带进来
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    // MARK: 拖入文本文件

    /// 单个文本文件超过这个大小不读（提示词顶多几万字，几 MB 的一定拖错了）
    static let maxDroppedBytes = 2_000_000
    static let textExtensions: Set<String> = ["txt", "md", "text"]

    /// 拖拽里的文本文件（第一个）；不是文件 / 不是文本文件 → nil
    static func droppedTextFile(_ pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.first { textExtensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.droppedTextFile(sender.draggingPasteboard) != nil else { return super.draggingEntered(sender) }
        coordinator?.parent.onDropTargetChange(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.droppedTextFile(sender.draggingPasteboard) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        coordinator?.parent.onDropTargetChange(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.droppedTextFile(sender.draggingPasteboard) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = Self.droppedTextFile(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        coordinator?.parent.onDropTargetChange(false)
        return acceptDroppedFile(url)
    }

    /// 读文件、整条换掉、告诉外面结果。读不出 / 太大 → 不动现有内容，把原因交给外面提示
    @discardableResult
    func acceptDroppedFile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxDroppedBytes else {
            coordinator?.parent.onDropResult(.failure(.tooLarge(name: url.lastPathComponent)))
            return false
        }
        guard let content = EpisodeSplitter.loadText(url), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            coordinator?.parent.onDropResult(.failure(.unreadable(name: url.lastPathComponent)))
            return false
        }
        replaceAll(with: content)
        coordinator?.parent.onDropResult(.success((name: url.lastPathComponent, count: content.count)))
        return true
    }

    /// 整条换成 `content`：走文本框自己的替换（记撤销、触发 `textDidChange` 写回绑定），再回到开头、拿到焦点（⌘Z 才作用在它身上）
    func replaceAll(with content: String) {
        window?.makeFirstResponder(self)
        let whole = NSRange(location: 0, length: (string as NSString).length)
        // ⚠️ 只调 `insertText`：它自己会走「即将修改 / 已修改」并登记撤销。外面再包一层 `shouldChangeText` / `didChangeText`
        // 会把撤销记录登记两遍，⌘Z 之后文本会多出一截（测试抓到过）
        insertText(content, replacementRange: whole)
        setSelectedRange(NSRange(location: 0, length: 0))
        scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    private func notifyFocus(_ focused: Bool) {
        // 不在 AppKit 的焦点回调里直接改 SwiftUI 状态（可能正赶上一次视图更新）
        DispatchQueue.main.async { [weak self] in self?.coordinator?.parent.onFocusChange(focused) }
    }
}

/// 拖文本文件进来失败的原因（直接给人看）
enum PromptTextDropError: Error, Equatable {
    case unreadable(name: String)
    case tooLarge(name: String)

    var message: String {
        switch self {
        case .unreadable(let name): "读不出「\(name)」：文件是空的，或者不是文本（支持 UTF-8 / GBK / UTF-16 的 TXT）。"
        case .tooLarge(let name): "「\(name)」太大了（超过 2 MB），提示词不会这么长，是不是拖错了文件？"
        }
    }
}
