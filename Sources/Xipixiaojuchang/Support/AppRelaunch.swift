import AppKit

/// 退出并重新打开软件（更换项目文件夹之后：整个软件要按新位置重新读一遍项目）
@MainActor
enum AppRelaunch {
    static func now() {
        // 先留一个等 1.5 秒再 `open -n` 的小进程（本进程退出后它还活着），再正常退出（先存盘、清掉「运行中」标记）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1.5; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        AppLog.write("exit", "重新启动软件（更换项目文件夹）")
        AppTermination.forced = true
        NSApp.terminate(nil)
        // 正开着模态框之类把退出挡住了：3 秒后补一遍落盘通知再结束，不让进程赖着不走（同 SIGTERM 那条路）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
            exit(0)
        }
    }
}
