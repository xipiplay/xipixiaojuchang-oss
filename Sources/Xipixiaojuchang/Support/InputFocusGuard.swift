import AppKit

/// 点输入框以外的任何地方，输入框就失去焦点、闪的竖条消失（2026-10-07 用户：点了输入框之后竖条一直在，点哪里都不消失）。
///
/// 原因：macOS 上 SwiftUI 的 TextField / TextEditor（和自绘的 NSTextView）一旦成了 first responder，
/// 点到一块「不会抢焦点」的地方（空白、卡片、按钮）它并不会放手，光标就一直闪。
/// 做法：窗口级的鼠标按下监听——正在编辑文字（first responder 是 NSTextView）而这一下点在编辑区域**外面**，就让窗口放掉 first responder。
/// 点到别的输入框 / 同一个输入框里面不受影响（还是各自拿焦点 / 继续编辑）。
@MainActor
enum InputFocusGuard {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handle(event)
            return event      // 事件照常往下走：点按钮就是点按钮，只是先让输入框放手
        }
    }

    private static func handle(_ event: NSEvent) {
        guard let window = event.window, !(window is NSPanel) else { return }
        process(window: window, locationInWindow: event.locationInWindow)
    }

    /// 返回 true = 放掉了焦点。拆出来是为了能在测试里直接喂坐标
    @discardableResult
    static func process(window: NSWindow, locationInWindow: NSPoint) -> Bool {
        guard let content = window.contentView,
              let editor = window.firstResponder as? NSTextView else { return false }
        // 正在编辑的「输入区域」：输入框的 field editor 挂在 NSTextField 里面；TextEditor / PromptEditor 的 NSTextView 自己就是
        let owner: NSView = (editor.delegate as? NSView) ?? editor
        if isInside(content.hitTest(locationInWindow), owner: owner) { return false }
        return window.makeFirstResponder(nil)
    }

    /// 点中的视图是不是在编辑区域里面（含编辑区域本身）
    static func isInside(_ hit: NSView?, owner: NSView) -> Bool {
        guard let hit else { return false }
        return hit === owner || hit.isDescendant(of: owner)
    }
}
