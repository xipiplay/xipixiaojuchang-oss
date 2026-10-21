import XCTest
import AppKit
import SwiftUI
import Observation
@testable import Xipixiaojuchang

@Observable private final class SchemeDriver { var scheme: ColorScheme? = nil }
private final class SchemeBox { var value: ColorScheme? }
private struct SchemeProbe: View {
    let box: SchemeBox
    @Environment(\.colorScheme) private var scheme
    var body: some View { Color.clear.onChange(of: scheme, initial: true) { _, new in box.value = new } }
}
private struct SchemeRoot: View {
    let driver: SchemeDriver; let box: SchemeBox
    var body: some View { SchemeProbe(box: box).preferredColorScheme(driver.scheme) }
}

/// 深色 / 浅色 / 跟随系统（2026-10-07 用户实测：点「跟随系统」界面没变化，要切到别的软件再回来才变）。
@MainActor
final class AppThemeTests: XCTestCase {
    func testFollowSystemGivesAnExplicitAppearanceMatchingTheSystemRightNow() throws {
        let expected: NSAppearance.Name = SystemAppearance.isDark ? .darkAqua : .aqua
        XCTAssertEqual(AppTheme.system.nsAppearance?.name, expected, "不再是 nil：nil 要等 App 重新激活才重算")
        XCTAssertEqual(AppTheme.dark.nsAppearance?.name, .darkAqua)
        XCTAssertEqual(AppTheme.light.nsAppearance?.name, .aqua)
    }

    func testSystemAppearanceReadsTheGlobalPreferenceDirectly() {
        let value = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        XCTAssertEqual(SystemAppearance.isDark, value == "Dark")
    }

    func testApplyingFollowSystemSetsEveryWindowToTheSystemAppearance() {
        let saved = AppThemeStore.current
        defer { AppThemeStore.current = saved; AppThemeStore.apply() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: SystemAppearance.isDark ? .aqua : .darkAqua)    // 先故意设成和系统相反
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        AppThemeStore.current = .system
        AppThemeStore.apply()
        XCTAssertEqual(window.appearance?.name, SystemAppearance.isDark ? .darkAqua : .aqua, "点完立刻就是系统的明暗")
    }

    func testResolvedSchemeIsNeverNilSoSwiftUIDoesNotClearTheWindowAppearance() {
        XCTAssertEqual(AppTheme.system.resolvedColorScheme(systemIsDark: true), .dark)
        XCTAssertEqual(AppTheme.system.resolvedColorScheme(systemIsDark: false), .light)
        XCTAssertEqual(AppTheme.dark.resolvedColorScheme(systemIsDark: false), .dark)
        XCTAssertEqual(AppTheme.light.resolvedColorScheme(systemIsDark: true), .light)
    }

    /// 真实的 SwiftUI 窗口：先强制成和系统相反的明暗，再切到「跟随系统」，窗口里的 colorScheme 必须马上等于系统的
    func testSwitchingToFollowSystemInARealHostedWindowTakesEffectImmediately() async throws {
        let saved = AppThemeStore.current
        defer { AppThemeStore.current = saved; AppThemeStore.apply() }
        let driver = SchemeDriver(), box = SchemeBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: SchemeRoot(driver: driver, box: box))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let system: ColorScheme = SystemAppearance.isDark ? .dark : .light
        let opposite: ColorScheme = SystemAppearance.isDark ? .light : .dark
        driver.scheme = opposite
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.value, opposite, "先强制成相反的明暗")

        AppThemeStore.current = .system
        AppThemeStore.apply()
        driver.scheme = AppTheme.system.resolvedColorScheme(systemIsDark: SystemAppearance.isDark)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.value, system, "切到跟随系统：马上是系统的明暗，不用等 App 重新激活")
    }
}
