import AppKit
import SwiftUI

/// 看大图的缩放 / 拖动（2026-10-28 用户要）：
/// - 触控板捏合、⌘+滑动缩放；`wheelZooms` 开着时（大图）所有上下滑动都缩放（以光标为中心）
/// - 放大后按住拖动；`wheelZooms` 关着时（嵌在页面里）也可以两指滑动拖
/// - 双击：适配窗口时放大到 2 倍（以点的位置为中心），放大了就还原
/// - 最小 = 适配窗口，最大 8 倍；换图回到适配窗口
///
/// 为什么自己画、不用 NSScrollView 的 magnification：放大 8 倍时整张文档视图按放大后的尺寸建图层，
/// 大图会占一大块内存；自己画只画看得见的那一块，缩放 / 平移也只是改两个数（`ZoomPanState`）。
struct ZoomPanState: Equatable {
    static let maxScale: CGFloat = 8
    static let doubleClickScale: CGFloat = 2

    var imageSize: CGSize
    var viewSize: CGSize
    /// 相对「适配窗口」的倍数，1...maxScale
    private(set) var scale: CGFloat = 1
    /// 图片中心相对视图中心的偏移（视图坐标）
    private(set) var offset: CGPoint = .zero

    init(imageSize: CGSize, viewSize: CGSize) {
        self.imageSize = imageSize
        self.viewSize = viewSize
    }

    var isZoomed: Bool { scale > 1.001 }

    /// 适配窗口时的图片尺寸
    var fitSize: CGSize {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let s = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return CGSize(width: imageSize.width * s, height: imageSize.height * s)
    }

    /// 图片画在视图里的位置
    var imageRect: CGRect {
        let fit = fitSize
        let size = CGSize(width: fit.width * scale, height: fit.height * scale)
        return CGRect(x: viewSize.width / 2 + offset.x - size.width / 2,
                      y: viewSize.height / 2 + offset.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 以 `point`（视图坐标）为中心缩放：点下面那块图不动
    mutating func zoom(by factor: CGFloat, at point: CGPoint) {
        guard factor > 0, factor.isFinite else { return }
        let newScale = min(max(scale * factor, 1), Self.maxScale)
        let f = newScale / scale
        let p = CGPoint(x: point.x - viewSize.width / 2, y: point.y - viewSize.height / 2)
        offset = CGPoint(x: p.x - (p.x - offset.x) * f, y: p.y - (p.y - offset.y) * f)
        scale = newScale
        clamp()
    }

    mutating func pan(dx: CGFloat, dy: CGFloat) {
        offset.x += dx
        offset.y += dy
        clamp()
    }

    /// 双击：没放大 → 放大到 2 倍；放大了 → 还原
    mutating func toggle(at point: CGPoint) {
        if isZoomed { reset() } else { zoom(by: Self.doubleClickScale, at: point) }
    }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    mutating func resize(to size: CGSize) {
        viewSize = size
        clamp()
    }

    /// 图比视图小的那一边居中；比视图大的那一边不许拖出空白
    private mutating func clamp() {
        let fit = fitSize
        let limitX = max(0, (fit.width * scale - viewSize.width) / 2)
        let limitY = max(0, (fit.height * scale - viewSize.height) / 2)
        offset.x = min(max(offset.x, -limitX), limitX)
        offset.y = min(max(offset.y, -limitY), limitY)
    }
}

/// 能缩放 / 拖动的大图（`AsyncFullImage` 加载好图之后交给它画）
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// 滑动 = 缩放（滚轮、妙控鼠标、触控板都算）。嵌在会滚动的页面里时关掉：没放大时滑动交还给页面滚动，⌘+滑动照样缩放
    var wheelZooms = true
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> ZoomableImageNSView {
        let view = ZoomableImageNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ZoomableImageNSView, context: Context) {
        view.wheelZooms = wheelZooms
        view.layer?.cornerRadius = cornerRadius
        if view.image !== image { view.image = image }
    }
}

final class ZoomableImageNSView: NSView {
    var wheelZooms = true
    var image: NSImage? {
        didSet {
            state = ZoomPanState(imageSize: image?.size ?? .zero, viewSize: bounds.size)
            stateChanged()
        }
    }
    private(set) var state = ZoomPanState(imageSize: .zero, viewSize: .zero)
    private var lastDrag: NSPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    // 放大后拖图，别把窗口拖走
    override var mouseDownCanMoveWindow: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        state.resize(to: newSize)
        stateChanged()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: state.imageRect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // MARK: 缩放

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    func zoom(by factor: CGFloat, at point: CGPoint) {
        state.zoom(by: factor, at: point)
        stateChanged()
    }

    /// 触控板两指轻点两下（系统的「智能缩放」）：同双击
    override func smartMagnify(with event: NSEvent) {
        state.toggle(at: convert(event.locationInWindow, from: nil))
        stateChanged()
    }

    override func scrollWheel(with event: NSEvent) {
        // 大图里**所有上下滑动都缩放**（2026-10-28 用户定）：妙控鼠标的滑动和触控板一样是精确滑动、分不开，
        // 原来当拖图用，妙控鼠标就缩放不了。拖图改成只靠按住拖
        if event.modifierFlags.contains(.command) || wheelZooms {
            let dy = event.scrollingDeltaY
            // 松手后的惯性不跟着缩，不然停不住
            guard dy != 0, event.momentumPhase.isEmpty else { return }
            // 鼠标一格约 1；精确滑动是像素量，压小一点
            zoom(by: Self.zoomFactor(deltaY: dy, precise: event.hasPreciseScrollingDeltas),
                 at: convert(event.locationInWindow, from: nil))
        } else if state.isZoomed {
            // 两指滑动跟着手指走（y 向上的坐标系里，往下滑 = 图往下 = offset.y 变小）
            state.pan(dx: event.scrollingDeltaX, dy: -event.scrollingDeltaY)
            stateChanged()
        } else {
            super.scrollWheel(with: event)   // 没放大：交还给外面的页面滚动
        }
    }

    static func zoomFactor(deltaY: CGFloat, precise: Bool) -> CGFloat {
        pow(precise ? 1.01 : 1.15, deltaY)
    }

    // MARK: 拖动 / 双击

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            state.toggle(at: convert(event.locationInWindow, from: nil))
            stateChanged()
            lastDrag = nil
            return
        }
        lastDrag = state.isZoomed ? event.locationInWindow : nil
        if lastDrag != nil { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastDrag else { return }
        let now = event.locationInWindow
        state.pan(dx: now.x - last.x, dy: now.y - last.y)
        lastDrag = now
        stateChanged()
    }

    override func mouseUp(with event: NSEvent) {
        guard lastDrag != nil else { return }
        lastDrag = nil
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        if state.isZoomed { addCursorRect(bounds, cursor: lastDrag == nil ? .openHand : .closedHand) }
    }

    private func stateChanged() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
}
