import SwiftUI
import AppKit

/// 剧本页的文本框（2026-10-07）：平时**只读**，点一下进入编辑，点外面回到只读并存盘。
///
/// 为什么自己做、不用 `TextEditor`：
/// - 剧本页的文本框直接可编辑，设置弹窗 / 素材库 / 任务抽屉盖在它上面时，鼠标滑过会被它改成插入竖线（遮罩管不住，试了三种压指针的办法）。
///   平时只读、不可选中的 NSTextView 不会改指针——和生图 / 生视频页那些只读的文字一样。
/// - 上一版用「钩子按位置去找 TextEditor 底下的 NSTextView」来切只读 / 编辑，在窗口里常驻的别的页面（也有 NSTextView，位置重叠）
///   被误找到，用户点一下，进入编辑的是别的输入框。现在文本框就是我们自己建的 NSTextView，**拿着它本身**，不用找。
/// - 脚本要一字不差：关掉智能引号、破折号替换、自动更正、拼写检查，粘贴一律纯文本。
struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// 是否在编辑。点一下（只读时）会把它设成 true；焦点离开文本框会把它设成 false 并调 `onEndEditing`
    @Binding var isEditing: Bool
    /// 文本框底部被浮在上面的东西盖住的高度（工作台的胶囊）：最后几行能滚到它上面来
    var bottomInset: CGFloat = 0
    /// 焦点离开（点外面 / 切到别的输入框）：页面在这里存盘
    var onEndEditing: () -> Void = {}

    static let fontSize: CGFloat = 14
    static let lineSpacing: CGFloat = 5

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 用 TextKit 1：TextKit 2 只「估」总高度（实测一份长剧本它只估出真实高度的一半），边滚边排版边修正，滚动时内容会跳行；
        // TextKit 1 一开始就排完全文，总高度是准的（1500 行 / 5 万字约 70 毫秒），滚动稳。
        let textView = ScriptTextView(usingTextLayoutManager: false)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        // 脚本一字不差：不要智能引号、不要把 -- 换成破折号、不要自动更正 / 文本替换 / 拼写检查
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        Self.style(textView)
        Self.setText(text, in: textView)
        Self.applyMode(editing: isEditing, to: textView)

        let scroll = NSScrollView()
        // 只许上下滚（2026-10-16 用户录屏：妙控鼠标横着一划，「本段名字」「本段剧情」的字整体往右偏一截再弹回来）：
        // 和编辑提示词弹窗同一个办法，横向位置钉在 0（见 `VerticalOnlyClipView`）
        scroll.contentView = VerticalOnlyClipView()
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.usesPredominantAxisScrolling = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ScriptTextView else { return }
        if scroll.contentInsets.bottom != bottomInset { scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0) }
        // 输入法拼音组合期间不替换文本（会打断组合、光标跳到末尾）
        if textView.string != text, !textView.hasMarkedText() { Self.setText(text, in: textView) }
        Self.applyMode(editing: isEditing, to: textView)
        // 页面要求回到只读（换集 / 打开弹窗 / 保存完）而它还拿着焦点：放手
        if !isEditing, textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }

    // MARK: 样式 / 模式

    /// 只读：不可编辑也不可选中（鼠标滑过不会变插入竖线）；编辑：都可以
    ///
    /// ⚠️ NSTextView 的插入竖线是靠「指针区域」(cursor rect) 实现的，而**改 `isEditable` / `isSelectable` 不会让 AppKit 重算它**：
    /// 点进编辑后竖线区域没建起来，指针一直是箭头，直到滚动 / 缩放窗口才被动重建（看起来像「滑一下才变、卡一下」）；
    /// 反过来，编辑过一次再回到只读，旧的竖线区域还留着（弹窗盖上来时又漏出竖线）。所以模式一变就主动让窗口重算。
    static func applyMode(editing: Bool, to textView: ScriptTextView) {
        let changed = textView.isEditable != editing || textView.isSelectable != editing
        textView.isEditable = editing
        textView.isSelectable = editing
        if changed { textView.refreshCursorRects() }
    }

    static func style(_ textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
    }

    static func setText(_ text: String, in textView: NSTextView) {
        textView.string = text
        if let storage = textView.textStorage {
            storage.setAttributes(textView.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor
        weak var textView: ScriptTextView?
        init(_ parent: ScriptTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, parent.text != textView.string else { return }
            parent.text = textView.string
        }

        /// 只读时点了一下：进入编辑（之后这一下点击照常交给 NSTextView，光标落在点的位置、双击选词、拖选都正常）
        func beginEditing(in textView: ScriptTextView) {
            parent.isEditing = true
            ScriptTextEditor.applyMode(editing: true, to: textView)
            textView.window?.makeFirstResponder(textView)
        }

        /// 焦点离开了文本框：回到只读并通知页面存盘
        func didResign(_ textView: ScriptTextView) {
            guard parent.isEditing else { return }
            parent.isEditing = false
            ScriptTextEditor.applyMode(editing: false, to: textView)
            parent.onEndEditing()
        }
    }
}

final class ScriptTextView: NSTextView {
    weak var coordinator: ScriptTextEditor.Coordinator?

    /// 只读时不抢焦点（点它只是「开始编辑」）
    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        if !isEditable { coordinator?.beginEditing(in: self) }
        super.mouseDown(with: event)
    }

    /// 要求窗口重算这个文本框的指针区域（模式切换后调，见 `ScriptTextEditor.applyMode`）；次数留给测试看
    private(set) var cursorRectRefreshes = 0
    func refreshCursorRects() {
        cursorRectRefreshes += 1
        window?.invalidateCursorRects(for: self)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { coordinator?.didResign(self) }
        return ok
    }
}
