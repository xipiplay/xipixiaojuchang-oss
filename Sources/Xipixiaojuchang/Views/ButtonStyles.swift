import SwiftUI

/// 「暗房」的两种按钮（2026-10-07）：**实心主按钮**（琥珀底 + 深色字，一个界面里最多一个）和**描边按钮**（1px 细线，其余都用它）。
///
/// - 悬停：底色提亮几个百分点；**按下：没有任何变化**（2026-10-08 用户："点了之后点击区域会闪一下"——按下瞬间变暗 / 缩小，松手又弹回，
///   一次点击只有几十毫秒，看着就是闪一下）。没有光晕、没有阴影。
/// - 尺寸跟着 `.controlSize`（mini / small / regular / large）走，和系统按钮的用法一样。
/// - 危险操作（`Button(role: .destructive)`）自动换成砖红。
/// - 不用系统的 `.borderedProminent` / `.bordered`：系统实心按钮上的字是白的，压在亮琥珀上对比度不够。
enum ButtonMetrics {
    struct Size { let height: CGFloat; let font: CGFloat; let padding: CGFloat; let radius: CGFloat }

    static func size(for control: ControlSize) -> Size {
        switch control {
        case .mini: Size(height: 20, font: Theme.FontSize.caption, padding: 8, radius: Theme.Radius.chip)
        case .small: Size(height: 24, font: Theme.FontSize.footnote, padding: 10, radius: Theme.Radius.control)
        case .large, .extraLarge: Size(height: 34, font: Theme.FontSize.emphasis, padding: 18, radius: Theme.Radius.tile)
        default: Size(height: 28, font: Theme.FontSize.body, padding: 14, radius: Theme.Radius.control)
        }
    }
}

/// 实心主按钮。`tint`：想要别的底色（比如确认删除用砖红）时传；不传 = 主色琥珀（危险角色自动砖红）。
struct AccentButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, tint: tint)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let m = ButtonMetrics.size(for: controlSize)
            let destructive = configuration.role == .destructive
            let fill = tint ?? (destructive ? Theme.danger : Theme.accent)
            let onFill: Color = (tint != nil || destructive) ? .white : Theme.onAccent
            configuration.label
                .font(.system(size: m.font, weight: .medium))
                .foregroundStyle(onFill)
                .padding(.horizontal, m.padding)
                .frame(minHeight: m.height)
                .background(RoundedRectangle(cornerRadius: m.radius).fill(fill))
                .brightness(hovered && isEnabled ? 0.06 : 0)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: m.radius))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// 描边按钮：透明底 + 1px 细线，悬停时底色略微提亮。
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false

        var body: some View {
            let m = ButtonMetrics.size(for: controlSize)
            let destructive = configuration.role == .destructive
            configuration.label
                .font(.system(size: m.font, weight: .medium))
                .foregroundStyle(destructive ? Theme.danger : Color.primary)
                .padding(.horizontal, m.padding)
                .frame(minHeight: m.height)
                .background(RoundedRectangle(cornerRadius: m.radius).fill(Color.primary.opacity(hovered && isEnabled ? 0.07 : 0)))
                .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(Theme.buttonStroke))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: m.radius))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

// MARK: - 悬停反馈（2026-10-10 用户：看一下软件哪里还缺少悬停交互）

/// 可点的东西悬停时的反馈方式。统一一套：淡底 / 亮一点，**按下没有任何变化**（见上面按钮的说明）。
enum HoverFeedback: Equatable {
    /// 自己已经有悬停效果的（描边按钮、带放大的、带自绘高亮的），或者不该有的
    case none
    /// 垫一层淡底（行、文字按钮、图标按钮）。`radius` 要和按钮自己的形状一致：胶囊 / 圆形传 `.capsule`
    case fill(radius: CGFloat = 8)
    /// 整体亮一点：自己带底色的（主色按钮、彩色小标签）、细条
    case brighten

    /// 胶囊 / 圆形的圆角（比任何高度的一半都大，等于完全圆）
    static let capsule = HoverFeedback.fill(radius: 999)
}

private struct HoverFeedbackEnabledKey: EnvironmentKey { static let defaultValue = true }
private struct HoverFeedbackForcedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// 悬停反馈开不开。**右侧的任务 / 素材库 / 历史抽屉里是关的**：抽屉是液态玻璃，里面一有悬停动画，
    /// 旁边底部的胶囊就跟着闪（2026-10-08 用户定：抽屉里去掉悬停高亮）。
    var hoverFeedbackEnabled: Bool {
        get { self[HoverFeedbackEnabledKey.self] }
        set { self[HoverFeedbackEnabledKey.self] = newValue }
    }
    /// 只给测试 / 离屏渲染用：把「正在悬停」硬设成真（合成事件触发不了 SwiftUI 的 onHover）
    var hoverFeedbackForced: Bool {
        get { self[HoverFeedbackForcedKey.self] }
        set { self[HoverFeedbackForcedKey.self] = newValue }
    }
}

/// 给一块「点一下有反应、但不是 Button」的区域加悬停反馈（点一下编辑的文字、整块可点的卡）：悬停时盖一层淡底
private struct HoverHighlight: ViewModifier {
    let radius: CGFloat
    /// 这一块现在点得动才有反馈（比如还没有视频就别亮）
    let clickable: Bool
    @Environment(\.hoverFeedbackEnabled) private var enabled
    @Environment(\.hoverFeedbackForced) private var forced
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity((hovered || forced) && enabled && clickable ? 0.05 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

// 滑动中照常亮悬停（2026-10-15 用户：恢复；10-14 为滑动卡顿关过，查明真凶是视频进度重算和滑动换集，不是悬停）

extension View {
    /// 悬停时盖一层淡底。用在 `.onTapGesture` 的区域上；要放在 `.contentShape` 之后
    func hoverHighlight(radius: CGFloat = 8, clickable: Bool = true) -> some View { modifier(HoverHighlight(radius: radius, clickable: clickable)) }
}

/// 「安静」按钮：什么装饰都不加，**按下也没有任何变化**。全 App 原来用 `.buttonStyle(QuietButtonStyle())` / `.borderless` 的地方都换成它。
///
/// 为什么不用系统的 `.plain`：macOS 上系统的 plain / borderless 按钮**按下时会把内容压暗**，松手再弹回——
/// 一次点击只有几十毫秒，看着就是"点击区域闪一下"（2026-10-08 用户：全 App 的点击都有）。
/// 禁用态仍然变淡（系统样式原来也会），数值和上面两种按钮一致。
/// `dimsWhenDisabled: false`：禁用时不变淡——用在「禁用只是为了挡住点击」的大块内容上（主页大图：进 / 出项目时点击会被禁用，
/// 变淡会让封面上的黑色渐变闪一下，2026-10-10 用户发现）。
struct QuietButtonStyle: ButtonStyle {
    var dimsWhenDisabled = true
    /// 悬停反馈（默认垫淡底）。自己带悬停效果的传 `.none`，见 `HoverFeedback`
    var hover: HoverFeedback = .fill()

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, dimsWhenDisabled: dimsWhenDisabled, hover: hover)
    }

    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        let dimsWhenDisabled: Bool
        let hover: HoverFeedback
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.hoverFeedbackEnabled) private var hoverEnabled
        @Environment(\.hoverFeedbackForced) private var forced
        @State private var hovered = false

        private var active: Bool { (hovered || forced) && isEnabled && hoverEnabled }

        @ViewBuilder
        var body: some View {
            let base = configuration.label
                .opacity(isEnabled || !dimsWhenDisabled ? 1 : 0.4)
                .background {
                    if case .fill(let radius) = hover {
                        RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(active ? 0.06 : 0))
                    }
                }
            switch hover {
            case .none:
                base
            case .fill:
                base.onHover { hovered = $0 }.animation(.easeOut(duration: 0.12), value: hovered)
            case .brighten:
                // 只有要「亮一点」的才挂 brightness（它会让里面的图片走离屏渲染，别给所有按钮都挂）
                base.brightness(active ? 0.07 : 0).onHover { hovered = $0 }.animation(.easeOut(duration: 0.12), value: hovered)
            }
        }
    }
}
