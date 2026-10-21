import SwiftUI
import AppKit

/// 把外面那个 SwiftUI `ScrollView` 锁成**只能上下滑**（2026-10-10 用户：设置弹窗右边的内容能左右滑、点配色时按钮往左跳一下）。
///
/// 查出来的根因（日志实锤）：内容并没有变宽——滚动区的内容宽度 = 可见宽度 = 671，里面没有任何视图比它宽；
/// 横向位置却在 −66 ~ +59 之间来回摆、再慢慢回弹：是 SwiftUI 的滚动容器（`HostingScrollView`）在竖向滚动区上也做了**横向橡皮筋**
/// （妙控鼠标 / 触控板横着一划就动；`horizontalScrollElasticity` 读出来是 `.none` 也拦不住它）。
/// 所以不是排版问题，直接在 AppKit 层禁掉横向移动：滚动区的横向位置只要不是 0 就立刻拉回 0（同一轮事件里，屏幕上看不到偏移）。
///
/// 用法：挂在 `ScrollView` 的**内容**上：`ScrollView { content.background(VerticalScrollLock()) }`
struct VerticalScrollLock: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.attachIfNeeded() }

    @MainActor
    final class Probe: NSView {
        private weak var scroll: NSScrollView?
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
            // 刚上树时 enclosingScrollView 可能还没接好：下一轮再试一次
            if scroll == nil { DispatchQueue.main.async { [weak self] in self?.attachIfNeeded() } }
        }

        func attachIfNeeded() {
            guard scroll == nil, let sv = enclosingScrollView else { return }
            scroll = sv
            sv.horizontalScrollElasticity = .none
            sv.hasHorizontalScroller = false
            let clip = sv.contentView
            clip.postsBoundsChangedNotifications = true
            snapBack()
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapBack() }
            }
        }

        /// 正在拉回：`setBoundsOrigin` 在**改位置的过程中**就同步发「位置变了」的通知，那一刻读到的还是旧值，
        /// 没有这个标志就会 `snapBack → setBoundsOrigin → 通知 → snapBack …` 无限递归、栈溢出闪退（2026-10-10 装上第一版就闪退了）
        private var isSnapping = false

        /// 横向位置拉回 0（只改 x，纵向照常）
        func snapBack() {
            guard !isSnapping, let sv = scroll else { return }
            let clip = sv.contentView
            guard abs(clip.bounds.origin.x) > 0.01 else { return }
            isSnapping = true
            defer { isSnapping = false }
            clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y))
            sv.reflectScrolledClipView(clip)
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
