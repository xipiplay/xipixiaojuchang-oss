import SwiftUI
import AppKit

/// App 主题（2026-09-18 用户要求：深色 / 浅色 / 跟随系统）。
///
/// ⚠️ **两边都要设**：
/// - SwiftUI 侧：根视图 `.preferredColorScheme`；
/// - AppKit 侧：`NSApp.appearance` —— **输入框的输入态（field editor）是 AppKit 的**，
///   只设 SwiftUI 侧的话，深色下打字会是黑字（用户实测 ✗）。
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "深色"
        case .light: "浅色"
        }
    }

    /// SwiftUI 侧给 `.preferredColorScheme` 的值。
    /// ⚠️ 「跟随系统」**也要给明确的深 / 浅**，不能给 nil（2026-10-07 用户：点「跟随系统」没有效果，只在软件周围出现一圈阴影，
    /// 切到别的软件再回来才变）：`.preferredColorScheme(nil)` 会把窗口的外观**清回「没设」**，
    /// 清掉之后窗口要等 App 重新激活才重算系统外观，我们刚给窗口设好的明确外观也被它冲掉了。
    /// 所以这里传「系统当下的明暗」，系统切换时由 `AppThemeStore` 更新它。
    func resolvedColorScheme(systemIsDark: Bool) -> ColorScheme {
        switch self {
        case .system: systemIsDark ? .dark : .light
        case .dark: .dark
        case .light: .light
        }
    }

    /// AppKit 侧。
    /// ⚠️ 「跟随系统」**不能给 nil**（2026-10-07 用户实测：在设置里点「跟随系统」界面没变化，要切到别的软件再回来才变）：
    /// nil = 让窗口自己去算系统外观，而 `NSApp.effectiveAppearance` 在 App 刚被清掉强制外观时不会立刻重算，
    /// 要等 App 重新激活才更新。现在直接读系统当下的明暗，给窗口一个明确的外观，点完马上就变；
    /// 之后系统自己切深 / 浅色，由 `AppThemeStore.followSystemChanges()` 的监听再应用一次。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: NSAppearance(named: SystemAppearance.isDark ? .darkAqua : .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

/// 系统现在是深色还是浅色。直接读全局偏好 `AppleInterfaceStyle`（深色 = "Dark"，浅色没有这个键），
/// 比 `NSApp.effectiveAppearance` 及时——后者在 App 不在前台 / 刚清掉强制外观时会滞后。
enum SystemAppearance {
    static var isDark: Bool {
        let value = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return value?.caseInsensitiveCompare("Dark") == .orderedSame
    }
}

enum AppThemeStore {
    private static let key = "appTheme"

    /// 当前主题（默认深色 —— 整个 App 的配色是按深色设计的）
    static var current: AppTheme {
        get { AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    @MainActor private static var systemObserver: NSObjectProtocol?

    /// 主题是「跟随系统」时，系统在深 / 浅色之间切换，App 也跟着换（App 不在前台时也收得到这条通知）。启动时调一次。
    @MainActor
    static func followSystemChanges() {
        guard systemObserver == nil else { return }
        systemObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard current == .system else { return }
                // 通知到的时候全局偏好可能还没写完，稍等一拍再读
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard current == .system else { return }
                    apply()
                }
            }
        }
    }

    /// 「系统当前是不是深色」的缓存键：根视图用 `@AppStorage` 读它，系统明暗变了它就变，根视图跟着重算 `.preferredColorScheme`
    nonisolated static let systemDarkKey = "systemIsDarkCache"

    /// 应用到 AppKit 侧（SwiftUI 侧由根视图的 `.preferredColorScheme` 负责）。
    /// ⚠️ **窗口级 appearance 也要显式复位**（2026-09-18 用户实测："跟随系统"没效果 ——
    /// 切浅色后再切跟随，还是浅色 ✗）：`.preferredColorScheme` 会把窗口的 appearance 粘住，
    /// 只清 `NSApp.appearance` 不够，必须逐个窗口设一遍（nil = 跟随系统）。
    static func apply() {
        UserDefaults.standard.set(SystemAppearance.isDark, forKey: systemDarkKey)   // 先更新缓存：根视图据此给 SwiftUI 明确的明暗
        let appearance = current.nsAppearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            // ⚠️ **不要在这里改窗口底色**（2026-09-19）：那是"另一条路径"，和 SwiftUI 的更新
            // 时序对不上 → 用户看到"界面和窗口不是同时变"。窗口底色统一由 `WindowBackdrop`
            // 的 `updateNSView` 在 SwiftUI 的更新里设置（见那边注释）。
        }
    }
}
