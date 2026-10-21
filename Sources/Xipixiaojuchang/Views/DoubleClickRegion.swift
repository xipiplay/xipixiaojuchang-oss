import AppKit
import CoreGraphics

/// 缩略图 / 卡片的「双击」监听（NSEvent 本地监听，整窗的鼠标事件都会经过它）该不该认这一下的判据（2026-10-07）。
///
/// 原来只看「点在滚动内容的全高范围里 + 命中缓存里某个格子的 frame」。可是：
/// - 滚动内容比看得见的区域高得多，滚下去之后，它的范围一直向上延伸到顶栏、页头，向下延伸到底栏下面；
/// - 滚出视野的格子的 frame 还留在缓存里；
/// 于是在顶栏、页头、悬浮底栏上双击，也会被当成双击了某个看不见的格子——弹大图 / 开始播放（用户 2026-10-07 实测）。
///
/// 现在要求：点在**滚动区看得见的那一块**里，并且**不在悬浮底栏上**。
enum DoubleClickRegion {
    /// 窗口坐标（左下原点）→ SwiftUI `.global`（左上原点）
    static func global(_ point: NSPoint, in window: NSWindow) -> CGPoint {
        CGPoint(x: point.x, y: (window.contentView?.bounds.height ?? window.frame.height) - point.y)
    }

    /// `viewport`：滚动区看得见的那一块；`toolbar`：悬浮底栏的胶囊（都是 `.global` 坐标）
    static func isOnVisibleGrid(viewport: CGRect, toolbar: CGRect, point: CGPoint) -> Bool {
        viewport.contains(point) && !toolbar.contains(point)
    }

    static func isOnVisibleGrid(viewport: CGRect, toolbar: CGRect, window: NSWindow, point: NSPoint) -> Bool {
        isOnVisibleGrid(viewport: viewport, toolbar: toolbar, point: global(point, in: window))
    }
}
