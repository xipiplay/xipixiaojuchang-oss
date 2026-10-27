import SwiftUI
import AppKit

/// 素材槽位项（用于 @ 弹窗展示）
struct SlotItem: Identifiable {
    var id: String { token }
    let token: String       // 图1 / 视频1 / 音频1（提交时还原用）
    let name: String        // 文件名或 URL
    let thumbnailURL: URL?  // 本地图片文件 URL（用于缩略图）
    let remoteThumbnailURL: URL?  // 远程图片直链（异步加载缩略图）
    /// 这张图是绑了音色的角色卡（2026-10-26）：缩略图角上画个小喇叭
    var hasVoice: Bool = false
}

extension SlotItem {
    /// 由分镜的素材引用生成槽位列表（卡片 / 编辑提示词弹窗 / 预览弹窗共用一套规则）。
    /// **传进来的 shot 要是实时数据**（从 `app.shots` 取），否则缩略图会陈旧。
    @MainActor
    static func list(for shot: ShotDraft, in app: AppModel) -> [SlotItem] {
        var items: [SlotItem] = []
        let lookup = { (id: UUID) in app.libraryItem(id) }
        for (i, ref) in shot.imageRefs.enumerated() {
            let item = app.libraryItem(ref.libraryItemID)
            let card = item?.imageGenItemID.flatMap { id in app.imageItems.first { $0.id == id } }
            items.append(SlotItem(
                token: "图\(i + 1)",
                name: item?.matchName ?? item?.fileName ?? "图\(i + 1)",
                thumbnailURL: item?.existingLocalImageURL,
                remoteThumbnailURL: item?.remoteURL.flatMap { URL(string: $0) },
                hasVoice: card.flatMap { CardVoice.resolve($0, library: lookup) } != nil
            ))
        }
        items += mediaSlots(for: shot, in: app)
        return items
    }

    /// 视频 / 音频的槽位：缩略图是首帧或「图标 + 名字」小标签（见 `MediaTokenThumbnail`）。
    /// ⚠️ 不给远程缩略图：原来把音视频直链当缩略图地址，编辑器会去下载整个 mp4 / wav 再解码失败
    @MainActor
    static func mediaSlots(for shot: ShotDraft, in app: AppModel) -> [SlotItem] {
        func slots(_ refs: [MaterialRef], prefix: String) -> [SlotItem] {
            refs.enumerated().map { i, ref in
                let item = app.libraryItem(ref.libraryItemID)
                let token = "\(prefix)\(i + 1)"
                return SlotItem(token: token, name: item?.matchName ?? item?.fileName ?? token,
                                thumbnailURL: MediaTokenThumbnail.url(for: item, token: token), remoteThumbnailURL: nil)
            }
        }
        return slots(shot.videoRefs, prefix: "视频") + slots(shot.audioRefs, prefix: "音频")
    }
}

/// 内嵌缩略图附件：视觉上是图，底层对应 token（提交时还原）
final class SlotAttachment: NSTextAttachment {
    let token: String
    let previewImage: NSImage   // 悬停放大用（**原图**，不做正方形裁剪 ✓）

    /// 内嵌图块的尺寸（pt）。**要更大/更小就改这两个数**（保持 16:9 ✓）。
    ///
    /// ⚠️ 2026-09-13 用户第二次调：先是"竖图太细"→ 做成正方形 ✓；
    /// 随后说"方形还是有点小，改成 16:9" → **32×18** ✓（比原来的 20×20 宽 60% ✓ 面积也更大 ✓）
    /// ⚠️ 卡片的 `ReadonlyPromptText.tokenThumbnail` 也用同一组尺寸 ✓ 两边要一起改 ✗
    private static let width: CGFloat = 32
    private static let height: CGFloat = 18
    /// 圆角（pt）。18 高的块上取 5（约 28%）—— 原来 20×20 时是 7（35%），按比例收了一点 ✓
    private static let cornerRadius: CGFloat = 6

    init(token: String, image: NSImage, voiceBadge: Bool = false) {
        self.token = token
        // ⚠️ 预览用**原图**：悬停放大时该看完整画面，不该是裁过、圆角过的方块 ✓
        self.previewImage = image
        super.init(data: nil, ofType: nil)
        // ⚠️ **嵌进文字里的图一律先裁成「圆角正方形」**（2026-09-12 用户要求）：
        // ① 正方形：原来宽是按图片比例算的（`宽 = 高 × 宽/高`）✗ → 竖图只有 11pt 宽，
        //    在文字里就是又细又窄的一条 ✓ 用户原话："有的竖图太细了" ✓
        // ② 圆角：**只能画进图里** ✗ —— `NSTextAttachment` 会把 `image` 原样贴上去，
        //    没有 `clipShape` 这类东西 ✓ 所以生成这张图时就带圆角（角上透明 ✓）
        if MediaTokenThumbnail.isChip(image) {
            // 音频 / 没有本地文件的视频：小标签（图标 + 名字）按原比例贴，同样 18 高（2026-10-16）
            // 缓存读回来的图尺寸按像素算（2 倍图）：按显示尺寸重画一张，不然贴上去只有一半大、后面空一截
            let size = NSSize(width: (Self.height * image.size.width / image.size.height).rounded(), height: Self.height)
            self.image = NSImage(size: size, flipped: false) { rect in image.draw(in: rect); return true }
            self.bounds = NSRect(x: 0, y: -5, width: size.width, height: size.height)
        } else {
            let square = Self.squareRounded(image)
            self.image = voiceBadge ? Self.withVoiceBadge(square) : square
            self.bounds = NSRect(x: 0, y: -5, width: Self.width, height: Self.height)
        }
    }

    /// 右下角画个小喇叭（绑了音色的角色图，2026-10-26）
    private static func withVoiceBadge(_ image: NSImage) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            let d: CGFloat = 11
            let badge = NSRect(x: rect.maxX - d, y: rect.minY, width: d, height: d)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 6.5, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// 按 **16:9** 居中裁剪 + 圆角（角上留透明 ✓）
    ///
    /// ⚠️ **画布必须开成「最终显示尺寸」（`side`），不能开成原图尺寸** ✗✓
    /// 这是踩过的坑：一开始画布用的是 `min(原宽, 原高)`（缩略图实际是 90~512pt ✓），
    /// 圆角写在那个坐标系里 → 图再被 `bounds` **缩到 20pt 显示**时，**圆角一起被缩掉了** ✓
    /// 7pt 的圆角缩到 90→20 只有约 1.6pt，肉眼根本看不出来（用户 2026-09-13 实测报的
    /// "提示词里的缩略图没改圆角" ✓）—— 方形生效了、圆角没有，就是这个原因 ✓
    /// 开成 `side × side` 之后，圆角与显示尺寸同一空间 ✓ 缩放在 draw **内部**完成 ✓
    private static func squareRounded(_ image: NSImage) -> NSImage {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return image }
        // 先把源图按 **16:9** 居中裁（跟方形那版的"按短边裁"是一个道理 ✓ 只是目标比例不同）：
        // 比 16:9 更宽的 → 裁两侧；更高的（竖图）→ 裁上下 ✓ 都不会压扁变形 ✓
        let target = width / height
        let crop: NSRect
        if w / h > target {
            let cw = h * target
            crop = NSRect(x: (w - cw) / 2, y: 0, width: cw, height: h)
        } else {
            let ch = w / target
            crop = NSRect(x: 0, y: (h - ch) / 2, width: w, height: ch)
        }
        let out = NSImage(size: NSSize(width: width, height: height))   // ← 最终显示尺寸 ✓
        out.lockFocus()
        // ⚠️ 圆角裁剪**必须在 draw 之前 addClip** —— 先画再裁就来不及了 ✗
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height),
                     xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: crop, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 预览弹窗打开状态：打开期间禁用分镜提示词框的悬停放大（NSTrackingArea 是窗口级分发，会穿透 SwiftUI 遮罩）
@MainActor
enum PreviewOverlayState {
    /// "当前有没有预览弹窗在显示" —— 由 `RootView.updatePreviewOverlayState()` 在三个
    /// `previewing*` 的 `onChange` 里写入（悬停抑制按它判断）。
    static var isShowing = false
}

/// 带鼠标跟踪的文本框：悬停在缩略图上时回调
@MainActor
/// 横向永远贴着左边的裁剪视图：文字框的宽度本来就等于可见宽度，没有横向可滚的东西；
/// 万一哪一刻文档比可见区域宽（排版重算、附件撑宽……），横向也不能被滑动 / 回弹带着走。
final class VerticalOnlyClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin.x = 0
        return rect
    }

    // 滚动 / 回弹 / 代码设定走的入口不止一个，都把横向钉住
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: newOrigin.y))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: newOrigin.y))
    }
}

final class PromptTextView: NSTextView {
    /// 悬停回调：`(命中的附件, 它在文本里的字符索引)`。
    /// ⚠️ **必须带上字符索引**：同一个 token 可能出现两次（@ 两次同一个素材），
    /// 只给附件的话下游只能按 token 反查位置 → 永远命中最后一个（用户实测 2026-09-13）。
    var onHover: ((SlotAttachment?, Int?) -> Void)?
    var onLayout: (() -> Void)?
    /// 获得 / 失去焦点（外框要显示聚焦描边：2026-10-07 用户「输入框点击缺少交互」）
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    /// 平时只读、点一下才编辑（2026-10-10 用户：编辑提示词弹窗里没点进去的时候鼠标就变成插入竖线，要和剧本页的原文 / 时长分割框一样）。
    /// 只读 = 不可编辑也不可选中：指针区域里没有插入竖线，鼠标滑过是箭头；悬停缩略图的预览不受影响。
    var clickToEdit = false

    /// 只读时不抢焦点（点它只是「开始编辑」）
    override var acceptsFirstResponder: Bool { clickToEdit ? isEditable : super.acceptsFirstResponder }

    func beginEditing() {
        setEditing(true)
        window?.makeFirstResponder(self)
    }

    /// 模式一变就让窗口重算指针区域——改 `isEditable` / `isSelectable` 不会让 AppKit 自己重算（同 `ScriptTextEditor.applyMode`）；
    /// 竖线区域是包着它的裁剪视图登记的，所以裁剪视图和滚动视图也要一起重算
    private func setEditing(_ editing: Bool) {
        let changed = isEditable != editing || isSelectable != editing
        isEditable = editing
        isSelectable = editing
        guard changed, let window else { return }
        window.invalidateCursorRects(for: self)
        if let scroll = enclosingScrollView {
            window.invalidateCursorRects(for: scroll)
            window.invalidateCursorRects(for: scroll.contentView)
        }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, clickToEdit { setEditing(false) }
        if ok { onFocusChange?(false) }
        return ok
    }

    private var trackingArea: NSTrackingArea?
    /// 上一次悬停命中的**字符索引**（不是 token —— 同 token 出现两次时 token 比不出区别，
    /// 鼠标在两份之间移动会被误判为"没换目标"，浮窗不更新）
    private var lastHoveredCharIndex: Int?

    override func layout() {
        super.layout()
        onLayout?()
    }

    /// 每次改字之后**强制整块重画**（2026-10-09 用户：「在句号后敲回车，下一行『描述：』就隐藏了，再敲一下回车才显示；
    /// 删掉一个回车又隐藏」——文字其实在，只是没画出来，滑动一下触发整块重画就好）。
    /// 这个现象在测试进程里复现不了（要真正的活动窗口），所以这里不赌系统给的脏区对不对：
    /// 改完字立刻把整个文本框标脏，再在下一轮主循环排好版、重画一次兜底（滑动触发的就是这种整块重画）。
    /// 弹窗里的提示词最多几万字，整块重画的代价可以忽略；卡片里的只读展示不会走到这里（没有用户编辑）。
    override func didChangeText() {
        super.didChangeText()
        redrawEverything()
        // 诊断：只在「段落数变了」（敲回车 / 删回车）时记一笔，别每个字都写日志
        let paragraphs = string.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
        guard paragraphs != lastLoggedParagraphs else { return }
        lastLoggedParagraphs = paragraphs
        AppLog.write("promptEditor", "改字后 段落数=\(paragraphs) frame=\(Int(frame.width))x\(Int(frame.height)) "
            + "已排版高度=\(Int(layoutManager?.usedRect(for: textContainer ?? NSTextContainer()).height ?? -1)) 可见=\(Int(visibleRect.height)) "
            + "key=\(window?.isKeyWindow == true) 滚动条样式=\(enclosingScrollView?.scrollerStyle.rawValue ?? -1)")
    }

    private var lastLoggedParagraphs = -1
    /// 强制整块重画的次数（测试用：每次用户改字都要加一）
    private(set) var forcedRedrawCount = 0

    private func redrawEverything() {
        forcedRedrawCount += 1
        setNeedsDisplay(bounds)
        enclosingScrollView?.contentView.needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if let layoutManager = self.layoutManager, let container = self.textContainer { layoutManager.ensureLayout(for: container) }
            self.setNeedsDisplay(self.bounds)
            self.enclosingScrollView?.contentView.needsDisplay = true
            self.displayIfNeeded()
        }
    }

    /// 点击时强制成为第一响应者（HStack 布局下 SwiftUI 不会自动设焦点，导致打不上字）
    override func mouseDown(with event: NSEvent) {
        // 只读的（点一下才编辑）：先进入编辑，再把这一下点击交给文本框——光标落在点的位置、双击选词、拖选都正常
        if clickToEdit, !isEditable { beginEditing() }
        super.mouseDown(with: event)
        if let window {
            window.makeFirstResponder(self)
        }
    }

    /// 粘贴统一按纯文本插入：用当前打字属性（白色 14pt），避免带入粘贴板的黑色/外来字体
    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        insertText(string, replacementRange: selectedRange())
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // 预览弹窗打开时忽略悬停（并清掉可能残留的放大浮窗）
        if PreviewOverlayState.isShowing {
            if lastHoveredCharIndex != nil {
                lastHoveredCharIndex = nil
                onHover?(nil, nil)
            }
            return
        }
        // 被别的弹窗盖着就不弹（2026-10-28 用户录屏：段落详情上叠开生图弹窗，鼠标在弹窗上移动，
        // 弹出了后面分镜提示词里「主持人」的放大图）——跟踪区是窗口级的，盖在上面的 SwiftUI 弹窗挡不住
        guard isTopmost(atWindowPoint: event.locationInWindow) else {
            if lastHoveredCharIndex != nil { clearHover() }
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let hit = attachment(at: point)
        // ⚠️ 比的是**字符索引**，不是 token：同 token 出现两次时，鼠标在两份之间移动也算
        // "换了目标"，浮窗才会跟着挪（这是比 token 老写法多修出来的那条）
        if hit?.charIndex != lastHoveredCharIndex {
            lastHoveredCharIndex = hit?.charIndex
            onHover?(hit?.attachment, hit?.charIndex)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    /// 强制收起悬停放大浮窗。
    ///
    /// **⚠️ 外部必须调这个，不能只 `HoverPreviewPanel.shared.hide()`**：
    /// 面板什么时候收，全靠这里把 `lastHoveredCharIndex` 清掉并回调一次 nil。
    /// 只 hide 面板而不清 token，下次鼠标移到**同一张图**上时 token 没变 →
    /// `mouseMoved` 里那个 `!=` 判断不成立 → 永远不再回调 → 浮窗再也出不来。
    ///
    /// 为什么需要外部主动调：`mouseExited` 只在鼠标**离开文本框**时触发，
    /// 而鼠标移进 `@` 素材列表（那是个**独立窗口**）时，本视图的 tracking area 是
    /// `.activeInKeyWindow` —— 它会**失活，但不触发 mouseExited**。
    /// 于是浮窗没人收，一直挂在屏幕上（用户实测："@素材选中之后，预览弹窗会一直在"）。
    func clearHover() {
        lastHoveredCharIndex = nil
        onHover?(nil, nil)
    }

    /// 窗口里这一点最上层的是不是自己（或自己里面的子视图）
    func isTopmost(atWindowPoint point: NSPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        let local = content.superview?.convert(point, from: nil) ?? point
        guard let hit = content.hitTest(local) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    /// 把「鼠标当前压着的那张图」记为已悬停，但**不弹**放大浮窗。
    ///
    /// 专治插入素材后的这个时序（2026-09-12 用户实测）：
    /// `@` 列表锚在插入位置旁边 → 点一行 → 列表关闭 → **鼠标正好停在刚插入的那张缩略图上**
    /// → 手一抖 `mouseMoved` 命中、token 从 nil 变成「图N」→ 被判成"新悬停" → 浮窗弹出来糊住正文，
    /// 而且之后鼠标不动就再没有事件去收它，于是一直挂着。
    ///
    /// 预先把它标记掉，浮窗就只会在鼠标**移到别的图**、或**移开再移回**时才弹 ——
    /// 也就是用户要的"只有专门把鼠标放上去才弹"。
    func markCurrentHoverWithoutShowing() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        lastHoveredCharIndex = attachment(at: point)?.charIndex
        onHover?(nil, nil)     // 确保浮窗此刻是收起的
    }

    /// 命中测试：`point` 处**真的有**一张缩略图才返回它。
    ///
    /// ⚠️ **光靠 `characterIndex(for:)` 不够，必须再校验点在不在附件的实际矩形里。**
    /// `characterIndex(for:)` 返回的是**离该点最近的字符** —— 鼠标在正文右侧的空白、
    /// 甚至在整段文字**下方**，它照样返回某个字符的索引。不校验矩形的话，
    /// **整个文本框都成了"悬停有效区"**，直接导致（用户 2026-09-12 实测）：
    ///   · 鼠标离图很远也会弹放大浮窗；
    ///   · 移到空白处时"最近字符"**仍是那张图** → token 没变 → 不触发收起 → **浮窗关不掉**；
    ///   · 只有移出整个文本框，`mouseExited` 才兜底收掉（"得移到提示词窗口外才关"）。
    ///
    /// **返回值带上命中位置的字符索引**：索引给下游算浮窗位置用 —— 按 token 反查会拿到
    /// "最后一个同 token 的位置"（@ 两次同一个素材时，浮窗就全跑到后添加的那份上，用户实测 2026-09-13）。
    private func attachment(at point: NSPoint) -> (attachment: SlotAttachment, charIndex: Int)? {
        guard let layoutManager = layoutManager, let textContainer = textContainer, let storage = textStorage else {
            return nil
        }
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index >= 0, index < storage.length else { return nil }
        // 两个候选：该字符本身、以及它前一个字符（缩略图边界上鼠标常落在紧邻的一侧）
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let att = storage.attribute(.attachment, at: candidate, effectiveRange: nil) as? SlotAttachment else {
                continue
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: candidate, length: 1),
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            // 外扩 2pt 容差：正好停在图片边缘时也算命中，但远不到"整个文本框都能触发"
            if rect.insetBy(dx: -2, dy: -2).contains(point) { return (att, candidate) }
        }
        return nil
    }
}

/// 提示词编辑框里文字的统一外观 + 「保证每个字都带着它」的补齐（2026-10-09）。
///
/// **根因（用户：「改提示词时有时文字不显示，滑一下才正常」）**：内嵌缩略图的附件字符自己没有字体和颜色
///（`NSAttributedString(attachment:)` 只带一个 `.attachment`）。光标停在缩略图后面时，NSTextView 把「光标前一个字符」的属性当作打字属性，
/// 于是新打的字**没有颜色**（画成默认的黑色）、字体也成了 12 号——暗色主题下黑字压在深色底上，看着就是「提示词没显示」。
/// 真实复现过：缩略图后打「，回头说话」，截图里是一行黑色小字。
/// 所以不能只在创建时给 `typingAttributes`，必须让**每个字符（含附件字符）自己就带着字体和颜色**：
/// 附件字符创建时就带上（`attachmentString`）+ 文本存储每次改动后补齐缺的（`normalizeAttributes`，输入 / 粘贴 / 撤销 / 程序替换都过这一道）。
enum PromptText {
    static var font: NSFont { NSFont.systemFont(ofSize: 14) }
    static var baseAttributes: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.textColor] }

    /// 缩略图附件（带着字体和颜色，光标停在它后面打字才对）
    static func attachmentString(_ attachment: SlotAttachment) -> NSAttributedString {
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(baseAttributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// 给 `range` 里缺字体 / 缺颜色的字符补上（已经有的不动）
    static func normalizeAttributes(in storage: NSTextStorage, range: NSRange) {
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard bounded.length > 0 else { return }
        var fixes: [(NSRange, [NSAttributedString.Key: Any])] = []
        storage.enumerateAttributes(in: bounded, options: []) { attrs, sub, _ in
            var missing: [NSAttributedString.Key: Any] = [:]
            if attrs[.font] == nil { missing[.font] = font }
            if attrs[.foregroundColor] == nil { missing[.foregroundColor] = NSColor.textColor }
            if !missing.isEmpty { fixes.append((sub, missing)) }
        }
        for (sub, missing) in fixes { storage.addAttributes(missing, range: sub) }
    }
}

/// 支持「@ 弹素材选择、插入缩略图、悬停放大」的提示词编辑器
struct PromptEditor: NSViewRepresentable {
    @Binding var text: String
    var slots: [SlotItem] = []
    /// 是否可编辑：false 为只读展示（只读态内容不变 → 高度稳定 → SwiftUI 缓存 → 滚动不卡）
    var isEditable: Bool = true
    /// 滚动模式：包 NSScrollView（固定高度 + 内部滚动）。给弹窗等独立浮层用；卡片列表场景保持 false（高度交给 SwiftUI）
    var scrollable: Bool = false
    /// 平时只读（箭头指针），点一下才进入编辑——弹窗里的提示词框用，和剧本页原文 / 时长分割框一样
    var clickToEdit: Bool = false
    /// 焦点变化（外框据此画聚焦描边）
    var onFocusChange: ((Bool) -> Void)? = nil
    /// 内容高度变化回调：(测量宽度, 高度)——宽度变化时高度缓存需要失效重算
    var onContentHeightChange: ((CGFloat, CGFloat) -> Void)? = nil
    var onTextChange: ((String) -> Void)? = nil
    /// 用户直接删掉了某张内嵌缩略图时回调，参数是被删掉的那个 token（如 `"图3"`）。
    /// 2026-10-16 起分镜 / 生图的编辑器都不再用它删素材（用户定：提示词里删素材，素材区的不删）
    var onTokenRemoved: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// 从 representable 的根视图里取出 NSTextView（滚动模式根是 NSScrollView）
    static func textView(from nsView: NSView) -> NSTextView? {
        if let tv = nsView as? NSTextView { return tv }
        if let sv = nsView as? NSScrollView { return sv.documentView as? NSTextView }
        return nil
    }

    func makeNSView(context: Context) -> NSView {
        // ⚠️ 必须一开始就用 **TextKit 1**（2026-10-09 用户：「在编辑提示词弹窗里改提示词，有时文字不显示，滑动一下就正常了」）。
        // `PromptTextView()` 默认是 TextKit 2；而下面这个文件里好几处会去碰 `layoutManager`（鼠标悬停缩略图时的 `characterIndex(for:)`、
        // 输入 `@` 时定位素材列表、卡片里量高度的 `ensureLayout`）——**碰一下，文本框就在屏幕上中途降级成 TextKit 1**，
        // 降级后重排了版面、却没有通知视图重画，于是文字消失，直到滚动才触发重画。一开始就是 TextKit 1 就没有这次中途切换。
        // 和剧本页 `ScriptTextEditor`、设置里的 `PromptTextEditor` 同一个做法。
        let textView = PromptTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.clickToEdit = clickToEdit && isEditable
        // 点一下才编辑的：一开始就是只读（不可编辑、不可选中）
        textView.isEditable = textView.clickToEdit ? false : isEditable
        textView.isSelectable = !textView.clickToEdit
        textView.drawsBackground = false
        textView.textColor = .textColor
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
        textView.textContainerInset = NSSize(width: 5, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // 文本存储每次改动后补齐缺的字体 / 颜色（见 `PromptText`）。**先挂代理、再塞文本**，初始内容也走这一道
        textView.textStorage?.delegate = context.coordinator
        textView.textStorage?.setAttributedString(attributedText(from: text))
        context.coordinator.resetTokenBaseline(text)

        context.coordinator.textView = textView

        let coordinator = context.coordinator
        textView.onHover = { [weak coordinator] attachment, charIndex in
            coordinator?.handleHover(attachment, charIndex: charIndex)
        }
        textView.onFocusChange = onFocusChange

        // 不用「非连续排版」：改字后只重排局部、其余用旧的排版结果，是 TextKit 1 里「某一行没画出来」的常见来源
        textView.layoutManager?.allowsNonContiguousLayout = false
        if scrollable {
            // 滚动模式：固定高度 + 内部滚动（弹窗等独立浮层用）。
            // 搭法对齐剧本页的 `ScriptTextEditor`（用得最久、没出过这个问题）：叠加式滚动条 + 自动隐藏 + 关掉横向回弹——
            // 原来是系统默认：接鼠标时每个框带一条常驻的滚动条（占 15pt 宽），文字宽度随设备切换而变。
            let scrollView = NSScrollView()
            // 只许上下滚（2026-10-10 用户：「编辑提示词弹窗在修改之后，提示词开始左右滑动」——妙控鼠标能左右划，文字不该跟着横移）
            scrollView.contentView = VerticalOnlyClipView()
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScrollElasticity = .none
            scrollView.usesPredominantAxisScrolling = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.drawsBackground = false
            textView.isVerticallyResizable = true
            textView.autoresizingMask = [.width]
            scrollView.documentView = textView
            return scrollView
        }

        // 自适应模式：高度交给 SwiftUI（sizeThatFits 汇报）：不能自己撑高，否则会冲出 frame 盖住下方卡片
        textView.isVerticallyResizable = false
        textView.autoresizingMask = []
        textView.onLayout = { [weak coordinator] in
            coordinator?.reportContentHeight()
        }
        return textView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = Self.textView(from: nsView) else { return }
        context.coordinator.parent = self
        context.coordinator.slots = slots
        if let pv = textView as? PromptTextView { pv.onFocusChange = onFocusChange }
        // 输入法拼音组合期间（hasMarkedText）跳过文本替换：否则会打断输入法组合、吞字、光标重置到末尾
        if context.coordinator.plainText() != text, !textView.hasMarkedText() {
            textView.textStorage?.setAttributedString(attributedText(from: text))
            // 外部换了正文（自动匹配 / 清空素材 / 删素材后重编号回灌）：文本存储是重建的 → 缩略图短路集合作废；
            // token 比对基线也要重置，否则下一次用户改字时，外部这次变化会被当成「用户删了缩略图」而连环回调（文档里一直这么写，但这里漏了）
            context.coordinator.invalidateAttachmentTokens()
            context.coordinator.resetTokenBaseline(text)
        }
        context.coordinator.loadRemoteThumbnails()
    }

    /// 由 SwiftUI 布局引擎按内容汇报高度（驱动卡片自适应；内容不变 → 高度稳定 → SwiftUI 缓存）。
    /// 滚动模式返回 nil：高度由外层 frame 决定，内部自己滚。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !scrollable, let textView = Self.textView(from: nsView) else { return nil }
        let width = proposal.width ?? 300
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: max(width - 12, 1), height: .greatestFiniteMagnitude)
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return nil }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let inset = textView.textContainerInset
        return CGSize(width: width, height: max(used.height + inset.height * 2, 28))
    }

    /// 从纯文本重建富文本：把「图N/视频N/音频N」等槽位 token 还原成缩略图附件
    private func attributedText(from plain: String) -> NSAttributedString {
        let font: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.textColor
        ]
        let full = NSMutableAttributedString(string: plain, attributes: font)
        // 按 token 长度降序，避免「图1」误匹配「图10」
        for slot in slots.sorted(by: { $0.token.count > $1.token.count }) {
            // 只查内存（2026-10-15 用户：有素材的段打开 / 翻页慢）：原来用 `image(at:)`，内存没有就当场读盘 + 解码，
            // 一段挂十张图就在主线程连着解十次。没在内存里的先留纯文字「图N」，`loadRemoteThumbnails` 在后台读好再换上
            guard let url = slot.thumbnailURL, let image = LocalImageCache.memoryThumb(atPath: url.path) else { continue }
            let pattern = NSRegularExpression.escapedPattern(for: slot.token) + "(?![0-9])"   // 「图1」不吃「图10」的前半截
            while let range = full.string.range(of: pattern, options: .regularExpression) {
                // 每处各用一个新的附件实例（同一个 NSTextAttachment 实例塞进多处，悬停定位 / 删除时会互相串）
                full.replaceCharacters(in: NSRange(range, in: full.string),
                                       with: PromptText.attachmentString(SlotAttachment(token: slot.token, image: image, voiceBadge: slot.hasVoice)))
            }
        }
        return full
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: PromptEditor
        weak var textView: NSTextView?
        /// 悬停能力只在 `PromptTextView` 上（基类 `NSTextView` 没有），
        /// 而 `textView` 声明成基类是因为滚动模式的根视图是 `NSScrollView`、要从里面取。
        private var hoverTextView: PromptTextView? { textView as? PromptTextView }
        var slots: [SlotItem] = []
        private var popover: NSPopover?

        /// 远程缩略图缓存（按 URL 字符串）+ 进行中的下载任务，避免重复请求
        private var remoteThumbnails: [String: NSImage] = [:]
        private var remoteLoadTasks: [String: Task<Void, Never>] = [:]
        /// **已经确认"文本存储里有对应附件"的 token**（O(1) 短路用）。
        ///
        /// ⚠️ 它是**纯性能短路，不是事实来源** —— 事实来源仍是直接遍历文本存储查
        ///（`enumerateAttributes`，那一段是权威的 ✓）。加它的原因：
        /// 那段遍历**每次 `updateNSView` 都会跑** ✗（`loadRemoteThumbnails` →
        /// `insertLocalThumbnail` / `insertRemoteThumbnail`，而内存命中时是立即回调 ✓），
        /// 于是滚动时**每张卡片的提示词框、每一帧都在遍历整段富文本** ✗✓
        /// —— 用户 2026-09-12 反馈的"滑动手感发涩、一顿一顿"就是它 ✓
        ///
        /// ⚠️ **任何重建文本存储的地方都必须调 `invalidateAttachmentTokens()`** ✗ ——
        /// 否则附件已经被重建掉了、这里还记着"有"，缩略图就不补了 ✓
        private var attachedTokens: Set<String> = []

        /// 文本存储被重建 / 用户改过字之后，作废上面的短路集合（下次更新会重新校验一遍 ✓）
        func invalidateAttachmentTokens() { attachedTokens.removeAll() }
        /// 上一轮的 token 集合（用于"用户是不是刚删掉了一张缩略图"的比对 ✓）
        /// 见 `textDidChange` / `resetTokenBaseline` 的说明
        private var lastTokens: Set<String> = []
        /// 上次高度测量的输入（宽度/文本长度），相同则跳过测量，避免 layout 回调频繁触发长文本测量导致滚动卡顿
        private var lastMeasuredWidth: CGFloat = 0
        private var lastMeasuredLength: Int = -1
        /// 触发 @ 弹窗时的位置（插入素材时用，避免 popover 弹出后光标漂移）
        private var triggerRange: NSRange?

        init(_ parent: PromptEditor) {
            self.parent = parent
        }

        /// 异步补齐提示词里的「图N」缩略图（含远程与本地）：图到了再替换纯文本 token
        func loadRemoteThumbnails() {
            for slot in slots {
                // ★ **O(1) 短路：已经有附件的槽位直接跳过** ——
                // 不加这一行的话，下面每条分支最终都会走到 `insertXxxThumbnail` ✗，
                // 而那里为了判重会 `enumerateAttributes` **遍历整段富文本** ✗✓
                //（内存命中时 `loadThumbnail` 是**立即回调**的 ✓ 所以每帧都会走一遍 ✓）
                // 这就是"滑动发涩、一顿一顿"的来源（用户 2026-09-12 反馈）✓
                guard !attachedTokens.contains(slot.token) else { continue }
                if let url = slot.remoteThumbnailURL, slot.thumbnailURL == nil {
                    // 远程缩略图：异步下载
                    let key = url.absoluteString
                    guard remoteThumbnails[key] == nil, remoteLoadTasks[key] == nil else { continue }
                    remoteLoadTasks[key] = Task { [weak self] in
                        let data = await Self.downloadData(from: url)
                        guard let self else { return }
                        self.remoteLoadTasks[key] = nil
                        // ⚠️ 用 `decoded(from:)`（**当场解码**），不要用 `NSImage(data:)` ——
                        // 后者懒解码，会把没解码的图存进缓存 ✗，直到第一次绘制才在主线程解 ✗
                        //（同 `LocalImageCache`，见 `NSImage.decoded(from:)` 的注释）
                        if let data, let image = NSImage.decoded(from: data) {
                            self.remoteThumbnails[key] = image
                            self.insertRemoteThumbnail(token: slot.token, url: url, image: image)
                        }
                    }
                } else if let url = slot.thumbnailURL {
                    // 本地缩略图：本轮若未命中缓存，异步降采样补齐（避免主线程解码大图）
                    // ⚠️ 这里只能查**内存** ✗ 不能调 `LocalImageCache.image(at:)` ——
                    // 那是**同步读盘 + 解码** ✗，而这段代码在 `updateNSView` 里、**每次更新都跑** ✓
                    // 磁盘那一路交给 `loadThumbnail` 在后台读 ✓（它内部已经改成后台读盘 ✓）
                    guard LocalImageCache.memoryThumb(atPath: url.path) == nil else { continue }
                    LocalImageCache.loadThumbnail(at: url) { [weak self] image in
                        guard let self, let image else { return }
                        self.insertLocalThumbnail(token: slot.token, url: url, image: image)
                    }
                }
            }
        }

        nonisolated private static func downloadData(from url: URL) async -> Data? {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return data
        }

        /// 把 token 的纯文本替换为缩略图附件；当前槽位配置变化则跳过
        private func insertRemoteThumbnail(token: String, url: URL, image: NSImage) {
            guard !attachedTokens.contains(token) else { return }   // ★ O(1) 短路（见 attachedTokens 的说明）
            guard slots.first(where: { $0.token == token })?.remoteThumbnailURL == url else { return }
            replacePlainTokens(token, with: image)
        }

        /// 本地缩略图异步补齐后替换「图N」纯文本（校验 slot 的本地 thumbnailURL 未变）
        private func insertLocalThumbnail(token: String, url: URL, image: NSImage) {
            guard !attachedTokens.contains(token) else { return }   // ★ O(1) 短路（见 attachedTokens 的说明）
            guard slots.first(where: { $0.token == token })?.thumbnailURL == url else { return }
            replacePlainTokens(token, with: image)
        }

        /// 把文本里**所有**还是纯文本的 `token` 换成缩略图附件。
        /// 原来只换第一处（`range(of:)` 一次）：同一个素材在提示词里 @ 了两次时，异步补图只补第一处，第二处一直是纯文字「图1」
        ///（同步命中缓存那条路是都换的，两条路不一致）。已经是附件的位置在 `string` 里是 U+FFFC，不会再被匹配到。
        /// `(?![0-9])`：「图1」不能吃掉「图10」「图12」的前半截。
        private func replacePlainTokens(_ token: String, with image: NSImage) {
            guard let storage = textView?.textStorage else { return }
            let pattern = NSRegularExpression.escapedPattern(for: token) + "(?![0-9])"
            while let range = storage.string.range(of: pattern, options: .regularExpression) {
                let badge = slots.first { $0.token == token }?.hasVoice ?? false
                storage.replaceCharacters(in: NSRange(range, in: storage.string),
                                          with: PromptText.attachmentString(SlotAttachment(token: token, image: image, voiceBadge: badge)))
            }
            attachedTokens.insert(token)
        }

        /// 缓存的远程缩略图（插入 @ 素材时直接可用）
        func cachedRemoteThumbnail(for url: URL) -> NSImage? {
            remoteThumbnails[url.absoluteString]
        }

        /// 文本存储每次改字时，给新进来的字符补上缺的字体 / 颜色（输入、粘贴、撤销、程序替换都会走到这里）。
        /// ⚠️ 必须在 **`willProcessEditing`**（系统补默认值**之前**）做，不能放 `didProcessEditing`：
        /// 系统处理改动时会先给没有字体的字符补一个默认的 12 号字体——放到 did 里再看，「缺字体」已经判断不出来了，字号就还是 12（测试抓到过）。
        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            PromptText.normalizeAttributes(in: textStorage, range: editedRange)
        }

        /// 当前记着的 token 集合（测试用：外部换正文后它该等于新正文里的 token）
        var trackedTokens: Set<String> { lastTokens }

        func textDidChange(_ notification: Notification) {
            guard textView != nil else { return }
            // 用户改过文本（可能删掉了某个槽位）→ 短路记录作废，下一轮重新校验 ✓
            invalidateAttachmentTokens()
            let newText = plainText()
            parent.text = newText
            parent.onTextChange?(newText)
            // ⚠️ **比对 token 集合**：少掉的那个 = 用户**直接在提示词里删掉的缩略图** ✓
            // 要立刻通知出去做「删引用 + 重编号」✗ —— 不然正文里会留下**序号空洞** ✓
            // （例：删了图4，剩下 1、2、3、5、6 ✓）空洞的后果：自动匹配每点一次
            //  就补一次洞、素材区顺序来回跳 ✓ 用户 2026-09-13 报的"点一次变一次"就是这个 ✓
            let now = Self.tokens(in: newText)
            let removed = lastTokens.subtracting(now)
            lastTokens = now
            for token in removed { parent.onTokenRemoved?(token) }
            detectTrigger()
            reportContentHeight()
        }

        /// 从正文里抓出所有 token（`图1` / `视频2` / `音频3` …）✓
        /// 用正则而不是 `contains` ✗ —— 否则「图1」会在「图10」里被误判成存在 ✓
        private static func tokens(in text: String) -> Set<String> {
            var out: Set<String> = []
            let ns = text as NSString
            for prefix in ["图", "视频", "音频"] {
                guard let re = try? NSRegularExpression(pattern: "\(prefix)(\\d+)") else { continue }
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    out.insert(ns.substring(with: m.range))
                }
            }
            return out
        }

        /// **外部**换掉了正文（弹窗回写 / 重编号后回灌 ✓）→ 重置比对基线 ✓
        /// 不重置的话，外部那次变化会被当成"用户删了一堆缩略图"而连环回调 ✗
        func resetTokenBaseline(_ text: String) { lastTokens = Self.tokens(in: text) }

        func reportContentHeight(retry: Int = 0) {
            guard let tv = textView else { return }
            let inset = tv.textContainerInset
            let contentWidth = tv.bounds.width - inset.width * 2
            // 宽度未布局好（0/负）时延迟重试，否则按错误宽度算出的换行高度会偏小
            guard contentWidth > 1 else {
                if retry < 6 {
                    DispatchQueue.main.async { [weak self] in
                        self?.reportContentHeight(retry: retry + 1)
                    }
                }
                return
            }
            // 宽度与内容长度都没变时跳过测量（layout 回调会频繁触发，避免滚动时重复测量长文本）
            let length = tv.textStorage?.length ?? 0
            // 宽度用容差比较：滚动重建时 bounds 可能有亚像素抖动，<0.5 视为不变，避免触发尺寸循环重排
            let widthChanged = abs(contentWidth - lastMeasuredWidth) > 0.5
            guard widthChanged || length != lastMeasuredLength else { return }
            lastMeasuredWidth = contentWidth
            lastMeasuredLength = length
            // 用富文本直接测量高度（纯测量、不强制排版，避免 ensureLayout 在滚动时引发全量重排/布局循环）
            let attributed = tv.textStorage ?? NSAttributedString()
            let rect = attributed.boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let height = rect.height + inset.height * 2
            parent.onContentHeightChange?(contentWidth, height)
        }

        /// 把富文本还原成平台要的纯文本（缩略图附件 → 图1 等 token）
        func plainText() -> String {
            guard let storage = textView?.textStorage else { return "" }
            let result = NSMutableString()
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, range, _ in
                if let attachment = attrs[.attachment] as? SlotAttachment {
                    result.append(attachment.token)
                } else {
                    result.append((storage.string as NSString).substring(with: range))
                }
            }
            return result as String
        }

        private func detectTrigger() {
            guard let tv = textView else { return }
            let cursor = tv.selectedRange().location
            let length = (tv.string as NSString).length
            guard cursor > 0, cursor <= length else {
                closePopover()
                return
            }
            let range = NSRange(location: cursor - 1, length: 1)
            let char = (tv.string as NSString).substring(with: range)
            if char == "@" {
                showPopover(at: range)
            } else {
                closePopover()
            }
        }

        private func showPopover(at range: NSRange) {
            guard let tv = textView else { return }
            // 收起可能残留的放大浮窗：鼠标往列表移动时往往会先扫过编辑器里的缩略图，
            // 那一下会把浮窗弹出来，而它进列表后**收不到 mouseExited**（列表是独立窗口）
            hoverTextView?.clearHover()
            triggerRange = range
            let content = SlotPickerView(slots: slots) { [weak self] item in
                self?.insert(item: item)
            }
            if popover == nil {
                let p = NSPopover()
                p.behavior = .transient
                // popover 自带的"连底衬一起淡入"必须留着：它保证不会先冒出一个空框。
                // 显式写出来是因为**内容那层还有个弹性缩放**（`SlotPickerView` 里的 `.scaleEffect`），
                // 两者是叠加关系、缺一不可 —— 哪天有人为了"只看内容动画"把它关掉，就会露出空框。
                p.animates = true
                popover = p
            }
            popover?.contentViewController = NSHostingController(rootView: content)

            var rect = tv.bounds
            if let layoutManager = tv.layoutManager, let textContainer = tv.textContainer {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var r = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                r.origin.x += tv.textContainerOrigin.x
                r.origin.y += tv.textContainerOrigin.y
                rect = r
            }
            popover?.show(relativeTo: rect, of: tv, preferredEdge: .maxY)
        }

        private func insert(item: SlotItem) {
            guard let tv = textView else { return }
            // 用触发 @ 时记录的位置，避免 popover 弹出后光标漂移到末尾
            guard let range = triggerRange else { return }

            let font: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.textColor
            ]
            let attr = NSMutableAttributedString()
            if let url = item.thumbnailURL, let image = LocalImageCache.image(at: url) {
                attr.append(PromptText.attachmentString(SlotAttachment(token: item.token, image: image, voiceBadge: item.hasVoice)))
            } else if let remoteURL = item.remoteThumbnailURL,
                      let image = cachedRemoteThumbnail(for: remoteURL) {
                attr.append(PromptText.attachmentString(SlotAttachment(token: item.token, image: image, voiceBadge: item.hasVoice)))
            } else {
                attr.append(NSAttributedString(string: item.token, attributes: font))
            }
            // ⚠️ 2026-09-18 用户要求去掉 token 后面的「是」（原来拼成「图1是」）：
            // 现在插入的就是纯「图1」，和自动匹配保持一致。
            tv.textStorage?.replaceCharacters(in: range, with: attr)
            tv.didChangeText()
            parent.text = plainText()
            closePopover()
            // ⚠️ 必须在 closePopover() **之后**调：closePopover 里会 clearHover（token 置 nil），
            // 顺序反了就会被它清掉，等于没标记。这是用户报的"@选中后浮窗一直弹/一直在"的根治点。
            hoverTextView?.markCurrentHoverWithoutShowing()
            // 弹窗里可能有搜索框占着焦点，关掉后把焦点还给提示词框，否则后续按键丢失
            tv.window?.makeFirstResponder(tv)
        }

        func handleHover(_ attachment: SlotAttachment?, charIndex: Int?) {
            // ⚠️ **滚动中一律不弹**（用户 2026-09-12 定的语义：弹窗只在静止时才有意义 ✗）
            //
            // 为什么必须拦在这里：触控板滚动时**鼠标光标一直悬在卡片上** ✓，悬停判断照常触发 ✓，
            // 于是弹窗会被排在"滚动过程中的某几帧"弹出来 ✗ —— 它是独立 NSPanel + spring 动画 ✗✓，
            // 正是"滑动发涩、一顿一顿"的来源 ✓
            //
            // `hide()` 即使当前没显示，也会**取消那次"待触发的弹出"** ✓（见其实现第一行）
            // → 滚动一发生，延迟触发就作废 ✓；停下后重新悬停 → 重新计时 ✓
            // 正好就是"停够 0.2~0.3 秒才弹" ✓
            if ScrollActivity.shared.isScrolling {
                HoverPreviewPanel.shared.hide()
                return
            }
            // 与卡片只读区共用同一个浮层组件：样式、位置（图片正上方）完全一致
            if let attachment, let charIndex,
               let screenRect = attachmentScreenRect(forCharIndex: charIndex), screenRect != .zero {
                HoverPreviewPanel.shared.show(image: attachment.previewImage, above: screenRect)
            } else {
                HoverPreviewPanel.shared.hide()
            }
        }

        /// 用**命中的字符索引**算屏幕矩形。
        ///
        /// ⚠️ **不要改回"按 token 反查"的老写法**（原来是遍历 textStorage 找
        /// `a.token == attachment.token`，而且**不 break**）：同一个 token 出现两次时
        ///（@ 两次同一个素材），它永远命中**最后一段** → 浮窗总弹在"后添加的那个素材"那里
        ///（用户实测 2026-09-13）。
        private func attachmentScreenRect(forCharIndex index: Int) -> NSRect? {
            guard let tv = textView, let storage = tv.textStorage else { return nil }
            guard index >= 0, index < storage.length else { return nil }
            return tv.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        }

        private func closePopover() {
            popover?.close()
            popover = nil
            triggerRange = nil
            // 关列表时一并收起放大浮窗：鼠标全程没动过，不主动收就会一直挂着
            hoverTextView?.clearHover()
        }
    }
}

/// 素材选择弹窗（顶部搜索框 + 缩略图 + 名称，不带槽位名）
private struct SlotPickerView: View {
    let slots: [SlotItem]
    let onSelect: (SlotItem) -> Void

    @State private var query = ""

    /// 按文件名过滤（不区分大小写，包含即命中）
    private var filtered: [SlotItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return slots }
        return slots.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 搜索框占弹窗顶部（替代原「插入素材」标题；样式与素材库搜索栏一致）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索素材", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.1)))
            .padding(.horizontal, 8)
            // 原 `.vertical, 7`：分割线拿走后面向内容那侧收掉
            .padding(.top, 7)
            .padding(.bottom, 3)

            if slots.isEmpty {
                Text("暂无素材，请先在素材区添加")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
            } else if filtered.isEmpty {
                Text("无匹配素材")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                HStack(spacing: 8) {
                                    ThumbnailView(url: item.thumbnailURL, remoteURL: item.remoteThumbnailURL, icon: iconName(for: item.token))
                                    Text(item.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 240)
    }

    private func iconName(for token: String) -> String {
        if token.hasPrefix("视频") { return "film" }
        if token.hasPrefix("音频") { return "waveform" }
        return "photo"
    }
}

/// 缩略图（本地图片 / 远程直链异步加载）或类型图标
private struct ThumbnailView: View {
    let url: URL?
    let remoteURL: URL?
    let icon: String

    var body: some View {
        if let url, let nsImage = LocalImageCache.image(at: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let remoteURL {
            AsyncImage(url: remoteURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    iconView
                }
            }
        } else {
            iconView
        }
    }

    private var iconView: some View {
        Image(systemName: icon)
            .frame(width: 32, height: 32)
            .foregroundStyle(.secondary)
    }
}
