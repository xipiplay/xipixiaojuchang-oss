import XCTest
@testable import Xipixiaojuchang

/// 2026-10-11 用户：完成通知带提示音，加个开关，默认关。
@MainActor
final class AppAttentionTests: XCTestCase {
    func testSystemNotificationsAreOffUntilTheUserTurnsThemOn() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: AppAttention.notificationsKey)
        defer { if let saved { defaults.set(saved, forKey: AppAttention.notificationsKey) } else { defaults.removeObject(forKey: AppAttention.notificationsKey) } }
        defaults.removeObject(forKey: AppAttention.notificationsKey)
        XCTAssertFalse(AppAttention.notificationsEnabled, "没设置过 = 关")
        defaults.set(true, forKey: AppAttention.notificationsKey)
        XCTAssertTrue(AppAttention.notificationsEnabled)
    }
}
