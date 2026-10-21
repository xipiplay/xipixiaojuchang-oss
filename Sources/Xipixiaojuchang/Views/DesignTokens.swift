import SwiftUI
import AppKit

/// 设计语言「暗房」（2026-10-07 用户定方向，我来设计）的底层数值。
///
/// 一句话：像一间剪辑暗房——偏暖的近黑 / 纸白做底，**只有一个主色（琥珀）**，像摄影棚的指示灯：
/// 它只表示「这里有动作」（选中、进行中、唯一的主按钮）；成功用鼠尾草绿、失败用砖红，其余都是安静的灰。
/// 层次靠明暗三档 + 1px 低透明细线，不靠光效和阴影（只有浮在最上层的弹窗 / 底栏才有阴影）。
///
/// - 颜色：`Theme.accent` 这类**自适应色**会跟着窗口的深 / 浅外观走，不用传 `colorScheme`；
///   页面底 / 卡片 / 浮层等「面」仍然走 `SolidTheme`（它们要按玻璃开关、主题取值）。
/// - 圆角：只用 6 / 8 / 10 / 14 / 18 五档（见 `Theme.Radius`）。
/// - 间距：按 4 的倍数（`Theme.Space`）。
/// - 字号：11 / 12 / 13 / 15 / 18 / 22（`Theme.FontSize`）；字重只用常规 / 中等 / 半粗。
enum Theme {
    // MARK: 颜色

    /// 当前配色主题的深 / 浅一份（`ColorThemeStore` 是 @Observable：在视图 body 里读这些颜色会自动订阅，换主题后跟着换）
    @MainActor private static var theme: ColorTheme { ColorThemeStore.shared.current }

    /// 按深 / 浅外观取色（跟窗口 appearance 走，不用传 colorScheme）
    @MainActor private static func color(_ pick: @escaping @Sendable (ColorTheme.Mode) -> UInt32,
                                         alpha: (dark: CGFloat, light: CGFloat) = (1, 1)) -> Color {
        let t = theme
        return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: pick(t.mode(dark: isDark)), alpha: isDark ? alpha.dark : alpha.light)
        }))
    }

    /// 指定主题取色（根视图的 `.tint` 用：它在 Scene 里，拿不到 @Observable 的订阅，就直接按持久化的主题值算）
    nonisolated static func controlTint(of theme: ColorTheme) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: theme.mode(dark: isDark).controlTint)
        }))
    }

    /// 主色（默认暗房 = 琥珀）。深色底上亮一点，浅色底上深一点，保证对比度
    @MainActor static var accent: Color { color { $0.accent } }
    /// 压在主色上的字 / 图标
    @MainActor static var onAccent: Color { color { $0.onAccent } }
    /// 系统控件（实心按钮、分段选择、开关）用的着色：比主色深一档。
    /// 系统控件压在它上面的字是白色，主色那种亮色配白字对比度不够，所以单独给一个深一点的。
    @MainActor static var controlTint: Color { color { $0.controlTint } }
    /// 成功：鼠尾草绿（所有主题共用）
    static let success = adaptive(dark: 0x6FBF8E, light: 0x3E8F62)
    /// 失败 / 危险：砖红（所有主题共用）
    static let danger = adaptive(dark: 0xE5645A, light: 0xC94A40)
    /// 提醒 / 排队 / 暂停：比主色偏橙一点的赭色（所有主题共用）
    static let warning = adaptive(dark: 0xDD8450, light: 0xB8622B)
    /// 待命 / 等待对方：黄（所有主题共用）。左栏 AI 图标的小圆点：外部智能体接力已开、还在等智能体
    static let standby = adaptive(dark: 0xF2C14E, light: 0xD9A21B)

    /// 文字三档：主 / 次 / 弱。大部分地方仍用系统的 `.primary / .secondary`，这里给自绘处用
    @MainActor static var textPrimary: Color { color { $0.textPrimary } }
    @MainActor static var textSecondary: Color { color { $0.textSecondary } }
    @MainActor static var textTertiary: Color { color { $0.textTertiary } }

    /// 细线：1px、低透明度，分区和描边都用它
    @MainActor static var hairline: Color { color({ $0.lineBase }, alpha: (0.09, 0.11)) }
    /// 描边按钮的线：比分区细线再明显一点
    @MainActor static var buttonStroke: Color { color({ $0.lineBase }, alpha: (0.20, 0.24)) }

    // MARK: 圆角

    enum Radius {
        /// 小标签、徽章
        static let chip: CGFloat = 6
        /// 按钮、输入框、下拉
        static let control: CGFloat = 8
        /// 导航高亮、紧凑卡
        static let tile: CGFloat = 10
        /// 卡片、面板
        static let card: CGFloat = 14
        /// 弹窗、抽屉
        static let sheet: CGFloat = 18
    }

    // MARK: 间距（4 的倍数）

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: 字号

    enum FontSize {
        static let caption: CGFloat = 11
        static let footnote: CGFloat = 12
        static let body: CGFloat = 13
        static let emphasis: CGFloat = 15
        static let heading: CGFloat = 18
        static let title: CGFloat = 22
    }

    // MARK: 实现

    private static func adaptive(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }))
    }
}

extension NSColor {
    /// 0xRRGGBB（sRGB）
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
