import SwiftUI

/// 输入框的「交互反馈」（2026-10-07 用户：点输入框缺少交互）：
/// 悬停 → 描边亮一档；获得焦点 → 一圈主色描边；平时是细线。所有自绘的输入框共用，样式不再各写各的。
struct InputChrome: ViewModifier {
    let focused: Bool
    var radius: CGFloat = Theme.Radius.control
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(focused ? Theme.accent : (hovered ? Theme.buttonStroke : Theme.hairline),
                                  lineWidth: focused ? 1.5 : 1)
                    .allowsHitTesting(false)
            )
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: focused)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

extension View {
    /// 给输入框的**外框**（背景那一层）加上悬停 / 焦点反馈；`focused` 来自输入框的 `@FocusState`
    func inputChrome(focused: Bool, radius: CGFloat = Theme.Radius.control) -> some View {
        modifier(InputChrome(focused: focused, radius: radius))
    }
}
