import SwiftUI

/// 主页和各工作页共用窗口外框，页面切换不改变外框与设置入口的位置。
enum AppWindowShellLayout {
    static let titleBarHeight: CGFloat = 38
    static let railWidth: CGFloat = 52
    /// 左侧导航栏图标的字号（按钮仍是 36×36，只缩图标本身）；设置齿轮比它大 1（齿轮笔画细，同字号看着小）。
    /// 2026-10-12 用户：图标有点大，19 → 16
    static let railIconSize: CGFloat = 16
    static let edgeInset: CGFloat = 8
    static let contentCornerRadius: CGFloat = 14
    /// 窗口最小尺寸 = 打开时的尺寸（2026-10-15 用户：用当时的窗口 1275×796；原来 1160×678）
    static let minimumWidth: CGFloat = 1275
    static let minimumHeight: CGFloat = 796
    /// 素材库 / 任务抽屉的宽。里面的切换条宽 244 = 260 − 两侧各 8（`LibraryView`、任务抽屉共用）。
    /// 2026-10-06 外壳改版时曾顺手改成 300，里面没跟着改、最小窗口下抽屉还盖住编辑提示词弹窗 38pt（2026-10-10 用户发现）→ 改回 260：
    /// 最小窗口（1160）下抽屉左沿 = 1160 − 8 − 260 = 892，刚好贴着弹窗右沿（580 + 620/2 = 890）。
    static let drawerWidth: CGFloat = 260
    /// 编辑提示词弹窗（视频 / 图片）的宽
    static let promptModalWidth: CGFloat = 620
    static let frostedTintOpacity: Double = 0.76   // 外框毛玻璃上叠的底色浓度**默认值**（2026-10-10 用户：稍微再透一点点，0.82 → 0.76）
    /// 2026-10-12 起可以在 设置 → 外观 里拖滑条改（用户：外边框看不出玻璃态）；存在 UserDefaults 的这个键
    static let frostedTintKey = "frostedTintOpacity"
    static let frostedTintRange: ClosedRange<Double> = 0.3...0.9

    /// 内容区的水平中心比窗口中心偏右这么多（左边导航栏 `railWidth`、右边只留 `edgeInset`）。
    /// 想让东西在**整个窗口**里居中（和弹窗对齐）而它又摆在内容区里时，往左挪这么多。
    static var contentCenterOffset: CGFloat { (railWidth - edgeInset) / 2 }

    static var contentMinimumWidth: CGFloat { minimumWidth - railWidth - edgeInset }
    static var contentMinimumHeight: CGFloat { minimumHeight - titleBarHeight - edgeInset }
}

/// 常驻的应用导航。项目相关入口只在进入项目后可用。
struct AppNavigationRail: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAIResult = false
    @State private var showUploadResult = false

    private enum Destination: String, CaseIterable {
        case script, image, video, library, tasks

        /// 2026-10-15 用户：「生视频」去掉过一阵又加回来——工作台只放段落卡（没有视频缩略图），按视频浏览 / 挑片 / 批量在生视频页
        static let mainPages: [Destination] = [.script, .image, .video]
        static let drawers: [Destination] = [.library, .tasks]

        var title: String {
            switch self {
            case .script: "工作台"
            case .image: "生图"
            case .video: "生视频"
            case .library: "素材库"
            case .tasks: "任务"
            }
        }

        var icon: String {
            switch self {
            // 工作台 = 项目的主界面：用原来主页按钮的房子图标（2026-10-10 用户定；主页按钮已去掉，原来这里是一本书）
            case .script: "house"
            case .image: "photo"
            case .video: "film"
            case .library: "photo.on.rectangle.angled"
            case .tasks: "list.bullet.rectangle"
            }
        }
    }

    /// 在项目里时选中的是哪一个；在主页（不在项目里）时没有——这几个按钮在主页不显示
    private var selectedDestination: Destination? {
        // 在同一观察作用域读取页面和抽屉状态，使导航选中态及时更新。
        let inWorkspace = app.isInWorkspace
        let libraryOpen = app.showLibraryDrawer
        let tasksOpen = app.showTaskDrawer
        let scriptOpen = app.projectPage == .script
        let mode = app.workspaceMode
        guard inWorkspace else { return nil }
        if libraryOpen { return .library }
        if tasksOpen { return .tasks }
        if scriptOpen { return .script }
        return mode == .image ? .image : .video
    }

    private var canAccessProject: Bool {
        app.isInWorkspace && app.currentProjectKey != nil
    }

    private func closeDrawers() {
        app.closeLibraryDrawer()
        app.closeHistoryDrawer()
        if app.showTaskDrawer { app.toggleTaskDrawer() }
    }

    private func navigate(to destination: Destination) {
        DropdownPanel.shared.dismiss()
        // 不在项目里（返回主页的淡出期间也算——`goHome` 一开始就把 `isInWorkspace` 置 false）这几个按钮不响应
        if canAccessProject { apply(destination) }
    }

    private func apply(_ destination: Destination) {
        switch destination {
        case .script:
            app.openScriptPage()
        case .image, .video:
            closeDrawers()
            app.switchWorkspaceMode(destination == .image ? .image : .video)
        case .library:
            app.closeHistoryDrawer()
            withAnimation(.easeInOut(duration: 0.2)) { app.toggleLibraryDrawer() }
        case .tasks:
            app.closeHistoryDrawer()
            withAnimation(.easeInOut(duration: 0.2)) { app.toggleTaskDrawer() }
        }
    }

    private func navigationButton(_ destination: Destination, selected: Destination?, projectAvailable: Bool) -> some View {
        Button { navigate(to: destination) } label: {
            Image(systemName: destination.icon)
                .font(.system(size: AppWindowShellLayout.railIconSize, weight: .regular))
                // 任务角标（2026-10-06 P2）：当前项目进行中的视频 + 生图 + 剧本 AI
                .overlay(alignment: .topTrailing) {
                    if destination == .tasks, app.activeTaskCount > 0 {
                        Text("\(app.activeTaskCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 8, y: -6)
                            .allowsHitTesting(false)
                    }
                }
                .foregroundStyle(!projectAvailable ? Color.secondary.opacity(0.45) :
                                 (selected == destination ? Color.primary : Color.secondary))
                .frame(width: 36, height: 36)
                .background {
                    if selected == destination {
                        RoundedRectangle(cornerRadius: 10).fill(SolidTheme.hover(colorScheme))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverHighlightButtonStyle(
            cornerRadius: 10, expandX: 0, expandY: 0,
            highlight: SolidTheme.hover(colorScheme)
        ))
        .accessibilityLabel(destination.title)
        .accessibilityIdentifier("global-\(destination.rawValue)")
        .accessibilityAddTraits(selected == destination ? .isSelected : [])
        .help(destination.title)
        .disabled(!projectAvailable ||
                  (app.activeModal != nil && destination != .library))
    }

    private enum Probe { case ai, upload }

    private func probeTint(_ state: ProbeState) -> Color {
        switch state {
        case .unknown: Color.secondary.opacity(0.45)
        case .testing: Color.secondary
        case .ok: Theme.accent
        case .failed: Theme.danger.opacity(0.9)
        }
    }

    /// 外部智能体接力的小圆点：没开 = 没有；开着等智能体 = 黄；智能体在工作 = 绿
    private var agentBadge: Color? {
        switch AgentBridge.shared.activity.state {
        case .off: nil
        case .waiting: Theme.standby
        case .working: Theme.success
        }
    }

    private var agentHelp: String {
        switch AgentBridge.shared.activity.state {
        case .off: ""
        case .waiting: "外部智能体接力：已开启，等智能体开始\n"
        case .working: "外部智能体接力：智能体正在工作\n"
        }
    }

    private func probeHelp(_ state: ProbeState, idle: String, message: String) -> String {
        switch state {
        case .unknown: idle
        case .testing: "正在测试…"
        case .ok, .failed: message.isEmpty ? idle : message + "\n（点一下重新测试）"
        }
    }

    /// 一个测试图标：点一下就测；测完在旁边弹出结果（`ProbeResultPanel`）
    private func probeButton<Icon: View>(_ kind: Probe, state: ProbeState, label: String, id: String, help: String,
                                         badge: Color? = nil,
                                         showResult: Binding<Bool>,
                                         @ViewBuilder icon: (Color) -> Icon,
                                         action: @escaping () -> Void) -> some View {
        let tint = probeTint(state)
        return Button {
            DropdownPanel.shared.dismiss()
            action()
        } label: {
            ZStack {
                icon(tint).opacity(state == .testing ? 0.25 : 1)
                if state == .testing { ProgressView().controlSize(.small) }
            }
            .frame(width: 36, height: 36)
            .overlay(alignment: .topTrailing) {
                // 右上角的小圆点（外部智能体接力：黄 = 等智能体，绿 = 智能体在工作）
                if let badge {
                    Circle().fill(badge)
                        .frame(width: 8, height: 8)
                        .padding(.top, 3).padding(.trailing, 3)
                        .accessibilityIdentifier("\(id)-badge")
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: badge)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(HoverHighlightButtonStyle(
            cornerRadius: 10, expandX: 0, expandY: 0,
            highlight: SolidTheme.hover(colorScheme)
        ))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
        .help(help)
        .disabled(state == .testing || app.activeModal != nil)
        .dropdownPopover(isPresented: showResult) {
            ProbeResultPanel(
                title: kind == .ai ? "AI 连接" : "素材上传 · \(ConnectionProbe.hostName(app.uploadProbeHost))",
                ok: (kind == .ai ? app.aiProbe : app.uploadProbe) == .ok,
                message: kind == .ai ? app.aiProbeMessage : app.uploadProbeMessage
            )
        }
    }

    /// 测完弹出结果：失败留着等点掉（要看原因），成功过几秒自己收（只在它还是当前面板时才收，别误关用户后来打开的）
    private func presentResult(_ state: ProbeState, show: Binding<Bool>) {
        show.wrappedValue = true
        guard state == .ok else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard let owner = DropdownPanel.shared.current?.owner else { return }
            try? await Task.sleep(for: .seconds(2.5))
            if DropdownPanel.shared.current?.owner == owner { DropdownPanel.shared.dismiss() }
        }
    }

    var body: some View {
        // 在导航本身的观察作用域读取选中态，不让 ForEach 的延迟内容捕获旧状态。
        let selected = selectedDestination
        let projectAvailable = canAccessProject
        let inWorkspace = app.isInWorkspace
        return VStack(spacing: 0) {
            // 2026-10-10 用户：主页按钮去掉（想点工作台老点成主页）；这五个按钮只在项目里显示，主页上不显示。
            // 用透明度藏起来而不是拆掉：进出项目时布局不跳。回主页：项目窗口的红色叉号 / ⌘W（`WindowCloseDelegate`）
            VStack(spacing: 8) {
                ForEach(Destination.mainPages, id: \.self) {
                    navigationButton($0, selected: selected, projectAvailable: projectAvailable)
                }
                // 分隔线：上面是工作台和两个制作页面，下面是素材库、任务这两个抽屉
                Rectangle()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(width: 22, height: 1)
                    .padding(.vertical, 2)
                ForEach(Destination.drawers, id: \.self) {
                    navigationButton($0, selected: selected, projectAvailable: projectAvailable)
                }
            }
            .opacity(inWorkspace ? 1 : 0)
            .allowsHitTesting(inWorkspace)
            .accessibilityHidden(!inWorkspace)
            .animation(.easeInOut(duration: 0.18), value: inWorkspace)
            .padding(.top, 8)
            Spacer(minLength: 0)
            // 连接测试（2026-10-07 用户定）：AI、上传两个图标点一下就测，不再跳设置页。
            // 默认暗（没测过）→ 转圈（测试中）→ 亮（成功）/ 红（失败）；测完在图标旁弹出结果，成功几秒后自动收，失败留着等点掉。
            probeButton(.ai, state: app.aiProbe, label: "AI 连接测试", id: "global-ai",
                        help: agentHelp + probeHelp(app.aiProbe, idle: "AI 连接：点一下测试", message: app.aiProbeMessage),
                        badge: agentBadge,
                        showResult: $showAIResult) { tint in
                // 「AI」两个字放在圆角方框里：一眼就能看出是 AI
                ZStack {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1.6)
                        // 跟着图标字号缩放（19 时是 25×20、字 12）
                        .frame(width: (AppWindowShellLayout.railIconSize * 1.3).rounded(), height: (AppWindowShellLayout.railIconSize * 1.05).rounded())
                    Text("AI")
                        .font(.system(size: (AppWindowShellLayout.railIconSize * 0.63).rounded(), weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }
            } action: { app.testAIConnection() }
                .padding(.bottom, 8)
            probeButton(.upload, state: app.uploadProbe, label: "上传测试", id: "global-upload",
                        help: probeHelp(app.uploadProbe, idle: "素材上传：点一下测试（测设置里选的那一条）", message: app.uploadProbeMessage),
                        showResult: $showUploadResult) { tint in
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: AppWindowShellLayout.railIconSize, weight: .regular))
                    .foregroundStyle(tint)
            } action: { app.testUploadConnection() }
                .padding(.bottom, 8)
            Button {
                DropdownPanel.shared.dismiss()
                closeDrawers()
                app.activeModal = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: AppWindowShellLayout.railIconSize + 1, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(HoverHighlightButtonStyle(
                cornerRadius: 10, expandX: 0, expandY: 0,
                highlight: SolidTheme.hover(colorScheme)
            ))
            .accessibilityLabel("设置")
            .accessibilityIdentifier("global-settings")
            .help("设置")
            .disabled(app.activeModal != nil)
        }
        .padding(.bottom, 16)
        .frame(width: AppWindowShellLayout.railWidth)
        .frame(maxHeight: .infinity)
        .onChange(of: app.aiProbe) { old, new in
            if old == .testing, new != .testing { presentResult(new, show: $showAIResult) }
        }
        .onChange(of: app.uploadProbe) { old, new in
            if old == .testing, new != .testing { presentResult(new, show: $showUploadResult) }
        }
    }
}

/// 测试结果小面板：一个对勾 / 叉 + 标题 + 一句话（失败原因可以选中复制）
struct ProbeResultPanel: View {
    let title: String
    let ok: Bool
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 17))
                .foregroundStyle(ok ? Theme.success : Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text(ok ? "\(title)：正常" : "\(title)：失败")
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}
