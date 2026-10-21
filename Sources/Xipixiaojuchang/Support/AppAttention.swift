import AppKit
import UserNotifications

/// 软件不在前台时让用户知道：长任务（视频几分钟、批量几十分钟）做完 / 失败了 → Dock 图标跳一下、角标写个数、发一条系统通知；
/// 软件回到前台就清掉。2026-10-10 优化：原来只有界面里的变化，离开窗口就不知道什么时候好了。
/// 软件在前台时什么都不做（界面里已经看得到）。
@MainActor
enum AppAttention {
    /// 退出时要问「还有任务在跑」，需要看得到 AppModel（`AppDelegate` 拿不到）
    static weak var model: AppModel?
    /// 离开期间攒了几条还没看的提醒
    private(set) static var unseen = 0
    private static var askedForPermission = false

    /// 「完成时发系统通知」的开关（设置 → 界面 → 提醒）。**默认关**（2026-10-11 用户：通知带提示音，默认别响）。
    /// 只管系统通知（和它的提示音）；Dock 图标跳动、角标不受影响
    nonisolated static let notificationsKey = "completionNotificationsEnabled"
    static var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: notificationsKey) }

    /// 单元测试里不提醒（也没有 NSApp 的前台状态可言）
    private static var isRunningTests: Bool { NSClassFromString("XCTestCase") != nil }

    static func notify(title: String, body: String, failed: Bool = false) {
        guard !isRunningTests, !NSApp.isActive else { return }
        unseen += 1
        NSApp.dockTile.badgeLabel = String(unseen)
        NSApp.requestUserAttention(failed ? .criticalRequest : .informationalRequest)
        if notificationsEnabled { postSystemNotification(title: title, body: body) }
    }

    /// 软件回到前台：角标、已发出的通知都清掉
    static func clear() {
        guard unseen > 0 else { return }
        unseen = 0
        NSApp.dockTile.badgeLabel = nil
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
    }

    /// 用户打开开关时就问系统要通知权限（不要等到第一条任务做完才突然弹出来）
    static func requestNotificationPermission() {
        guard !isRunningTests, Bundle.main.bundleURL.pathExtension == "app" else { return }
        askedForPermission = true
        requestAuthorization(UNUserNotificationCenter.current())
    }

    /// 问系统要通知权限，结果写进日志（系统设置 → 通知 里找不到软件时，靠这一行判断是没问过、被拒了，还是系统没认）
    private static func requestAuthorization(_ center: UNUserNotificationCenter) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            let result = error.map { "出错：\($0.localizedDescription)" } ?? (granted ? "允许" : "不允许")
            AppLog.write("notify", "通知权限：\(result)")
        }
    }

    /// 系统通知：尽力而为。没打包成 .app（命令行运行）就跳过；用户在系统设置里关了通知就发不出来，Dock 跳动和角标仍然有
    private static func postSystemNotification(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        if !askedForPermission {
            askedForPermission = true
            requestAuthorization(center)
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// 退出确认要区分「用户自己退出」和「重装脚本 / 更换项目文件夹后重启」：后者不能被弹窗挡住。
/// 主页点关闭按钮时在关窗之前就问过了（见 `WindowCloseDelegate`），问过的也记在 `forced` 里，退出时不再问第二遍
@MainActor
enum AppTermination {
    static var forced = false

    /// 有任务在跑时，用户自己退出要确认。返回 true = 可以退出
    static func confirmQuit(busy summary: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "还有任务在跑"
        alert.informativeText = "\(summary)。现在退出：视频下次打开会接着查结果，生图和剧本 AI 会中断。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn
    }
}
