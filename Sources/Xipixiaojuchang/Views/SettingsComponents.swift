import SwiftUI

// MARK: - 设置弹窗的共用组件（2026-10-07 重新设计）
//
// 结构：左侧导航 → 右侧一页 = 页头 + 若干「分组」；一个分组 = 小标题 + 一张卡片 + 脚注，
// 卡片里是一行一行的「左：名称（+ 说明）· 右：控件」，行与行之间一条细线。
// 说明文字用常规字重的次要色，不再加粗；所有输入框、按钮用同一套尺寸。
//
// ⚠️ 不用 `Form`：它首次实例化要花约 1.9s 布局（见 `SettingsView` 里的说明），这里全是 `VStack`。
// ⚠️ 卡片底用 `Color.primary` 的低透明度，玻璃 / 纯色两种界面材质下都成立，不依赖具体底色。

enum SettingsStyle {
    static let cardRadius: CGFloat = Theme.Radius.card
    static let rowHorizontal: CGFloat = 14
    static let fieldRadius: CGFloat = Theme.Radius.control
}

/// 页头：页名（+ 右侧操作）。不再写「一句话说明」（2026-10-10 用户：这类说明文字占地方，没必要）
struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }
}

extension SettingsPageHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// 一个分组：小标题 + 卡片。行与行之间自己放 `SettingsDivider()`。
struct SettingsGroup<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    init(title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            SettingsCard { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 卡片底（也给「渠道」这种自带折叠的块用）
struct SettingsCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    init(highlighted: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius).fill(Color.primary.opacity(0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsStyle.cardRadius)
                    .strokeBorder(highlighted ? Theme.accent.opacity(0.45) : Theme.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, SettingsStyle.rowHorizontal)
    }
}

/// 一行：左边名称，右边控件
struct SettingsRow<Control: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, SettingsStyle.rowHorizontal)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

/// 输入框外观：圆角浅底 + 细边；`width` 不给就撑满所在位置
private struct SettingsFieldStyle: ViewModifier {
    var width: CGFloat?
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).fill(Color.primary.opacity(focused ? 0.09 : 0.06)))
            .inputChrome(focused: focused, radius: SettingsStyle.fieldRadius)
    }
}

extension View {
    func settingsField(width: CGFloat? = 300) -> some View { modifier(SettingsFieldStyle(width: width)) }
}

/// 一行里的小说明 / 状态文字（常规字重的次要色）
struct SettingsNote: View {
    let text: String
    var tone: Tone = .secondary

    enum Tone { case secondary, good, bad }

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11.5))
            .foregroundStyle(tone == .good ? Theme.success : (tone == .bad ? Theme.danger : Color.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}


/// 配色主题的选择卡：一张迷你界面预览（页面底 + 左栏 + 两张卡片 + 一枚主色）+ 名字 + 一句说明。选中的描一圈主色。
struct ColorThemeCard: View {
    let theme: ColorTheme
    let selected: Bool
    /// 预览画深色版还是浅色版（跟着设置页自己当前的明暗）
    let dark: Bool
    let action: () -> Void
    @State private var hovered = false

    private func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        let m = theme.mode(dark: dark)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                // 迷你界面
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.control).fill(c(m.background))
                    HStack(spacing: 5) {
                        // 左栏
                        VStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 2).fill(i == 0 ? c(m.accent) : c(m.textTertiary).opacity(0.5))
                                    .frame(width: 8, height: 8)
                            }
                        }
                        .padding(.top, 7)
                        .frame(width: 14)
                        // 两张卡片
                        VStack(spacing: 5) {
                            HStack(spacing: 5) {
                                miniCard(m, highlighted: true)
                                miniCard(m, highlighted: false)
                            }
                            // 一条按钮
                            HStack(spacing: 4) {
                                Capsule().fill(c(m.accent)).frame(width: 26, height: 7)
                                Capsule().strokeBorder(c(m.overlayStroke)).frame(width: 18, height: 7)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.trailing, 6)
                    }
                    .padding(.leading, 5)
                }
                .frame(height: 66)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(c(m.cardStroke)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(theme.displayName).font(.system(size: 12.5, weight: .medium))
                    Text(theme.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Color.primary.opacity(hovered && !selected ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile)
                .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        }
        .buttonStyle(QuietButtonStyle(hover: .none))
        .onHover { hovered = $0 }
        .accessibilityLabel("配色：\(theme.displayName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func miniCard(_ m: ColorTheme.Mode, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c(m.inset)).frame(height: 14)
            Capsule().fill(c(m.textSecondary).opacity(0.7)).frame(width: 22, height: 3)
            Capsule().fill(c(m.textTertiary).opacity(0.6)).frame(width: 14, height: 3)
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 4).fill(c(m.card)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(highlighted ? c(m.accent) : c(m.cardStroke), lineWidth: highlighted ? 1.2 : 0.8))
    }
}


// MARK: - 主题 / 界面材质的预览选择卡（2026-10-10 用户：别用分段按钮，做成配色那样的方形预览）

/// 迷你界面预览的画法：同一张小图，换底色 / 换质感
enum MiniInterfaceStyle {
    /// 一套明暗的实色界面
    case solid(ColorTheme.Mode)
    /// 左浅右深各一半（「跟随系统」）
    case split(light: ColorTheme.Mode, dark: ColorTheme.Mode)
    /// 玻璃：彩色壁纸上盖半透明的面板
    case glass(ColorTheme.Mode)
}

/// 主题 / 界面材质卡里的迷你界面：固定 84×54（页面底 + 左栏 + 两张卡片 + 一枚主色），尺寸写死，不随内容 / 系统控件变
struct MiniInterfacePreview: View {
    static let size = CGSize(width: 84, height: 54)
    let style: MiniInterfaceStyle

    private func c(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    var body: some View {
        Group {
            switch style {
            case .solid(let m):
                interface(m, glass: false)
            case .split(let light, let dark):
                ZStack {
                    interface(light, glass: false)
                    interface(dark, glass: false)
                        .mask(HStack(spacing: 0) { Color.clear; Color.black }.frame(width: Self.size.width, height: Self.size.height))
                }
            case .glass(let m):
                interface(m, glass: true)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
    }

    private func interface(_ m: ColorTheme.Mode, glass: Bool) -> some View {
        let panel = glass ? c(m.card).opacity(0.5) : c(m.card)
        let stroke: Color = glass ? Color.white.opacity(0.45) : c(m.cardStroke)
        return ZStack(alignment: .topLeading) {
            if glass {
                // 彩色「壁纸」：让半透明的面板看得出是透的
                LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.95), Color(red: 0.80, green: 0.42, blue: 0.85), Color(red: 0.95, green: 0.62, blue: 0.40)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                c(m.background).opacity(0.28)
            } else {
                c(m.background)
            }
            // 左栏
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(i == 0 ? c(m.accent) : c(m.textTertiary).opacity(0.55)).frame(width: 5, height: 5)
                }
            }
            .padding(.top, 6).padding(.leading, 5)
            // 两张卡片
            HStack(spacing: 4) {
                card(m, panel: panel, stroke: stroke, highlighted: true)
                card(m, panel: panel, stroke: stroke, highlighted: false)
            }
            .padding(.leading, 15).padding(.top, 6)
            // 一条按钮
            HStack(spacing: 3) {
                Capsule().fill(c(m.accent)).frame(width: 18, height: 4)
                Capsule().strokeBorder(glass ? Color.white.opacity(0.7) : c(m.overlayStroke), lineWidth: 0.8).frame(width: 12, height: 4)
            }
            .padding(.leading, 31).padding(.top, 38)
        }
    }

    private func card(_ m: ColorTheme.Mode, panel: Color, stroke: Color, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 1.5).fill(c(m.inset).opacity(0.9)).frame(height: 9)
            Capsule().fill(c(m.textSecondary).opacity(0.7)).frame(width: 14, height: 2)
            Capsule().fill(c(m.textTertiary).opacity(0.6)).frame(width: 9, height: 2)
        }
        .padding(3)
        .frame(width: 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(highlighted ? c(m.accent) : stroke, lineWidth: highlighted ? 1 : 0.6))
    }
}

/// 外观选择卡（主题 / 界面材质）：一张固定尺寸的迷你界面预览 + 名字，选中描一圈主色。和 `ColorThemeCard` 同一套外框。
struct AppearanceChoiceCard: View {
    static let width: CGFloat = 96
    let title: String
    /// 读屏标签：「主题：深色」
    let accessibilityText: String
    let selected: Bool
    let style: MiniInterfaceStyle
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MiniInterfacePreview(style: style)
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .medium)).lineLimit(1)
            }
            .padding(6)
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.tile).fill(Color.primary.opacity(hovered && !selected ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tile).strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
        }
        .buttonStyle(QuietButtonStyle(hover: .none))
        .onHover { hovered = $0 }
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
