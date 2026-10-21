import AppKit

/// 让窗口重算鼠标指针区域（2026-10-10）。
///
/// AppKit 的指针区域（cursor rect，输入框的插入竖线就是靠它）在输入框的状态变了之后**不会自己重算**——
/// 和剧本框 `ScriptTextEditor.applyMode` 里写的是同一个坑：改了「可编辑 / 可选中 / 启用」，旧的竖线区域还留着，
/// 弹窗盖上来时鼠标滑过弹窗就变成插入竖线（用户：编辑提示词弹窗里只读的地方鼠标变成了插入）。
/// 页头的搜索框平时已经是一行字（`QuietSearchField`），这里是兜底：弹窗开 / 关之后再让窗口把指针区域整个重算一遍，防止别处还留着旧的。
@MainActor
enum PointerRegions {
    /// 调用了几次（测试用）
    private(set) static var refreshCount = 0

    static func refresh() {
        refreshCount += 1
        // 状态变化在这一轮界面更新里才落到 AppKit：晚一拍重算；弹窗入场有一小段位移动画，动画结束后再算一次
        DispatchQueue.main.async { resetAll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { resetAll() }
    }

    private static func resetAll() {
        for window in NSApp.windows { window.resetCursorRects() }
    }
}
