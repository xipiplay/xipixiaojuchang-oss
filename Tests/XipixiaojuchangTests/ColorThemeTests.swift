import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 配色主题（2026-10-07）：四套色系 × 深 / 浅，颜色要读得清、换主题要真的换到各处、选择要持久化。
@MainActor
final class ColorThemeTests: XCTestCase {
    private var savedTheme: ColorTheme!

    override func setUp() {
        super.setUp()
        savedTheme = ColorThemeStore.shared.current
    }
    override func tearDown() {
        ColorThemeStore.shared.current = savedTheme
        super.tearDown()
    }

    // MARK: 对比度（WCAG）

    private func luminance(_ hex: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin((hex >> 16) & 0xFF) + 0.7152 * lin((hex >> 8) & 0xFF) + 0.0722 * lin(hex & 0xFF)
    }
    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testEveryThemeIsReadableInBothModes() {
        for theme in ColorTheme.allCases {
            for dark in [true, false] {
                let m = theme.mode(dark: dark)
                let name = "\(theme.displayName)/\(dark ? "深" : "浅")"
                XCTAssertGreaterThanOrEqual(contrast(m.onAccent, m.accent), 4.5, "\(name)：主色上的字要读得清")
                XCTAssertGreaterThanOrEqual(contrast(0xFFFFFF, m.controlTint), 3.0, "\(name)：系统控件的白字压在着色上要读得清")
                XCTAssertGreaterThanOrEqual(contrast(m.textPrimary, m.card), 7.0, "\(name)：正文在卡片上")
                XCTAssertGreaterThanOrEqual(contrast(m.textSecondary, m.card), 4.5, "\(name)：次要文字在卡片上")
                XCTAssertGreaterThanOrEqual(contrast(m.textTertiary, m.card), 2.5, "\(name)：弱文字在卡片上（只用于占位 / 提示）")
                XCTAssertGreaterThanOrEqual(contrast(m.accent, m.card), 3.0, "\(name)：主色（文字 / 图标 / 选中框）在卡片上")
            }
        }
    }

    func testSurfacesStepInTheDocumentedOrder() {
        // 深色：页面 < 内容区 < 卡片 < 浮层 < 悬停；浅色：页面最深一档（纸白），浮层纯白
        for theme in ColorTheme.allCases {
            let d = theme.mode(dark: true)
            XCTAssertLessThan(luminance(d.background), luminance(d.inset), "\(theme)")
            XCTAssertLessThan(luminance(d.inset), luminance(d.card), "\(theme)")
            XCTAssertLessThan(luminance(d.card), luminance(d.overlay), "\(theme)")
            XCTAssertLessThan(luminance(d.overlay), luminance(d.hover), "\(theme)")
            XCTAssertEqual(theme.mode(dark: false).overlay, 0xFFFFFF, "\(theme)：浅色浮层是纯白")
        }
    }

    // MARK: 真的换到了

    private func resolve(_ color: Color, dark: Bool) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            result = (UInt32((c.redComponent * 255).rounded()) << 16) | (UInt32((c.greenComponent * 255).rounded()) << 8) | UInt32((c.blueComponent * 255).rounded())
        }
        return result
    }

    func testChangingTheThemeChangesTheAccentTheSurfacesAndTheWindowBackground() {
        for theme in ColorTheme.allCases {
            ColorThemeStore.shared.current = theme
            XCTAssertEqual(resolve(Theme.accent, dark: true), theme.mode(dark: true).accent, "\(theme) 深色主色")
            XCTAssertEqual(resolve(Theme.accent, dark: false), theme.mode(dark: false).accent, "\(theme) 浅色主色")
            XCTAssertEqual(resolve(Theme.onAccent, dark: true), theme.mode(dark: true).onAccent)
            XCTAssertEqual(resolve(SolidTheme.card(.dark), dark: true), theme.mode(dark: true).card, "\(theme) 卡片底")
            XCTAssertEqual(resolve(SolidTheme.background(.light), dark: false), theme.mode(dark: false).background)
        }
        XCTAssertNotEqual(ColorTheme.darkroom.mode(dark: true).accent, ColorTheme.classic.mode(dark: true).accent)
    }

    func testStatusColorsAreSharedByAllThemes() {
        var seen = Set<UInt32>()
        for theme in ColorTheme.allCases {
            ColorThemeStore.shared.current = theme
            seen.insert(resolve(Theme.danger, dark: true))
        }
        XCTAssertEqual(seen.count, 1, "失败色所有主题一样，不会和某个主题的主色撞")
    }

    // MARK: 持久化

    func testTheChoiceIsPersistedAndRestoredByName() {
        ColorThemeStore.shared.current = .celadon
        XCTAssertEqual(UserDefaults.standard.string(forKey: ColorThemeStore.defaultsKey), "celadon")
        XCTAssertEqual(ColorThemeStore.persisted, .celadon)
        UserDefaults.standard.set("没有这个主题", forKey: ColorThemeStore.defaultsKey)
        XCTAssertEqual(ColorThemeStore.persisted, .darkroom, "读不懂就回到默认的暗房")
    }

    func testThumbnailTextCacheIsSeparatedPerTheme() throws {
        let state = ThumbTextState(title: "t-\(UUID().uuidString)", countText: "", statusTitle: "待生成", statusColorTag: 0,
                                   paramsText: "", showsParams: false, paramsDirty: false, width: 160)
        ColorThemeStore.shared.current = .darkroom
        let image = try XCTUnwrap(ThumbTextRaster.render(state, theme: ThumbTextThemeStore.shared))
        ThumbTextImageCache.store(image, for: state)
        XCTAssertNotNil(ThumbTextImageCache.cached(for: state))
        ColorThemeStore.shared.current = .classic
        XCTAssertNil(ThumbTextImageCache.cached(for: state), "换主题后，旧主色烤出来的图不再被用")
    }

    func testTheDirtyParamsColorFollowsTheThemeAccent() {
        ColorThemeStore.shared.current = .indigo
        XCTAssertEqual(ThumbTextThemeStore.shared.paramsDirtyColor, NSColor(hex: ColorTheme.indigo.mode(dark: true).accent))
    }
}
