import SwiftUI
import AppKit
import Observation

/// 配色主题（2026-10-07 用户要求：整套色系做成可以在设置里选的主题）。
///
/// 一个主题 = 一套**面**（页面底 / 卡片 / 内容区 / 浮层 / 悬停 / 描边）+ 一个**主色**，深色、浅色各一份。
/// 成功（鼠尾草绿）/ 失败（砖红）/ 提醒（赭）这三个状态色所有主题共用，免得换主题后「失败」和「选中」撞色。
///
/// - 和「深色 / 浅色 / 跟随系统」（`AppTheme`）互相独立：两个都能选，组合起来每个主题都有深浅两版。
/// - 颜色全部走 `Theme` / `SolidTheme`，它们读 `ColorThemeStore.shared.current`；
///   Store 是 `@Observable`，视图 body 里读到颜色就自动跟着换，不用每个视图各自订阅。
enum ColorTheme: String, CaseIterable, Identifiable, Sendable {
    /// 暗房：暖近黑 / 纸白 + 琥珀（默认）
    case darkroom
    /// 经典：软件原来的中性灰 + 蓝
    case classic
    /// 靛夜：冷蓝灰 + 靛紫
    case indigo
    /// 青瓷：青灰 + 青绿
    case celadon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .darkroom: "暗房"
        case .classic: "经典"
        case .indigo: "靛夜"
        case .celadon: "青瓷"
        }
    }

    var detail: String {
        switch self {
        case .darkroom: "暖黑 · 琥珀"
        case .classic: "中性灰 · 蓝"
        case .indigo: "蓝灰 · 靛紫"
        case .celadon: "青灰 · 青绿"
        }
    }

    /// 一个明暗模式下用到的全部颜色（0xRRGGBB）
    struct Mode: Sendable {
        var background, card, inset, overlay, hover, cardStroke, overlayStroke: UInt32
        /// 细线 / 描边按钮的线用的底色（透明度在 `Theme` 里按深浅另加）
        var lineBase: UInt32
        var textPrimary, textSecondary, textTertiary: UInt32
        /// 主色（文字 / 图标 / 选中描边 / 进度）
        var accent: UInt32
        /// 压在主色上的字
        var onAccent: UInt32
        /// 系统控件（实心按钮、分段、开关）用的着色：比主色深一档，保证白字对比度
        var controlTint: UInt32
    }

    struct Palette: Sendable { var dark: Mode; var light: Mode }

    var palette: Palette {
        switch self {
        case .darkroom:
            Palette(
                dark: Mode(background: 0x131211, card: 0x242220, inset: 0x1C1B19, overlay: 0x2E2C29, hover: 0x373431,
                           cardStroke: 0x2F2D2A, overlayStroke: 0x3E3B37, lineBase: 0xFFF4E4,
                           textPrimary: 0xF2EFEA, textSecondary: 0xA8A29A, textTertiary: 0x6F6A63,
                           accent: 0xE9A23B, onAccent: 0x1A1206, controlTint: 0xCC7A14),
                light: Mode(background: 0xF3F0EA, card: 0xFCFBF8, inset: 0xF0ECE5, overlay: 0xFFFFFF, hover: 0xEAE5DC,
                            cardStroke: 0xE6E1D8, overlayStroke: 0xD9D3C8, lineBase: 0x281E14,
                            textPrimary: 0x1C1A17, textSecondary: 0x6B655D, textTertiary: 0x9A938A,
                            accent: 0xB0620B, onAccent: 0xFFFFFF, controlTint: 0xB0620B))
        case .classic:
            Palette(
                dark: Mode(background: 0x141414, card: 0x262626, inset: 0x1C1C1C, overlay: 0x303030, hover: 0x383838,
                           cardStroke: 0x2E2E2E, overlayStroke: 0x3D3D3D, lineBase: 0xFFFFFF,
                           textPrimary: 0xF2F2F2, textSecondary: 0xA0A0A0, textTertiary: 0x6A6A6A,
                           accent: 0x4C9AFF, onAccent: 0x08162E, controlTint: 0x2F7DF0),
                light: Mode(background: 0xF1F1F3, card: 0xFFFFFF, inset: 0xF2F2F4, overlay: 0xFFFFFF, hover: 0xECECEE,
                            cardStroke: 0xE5E5E7, overlayStroke: 0xD9D9DC, lineBase: 0x000000,
                            textPrimary: 0x1A1A1A, textSecondary: 0x6A6A6A, textTertiary: 0x9A9A9A,
                            accent: 0x1F6FE0, onAccent: 0xFFFFFF, controlTint: 0x1F6FE0))
        case .indigo:
            Palette(
                dark: Mode(background: 0x101219, card: 0x1F2230, inset: 0x171A26, overlay: 0x2A2E40, hover: 0x333850,
                           cardStroke: 0x2B2F42, overlayStroke: 0x3A405A, lineBase: 0xD8DCFF,
                           textPrimary: 0xEEF0FA, textSecondary: 0xA3A8C2, textTertiary: 0x6B7090,
                           accent: 0x9A9BFF, onAccent: 0x14143A, controlTint: 0x6B6DE0),
                light: Mode(background: 0xEFF0F7, card: 0xFAFAFF, inset: 0xEBECF5, overlay: 0xFFFFFF, hover: 0xE3E5F2,
                            cardStroke: 0xDDDFEE, overlayStroke: 0xCDD0E4, lineBase: 0x1A1E3C,
                            textPrimary: 0x191B2E, textSecondary: 0x5E6283, textTertiary: 0x9498B5,
                            accent: 0x5557D6, onAccent: 0xFFFFFF, controlTint: 0x4B4DC8))
        case .celadon:
            Palette(
                dark: Mode(background: 0x0F1413, card: 0x1D2523, inset: 0x161C1B, overlay: 0x28322F, hover: 0x313D3A,
                           cardStroke: 0x27312E, overlayStroke: 0x36443F, lineBase: 0xDFFFF6,
                           textPrimary: 0xEEF5F2, textSecondary: 0x9DB0AA, textTertiary: 0x65766F,
                           accent: 0x45C2B0, onAccent: 0x06201B, controlTint: 0x1E9A8A),
                light: Mode(background: 0xEDF2F0, card: 0xF9FCFB, inset: 0xE9EFED, overlay: 0xFFFFFF, hover: 0xE0E8E5,
                            cardStroke: 0xD9E2DF, overlayStroke: 0xC9D5D1, lineBase: 0x10241E,
                            textPrimary: 0x14201C, textSecondary: 0x566963, textTertiary: 0x8A9C96,
                            accent: 0x17806F, onAccent: 0xFFFFFF, controlTint: 0x17806F))
        }
    }

    func mode(dark: Bool) -> Mode { dark ? palette.dark : palette.light }
}

/// 当前配色主题（持久化在 UserDefaults 的 `colorTheme`）。
/// `@Observable`：视图 body 里读到 `Theme` / `SolidTheme` 的颜色时会自动订阅，换主题后相关视图自己重算。
@MainActor @Observable
final class ColorThemeStore {
    static let shared = ColorThemeStore()
    nonisolated static let defaultsKey = "colorTheme"

    var current: ColorTheme {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: Self.defaultsKey)
        }
    }

    private init() {
        current = ColorTheme(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .darkroom
    }

    /// 非主线程（烤图、AppKit 回调）里也要读：直接读持久化的值
    nonisolated static var persisted: ColorTheme {
        ColorTheme(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .darkroom
    }
}

/// 环境里的配色主题：根视图把当前主题放进来，换主题时用到它的视图（含 `ShapeStyle.resolve`）会重新计算
private struct ColorThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: ColorTheme = .darkroom
}

extension EnvironmentValues {
    var colorTheme: ColorTheme {
        get { self[ColorThemeEnvironmentKey.self] }
        set { self[ColorThemeEnvironmentKey.self] = newValue }
    }
}
