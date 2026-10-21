import SwiftUI
import AppKit

/// 关闭最后一个窗口后退出应用（主页叉号 = 真正退出，坞图标消失）
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 「本段未激活期间是否已经吞过一次点击」——见 `applicationDidFinishLaunching` 里的说明。
    /// 应用真正激活后由 `applicationDidBecomeActive` 复位。
    private var hasSwallowedForThisInactivePeriod = false

    /// 刚刚吞掉了一次 `mouseDown` → 它**配对的 `mouseUp` 也要吞**（理由见监听器里的说明）。
    private var shouldSwallowMouseUp = false

    /// 收到「请退出」信号（`pkill` / 重装脚本发的 SIGTERM）时走正常退出：先落盘、清掉「运行中」标记。
    /// 2026-10-09：原来 SIGTERM 会直接结束进程——防抖写盘来不及落（`flushAll` 只在正常退出路径上跑），
    /// 下次启动还会弹一条「上次异常退出」的假警报。
    private var terminationSignalSource: DispatchSourceSignal?

    private func installGracefulTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppLog.write("exit", "收到 SIGTERM：正常退出（先存盘）")
                AppTermination.forced = true          // 重装脚本发的：不能被「还有任务在跑」的确认弹窗挡住
                NSApp.terminate(nil)
                // 正开着模态框之类把退出挡住了：3 秒后补一遍落盘通知再结束，不让进程赖着不走
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: NSApp)
                    exit(0)
                }
            }
        }
        source.resume()
        terminationSignalSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 用户自己退出（⌘Q、关主页窗口）时，还有视频 / 生图 / 剧本 AI 在跑就先确认一下
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppTermination.forced, let busy = AppAttention.model?.busyWorkSummary() else { return .terminateNow }
        return AppTermination.confirmQuit(busy: busy) ? .terminateNow : .terminateCancel
    }

    /// 正常退出：清掉"运行中"标记（下次启动就不会报"异常退出"）。
    /// ⚠️ 防抖写盘（shots / library / imageItems / tasks）由 AppModel 内部注册的
    ///    `NSApplication.willTerminateNotification` 观察者（`flushAll()`）处理，
    ///    此处无需重复调用。
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.markCleanExit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppAttention.clear()
        // 回到激活态 → 复位，下一次"从别的 App 点过来"仍然只吞第一下
        hasSwallowedForThisInactivePeriod = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--run") {
            Task {
                await RunAutomationService.runFromCommandLine()
            }
            return
        }

        installGracefulTermination()

        // 崩溃记录 + 异常退出检测（2026-09-18 用户要求）：
        // 上次非正常退出（崩溃/被强杀）→ 写日志 + 弹一条提示；正常退出会清掉 marker。
        CrashReporter.install()
        if CrashReporter.lastRunCrashed {
            let logPath = CrashReporter.lastCrashLogPath ?? "（无崩溃日志，可能是被强杀）"
            AppLog.write("crash", "检测到上次异常退出；崩溃日志：\(logPath)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "上次异常退出"
                alert.informativeText = "上次运行没有正常退出（崩溃或被强制结束）。\n\n崩溃日志：\(logPath)\n\n如果正在进行的任务中断了，可以在任务列表里重试。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }

        // **外观按主题设置**（2026-09-18 用户要求：深色/浅色/跟随系统）：
        // AppKit 侧的输入框（field editor）会按这里设的外观渲染；SwiftUI 侧见根视图的
        // `.preferredColorScheme`。两边必须一致，否则深色下打字是黑字 ✗。
        AppThemeStore.apply()
        AppThemeStore.followSystemChanges()   // 跟随系统时，系统切深 / 浅色 App 跟着换

        // 主线程看门狗：偶发卡顿抓不到（`sample` 是概率采样，卡顿不落在窗口里就抓不着），
        // 让它常驻记录；卡超过 1 秒还会**在卡住的当下**自动抓一份 sample 存盘。
        // 不需要了把 MainThreadWatchdog.stallThreshold 设为 nil 即可。
        MainThreadWatchdog.start()

        // **从别的 App 点过来时，第一下只"把软件点过来"** —— 激活窗口，但不触发鼠标底下的控件。
        // SwiftUI 的视图默认 acceptsFirstMouse，点一下就既激活又按到了那个按钮，很别扭。
        //
        // ⚠️ 只在 **App 未激活**时拦截：活跃状态下的点击一律放行。
        //    否则会误伤下拉面板那类「非激活窗口」（NSPanel）—— 点选项会被吞掉、选不中。
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { event in
            // ⚠️ **吞了 down，就必须把它配对的 up 也吞掉**（2026-09-13 补，别再拆开）。
            //
            // `mouseUp` 是一个**独立事件** —— 吞掉 `mouseDown` 并不会让 up 也消失，
            // 它照样会被分发到鼠标底下的那个控件。而顶栏的罩子（`TopBarControlShieldButton`）
            // 是**自己重写 `mouseUp` 派发点击**的（为了不被 AppKit 合并双击），
            // 收到一个"没有 down 的 up"照样会触发 →
            // 表现为「从别的 App 点回来，第一下就把开着的浮层关掉了」，
            // 而且第二下又把浮层开回来（用户实测 2026-09-13）。
            if event.type == .leftMouseUp || event.type == .rightMouseUp {
                guard self.shouldSwallowMouseUp else { return event }
                self.shouldSwallowMouseUp = false
                AppLog.write("clickSwallow", "配对吞掉 up")
                return nil
            }

            guard !NSApp.isActive, let window = event.window else {
                // 应用是激活的（正常点击）→ 清标志，保证这一次的 up 不被误吞
                self.shouldSwallowMouseUp = false
                return event
            }

            // **同一段"未激活"期间只吞一次。**
            //
            // ⚠️ 这里绕过两个坑，别再改回去：
            // ① **不能无条件吞**：原来的写法是 `activate` 后无脑 `return nil`。一旦 `isActive`
            //    因为某种原因一直是 false，**每一次点击都会被吞掉**，应用看起来完全"点不动"
            //    —— 而它其实是活的、内容还能滚动（2026-09-12 实测连吞 10 击）。
            // ② **也不能"激活后立刻查 isActive 才吞"**：激活是**异步**的，要等下一轮 run loop
            //    才生效，紧接着查几乎永远是 false → 等于永远不吞 → 用户要的
            //    「第一下只把软件点过来、不触发底下控件」就失效了（实测确认）。
            // 所以用「只吞一次」：既保住设计，又保证第二下一定能点到东西。
            guard !self.hasSwallowedForThisInactivePeriod else {
                AppLog.write("clickSwallow", "本段未激活期已吞过一次 → 放行")
                self.shouldSwallowMouseUp = false
                return event
            }
            self.hasSwallowedForThisInactivePeriod = true
            self.shouldSwallowMouseUp = true      // ← down 被吞了，它的 up 也要配对吞掉

            AppLog.write("clickSwallow", "未激活 → 吞掉这一下并激活；窗口数=\(NSApp.windows.count)")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return nil   // 吞掉这一下，只做"点过来"
        }
    }
}

@main
@MainActor
struct XipixiaojuchangApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel
    /// 主题（设置页「界面」可切；@AppStorage 保证切换即时生效）
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.dark.rawValue
    /// 玻璃效果开关（默认开、持久化）：关掉后全软件变纯色
    @AppStorage("glassEffectEnabled") private var glassEffectEnabled = true
    /// 配色主题（设置 → 界面 → 配色；`ColorThemeStore` 写它，这里读到变化后重算根视图）
    @AppStorage("colorTheme") private var colorThemeRaw = ColorTheme.darkroom.rawValue
    /// 系统现在是不是深色（`AppThemeStore.apply()` 更新它）：「跟随系统」时 SwiftUI 也要拿到明确的明暗，见 `AppTheme.resolvedColorScheme`
    @AppStorage(AppThemeStore.systemDarkKey) private var systemIsDark = SystemAppearance.isDark

    init() {
        // 诊断（临时，验完删）：启动耗时分段（配合 AppModel.init 里的 `startup` 日志一起看）
        _ = StartupClock.t0     // ⚠️ 必须有这一句：`static let` 是懒初始化，不先摸一下，基准时间会晚到第一次打点才建立
        let t0 = Date()
        let model = AppModel()
        AppAttention.model = model
        AppLog.write("startup", "AppModel 构造总计: \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        _appModel = State(initialValue: model)
        let t1 = Date()
        model.poller.resumeAllInProgress()
        AppLog.write("startup", "resumeAllInProgress: \(Int(Date().timeIntervalSince(t1) * 1000))ms")
        // 保证窗口激活（从裸二进制运行时窗口可能不在前台）
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate()
        ThumbnailDiskCache.trimInBackground()      // 缩略图磁盘缓存超过上限就删最旧的（启动 20 秒后，后台）
        // 诊断（临时，验完删）：启动打点 ①（App 层初始化完成）
        AppLog.write("startup", "① App.init 结束 @ \(StartupClock.ms())ms")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                // 玻璃效果开关（2026-09-19 用户要求）：关掉后全软件变纯色（浅色为白）
                .environment(\.glassEffectEnabled, glassEffectEnabled)
                // SwiftUI 侧跟随主题设置（和 AppKit 侧一致）
                .preferredColorScheme((AppTheme(rawValue: appThemeRaw) ?? .dark).resolvedColorScheme(systemIsDark: systemIsDark))
                // 系统控件（实心按钮、开关、分段、进度条）的着色跟主色走，不再用系统强调色
                // （用深一档的 `controlTint`：系统控件上的字是白色，要保证对比度）
                .tint(Theme.controlTint(of: ColorTheme(rawValue: colorThemeRaw) ?? .darkroom))
                .environment(\.colorTheme, ColorTheme(rawValue: colorThemeRaw) ?? .darkroom)
        }
        .windowStyle(.hiddenTitleBar)
        // 菜单栏「设置…」（2026-09-21 用户要求：主页没有设置入口，从菜单进）：
        // 顶掉系统那一项（系统会打开 SwiftUI 的 `Settings` 场景，而我们的设置是**应用内浮层**），
        // 换成自己的动作 + 标准快捷键 ⌘, —— 主页/工作区/全屏下都能开。
        .commands {
            // ⌘N：主页新建项目、项目里新增分镜 / 图片（剧本页没有「新建」，菜单项灰掉）
            CommandGroup(replacing: .newItem) {
                Button("新建（项目 / 分镜 / 图片）") { appModel.performNewItemShortcut() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!appModel.canCreateNewItem)
            }
            // ⌘F：当前页的搜索框
            CommandGroup(after: .textEditing) {
                Button("搜索") { appModel.focusPageSearch() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appModel.activeModal = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        // 默认尺寸 = **最小尺寸**（`AppWindowShellLayout.minimumWidth/Height`，2026-10-15 起 1275×796）：一打开就缩无可缩。
        // 系统记住的上次尺寸不管用：启动时 RootView 里会再设一遍并居中（见 `window.minSize` 那里）
        .defaultSize(width: AppWindowShellLayout.minimumWidth, height: AppWindowShellLayout.minimumHeight)
    }
}
