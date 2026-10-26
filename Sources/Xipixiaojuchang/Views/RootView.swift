import SwiftUI
import AppKit
import AVKit
import Combine

/// 三个预览浮层（分镜/视频、素材、图片）占窗口的比例。
///
/// **抽成常量是为了三个必须一致** —— 之前三个各写各的数字（86%×82% / 70%×70% / 86%×82%），
/// 用户要求"把图片预览和视频预览对齐到素材预览"。以后只改这一处，三个一起变。
enum PreviewLayout {
    static let widthRatio: CGFloat = 0.7
    static let heightRatio: CGFloat = 0.7
}
import AppKit

/// 底栏那条在窗口底部占的高度（含 12pt 下边距 + 胶囊 42）。
/// **抽屉的捕获层要在底部让出这一段**（2026-09-19）：抽屉开着时底栏按钮仍要可点，
/// 否则点「任务/素材库」只会被捕获层吃掉 → 看着像"点一下缩回去了"。
/// 取 62 留一点余量（放大/阴影都在视觉上，不影响命中，但别让边缘差几 pt 就失效）。
private let dockStripHeight: CGFloat = 62

/// 根视图：主页（新建项目 / 历史项目）↔ 分镜工作区
struct RootView: View {
    /// 玻璃效果开关（设置里切；关掉后全软件变纯色）——读它才会在切换时重算整棵树
    @AppStorage("glassEffectEnabled") private var glassEffectEnabled = true
    /// 外框毛玻璃上叠的底色浓度（设置 → 外观 →「外框浓度」）
    @AppStorage(AppWindowShellLayout.frostedTintKey) private var frostedTint = AppWindowShellLayout.frostedTintOpacity
    /// 主题原始值：窗口底色的深浅要跟着它（纯色模式）
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.dark.rawValue
    @AppStorage("colorTheme") private var colorThemeRaw = ColorTheme.darkroom.rawValue
    /// 纯色模式下要按浅/深取底色
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var app
    // 设置等浮层的开关已统一到 `AppModel.activeModal`（见 RootModals）
    @State private var editingName = ""
    /// 顶栏项目名是否处于**就地编辑**态（不再弹窗）。
    @State private var isEditingName = false
    /// 项目名文字的实测宽度：编辑框按它定宽（跟着文字走），
    /// 双击缩放那边也用它来避开名字这块区域。
    @State private var nameTextWidth: CGFloat = 0
    /// 顶栏右侧**按钮组**的实测宽度（不含外边距）。
    ///
    /// 给两处用，**都是"避开"**：
    /// ① 双击缩放（`installDoubleClickMonitor`）—— 双击按钮不该把窗口放大；
    /// ② 拖窗口背景（`WindowDragBackground`）—— 按住按钮拖动不该移动窗口。
    /// 这两个都得靠实测宽度来划界，写死数值会在按钮增减/文案变化后失准。
    @State private var topBarTrailingWidth: CGFloat = 0
    @FocusState private var nameFieldFocused: Bool
    /// 就地编辑项目名期间挂的"点外面保存"监听（见 `installNameClickMonitor`）
    @State private var nameClickMonitor: Any?

    /// 提交重命名（回车 / 点外面时调）。空名字或没变都不写，然后退出编辑态。
    private func commitRename() {
        defer { isEditingName = false }
        guard let key = app.currentProjectKey else { return }
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != app.projectName(for: key) else { return }
        app.renameProject(key, to: trimmed)
    }

    /// 就地编辑期间监听全局左键按下，实现「**点其他地方保存**」。
    ///
    /// ⚠️ **不能只靠 `@FocusState` 的失焦**：点在**非可聚焦**的地方（空白、非按钮区）
    /// 不一定会让输入框失焦 → `nameFieldFocused` 一直为 true → 保存永远不触发
    /// （用户实测"鼠标点外边没有保存作用"）。所以这里明确判"点在不在名字这块区域"。
    ///
    /// **点在外面 → 只保存，不再触发别的操作**（`return nil` 把这一下吞掉）。
    ///
    /// 这与全 App 的统一规则一致：「弹层开着时，点外面只是关掉它，不再同时触发别的」。
    /// （曾按"点击照常生效"做过一版 —— 用户实测后要求改成不触发。）
    /// 点在**名字这块区域内**时不吞（`return event`），交给输入框自己处理（定位光标、选词）。
    private func installNameClickMonitor() {
        guard nameClickMonitor == nil else { return }
        nameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window, !(window is NSPanel) else { return event }
            let p = event.locationInWindow
            let halfWidth = max(nameTextWidth, 60) / 2 + 20
            let inTopBar = p.y > window.frame.height - 38
            let nearCenter = abs(p.x - window.frame.width / 2) < halfWidth
            if inTopBar && nearCenter { return event }   // 名字区域内：交给输入框
            AppLog.write("renameInline", "点在外面 → 保存（吞掉这一下，不触发别的）")
            commitRename()
            return nil                                    // ⚠️ 吞掉：只保存，不触发别的
        }
    }

    private func removeNameClickMonitor() {
        if let nameClickMonitor { NSEvent.removeMonitor(nameClickMonitor) }
        nameClickMonitor = nil
    }
    @State private var doubleClickMonitor: Any?
    /// 双击缩放**前**的窗口 frame（见 `zoomWithoutAnimation`：不用 `zoom(nil)` 就得自己记）
    @State private var preZoomFrame: CGRect?
    @State private var previewOverlayOpacity: Double = 0
    @State private var previewCloseWork: DispatchWorkItem?
    /// 浮层本体的入场姿态：略小、略靠下，进来时弹到 1.0 —— 这一下"由远及近"是自然感的关键。
    /// 遮罩的淡入淡出另由 `previewOverlayOpacity` 管；两者分开动，才有"背景先压暗、弹窗再落位"的层次。
    @State private var previewPanelScale: CGFloat = 0.96
    @State private var previewPanelOffsetY: CGFloat = 14
    @State private var closeDelegate: WindowCloseDelegate?

    @State private var mediaPresentation = MediaWorkspacePresentation()

    /// 工作台建过没有（2026-10-12 用户：从分段弹窗去生图 / 生视频页再回来，像是先回一级页面又点开了一次）。
    /// 原来切到别的页就整个拆掉、回来从头建，开着的弹窗要等建完下一拍才恢复；现在建过就留着，切走只是藏起来。
    /// 离开项目（回主页）时拆掉：主页悬停预绑会换 `currentProjectKey`，留着它就会跟着在后台一遍遍重建
    @State private var scriptPageMaterialized = false

    /// 启动淡入的不透明度（2026-09-13）：窗口出现时**内容**渐显。
    ///
    /// ⚠️ **不要改成"淡入整个窗口"**（`window.alphaValue`）：实测 `viewDidMoveToWindow` 发生在
    /// `RootView.onAppear` **之后**（日志：②@251ms、⓪@267ms），也就是**窗口在我们能碰到它之前就已经显示了** ——
    /// 那条路只会做出"先亮、又被设成 0、再靠兜底亮回来"的怪效果（用户实测"看不出效果"）。
    /// 所以改为：窗口（含毛玻璃 backdrop）照常立刻出现，只让**内容**淡入 —— 时序完全可控。
    @State private var launchOpacity: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏的"点空白关抽屉"捕获层**已经挪进 `topBar` 的 ZStack 里面**了
            //（原因见那边的注释：挂 `.background` 会被 `WindowDragBackground` 这个 AppKit 视图盖住，
            //  空白处的点击全被"拖窗口"吃掉，捕获层一次都接不到）。
            // ⚠️ 别再改回 `.background { drawerTopCatcher }`，也别改成 `.overlay`（那会连按钮一起盖住）。
            topBar
            // 外框常驻；主页、剧本与制作页在同一个内缩内容面板里切换。
            HStack(spacing: 0) {
                AppNavigationRail()
                ZStack {
                    if let state = mediaState {
                        workspaceContainer(state)
                            .id(state.id)
                            .environment(\.mediaWorkspaceContext, MediaWorkspaceContext(
                                projectKey: state.projectKey, mode: state.mode, active: app.isProductionWorkspaceVisible))
                            .opacity(app.isProductionWorkspaceVisible ? 1 : 0)
                            .allowsHitTesting(app.isProductionWorkspaceVisible)
                            .disabled(!app.isProductionWorkspaceVisible)
                    }
                    if app.isInWorkspace && (app.projectPage == .script || scriptPageMaterialized) {
                        // 分镜状态整页算一次，各块直接拿（见 `WorkbenchBoardProvider`）
                        WorkbenchBoardProvider { PipelinePage() }
                            .id(app.currentProjectKey)          // 换项目照旧重建（每个项目的集、段都不同）
                            .opacity(app.isScriptPageVisible ? 1 : 0)
                            .allowsHitTesting(app.isScriptPageVisible)
                            .disabled(!app.isScriptPageVisible)   // 藏着时它的快捷键（⌘[ / ⌘]）也不能响应
                    }
                    WelcomeView()
                        .opacity(app.isInWorkspace ? 0 : 1)
                        .allowsHitTesting(!app.isInWorkspace)
                }
                .animation(.easeInOut(duration: 0.18), value: app.isInWorkspace)
                .onChange(of: app.isInWorkspace, initial: true) { _, inWorkspace in
                    if !inWorkspace { mediaPresentation.didLeaveProject() }
                    scriptPageMaterialized = inWorkspace && app.projectPage == .script
                }
                // 自由创作的工作台固定在生视频那一侧
                .onChange(of: app.projectPage == .script && app.isFreeCreation, initial: true) { _, free in
                    if free { app.workspaceMode = .video }
                }
                .onChange(of: app.projectPage) { _, page in
                    if page == .script && app.isInWorkspace { scriptPageMaterialized = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SolidTheme.background(colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: AppWindowShellLayout.contentCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: AppWindowShellLayout.contentCornerRadius)
                        .strokeBorder(SolidTheme.cardStroke(colorScheme), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .padding(.trailing, AppWindowShellLayout.edgeInset)
                .padding(.bottom, AppWindowShellLayout.edgeInset)
            }
        }
        // 启动淡入：内容渐显（窗口本身照常立刻出现，见 `launchOpacity` 的说明）
        .opacity(launchOpacity)
        .ignoresSafeArea()
        // 软件共用的毛玻璃外框：真实桌面模糊上叠加中性色，减弱背景透出。
        .background {
            ZStack {
                WindowBackdrop(enabled: glassEffectEnabled, theme: appThemeRaw + "|" + colorThemeRaw)
                SolidTheme.card(colorScheme).opacity(min(max(frostedTint, AppWindowShellLayout.frostedTintRange.lowerBound), AppWindowShellLayout.frostedTintRange.upperBound))
            }
            // ⚠️ **这里必须再来一次 `.ignoresSafeArea()`**，外面那次不够。
            //
            // 外面那次只让**内容**延伸进标题栏区（顶栏才能和红绿灯同行）；
            // `.background` 拿到的仍是被标题栏 inset 切过的 frame —— 实测（lldb dump 视图树）：
            // 窗口高 746，而本背景只有 `f=(0,32,1160,714)`，**顶上 32pt 一点没铺到**。
            // 那 32pt 于是露出未模糊、未压色的原始桌面，表现为"红绿灯那一栏是透明的"——
            // 这正是长期调不出毛玻璃的原因（怎么调浓度都无效，因为那一块底下根本没有毛玻璃）。
            .ignoresSafeArea()
        }
        // 应用内浮层（设置 / 批量设置参数）拆到 `RootModals` 里挂载 ——
        // **不能直接写在这条链上**：body 的修饰符链已经很长，再加两个浮层会让
        // Swift 类型检查器超时（`unable to type-check this expression in reasonable time`）。
        .modifier(RootModals())
        // 素材库抽屉挂在 `RootModals` **之后**：它要浮在提示词弹窗之上（理由见 `RightWorkspaceDrawerLayer`）。
        // 同样拆成独立 ViewModifier，不写进上面那条链（类型检查器会超时）。
        .modifier(HistoryDrawerLayer())
        .modifier(RightWorkspaceDrawerLayer())
        // 更换项目文件夹、正在搬项目时盖住整个窗口
        .modifier(ProjectsRootChangeOverlay())
        // 重命名改为**顶栏就地编辑**（点名字 → 变输入框，回车/点外面保存、Esc 取消），
        // 原来那个 `.alert` 弹窗已按用户要求删掉。
        .onAppear {
            // 诊断（临时，验完删）：启动打点 ②（根视图出现）
            AppLog.write("startup", "② RootView.onAppear @ \(StartupClock.ms())ms")
            // 启动淡入（2026-09-13）：让**内容**渐显（见 `launchOpacity` 的说明 —— 试过淡入整个窗口，
            // 但 `viewDidMoveToWindow` 比这里还晚，那条路时序不可控）。`async` 推到下一轮 runloop，
            // 确保首帧是以 opacity 0 呈现的，动画才看得见。
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.35)) { launchOpacity = 1 }
            }
            installDoubleClickMonitor()
            InputFocusGuard.install()   // 点输入框以外的地方，输入框放手、竖条消失
            AgentBridge.shared.refresh(app: app)   // 设置里开着「外部智能体接力」就开始收件 / 收命令
            app.previewCloseRequest = { requestClosePreview() }
            // 内容延伸进标题栏区域：顶栏与红绿灯同行（透明标题栏 + 全尺寸内容视图）
            for window in NSApp.windows {
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                // 窗口非不透明 + 近全透明底 —— 这是 WindowBackdrop 的 `.behindWindow` 能采到桌面的前提。
                // 少任何一条，毛玻璃都会糊成一片灰（采不到窗口后面的东西）。
                // 底色为什么不用 `.clear` 而用 white(0.001)，见 WindowBackdrop.windowBackground。
                // ⚠️ 排除 NSPanel（悬停预览浮层）：它们自己管透明度（见 Components 里 p.isOpaque = false），
                //    被这里改掉会连浮层底一起透掉。NSApp.windows 是**所有**窗口，不只是主窗。
                if !(window is NSPanel) {
                    AppLog.write("backdrop", "onAppear 设置前: isOpaque=\(window.isOpaque)"
                        + " bgAlpha=\(window.backgroundColor.alphaComponent) class=\(type(of: window))")
                    window.isOpaque = false
                    window.backgroundColor = GlassEffectSetting.isEnabled
                        ? WindowBackdrop.windowBackground
                        : SolidTheme.windowBackgroundColor()
                    AppLog.write("backdrop", "onAppear 设置后: isOpaque=\(window.isOpaque)"
                        + " bgAlpha=\(window.backgroundColor.alphaComponent)")
                }
                // 窗口最小尺寸两态统一（主页/工作区一致），= 打开时的尺寸（`AppWindowShellLayout.minimumWidth/Height`，
                // 2026-10-15 用户：1160×678 → 1275×796）
                let size = NSSize(width: AppWindowShellLayout.minimumWidth, height: AppWindowShellLayout.minimumHeight)
                window.minSize = size
                // 🎯 启动时固定窗口尺寸并居中，不让系统恢复上次关闭时的尺寸 / 位置（2026-09-29 用户定，2026-10-15 再确认：
                // 原来同尺寸时不居中，位置还是上次的；现在一律居中，也不让系统做窗口状态恢复）。
                // ⚠️ 只对主窗生效：NSPanel（悬停预览浮层）的 frame 别动。
                if !(window is NSPanel) {
                    window.isRestorable = false
                    window.setContentSize(size)
                    window.center()
                    AppLog.write("windowSize", "启动固定为 \(Int(size.width))×\(Int(size.height)) 并居中")
                }
                // 诊断：把窗口实际的圆角值记下来（首页「开始创作」的方块要跟它对齐）
                AppLog.write("windowCorner", "contentView.superview.layer.cornerRadius=\(window.contentView?.superview?.layer?.cornerRadius ?? -1)")
                // 拦截关闭：工作区时叉号/Cmd+W = 返回主页；主页时正常关闭（需持有 delegate，window 只弱引用）
                if closeDelegate == nil {
                    let delegate = WindowCloseDelegate()
                    delegate.app = app
                    closeDelegate = delegate
                }
                window.delegate = closeDelegate
            }
        }
        .onDisappear {
            if let monitor = doubleClickMonitor {
                NSEvent.removeMonitor(monitor)
                doubleClickMonitor = nil
            }
            removeNameClickMonitor()
        }
        // 批量操作的确认框（生图 / 生视频页的工具条和工作台的批量条共用，见 `batchDialogs`）
        .background(batchDialogs)
        // 就地编辑项目名：进出编辑态时挂/摘"点外面保存"的监听
        .onChange(of: isEditingName) { _, editing in
            if editing { installNameClickMonitor() } else { removeNameClickMonitor() }
        }
        .onChange(of: app.previewingShotID) { _, newValue in
            if newValue == nil { app.shotPreviewEditSegment = nil }
            updatePreviewOverlayState()
            if newValue != nil { fadeInPreviewOverlay() }
        }
        .onChange(of: app.previewingLibraryItemID) { _, newValue in
            updatePreviewOverlayState()
            if newValue != nil { fadeInPreviewOverlay() }
        }
        .onChange(of: app.previewingImageItemID) { _, newValue in
            updatePreviewOverlayState()
            if newValue != nil { fadeInPreviewOverlay() }
        }
        .onChange(of: app.previewingStandaloneImagePath) { _, newValue in
            updatePreviewOverlayState()
            if newValue != nil { fadeInPreviewOverlay() }
        }
        .overlay {
            // 预览弹窗（覆盖层，尺寸随窗口比例缩放）
            if let shotID = app.previewingShotID,
               let shot = app.shots.first(where: { $0.id == shotID }) {
                GeometryReader { geo in
                    ZStack {
                        // 遮罩压暗：**这是"弹窗浮起来、界面退成背景"的主要手段**——
                        // 只加阴影不够，背后界面还亮着就没有纵深。0.22→0.45（嫌深/嫌浅告诉我数值）。
                        Color.black.opacity(0.40)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                AppLog.write("previewOverlay", "点遮罩关闭分镜预览")
                                requestClosePreview()
                            }
                        // 真 AppKit 遮罩（见 Components.swift 的 OverlayEventShield）：
                        // 让 AppKit 的 hitTest 看得见遮罩 → 滚轮不再穿透到后面的卡片列表。
                        OverlayEventShield { requestClosePreview() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                        ShotPreviewSheet(shot: shot)
                            // 全屏时铺满整个窗口（配合窗口全屏 = 视频占满屏幕），否则按 PreviewLayout 的比例
                            .frame(
                                width: app.previewFullscreen ? geo.size.width : geo.size.width * PreviewLayout.widthRatio,
                                height: app.previewFullscreen ? geo.size.height : geo.size.height * PreviewLayout.heightRatio
                            )
                            .glassPanel(cornerRadius: app.previewFullscreen ? 0 : 20)
                            // 历史版本：单独一条贴在弹窗外面右边，不挤视频（2026-10-14）；全屏时不显示
                            .overlay(alignment: .topTrailing) {
                                if !app.previewFullscreen {
                                    ShotVersionColumn(shotID: shotID)
                                        .frame(height: geo.size.height * PreviewLayout.heightRatio)
                                        .glassPanel(cornerRadius: 20)
                                        .offset(x: VersionStripLayout.width + VersionStripLayout.gap)
                                }
                            }
                            // 入场姿态：只有**弹窗本体**缩放/位移，遮罩不参与（见 fadeInPreviewOverlay）
                            .scaleEffect(previewPanelScale)
                            .offset(y: previewPanelOffsetY)
                    }
                }
                .opacity(previewOverlayOpacity)
                .onAppear { AppLog.write("previewOverlay", "显示 shot=\(shotID)") }
            } else if let item = app.previewingItem {
                GeometryReader { geo in
                    ZStack {
                        // 遮罩压暗：**这是"弹窗浮起来、界面退成背景"的主要手段**——
                        // 只加阴影不够，背后界面还亮着就没有纵深。0.22→0.45（嫌深/嫌浅告诉我数值）。
                        Color.black.opacity(0.40)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                AppLog.write("previewOverlay", "点遮罩关闭素材预览")
                                requestClosePreview()
                            }
                        OverlayEventShield { requestClosePreview() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                        PreviewSheet(item: item)
                            .frame(width: geo.size.width * PreviewLayout.widthRatio,
                                   height: geo.size.height * PreviewLayout.heightRatio)
                            .glassPanel(cornerRadius: 18)
                            // 入场姿态：只有弹窗本体缩放/位移，遮罩不参与
                            .scaleEffect(previewPanelScale)
                            .offset(y: previewPanelOffsetY)
                    }
                }
                .opacity(previewOverlayOpacity)
            } else if let path = app.previewingStandaloneImagePath {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.40)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                AppLog.write("previewOverlay", "点遮罩关闭生图单图预览")
                                requestClosePreview()
                            }
                        OverlayEventShield { requestClosePreview() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                        PreviewSheet(item: LibraryItem(
                            kind: .image,
                            localPath: path,
                            fileName: app.previewingStandaloneImageFileName
                        ))
                        .frame(width: geo.size.width * PreviewLayout.widthRatio,
                               height: geo.size.height * PreviewLayout.heightRatio)
                        .glassPanel(cornerRadius: 18)
                        .scaleEffect(previewPanelScale)
                        .offset(y: previewPanelOffsetY)
                    }
                }
                .opacity(previewOverlayOpacity)
            } else if let imageItemID = app.previewingImageItemID,
                      let imageItem = app.imageItems.first(where: { $0.id == imageItemID }) {
                GeometryReader { geo in
                    ZStack {
                        // 遮罩压暗：**这是"弹窗浮起来、界面退成背景"的主要手段**——
                        // 只加阴影不够，背后界面还亮着就没有纵深。0.22→0.45（嫌深/嫌浅告诉我数值）。
                        Color.black.opacity(0.40)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                AppLog.write("previewOverlay", "点遮罩关闭生图预览")
                                // 走统一的关闭流程，才有淡出动画（原来直接清状态 = 瞬间消失）
                                requestClosePreview()
                            }
                        OverlayEventShield { requestClosePreview() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                        ImagePreviewSheet(item: imageItem)
                            .frame(width: geo.size.width * PreviewLayout.widthRatio,
                                   height: geo.size.height * PreviewLayout.heightRatio)
                            .glassPanel(cornerRadius: 18)
                            // 历史版本：单独一条贴在弹窗外面右边，不挤大图（2026-10-14）
                            .overlay(alignment: .topTrailing) {
                                ImageVersionColumn(itemID: imageItem.id)
                                    .frame(height: geo.size.height * PreviewLayout.heightRatio)
                                    .glassPanel(cornerRadius: 18)
                                    .offset(x: VersionStripLayout.width + VersionStripLayout.gap)
                            }
                            // 入场姿态：只有弹窗本体缩放/位移，遮罩不参与
                            .scaleEffect(previewPanelScale)
                            .offset(y: previewPanelOffsetY)
                    }
                }
                .opacity(previewOverlayOpacity)
            }
        }
        // 下拉浮层（窗口内实现）：**最后一层** —— 保证盖住卡片 / 抽屉 / 批量弹窗。
        // ⚠️ `.ignoresSafeArea()` 必须再来一次（同右侧抽屉层的安全区说明）：
        // `.overlay` 拿到的 frame 被标题栏 inset 过，少了它坐标会与按钮的 `.global` 错开 32pt。
        .overlay {
            if let item = DropdownPanel.shared.current {
                DropdownOverlay(item: item)
                    .ignoresSafeArea()
            }
        }
    }

    /// 预览弹窗打开/关闭时更新全局悬停抑制状态（防止卡片悬停放大浮窗穿透预览遮罩）
    private func updatePreviewOverlayState() {
        PreviewOverlayState.isShowing = app.previewingShotID != nil
            || app.previewingLibraryItemID != nil
            || app.previewingImageItemID != nil
            || app.previewingStandaloneImagePath != nil
    }

    /// 预览弹窗入场：**遮罩快速淡入 + 弹窗弹簧落位**（两者分开动）。
    /// 弹窗从 96%、下方 14pt 弹到原位——没有这一下空间位移，弹窗就是"凭空出现"，
    /// 那正是"不自然"的来源（跟翻页只有渐变没有方向感是同一类问题）。
    private func fadeInPreviewOverlay() {
        previewCloseWork?.cancel()
        withAnimation(.easeOut(duration: 0.14)) {
            previewOverlayOpacity = 1
        }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            previewPanelScale = 1
            previewPanelOffsetY = 0
        }
    }

    /// 淡出并关闭预览弹窗：遮罩快速淡出，弹窗**轻微回缩**着离开（不是原地淡掉）
    private func requestClosePreview() {
        previewCloseWork?.cancel()
        withAnimation(.easeIn(duration: 0.14)) {
            previewOverlayOpacity = 0
            previewPanelScale = 0.97
            previewPanelOffsetY = 8
        }
        let work = DispatchWorkItem {
            // 全屏状态下关预览：连带退出窗口全屏，否则会把人留在全屏里（只剩空工作区）
            if app.previewFullscreen {
                app.previewFullscreen = false
                if NSApp.mainWindow?.styleMask.contains(.fullScreen) == true {
                    NSApp.mainWindow?.toggleFullScreen(nil)
                }
            }
            app.previewingShotID = nil
            app.previewingLibraryItemID = nil
            app.previewingImageItemID = nil
            app.previewingStandaloneImagePath = nil
            app.previewingStandaloneImageFileName = nil
            app.stopPlayback()
            // 复位成**全透明**（不是 1）：下次打开的淡入是"从当前值动画到 1"，
            // 复位成 1 的话 1→1 等于没有动画 —— 弹窗会"啪"地全亮出现（用户反馈的"闪一下"）。
            previewOverlayOpacity = 0
            // 同理复位成"入场前的姿态"：下次打开才有从 96%/下移 14pt 弹进来的动画。
            previewPanelScale = 0.96
            previewPanelOffsetY = 14
        }
        previewCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// 用 NSEvent 监听双击顶部栏缩放窗口（hiddenTitleBar 下系统双击行为失效，需手动补）
    /// 双击缩放的**无动画版**。
    ///
    /// ⚠️ **不要换回 `window.zoom(nil)`**：它内部会跑 `NSMoveHelper _doAnimation`
    /// —— 一个**嵌套 run loop**，**主线程被阻塞整个动画时长**。
    /// 实测（2026-09-12，`sample` 抓的栈 + 日志双重对上）：
    /// 双击一次阻塞 **359ms**，缩回去再一次 **373ms**，
    /// 日志里 `[windowZoom]` 和 `[watchdog] 主线程卡顿` 的时间戳一一对应。
    ///
    /// 代价：失去系统那个缩放动画（双击后窗口直接到位）。
    /// 换来的是**双击不再卡**——这笔账划算。
    ///
    /// 副作用：`preZoomFrame` 是我们自己记的（`zoom(nil)` 用的是 AppKit 内部的记录），
    /// 所以"还原"回到的是**上一次双击前**的尺寸，与系统行为一致。
    private func zoomWithoutAnimation(_ window: NSWindow) {
        let full = window.screen?.visibleFrame ?? window.frame
        let isFilling = abs(window.frame.width - full.width) < 2
            && abs(window.frame.height - full.height) < 2
        if isFilling {
            window.setFrame(preZoomFrame ?? window.frame, display: true, animate: false)
        } else {
            preZoomFrame = window.frame
            window.setFrame(full, display: true, animate: false)
        }
        // ⚠️ **2026-09-27 修「双击缩回后内容还是放大时的布局、两边被裁」**：
        // `setFrame` 之后 SwiftUI 的内容**不保证重排**——日志实测：缩回 1160 宽后网格宽度还停在
        // 放大时的 1253（布局仍按 1658 排）→ 内容溢出、左右被裁。这里显式把窗口 + 内容视图标脏、
        // 立刻排一次，再在下一轮 runloop 兜一次（双保险）。
        forceRelayout(window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            forceRelayout(window)
        }
    }

    /// 强制窗口 + 内容视图重排（`setFrame` 程序化改尺寸后用；见 `zoomWithoutAnimation` 的注释）。
    private func forceRelayout(_ window: NSWindow) {
        window.layoutIfNeeded()
        if let cv = window.contentView {
            markNeedsLayoutRecursively(cv)
            cv.layoutSubtreeIfNeeded()
        }
    }

    private func markNeedsLayoutRecursively(_ view: NSView) {
        view.needsLayout = true
        for sub in view.subviews { markNeedsLayoutRecursively(sub) }
    }

    private func installDoubleClickMonitor() {
        guard doubleClickMonitor == nil else { return }
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.clickCount == 2,
               let window = event.window,
               !(window is NSPanel) {
                // 顶部栏区域（窗口坐标系，顶部 40pt 内）
                let topDistance = window.frame.height - event.locationInWindow.y
                if topDistance < 40 {
                    // ⚠️ **编辑中的双击不缩放**：那是在输入框里选词。
                    if isEditingName { return event }
                    // ⚠️ **双击"项目名"这块区域也不缩放**：名字现在是个按钮，
                    // 双击它是「进入编辑」的自然动作，而顶栏高 38pt 正好落在这 40pt 里 ——
                    // 不排除的话，双击名字会把窗口缩放掉（改内联编辑时才暴露出来的老问题）。
                    // 名字居中，所以按窗口水平中点 ± 半个宽度判定。
                    if app.isInWorkspace {
                        let half = max(nameTextWidth, 60) / 2 + 12
                        if abs(event.locationInWindow.x - window.frame.width / 2) < half {
                            return event
                        }
                    }
                    // ⚠️ **双击右侧按钮组也不缩放**：那一片全是按钮（模式切换 / 素材库 / 任务 / 设置），
                    // 双击它们只该触发按钮本身（用户要求"顶栏的按钮不参与双击放大")。
                    // 按实测宽度划界：按钮组贴右边，右边距 12pt（与 topBar 的 padding 一致）。
                    if event.locationInWindow.x > window.frame.width - topBarTrailingWidth - 12 {
                        return event
                    }
                    AppLog.write("windowZoom", "双击缩放前 frame=\(window.frame) contentSize=\(String(describing: window.contentView?.frame.size))")
                    zoomWithoutAnimation(window)
                    DispatchQueue.main.async {
                        AppLog.write("windowZoom", "缩放后 frame=\(window.frame) contentSize=\(String(describing: window.contentView?.frame.size))")
                    }
                    return nil
                }
            }
            return event
        }
    }

    /// 标题栏行（与红绿灯同行）：项目名居中，设置位于常驻左侧外框；空白可拖动窗口。
    private var topBar: some View {
        ZStack {
            // 底层：空白处按下可拖动窗口。
            //
            // ⚠️ **必须给按钮区让位**（实测结论，两次踩到）：
            // 这一层铺满顶栏、`mouseDownCanMoveWindow = true`，而**按住按钮拖动时，
            // SwiftUI 的按钮不消费那串拖拽事件** → 事件继续往下落到它身上 → 窗口被拖走
            //（用户实测："素材库、任务、设置三个按钮依然参与拖动"）。
            //
            // 那为什么之前撤回过一次？因为**首次点击语义原本是它顺带提供的**
            //（`acceptsFirstMouse` 默认 false），让位就把那条一起丢了。
            // **现在首次点击由 `FirstClickShield` 显式接管**，所以让位可以放心加回来 ——
            // 这两条各管一段，缺一不可：
            //   · `FirstClickShield`  → 从别的 App 点过来，第一下只激活
            //   · 这里的 padding     → 按住按钮拖动不拖走窗口
            WindowDragBackground()
                .padding(.trailing, topBarTrailingWidth + 12)
            // ⚠️ **捕获层必须放在这里**（WindowDragBackground 之上、按钮之下），不能写成
            // `topBar.background { drawerTopCatcher }`：
            // `WindowDragBackground` 是**真 AppKit 视图**，而 AppKit 视图永远在 SwiftUI 内容之上 ——
            // 挂在 `.background` 的捕获层会被它**整个盖住**，空白处的点击全被"拖窗口"吃掉，
            // 捕获层的 `onTapGesture` 一次都接不到 → 表现为"点顶栏空白关不掉抽屉"（用户实测）。
            // 放在这个位置：空白处落到捕获层 ✓、按钮/项目名在它之上照常响应 ✓。
            drawerTopCatcher
            if app.isInWorkspace, let key = app.currentProjectKey {
                HStack(spacing: 6) {
                    if isEditingName {
                        // 就地编辑：**不出现任何弹窗**。宽度跟着正在输入的文字走（打字时框子会变宽），
                        // 最小 80 免得空名字时框子缩成一条线。
                        TextField("", text: $editingName)
                            .textFieldStyle(.plain)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .frame(width: max(nameTextWidth + 20, 80))
                            .focused($nameFieldFocused)
                            .onSubmit { commitRename() }              // 回车保存
                            .onExitCommand { isEditingName = false }  // Esc 取消（不保存）
                            .background {
                                // 量"正在输入的文字"有多宽 —— 编辑框的宽度由它决定
                                Text(editingName.isEmpty ? " " : editingName)
                                    .font(.headline)
                                    .fixedSize()
                                    .opacity(0)
                                    .background {
                                        GeometryReader { g in
                                            Color.clear
                                                .onChange(of: g.size.width, initial: true) { _, w in
                                                    nameTextWidth = w
                                                }
                                        }
                                    }
                            }
                    } else {
                        // 名字本身就是按钮：**点击区域就是它自己**（所见即所点），
                        // 宽度天然跟着文字走。原来那个小铅笔已按用户要求去掉。
                        //
                        // ⚠️ 用 `TopBarButton` 而不是裸 `Button`：它是 SwiftUI 按钮，
                        // **不消费拖拽**且**无视浮层** —— 实测两个症状：任务抽屉开着时点名字照样进编辑、
                        // 按住名字拖动会把窗口拖走。`TopBarButton` 的 AppKit 罩子把这两条都解决了
                        //（罩子有浮层时只关浮层，见其注释）。
                        TopBarButton {
                            editingName = app.projectName(for: key)
                            isEditingName = true
                            nameFieldFocused = true
                        } label: {
                            Text(app.projectName(for: key))
                                .font(.headline)
                                .lineLimit(1)
                        }
                        // 非编辑态也要知道名字多宽 —— 双击缩放那边要避开这块区域
                        .background {
                            GeometryReader { g in
                                Color.clear
                                    .onChange(of: g.size.width, initial: true) { _, w in
                                        nameTextWidth = w
                                    }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                // 焦点丢了就保存（"点其他地方保存"）。**那一下点击照常生效** ——
                // 编辑框不是弹层，不适用「点外面只是关掉它、不再触发别的」那条规则，
                // 否则又会变成"点一下没反应"（用户最反感的那种手感）。
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused, isEditingName { commitRename() }
                }
            }
            // 顶栏不放页面切换或工具按钮；页面切换统一放在下方内容第一行。
            HStack(spacing: 10) {
                Spacer()
                // ⚠️ 外面套着 `Spacer()`，所以这层 HStack 承载**顶栏右侧内容**，
                // 同时用于量宽：双击缩放 / 拖窗口都要避开这块的实际占宽（见 `topBarTrailingWidth`）。
                // 2026-10-06 P2：剧本 AI 状态搬进任务抽屉（左栏任务图标带角标），顶栏这里暂时空着。
                HStack(spacing: 10) {
                    // 批量分割 / 提取素材的进度和结果（2026-10-07）：软件右上角，项目名那一行的右边
                    if app.isInWorkspace, let key = app.currentProjectKey {
                        BatchStatusLabel(project: key)
                    }
                }
                // 量出按钮组实际占多宽（双击缩放要避开这块，见 `topBarTrailingWidth`）
                .background {
                    GeometryReader { g in
                        Color.clear.onChange(of: g.size.width, initial: true) { _, w in
                            topBarTrailingWidth = w
                        }
                    }
                }
            }
            .padding(.trailing, 12)
        }
        .frame(height: AppWindowShellLayout.titleBarHeight)
        // 顶栏直接露出全局窗口背景，与页面保持一致。
    }

    /// 项目工作区容器：顶部「生图/生视频」切换 + 对应内容 + 可收起任务抽屉
    /// 抽屉打开时，铺在**两条顶栏**上的点击捕获层。
    ///
    /// 为什么需要它：`workspaceContainer` 里那层捕获层只铺在内层 ZStack 上，而
    /// `topBar`（红绿灯那条）和 `modeSwitcher`（「任务」按钮那条）在它**外面** ——
    /// 点这两条没有任何东西接住，抽屉关不掉（用户实测）。
    /// 抽屉的纵向范围从 `modeSwitcher` **之下**才开始（实测 y=74 = 顶栏 38 + 工作区顶栏 36），
    /// 所以这两层捕获层**不会盖到抽屉本身**，可以放心铺满整条。
    ///
    /// 它会**消费掉**这一下点击（不再同时触发别的按钮）—— 与下拉面板规则统一：
    /// 「弹层开着时，点外面只是关掉它」。
    @ViewBuilder
    private var drawerTopCatcher: some View {
        if app.showTaskDrawer {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { app.toggleTaskDrawer() }
                }
        }
    }

    // MARK: 页壳：共享右侧栏 + 共享底栏（2026-09-27 用户定）
    //
    // ⚠️ 右栏本体在 `WorkspacePanelColumn`（独立子视图）：
    // 页壳**不读条目列表**，切开"每秒重算页壳 → 连累两个面板"的链（2026-09-27 实测日志确认过这条链）。

    /// 共享底栏的「批量匹配完成」提示（原来在 GenerateView 的 info alert 里）
    @State private var shellInfoTitle = ""
    @State private var shellInfoMessage = ""
    @State private var shellShowInfo = false
    /// 选中工具条的两个确认框（2026-09-27 从两个页面搬过来）
    @State private var showBatchDeleteConfirm = false
    @State private var showBatchSubmitConfirm = false
    /// 提交确认里多说的那一句（有素材图还没挂上的），**弹确认的时候算一次**存在这里。
    /// 原来写成计算属性放在确认框文案里：`RootView` 每重画一次（开关任何弹窗都会）就把整个工作台状态算一遍，
    /// 大项目一次一百多毫秒——开关编辑提示词弹窗卡就是它（2026-10-14 用户实测）
    @State private var batchSubmitNote = ""
    /// 批量匹配前要先入库的张数（> 0 = 在等确认）
    @State private var batchMatchPendingLibrary = 0
    /// 批量入库的二次确认 + 待入库 ID（2026-09-28；ID 先存下来，避免确认框打开期间选中变化）
    @State private var showBatchSaveToLibraryConfirm = false
    @State private var batchSaveToLibraryIDs: [UUID] = []
    /// 批量入库预检没过时的提示框（2026-10-09 起单独一个：只差「已入库过」的，多一个「跳过已入库」按钮）
    @State private var showBatchSaveIssue = false
    @State private var batchSaveIssueMessage = ""
    /// 跳过已入库之后剩下要存的卡（空 = 这次没有这个按钮）
    @State private var batchSaveSkippingIDs: [UUID] = []

    /// **共享底栏**（2026-09-27 用户定：四个页面共用一个底栏）——
    /// **没选中** = 按模式换按钮；**选中** = 视频、生图各四个按钮（含取消）。
    /// 宽度弹簧收放 + 内容交叉淡入由 `WorkspaceBar` 里的动画负责（同一个胶囊内换内容才跟手）。
    private var sharedToolbar: some View {
        WorkspaceBar(selectionContent: AnyView(selectionButtons), showsSelection: hasSelection) {
            if app.workspaceMode == .video {
                BarIconButton(icon: "doc.badge.plus", help: "导入分镜（粘贴或拖入 txt 剧本）") {
                    app.activeModal = .batchParseShots
                }
                BarIconButton(icon: "plus", help: "新增分镜") {
                    app.addShotAndInspect()
                }
                ToolbarGenerationParams()      // 右栏正在看的那张分镜的生成参数 + 提交生成（2026-10-08 从右栏底部搬来）
            } else {
                BarIconButton(icon: "doc.badge.plus", help: "批量解析（粘贴文本）") {
                    app.activeModal = .batchParse
                }
                BarIconButton(icon: "plus", help: "新增图片") {
                    app.addImageItem()
                }
                ToolbarGenerationParams()      // 右栏正在看的那张图片的生成参数 + 提交生成（2026-10-08 从右栏底部搬来）
            }
            // 提示：选中后整条换成批量按钮（视频、生图各四个，含取消）；
            // 清空 = 全选 → 删除（工具条上的垃圾桶已删）。
        }
    }

    /// 批量操作的确认框和后续流程（删除确认、批量设参数应用后接着确认提交、入库前询问、结果提示）。
    /// 2026-10-14 从工具条上拆下来、挂在窗口最外层：工作台分镜网格的批量条也用它（工具条在生图 / 生视频页里，工作台上它不在）
    private var batchDialogs: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        // 工作台批量条点的按钮（见 `AppModel.shotBatchRequest`）
        .onChange(of: app.shotBatchRequest) { _, request in
            guard let request else { return }
            switch request.action {
            case .delete: showBatchDeleteConfirm = true
            case .match: prepareBatchMatch()
            case .submit: startBatchSubmit()
            }
        }
        // 批量设置参数点了「应用」→ 接着检查、弹提交确认（等弹窗这一拍收掉再弹）
        .onChange(of: app.batchParamsAppliedForSubmit) { _, _ in
            DispatchQueue.main.async { prepareBatchSubmit() }
        }
        // 删除 / 提交的确认框（文案与原来两个页面里的完全一致）+ 通用信息提示
        .alert(app.batchTargetsShots ? "删除选中的分镜？" : "删除选中的图片？",
               isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除 \(selectionCount) 个", role: .destructive) {
                // ⚠️ 按「当前项目里真正选中」的条目来删（2026-09-27 修）：
                // 不再直接拿集合去 for —— `deleteShot` / `removeImageItem` 都是**按 ID 全局删**的，
                // 集合里万一残留别的项目的 ID 就会误删那边的条目（方案 B 下集合已按项目/筛选约束，
                // 这里再上一道保险；计数与真正删掉的数量也就永远一致了）。
                if app.batchTargetsShots {
                    let targets = app.currentShots.filter { app.selectedShotIDs.contains($0.id) }
                    for shot in targets { app.deleteShot(id: shot.id) }
                    app.selectedShotIDs.removeAll()
                } else {
                    let targets = app.currentImageItems.filter { app.selectedImageItemIDs.contains($0.id) }
                    for item in targets { app.removeImageItem(id: item.id) }
                    app.selectedImageItemIDs.removeAll()
                }
            }
        } message: {
            Text(app.batchTargetsShots
                 ? "将删除这 \(selectionCount) 个分镜及其任务记录，此操作不可撤销。"
                    + (app.isScriptPageVisible ? "删掉的那几段会变成「待推理分镜」，要单独重新推理那一段才会补回分镜。" : "")
                 : "将删除这 \(selectionCount) 个图片条目及其生成结果，此操作不可撤销。")
        }
        .alert("批量提交确认", isPresented: $showBatchSubmitConfirm) {
            // 刚才设的参数是草稿（D08）：取消 = 参数也不改；「只保存参数」= 不提交、参数留下
            Button("取消", role: .cancel) { app.revertBatchParamDraft() }
            Button("只保存参数") { app.keepBatchParamDraft() }
            Button("提交 \(selectionCount) 个") {
                app.keepBatchParamDraft()
                if app.batchTargetsShots {
                    let targets = app.currentShots.filter { app.selectedShotIDs.contains($0.id) }
                    app.batchSubmitExecute(shots: targets)
                    // 🆕 2026-10-03（用户定）：提交成功后**清空选择**——底栏批量条自动收起，
                    // 不用再手动点一次「取消」（用户实测痛点）
                    app.selectedShotIDs.removeAll()
                    shellInfoTitle = "批量提交已发起"
                    shellInfoMessage = "已提交 \(targets.count) 个分镜。"
                    shellShowInfo = true
                } else {
                    let targets = app.currentImageItems.filter { app.selectedImageItemIDs.contains($0.id) }
                    // 模型对账：有模型已从配置删除的 → 先提示，不发送（同原逻辑）
                    let stale = targets.filter { !imageModelConfigured($0) }
                    if !stale.isEmpty {
                        shellInfoTitle = "请先选择模型"
                        shellInfoMessage = "有 \(stale.count) 个条目的模型已不在配置里。请先在卡片上重新选择模型再提交。"
                        shellShowInfo = true
                    } else {
                        for item in targets {
                            app.requestImageGeneration(item.id)
                        }
                        // 🆕 2026-10-03（用户定）：提交成功后清空选择（底栏批量条自动收起）；
                        // "请先选择模型"那条失败路径**不清**，方便继续处理
                        app.selectedImageItemIDs.removeAll()
                    }
                }
            }
        } message: {
            Text(app.batchTargetsShots
                 ? "将按刚才设的参数提交选中的 \(selectionCount) 个分镜，会产生费用。点「取消」参数也不改。" + batchSubmitNote
                 : "将按刚才设的参数提交选中的 \(selectionCount) 个图片条目，会产生费用。点「取消」参数也不改。")
        }
        // 批量匹配：选中的里有还没入库的图 → 先问一句（和工作台「匹配」「应用素材」一样，视频生成要用素材库里的图）
        .alert("有 \(batchMatchPendingLibrary) 张图还没入库", isPresented: Binding(get: { batchMatchPendingLibrary > 0 }, set: { if !$0 { batchMatchPendingLibrary = 0 } })) {
            Button("入库并匹配") { runBatchMatch() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("匹配时会先存进素材库（后台上传，进度在素材库底部），视频生成才拿得到这些参考图。")
        }
        // 批量入库：二次确认（2026-09-28 用户定；只有预检全过才会走到这里）
        .alert("批量入库确认", isPresented: $showBatchSaveToLibraryConfirm) {
            Button("取消", role: .cancel) { batchSaveToLibraryIDs = [] }
            Button("保存 \(batchSaveToLibraryIDs.count) 张") {
                let ids = batchSaveToLibraryIDs
                batchSaveToLibraryIDs = []
                saveBatchToLibrary(ids)
            }
        } message: {
            Text("将把选中的 \(batchSaveToLibraryIDs.count) 张保存到素材库（每张存它当前显示的那一版）。")
        }
        // 批量入库预检没过：只差「已入库过」的，可以一键跳过它们、存其余的（按钮上写明张数，点了就存，不再二次确认）
        .alert("无法批量入库", isPresented: $showBatchSaveIssue) {
            if !batchSaveSkippingIDs.isEmpty {
                Button("跳过已入库，保存其余 \(batchSaveSkippingIDs.count) 张") {
                    let ids = batchSaveSkippingIDs
                    batchSaveSkippingIDs = []
                    saveBatchToLibrary(ids)
                }
            }
            Button("好", role: .cancel) { batchSaveSkippingIDs = [] }
        } message: {
            Text(batchSaveIssueMessage)
        }
        .alert(shellInfoTitle, isPresented: $shellShowInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shellInfoMessage)
        }
    }

    /// **选中时的批量按钮**（视频、生图各四个，含取消；塞进同一个工具条胶囊里）。
    /// 按钮本身是 `SelectionBarIconButton` / `SelectionBarCancelButton`（主页的多选条共用同一套）。
    private var selectionButtons: some View {
        // 2026-09-29 用户：「间隔太大了」→ 28 → **16**
        HStack(spacing: 16) {
            SelectionBarIconButton(icon: "trash", color: Theme.danger, help: "删除选中") {
                showBatchDeleteConfirm = true
            }
            if app.batchTargetsShots {
                SelectionBarIconButton(icon: "wand.and.stars", help: "批量匹配素材（只对选中的 \(selectionCount) 个分镜）") {
                    prepareBatchMatch()
                }
            }
            // 批量提交生成：**只对选中的生效**（2026-09-26 用户定）。
            // 2026-10-12 用户定：「批量设置参数」并进来——先弹批量设置参数，点「应用」后再弹提交确认（见 `batchParamsAppliedForSubmit`）
            SelectionBarIconButton(icon: "paperplane.fill", color: Theme.accent, help: "批量提交生成（只对选中的 \(selectionCount) 个；先设参数，再确认）") {
                startBatchSubmit()
            }
            // 批量入库：**只对生图侧**（2026-09-28 用户定；"入库"是生图专有）。
            // 校验/确认/汇总逻辑见 `prepareBatchSaveToLibrary()`：
            // 全有全无 —— 有任何一张不能入（无类型/没结果/已入库/文件缺失）只弹提示、不提交。
            if !app.batchTargetsShots {
                // 图标和左栏「上传测试」同一个（icloud.and.arrow.up；2026-10-08 用户："批量入库的图标和上传测试的不一致，以上传测试的为准"）
                SelectionBarIconButton(icon: "icloud.and.arrow.up",
                                       help: "批量保存到素材库（只对选中的 \(selectionCount) 个；每张存当前显示的那一版）") {
                    prepareBatchSaveToLibrary()
                }
            }
            SelectionBarCancelButton { clearSelection() }
        }
    }

    /// 当前模式的选中集合是否非空 / 数量（决定工具条内容）
    private var hasSelection: Bool {
        app.batchTargetsShots ? !app.selectedShotIDs.isEmpty : !app.selectedImageItemIDs.isEmpty
    }
    private var selectionCount: Int {
        app.batchTargetsShots ? app.selectedShotIDs.count : app.selectedImageItemIDs.count
    }

    private func clearSelection() {
        if app.batchTargetsShots { app.selectedShotIDs.removeAll() } else { app.selectedImageItemIDs.removeAll() }
    }

    private func setBatchParamScope() {
        if app.batchTargetsShots {
            app.batchShotScopeIDs = Array(app.selectedShotIDs)
        } else {
            app.batchImageScopeIDs = Array(app.selectedImageItemIDs)
        }
    }

    /// 点「批量提交」：参数改不好的问题（没提示词、正在生成中）先拦住，免得设完参数才说不能提交；
    /// 都没有就弹批量设置参数，应用之后再走 `prepareBatchSubmit` 的完整检查和确认
    private func startBatchSubmit() {
        let reasons = batchSubmitBlockers(includingParams: false)
        guard reasons.isEmpty else { showBatchSubmitBlocked(reasons); return }
        setBatchParamScope()
        app.activeModal = .batchParam
    }

    /// 批量设置参数点了「应用」之后：完整检查一遍（含模型、时长），都满足就弹提交确认
    private func prepareBatchSubmit() {
        let reasons = batchSubmitBlockers(includingParams: true)
        guard reasons.isEmpty else {
            // 按刚才的参数交不了 → 这次设的参数也不留（D08：没交就不变）
            app.revertBatchParamDraft()
            showBatchSubmitBlocked(reasons, note: "刚才设的参数没有保存。")
            return
        }
        batchSubmitNote = app.batchTargetsShots ? unmatchedSelectionNote : ""
        showBatchSubmitConfirm = true
    }

    private func showBatchSubmitBlocked(_ reasons: [String], note: String = "") {
        shellInfoTitle = "还不能提交"
        shellInfoMessage = "选中的\(app.batchTargetsShots ? "分镜" : "条目")里有 \(reasons.joined(separator: "、"))。请先处理再提交。" + note
        shellShowInfo = true
    }

    /// 选中的里面不能提交的原因：**有任何一个不满足条件就直接拦住**（2026-09-26 用户定；
    /// 2026-09-27 从两个页面搬到这里——工具条要随选中态换内容）。
    /// `includingParams` = false 时只看批量设置参数改不了的（没提示词、正在生成中）
    private func batchSubmitBlockers(includingParams: Bool) -> [String] {
        var reasons: [String] = []
        if app.batchTargetsShots {
            let targets = app.currentShots.filter { app.selectedShotIDs.contains($0.id) }
            let invalid = targets.filter { !ShotValidator.validate($0).isEmpty || !videoModelConfigured($0) }
            let busy = targets.filter { shot in
                guard let t = shot.taskID.flatMap({ app.store.task(id: $0) }) else { return false }
                return t.phase == .queued || t.phase == .inProgress
            }
            if includingParams, !invalid.isEmpty { reasons.append("\(invalid.count) 个不满足条件（缺模型 / 时长不在 1~30）") }
            if !busy.isEmpty { reasons.append("\(busy.count) 个正在生成中") }
        } else {
            let targets = app.currentImageItems.filter { app.selectedImageItemIDs.contains($0.id) }
            var noPrompt = 0
            var modelIssue = 0
            var busy = 0
            for item in targets {
                if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { noPrompt += 1 }
                if !imageModelConfigured(item) { modelIssue += 1 }
                if item.status.isBusy { busy += 1 }
            }
            if noPrompt > 0 { reasons.append("\(noPrompt) 个没提示词") }
            if includingParams, modelIssue > 0 { reasons.append("\(modelIssue) 个没选模型（或模型已失效）") }
            if busy > 0 { reasons.append("\(busy) 个正在生成中") }
        }
        return reasons
    }

    /// 选中的分镜里有素材图却还没挂上的（重新推理会清掉参考图）：提交确认里多说一句
    private var unmatchedSelectionNote: String {
        guard let key = app.currentProjectKey, let archive = app.currentPipelineArchive, !archive.episodes.isEmpty else { return "" }
        let count = WorkbenchBatch.unmatchedCount(board: app.workbenchBoard(project: key, archive: archive), shotIDs: app.selectedShotIDs)
        return count > 0 ? "\n\n其中 \(count) 个有素材图还没挂上（比如重新推理过），视频里不会带这些参考图；要带的话先点「批量匹配」。" : ""
    }

    /// 生视频页拖选的「批量匹配」（2026-10-12 用户：和工作台工具条的「匹配」一样改）：
    /// 属于某一集的分镜按头行里的名字挂它该用的那一版卡（没入库的先入库）；生视频页自己新建、不属于任何一集的，照旧按素材库名字匹配
    private func batchMatchPlan() -> (plan: [WorkbenchBatch.MatchItem], others: Set<UUID>) {
        let selected = app.selectedShotIDs
        guard let key = app.currentProjectKey, let archive = app.currentPipelineArchive, !archive.episodes.isEmpty else { return ([], selected) }
        let plan = WorkbenchBatch.matchPlan(board: app.workbenchBoard(project: key, archive: archive), shotIDs: selected, app: app)
        return (plan, selected.subtracting(plan.map(\.shotID)))
    }

    private func prepareBatchMatch() {
        let pending = WorkbenchBatch.matchNeedsLibrary(batchMatchPlan().plan, app: app)
        if pending > 0 { batchMatchPendingLibrary = pending } else { runBatchMatch() }
    }

    private func runBatchMatch() {
        batchMatchPendingLibrary = 0
        let (plan, others) = batchMatchPlan()
        let workbench = WorkbenchBatch.match(plan, app: app)
        let byName = others.isEmpty ? AppModel.BatchMatchReport(shotCount: 0, totalMatched: 0) : app.batchAutoMatch(shotIDs: others)
        var message = "共处理 \(workbench.shots + byName.shotCount) 个分镜，挂上 \(workbench.applied + byName.totalMatched) 个素材。"
        if workbench.withoutImage > 0 { message += "还有 \(workbench.withoutImage) 个名字没有图，没挂（先提取、出图）。" }
        if workbench.notInHeadLine > 0 { message += "\(workbench.notInHeadLine) 个在分镜头行里找不到名字。" }
        shellInfoTitle = "批量匹配完成"
        shellInfoMessage = message
        shellShowInfo = true
    }

    /// 点「批量入库」：先**整体预检**（全有全无，2026-09-28 用户定）——
    /// 有任何一张不能入库（无类型 / 没结果 / 已入库过 / 文件缺失）就**只弹提示、不提交**；
    /// 全部可入才弹二次确认。每张存"当前显示的那一版"（见 `batchSaveImageItemsToLibrary`）。
    private func prepareBatchSaveToLibrary() {
        let targets = app.currentImageItems.filter { app.selectedImageItemIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        let issues = app.batchSaveLibraryIssues(for: ids)
        guard issues.isEmpty else {
            let skipping = app.batchSaveIDsSkippingSaved(ids) ?? []
            batchSaveSkippingIDs = skipping
            if issues.alreadySaved == targets.count {
                batchSaveIssueMessage = "选中的 \(targets.count) 张当前显示的那一版都已经入库过了，没有要保存的。"
            } else if skipping.isEmpty {
                batchSaveIssueMessage = "选中的 \(targets.count) 张里有：" + issues.summary
                    + "。批量入库要求选中的全部都能入库，不跳过任何一张。"
            } else {
                batchSaveIssueMessage = "选中的 \(targets.count) 张里有：" + issues.summary
                    + "。可以跳过已入库的，只保存其余 \(skipping.count) 张。"
            }
            showBatchSaveIssue = true
            return
        }
        batchSaveToLibraryIDs = ids
        showBatchSaveToLibraryConfirm = true
    }

    /// 执行批量入库并弹结果（二次确认框和「跳过已入库」按钮共用）
    private func saveBatchToLibrary(_ ids: [UUID]) {
        let saved = app.batchSaveImageItemsToLibrary(ids)
        shellInfoTitle = "批量入库完成"
        shellInfoMessage = (saved == ids.count
            ? "已保存 \(saved) 张到素材库。"
            : "已保存 \(saved)/\(ids.count) 张；有 \(ids.count - saved) 张没能保存（可在素材库查看或重传）。")
            + (app.libraryUploadBatch.isRunning ? "正在后台上传，进度在素材库底部。" : "")
        shellShowInfo = true
    }

    /// 模型与配置对账（同两个页面原来的口径）
    private func videoModelConfigured(_ shot: ShotDraft) -> Bool {
        !app.videoModelNames.isEmpty && app.videoModelNames.contains(shot.model)
    }
    private func imageModelConfigured(_ item: ImageGenItem) -> Bool {
        guard !app.imageModelNames.isEmpty else { return false }
        guard let m = item.model, !m.isEmpty else { return true }
        return app.imageModelNames.contains(m)
    }

    private var mediaState: MediaWorkspacePresentation.State? {
        mediaPresentation.resolve(projectKey: app.currentProjectKey, visible: app.isProductionWorkspaceVisible,
                                  mode: app.isFreeCreation ? .video : app.workspaceMode)
    }

    private func workspaceContainer(_ state: MediaWorkspacePresentation.State) -> some View {
        HStack(spacing: 4) {
            ZStack {
                // 各页第一次实际访问才创建；同一项目内切换保留筛选、滚动等 @State。
                if state.hasVideo {
                    workspace
                        .frame(maxWidth: .infinity)
                        .opacity(state.mode == .video ? 1 : 0)
                        .allowsHitTesting(state.mode == .video)
                }
                if state.hasImages {
                    imageWorkspace
                        .frame(maxWidth: .infinity)
                        .opacity(state.mode == .image ? 1 : 0)
                        .allowsHitTesting(state.mode == .image)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 右侧详情栏已去掉（2026-10-26 用户：生图 / 生视频都改成单击缩略图开编辑弹窗，信息都在弹窗里）
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if app.isProductionWorkspaceVisible { sharedToolbar }
        }
        .frame(minWidth: 640, minHeight: AppWindowShellLayout.contentMinimumHeight)
    }

    /// 视频页（**存成属性**：模式切换只翻透明度，不重建页面——2026-09-27 用户要求"跟卡片/缩略图一样"）。
    /// 视图值的构造是廉价的；上面按实际访问控制它进入视图树。
    private let workspace = GenerateView()

    /// 生图页（同上：存成属性，切模式不重算）
    private let imageWorkspace = ImageWorkspaceView()
}

/// 窗口毛玻璃底（AppKit 的 `NSVisualEffectView`，Finder 侧栏 / 系统设置用的就是它）。
///
/// **为什么不用 SwiftUI 的 `.glassEffect`**：液态玻璃的边缘反光是去不掉的一条"边线"
/// （`Glass` 只有 `.regular` / `.clear` / `.tint()` / `.interactive()` 四个旋钮，**没有关边缘的开关**），
/// 之前因此把整窗改成了实底。`NSVisualEffectView` **不画描边、不画边缘反光、没有内高光** ——
/// "不要边线"这条是天然满足的，不是妥协。
///
/// `blendingMode = .behindWindow` 要求窗口**非不透明**（`isOpaque = false` + 背景清空，见 RootView.onAppear），
/// 否则毛玻璃采不到桌面，只会糊成一片灰。
final class WindowBackdropView: NSVisualEffectView {
    /// 纯背景层，不吃鼠标事件：它铺满整窗，若参与命中测试会挡住上层的点击与拖窗。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 上一次记录的尺寸，只在变化时写日志（`layout()` 每帧都调，不拦会刷爆日志）
    private var lastLoggedSize: NSSize = .zero

    /// **诊断 + 自愈**：窗口属性可能在 RootView.onAppear 之后被 SwiftUI 重置，
    /// 一旦 `isOpaque` 回到 true，窗口就用自己的不透明底色盖住一切 —— 表现正是"死灰一片、
    /// 既看不到壁纸也看不到模糊"。这里在视图真正落进窗口树时再核对一次，不对就补设。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            AppLog.write("backdrop", "didMoveToWindow: window=nil —— 视图没进窗口树（那就是尺寸/层级问题）")
            return
        }
        AppLog.write("backdrop", "didMoveToWindow: isOpaque=\(window.isOpaque)"
            + " bgAlpha=\(window.backgroundColor.alphaComponent)"
            + " titlebarTransparent=\(window.titlebarAppearsTransparent)"
            + " fullSizeContent=\(window.styleMask.contains(.fullSizeContentView))"
            + " material=\(material.rawValue) blending=\(blendingMode.rawValue) state=\(state.rawValue)"
            + " frame=\(frame)")
        if GlassEffectSetting.isEnabled {
            if window.isOpaque || window.backgroundColor.alphaComponent > 0.01 {
                window.isOpaque = false
                window.backgroundColor = WindowBackdrop.windowBackground
                AppLog.write("backdrop", "→ 窗口属性确实被重置过，已在 didMoveToWindow 补设为非不透明 + 近全透明底")
            }
        } else {
            // 玻璃效果关掉：藏掉模糊层，窗口用纯色底（浅色白 / 深色深底）
            setSolidMode(true)
        }
        // ⚠️ **别在这里做"窗口淡入"**（曾经试过 `window.alphaValue = 0` + 在 `RootView.onAppear` 里动画）：
        // 实测这个回调发生在 `RootView.onAppear` **之后**（②@251ms → 这里@267ms），也就是**窗口早就显示了**，
        // 于是只能做出"先亮、又被设回 0、再靠兜底亮回来"的怪效果（用户实测"看不出效果"）。
        // 淡入改在 SwiftUI 层做（`RootView.launchOpacity`：窗口照常立刻出现，只让内容渐显）。
    }

    override func layout() {
        super.layout()
        if abs(frame.width - lastLoggedSize.width) > 1 || abs(frame.height - lastLoggedSize.height) > 1 {
            lastLoggedSize = frame.size
            AppLog.write("backdrop", "layout: frame=\(frame) hidden=\(isHidden) alpha=\(alphaValue)")
        }
    }

    /// 玻璃效果关掉时的处理：**藏掉模糊层**，窗口底色换成纯色（浅色白 / 深色深底）。
    /// 开着时恢复：显示模糊层 + 近全透明底（`.behindWindow` 采样桌面的前提）。
    func setSolidMode(_ solid: Bool) {
        isHidden = solid
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = solid
            ? SolidTheme.windowBackgroundColor()
            : WindowBackdrop.windowBackground
    }
}

struct WindowBackdrop: NSViewRepresentable {
    /// 玻璃效果开关（设置里切）：关掉 → 藏掉模糊层 + 窗口用纯色底
    var enabled: Bool = true
    /// 当前主题（原始值）。**必须传进来**：主题变了窗口底也要重设，
    /// 否则 SwiftUI 内容已换色、窗口还停在旧色（用户实测"界面和窗口不是同时变"）。
    var theme: String = AppTheme.dark.rawValue
    /// 窗口底色。
    ///
    /// **不能用 `.clear`**：theme frame / borderView 会因此**关掉圆角遮罩**，
    /// 导致 WindowServer 为非不透明窗口重算"真实形状" → **窗口缩放严重卡顿**，
    /// 而且四角的圆角也跟着失守。用"几乎全透明的白"既保透明又保住遮罩。
    static let windowBackground = NSColor.white.withAlphaComponent(0.001)

    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView()
        // `.underWindowBackground`：整窗底的那种材质，随系统浅/深色自动切。
        // ⚠️ **改回 `.underWindowBackground`（2026-09-12）**：试过 `.sidebar`，用户实测**没改善**，
        // 所以材质这条线**不是主因**（改它只会白折腾）。真正能动的是下面那层色调，
        // 外框浓度由 AppWindowShellLayout.frostedTintOpacity 控制。
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        // `.active`（不是 `.followsWindowActiveState`）：所有已知可用的配方都用这个。
        // `.followsWindowActiveState` 在窗口非 key/main 时会切成"失焦变体"，
        // 那种变体更不透明——排查模糊失效时不该引入这个变量。
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: WindowBackdropView, context: Context) {
        // 设置里切「玻璃效果」或「主题」时 RootView 会重算 → 这里跟着切模糊/纯色 + 窗口底色。
        // ⚠️ 全部在 SwiftUI 的这次更新里做完，别再去 `AppThemeStore.apply()` 里直接改窗口
        //（那样是两条路径、时序对不上 → 用户看到"界面和窗口不是同时变"）。
        nsView.setSolidMode(!enabled)
    }
}

/// **sheet（独立 NSWindow）专用的毛玻璃底**。用法：`.presentationBackground { SheetGlass() }`
///
/// 为什么不能照搬 `.glassPanel()`：sheet 是**独立窗口**，液态玻璃采样的是**本窗口内它背后的内容**，
/// 而 sheet 里面板背后什么都没有 → 结果是一块**没糊起来的纯色 + 一条去不掉的边缘反光（"边线"）**。
/// （原来的代码用 `.presentationBackground(.clear)` 想让主窗透上来，但那只解决了"窗口底色"，
///   没解决"玻璃采样的是窗口内"这件事。）
///
/// 要真糊起来必须走 `.behindWindow`（采样**窗口后面**的主窗内容），而这前提是
/// **sheet 的窗口非不透明** —— 那个 NSWindow 是 AppKit 建的、我们拿不到引用，
/// 所以由这个视图在自己的 `viewDidMoveToWindow` 里**自己找窗口**并配置（同 WindowBackdrop 的配方）。
final class SheetGlassView: NSVisualEffectView {
    /// 纯背景，不吃点击（铁律：塞进 SwiftUI 的 AppKit 视图默认都该如此）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            AppLog.write("sheetGlass", "viewDidMoveToWindow: window=nil")
            return
        }
        window.isOpaque = false
        window.backgroundColor = GlassEffectSetting.isEnabled
            ? WindowBackdrop.windowBackground
            : SolidTheme.windowBackgroundColor()
        AppLog.write("sheetGlass", "已配置 sheet 窗口: class=\(type(of: window))"
            + " isOpaque=\(window.isOpaque) bgAlpha=\(window.backgroundColor.alphaComponent)")
    }
}

struct SheetGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> SheetGlassView {
        let view = SheetGlassView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: SheetGlassView, context: Context) {}
}

/// **浮层毛玻璃**：糊的是"同一个窗口里、位于它下面的内容"（`.withinWindow`），
/// 而不是靠不透明度去盖卡片。
///
/// 和 `WindowBackdrop`（`.behindWindow`，糊窗口后面的桌面）是**两种不同的模糊**，别混：
/// 这个对应的是 macOS 工具条 / 侧栏的做法 —— 底下的卡片仍会透出来一点、但被糊掉，
/// 所以既读得清又有玻璃质感，而且**不靠 alpha**，不存在"0.96 还是 0.97"那种没法定的问题。
///
/// ⚠️ **必须 `hitTest` 返回 nil（和 `WindowBackdropView` 一样）**。
///
/// 曾经想当然地"不拦"、让它吃掉点击，理由是"抽屉底下是卡片列表、点空白处不能穿透"——
/// **错的**：那个职责本来就由 SwiftUI 那层 `.contentShape(Rectangle())` 承担，与背景是不是 NSView 无关。
/// 插一个会吃点击的 NSView 进去，等于在 SwiftUI 的手势体系里多插了一只手，
/// 直接打断了「点外面关闭抽屉」那条链（用户实测：任务列表打开后点外面关不掉）。
/// **教训：往 SwiftUI 里塞 AppKit 视图时，默认让 `hitTest` 返回 nil，除非确认它必须接收事件。**
final class FrostedPanelView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 浮层毛玻璃的 SwiftUI 入口（2026-09-19 起包了一层）：设置里关掉「玻璃效果」时直接给纯色，
/// 不再装 NSVisualEffectView（那样最省，也不会有任何模糊）。
struct FrostedPanel: View {
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme
    /// `.sidebar` 是苹果为"侧栏背景"指定的材质（文档明确：侧栏背景就用它）。
    var material: NSVisualEffectView.Material = .sidebar

    var body: some View {
        if glassEnabled {
            FrostedPanelRepresentable(material: material)
        } else {
            SolidTheme.overlay(colorScheme)
        }
    }
}

struct FrostedPanelRepresentable: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> FrostedPanelView {
        let view = FrostedPanelView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: FrostedPanelView, context: Context) {}
}

/// RootView 挂载的**应用内浮层**：设置 + 批量设置参数（替代原来的 `.sheet`）。
///
/// 单独抽成一个 `ViewModifier` 只有一个原因：**RootView.body 的修饰符链太长，
/// 把两段浮层直接写上去会让 Swift 类型检查器超时**（报
/// `unable to type-check this expression in reasonable time`）。拆开后既快又清楚。
///
/// 两个都挂在**根视图**：浮层要盖住整窗，挂在工作区里只盖得住中栏。
private struct RootModals: ViewModifier {
    @Environment(AppModel.self) private var app

    /// Esc 统一路由的监听句柄（全 App 只装这一个，见 `installEscRouter`）
    @State private var escRouter: Any?
    /// 窗口内容区大小（段落详情的尺寸按它算）
    @State private var windowSize: CGSize = CGSize(width: 1275, height: 796)

    /// `activeModal != nil` ↔ 浮层显示。点遮罩关闭时写回 nil。
    private var isPresented: Binding<Bool> {
        Binding(
            get: { app.activeModal != nil },
            set: { if !$0 { app.activeModal = nil } }
        )
    }

    private var stackedPresented: Binding<Bool> {
        Binding(get: { app.stackedImageEditorID != nil }, set: { if !$0 { app.stackedImageEditorID = nil } })
    }

    /// 各浮层的尺寸（nil = 由内容撑）
    private var size: (width: CGFloat?, height: CGFloat?) {
        switch app.activeModal {
        case .settings:                                  return (860, 610)
        case .editVideoPrompt:                           return (AppWindowShellLayout.promptModalWidth, nil)
        // 生图的编辑提示词 2026-10-26 改成两栏：宽度由内容定（最宽 1000，窗口窄了跟着缩，见 `EditImagePromptSheet`）
        case .editImagePrompt:                           return (nil, nil)
        // 段落详情：和工作台里点开的同一个大小（见 `PipelinePage.segmentDetailSize`）
        case .segmentDetail:
            let detail = PipelinePage.segmentDetailSize(in: windowSize)
            return (detail.width, detail.height)
        default:                                         return (nil, nil)
        }
    }

    /// **Esc 统一路由：全 App 只装这一个监听，按「上层优先」逐层关。**
    ///
    /// 不能让每层浮层各装一个（`AppModal.handlesEsc` 就是为此关掉的）：
    /// NSEvent 本地监听不是互斥的，一次 Esc 会派发到所有监听；而"该关哪一层"的判断
    /// 会在两次回调**之间**因为上一层已经把状态改掉而失真 —— 结果是**一次 Esc 关掉两层**，
    /// 用户正在编辑的提示词弹窗就这么没了（正是这次要修的那类毛病）。
    /// 放在这里统一判一次，就跟监听的先后顺序无关了。
    private func installEscRouter() {
        escRouter = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            // **按层级从高到低**：素材库抽屉 > 主浮层。
            // 顺序就是视觉上的叠放顺序（抽屉挂在 `RootModals` 之后），改层级时这里要跟着改。
            if app.showLibraryDrawer {
                AppLog.write("modal", "Esc 关闭（素材库抽屉）")
                app.closeLibraryDrawer()
            } else if app.showHistoryDrawer {
                // 历史版本面板（2026-09-23）—— 和素材库抽屉同级（都是浮层）
                AppLog.write("modal", "Esc 关闭（历史版本面板）")
                app.closeHistoryDrawer()
            } else if app.showTaskDrawer {
                AppLog.write("modal", "Esc 关闭（任务抽屉）")
                app.toggleTaskDrawer()
            } else if app.activeModal != nil, app.previewingImageItemID != nil || app.previewingShotID != nil {
                // 编辑弹窗里点图 / 视频全屏开的大预览浮在弹窗上面：先关大预览，弹窗留着（2026-10-26）
                AppLog.write("modal", "Esc 关闭（弹窗上的大预览）")
                app.previewingImageItemID = nil
                app.previewingImageResultID = nil
                app.previewingShotID = nil
            } else if app.stackedImageEditorID != nil {
                AppLog.write("modal", "Esc 关闭（段落详情上的生图弹窗）")
                app.stackedImageEditorID = nil
            } else if case .segmentDetail? = app.activeModal,
                      let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
                // 段落详情里正在改剧情 / 提示词：这一下只放手（存盘），再按一次才关（同工作台里的段落详情）
                NSApp.keyWindow?.makeFirstResponder(nil)
            } else if app.activeModal != nil {
                AppLog.write("modal", "Esc 关闭")
                app.activeModal = nil
            } else if let close = app.closeWorkbenchSegmentDetail, app.isScriptPageVisible,
                      !PreviewOverlayState.isShowing, DropdownPanel.shared.current == nil {
                // 分镜页的分段弹窗在最下层：大图预览、下拉层开着时不动它，让那些自己处理
                if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable {
                    // 正在改剧情：这一下只放手（存盘），再按一次才关弹窗
                    NSApp.keyWindow?.makeFirstResponder(nil)
                } else {
                    AppLog.write("modal", "Esc 关闭（分段弹窗）")
                    close()
                }
            } else {
                return event                                   // 没浮层开着 → 不吞，让给别人
            }
            return nil
        }
    }

    func body(content: Content) -> some View {
        return content
            // 窗口内容区大小：段落详情按它定尺寸（和工作台里点开的一样大）
            .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
            // 页面里点开、要盖住整个窗口的弹窗（工作台的段落详情，见 `WindowModalPortal`）。
            // 挂在主浮层**之前**：从它里面打开的生图弹窗等走主浮层，要叠在它上面
            .environment(\.windowModalPortalAvailable, true)
            .overlayPreferenceValue(WindowModalPortalKey.self) { portal in
                let portalSize = portal?.size(windowSize) ?? .zero
                Color.clear
                    .allowsHitTesting(false)
                    .appModal(isPresented: Binding(get: { portal != nil }, set: { if !$0 { portal?.close() } }),
                              width: portalSize.width, height: portalSize.height, handlesEsc: false) {
                        portal?.content
                    }
            }
            // Esc 由下面的路由统一处理，两层浮层都关掉自带的监听
            .appModal(isPresented: isPresented, width: size.width, height: size.height, handlesEsc: false) {
                switch app.activeModal {
                case .settings:
                    SettingsView(onClose: close)

                case .batchParam:
                    // 内容按当前工作区模式选（生视频 / 生图两套）
                    if app.batchTargetsShots {
                        BatchParamView(onClose: close)
                    } else {
                        BatchImageParamView(onClose: close)
                    }

                case .editVideoPrompt(let shotID):
                    if let shot = app.shots.first(where: { $0.id == shotID }) {
                        EditPromptSheet(shot: shot, onClose: close)
                    }

                case .segmentDetail(let shotID):
                    ShotSegmentDetailModal(shotID: shotID, onClose: close)

                case .batchParse:
                    BatchImageParseView(onClose: close)

                case .batchParseShots:
                    BatchShotParseView(onClose: close)

                case .editImagePrompt(let itemID):
                    if let item = app.imageItems.first(where: { $0.id == itemID }) {
                        EditImagePromptSheet(item: item, onClose: close)
                    }

                case .confirmDeleteShot(let shotID):
                    ConfirmDeleteShotView(shotID: shotID, onClose: close)

                case .confirmDeleteImage(let itemID):
                    ConfirmDeleteImageView(itemID: itemID, onClose: close)

                case nil:
                    EmptyView()
                }
            }
            // 叠在段落详情上面的生图弹窗（生视频页打开的段落详情里点「编辑这张卡」，2026-10-26）
            .appModal(isPresented: stackedPresented, handlesEsc: false) {
                if let id = app.stackedImageEditorID, let item = app.imageItems.first(where: { $0.id == id }) {
                    EditImagePromptSheet(item: item, onClose: { app.stackedImageEditorID = nil })
                }
            }
            // **归因日志**：把"弹窗开/关"的时刻写进同一份 app.log，
            // 这样看门狗记下的卡顿时间戳就能对上"当时在做什么"——
            // 否则只知道卡了、不知道因谁而起。排查开关路径的 bug 时也靠它。
            // 开销可忽略（每次开关各一条），留着。
            .onChange(of: app.activeModal) { old, kind in
                // 主浮层关了：叠在上面的生图弹窗也一起关
                if kind == nil, app.stackedImageEditorID != nil { app.stackedImageEditorID = nil }
                if let kind {
                    AppLog.write("modal", "\(Self.name(of: kind)) 打开")
                } else {
                    AppLog.write("modal", "浮层 关闭")
                }
                // 「批量解析」关掉时清空粘贴文本 —— 原来由 sheet 的 `.onDisappear` 做，
                // 改成浮层后没有 onDisappear 了，在这里保持同样的行为
                if old == .batchParse { app.imagePasteText = "" }
                if old == .batchParseShots { app.shotScriptText = "" }

                // ⚠️ **浮层开合也要清下拉面板**（2026-09-12 补，已实测闭合）。
                // 这里一直是漏的：另一处注释写着"两处都要管（浮层 / 抽屉）"，
                // 但两个 `dismiss()` 全在 `showTaskDrawer` 的 handler 里，**浮层这条从没接上**。
                // 后果就是用户报的「开着批量设置参数、快速点别的按钮，几次之后按钮点不动」：
                // 批量设置参数里有 8 个 `IconDropdown`，面板的 NSEvent 监听在浮层关闭时没被清掉，
                // 留下来吞掉之后所有鼠标按下；滚动一下才恢复（命中它的 scrollWheel 分支）。
                // 实测证据：加诊断后复现，dismiss 日志打出 `拆监听=true 关面板=true` ——
                // 那一刻**确实有一个还在生效的监听被拆掉**，修复前它会留下来。
                DropdownPanel.shared.dismiss()
                // 弹窗开 / 关之后让窗口重算鼠标指针区域：后面的输入框被禁用 / 恢复了，AppKit 不会因此自己重算（见 `PointerRegions`）
                PointerRegions.refresh()
            }
            // **任务列表（抽屉）开合时也要清**：抽屉里有排序用的两个 `IconDropdown`，
            // 用户实测"点不动"就出在**任务列表与设置来回切换**——抽屉关掉时面板若没跟着关，
            // 监听会留下吞掉之后所有点击。理由详见上一条注释。
            .onChange(of: app.showTaskDrawer) { _, _ in
                DropdownPanel.shared.dismiss()

                // ⚠️ **弹层状态一变，就清掉可能残留的下拉面板。**
                //
                // `DropdownPanel` 会装一个 `NSEvent` 本地监听，**只要面板开着，
                // 它外面的每一次鼠标按下都会被吞掉**（设计如此：先关弹层、这一下到此为止）。
                // 承载它的视图消失时如果面板没跟着关，监听就留下来了 —— 表现为
                // **"点哪里都没用，但滑动一下（滚动列表）就恢复正常"**
                // （滚动会命中监听里的 scrollWheel 分支 → 关面板 + 卸监听）。
                //
                // 残留时面板不自动关的原因：它的"鼠标移出"判定用的是**锚点按钮的旧坐标**，
                // 鼠标还在那片区域里 → 一直不关。
                //
                // **三处都要管**（都是真实踩过的）：
                //   · 浮层（设置 / 批量设置参数 / 批量解析 / 提示词弹窗…）→ 见**上一个** onChange
                //   · **素材库抽屉** → 见 `RightWorkspaceDrawerLayer` 的 onChange
                //   · **任务列表（抽屉）**：里面有两个排序下拉 → 就是这里
                DropdownPanel.shared.dismiss()
            }
            // **全片全屏播放层**（最外层，盖住顶栏/抽屉/弹窗）——2026-09-17
            .overlay {
                if app.cinemaPlaying {
                    CinemaPlaybackLayer()
                }
            }
            // Esc 统一路由：只装一个，按上层优先逐层关（理由见 installEscRouter）
            .onAppear { installEscRouter() }
            .onDisappear {
                if let escRouter { NSEvent.removeMonitor(escRouter) }
                escRouter = nil
            }
    }

    private func close() { app.activeModal = nil }

    private static func name(of kind: AppModel.AppModalKind) -> String {
        switch kind {
        case .settings:          return "设置"
        case .batchParam:        return "批量设置参数"
        case .editVideoPrompt:   return "编辑提示词"
        case .batchParse:        return "批量解析"
        case .batchParseShots:   return "导入分镜"
        case .editImagePrompt:   return "编辑图片提示词"
        case .confirmDeleteShot: return "删除分镜确认"
        case .confirmDeleteImage: return "删除图片确认"
        case .segmentDetail:     return "段落详情"
        }
    }
}

/// 三种抽屉共用同一滑动效果。显式插值避免布局的 transaction 影响位移动画。
private struct DrawerSlideMotion: AnimatableModifier {
    nonisolated var progress: CGFloat
    let closedOffset: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: closedOffset * (1 - progress))
            .opacity(Double(progress))
    }
}

/// 由可见卡片上报资产库边界，根层直接解析，缩放和滚动时也保持对齐。
struct HistoryAssetBoundsKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 历史版本在窗口右侧展示，与卡片里的资产库布局独立。
private struct HistoryDrawerLayer: ViewModifier {
    @Environment(AppModel.self) private var app

    private let width: CGFloat = 200
    private var drawerShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20, bottomLeadingRadius: 20,
            bottomTrailingRadius: 0, topTrailingRadius: 0
        )
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { app.closeHistoryDrawer() }
    }

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(HistoryAssetBoundsKey.self) { anchors in
            GeometryReader { geometry in
                let bounds = app.historyDrawerShotID.flatMap { anchors[$0] }.map { geometry[$0] }
            ZStack(alignment: .topTrailing) {
                if app.showHistoryDrawer {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .padding(.leading, AppWindowShellLayout.railWidth)
                    OverlayEventShield { close() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, AppWindowShellLayout.railWidth)
                }
                HistoryVersionList()
                    .frame(width: bounds?.width ?? width, height: bounds?.height ?? 0)
                    .environment(\.hoverFeedbackEnabled, false)
                    // 底 = 液态玻璃（同素材库 / 任务抽屉，2026-10-08 由 `.regularMaterial` 换过来；玻璃关闭时纯色），已含圆角裁剪
                    .glassPanel(in: drawerShape, shadow: false)
                    .contentShape(Rectangle())
                    .padding(.trailing, AppWindowShellLayout.edgeInset)
                    .offset(y: bounds?.minY ?? 0)
                    // 首次打开才确定分镜：尺寸和纵向位置必须立即就位，
                    // 否则会把默认的 y=0、height=0 一起插值成“从上面展开”。
                    // 布局不参与动画；外层共用 modifier 自己插值横向位置和透明度。
                    .transaction { transaction in transaction.animation = nil }
                    .modifier(DrawerSlideMotion(progress: app.showHistoryDrawer ? 1 : 0, closedOffset: width + 60))
                    .animation(.easeInOut(duration: 0.2), value: app.showHistoryDrawer)
                    .allowsHitTesting(app.showHistoryDrawer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .ignoresSafeArea()
            .allowsHitTesting(app.showHistoryDrawer && bounds != nil)
            }
            .ignoresSafeArea()
        }
        .onChange(of: app.showHistoryDrawer) { _, _ in
            DropdownPanel.shared.dismiss()
        }
    }
}

/// 素材库与任务共用右侧抽屉，主页、剧本、制作页使用同一挂载位置。
/// 挂在 RootModals 之后，保留从素材库向提示词弹窗拖素材的能力。
/// 背景必须用 SwiftUI 材质；NSView 背景不会跟随抽屉的 offset，曾导致关闭残留。
private struct RightWorkspaceDrawerLayer: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var taskMaterialized = false

    private var isOpen: Bool { app.showLibraryDrawer || app.showTaskDrawer }
    private var drawerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppWindowShellLayout.contentCornerRadius)
    }

    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) {
            app.closeLibraryDrawer()
            if app.showTaskDrawer { app.toggleTaskDrawer() }
        }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            ZStack(alignment: .topTrailing) {
                if isOpen {
                    // 左侧常驻导航不遮挡，点另一入口直接切换。其余内容点击只关闭抽屉。
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .padding(.leading, AppWindowShellLayout.railWidth)
                    OverlayEventShield { close() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, AppWindowShellLayout.railWidth)
                }

                // 滑动层先裁在内容面板范围内，再给外框留位；移动时不经过毛玻璃边框。
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        // 常驻以保留搜索与显示方式；项目切换仍按项目 key 重建素材行。
                        LibraryView()
                            .id(app.currentProjectKey)
                            .opacity(app.showLibraryDrawer ? 1 : 0)
                            .allowsHitTesting(app.showLibraryDrawer)
                        // 首次点任务才建列表，避免主页启动时构建所有任务。
                        if app.showTaskDrawer || taskMaterialized {
                            WorkspaceTaskDrawerContent()
                                .opacity(app.showTaskDrawer ? 1 : 0)
                                .allowsHitTesting(app.showTaskDrawer)
                        }
                    }
                    .frame(width: AppWindowShellLayout.drawerWidth)
                    .frame(maxHeight: .infinity)
                    // 抽屉里不做悬停反馈（2026-10-08 用户定；见 `EnvironmentValues.hoverFeedbackEnabled`）
                    .environment(\.hoverFeedbackEnabled, false)
                    // 抽屉底 = 和「场景提取 / 角色提取」那些弹窗同一套：**液态玻璃**（玻璃关闭时纯色），已含圆角裁剪。
                    // ⚠️ 2026-10-08 由 `.thickMaterial` 换过来：抽屉里一有悬停动画，旁边底部胶囊（`.regularMaterial`）右侧就闪——
                    // 两层 `Material` 毛玻璃相邻时会互相采样；弹窗用的液态玻璃走另一套渲染，从不让周围的材质闪。
                    // 不要有阴影：外层滑动层 `.clipShape` 会把它裁掉。
                    .glassPanel(in: drawerShape, shadow: false)
                    .contentShape(Rectangle())
                    .modifier(DrawerSlideMotion(progress: isOpen ? 1 : 0,
                                               closedOffset: AppWindowShellLayout.drawerWidth + 60))
                    .allowsHitTesting(isOpen)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .clipShape(drawerShape)
                .padding(.leading, AppWindowShellLayout.railWidth)
                .padding(.trailing, AppWindowShellLayout.edgeInset)
                .padding(.bottom, AppWindowShellLayout.edgeInset)
                .padding(.top, AppWindowShellLayout.titleBarHeight)
                .animation(.easeInOut(duration: 0.2), value: isOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            // overlay 的 frame 也要延伸进原生标题栏，否则抽屉会整体低 32pt。
            .ignoresSafeArea()
            .allowsHitTesting(isOpen)
        }
        .onChange(of: app.showLibraryDrawer) { _, show in
            AppLog.write("drawer", show ? "素材库 打开" : "素材库 关闭")
            DropdownPanel.shared.dismiss()
        }
        .onChange(of: app.showTaskDrawer, initial: true) { _, show in
            if show { taskMaterialized = true }
            DropdownPanel.shared.dismiss()
        }
    }
}

private struct WorkspaceTaskDrawerContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // 2026-10-06 P2：视频 / 生图 / 剧本 AI 合成一个列表
        JobDrawerView()
    }
}

/// 可拖动窗口的背景视图：按下空白处即拖动窗口（标准 macOS 标题栏行为）
final class MovableBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> MovableBackgroundView {
        MovableBackgroundView()
    }

    func updateNSView(_ nsView: MovableBackgroundView, context: Context) {}
}

/// 顶栏按钮的**输入罩**：一层不可见的 `NSButton`，盖在 SwiftUI 按钮上。
///
/// ## ⚠️ 为什么必须是 `NSButton`（而不是普通 `NSView`）—— 这是本组件最关键的一点
/// 启用了 `.fullSizeContentView` 之后，窗口的 **`NSThemeFrame`（标题栏那层私有视图）
/// 依然接管顶部约 28pt 的鼠标事件**，而且它有一条写死的判定：
/// **命中视图是 `NSControl`（`NSButton`/`NSSegmentedControl` 这类）→ 放行，让控件自己处理；
/// 只是个普通 `NSView`（`NSHostingView`、或自绘的罩子）→ 强行吃掉、判定为"拖动窗口"，
/// 并且 `mouseDownCanMoveWindow` 的返回值在这个判定里不起作用。**
///
/// 这正是本组件第一版（继承 `NSView`、重写 `mouseDown/Dragged/Up` 并返回
/// `mouseDownCanMoveWindow = false`）**点击通了、拖动照旧**的原因 ——
/// 也解释了同行的 `NSSegmentedControl` 为什么天然不拖（它是 `NSControl`）。
///
/// 所以这里把自己伪装成一个空按钮：**只要能骗过 `NSThemeFrame` 的 `hitTest` 就行**，
/// 外观零绘制、事件由 `target/action` 回调出去。
///
/// ## 两条期望行为
/// - 按住按钮拖动 → **不拖走窗口**（现在是 `NSControl`，`NSThemeFrame` 放行）✓
/// - 从别的 App 点过来 → 第一下只激活、不触发按钮（`acceptsFirstMouse = false`）✓
///
/// ## ⚠️ 悬停必须由罩子回报
/// 罩子既然是**命中视图**，SwiftUI 的 `onHover` 就**收不到事件了** —— 悬停状态必须由这里用
/// `NSTrackingArea` 测出来、经 `onHoverChange` 回报给 SwiftUI 去画高亮。
/// （曾以为"悬停走 `NSTrackingArea`、不依赖命中测试所以不受影响"——**实测是错的**，加了罩子高亮就没了。）
///
/// ## ⚠️ 浮层开着时必须让点击穿透
/// 罩子是 **AppKit 视图，永远在 SwiftUI 内容之上** —— 浮层遮罩**盖不住它**。
/// 不让开的话，"弹窗开着时点齿轮"会**直接打开设置**（用户报的历史问题：
/// 设置按钮在任何弹窗都会无条件触发）。所以有浮层时 `hitTest` 返回 `nil`，
/// 让点击落到浮层遮罩上（遮罩自己会关掉浮层，符合全 App「点外面只关掉它」的规则）。
final class TopBarControlShieldButton: NSButton {
    var onClick: (() -> Void)?
    /// 悬停变化回报（SwiftUI 据此画高亮）
    var onHoverChange: ((Bool) -> Void)?
    /// true = 让点击穿透（有浮层开着时置 true，见类型注释）
    var isTransparentToHits = false

    private var hoverArea: NSTrackingArea?

    /// 这一轮按下是否拖动过（拖过就不算点击）
    private var dragged = false

    init() {
        super.init(frame: .zero)
        // 画成"什么都没有"：无边框、无标题 —— 纯占位，只为让 NSThemeFrame 认它是 NSControl
        isBordered = false
        title = ""
        // ⚠️ **不能参与焦点**：它只是个"骗过 NSThemeFrame 的占位控件"，不该成为第一响应者 ——
        // 否则点一下会画出**焦点环**，在顶栏那种位置看着就是"有个框闪了一下"（用户实测反馈）。
        focusRingType = .none
        refusesFirstResponder = true
        // ⚠️ **不用 `target/action`**：改成自己重写 `mouseDown/Dragged/Up` 来数点击。
        // 原因：AppKit 按钮会按"双击"把连续两下合并成一次动作，而**我们这里两下是两个独立语义**
        //（素材库开着时：第一下关素材库、第二下开任务抽屉）—— 被合并掉第二下就丢了
        //（用户实测："双击任务按钮打不开，点慢一点就行"）。自己派发就没这个问题。
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不参与键盘导航（同 `refusesFirstResponder`，双保险）
    override var canBecomeKeyView: Bool { false }

    /// 这一轮是不是"连击的后续点击"（双击的第 2 下、三击的第 2/3 下）——是就整轮忽略
    private var isExtraClickOfMultiClick = false

    /// 这一轮是否真的收到过 `mouseDown` —— 见 `mouseUp` 里的说明
    private var mouseDownReceived = false

    /// 上一次 `mouseDown` 的位置（屏幕/窗口坐标）—— 见 `mouseDown` 里"位置也要接近"的说明
    private var lastClickLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        // ⚠️ **连击只认第一下**。双击这些按钮时：第 1 下打开抽屉/弹窗，第 2 下会发现
        // "已经有浮层开着"→按「点外面只关掉它」的规则又关掉 → **净效果等于什么都没发生**
        //（用户实测："素材库、任务这两个弹窗双击都不行"，其实是开了又立刻关）。
        // 用户要的是"双击 = 只生效一次"，所以第 2 下起整轮丢掉。
        //
        // ⚠️ **但不能只信系统的 `clickCount`**（2026-09-13 用户实测）：它只看"时间 + 距离"，
        // 而**顶栏这几个按钮挨得很近** —— 快速点「素材库」再点「任务」也会被判成双击，
        // 第 2 下整轮丢掉 → 表现为"**连续点顶栏按钮，第 2 下起失效，要等一会儿才好**"
        //（用户原话："只有顶栏的按钮有这种情况，其他地方的按钮都正常"）。
        // 所以补一道**位置判定**：两次点击挨得足够近才算连击，点不同按钮时照常触发。
        let p = event.locationInWindow
        let moved = hypot(p.x - lastClickLocation.x, p.y - lastClickLocation.y)
        mouseDownReceived = true
        isExtraClickOfMultiClick = event.clickCount > 1 && moved < 8
        lastClickLocation = p
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) { dragged = true }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownReceived = false }
        // ⚠️ **没收到 `mouseDown` 的 `mouseUp` 不算点击** —— 别删这一道闸。
        // 从别的 App 点过来的第一下：`mouseDown` 会被 AppDelegate 的监听器吞掉（只做激活），
        // 但 `mouseUp` 是独立事件、照常分发到这里；少了这道闸，那半下点击会直接派发出去 →
        // 「第一下就把浮层关了」（用户实测 2026-09-13）。
        //（AppDelegate 那边已经配对吞 up 了，这里是第二道保险。）
        guard mouseDownReceived, !dragged, !isExtraClickOfMultiClick else { return }
        onClick?()
    }

    /// 未激活时第一下只把窗口点过来、不触发按钮（全 App 既定规则）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    /// 显式写出来更保险（NSButton 默认即 false）
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isTransparentToHits ? nil : super.hitTest(point)
    }

    // MARK: 悬停回报（见类型注释）

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}

/// 见 `TopBarControlShieldButton`。
struct TopBarControlShield: NSViewRepresentable {
    let onClick: () -> Void
    var onHoverChange: (Bool) -> Void = { _ in }
    var isTransparentToHits: Bool = false

    func makeNSView(context: Context) -> TopBarControlShieldButton {
        let button = TopBarControlShieldButton()
        button.onClick = onClick
        button.onHoverChange = onHoverChange
        button.isTransparentToHits = isTransparentToHits
        return button
    }

    func updateNSView(_ nsView: TopBarControlShieldButton, context: Context) {
        nsView.onClick = onClick
        nsView.onHoverChange = onHoverChange
        nsView.isTransparentToHits = isTransparentToHits
    }
}

/// 顶栏按钮：**视觉用 SwiftUI 画、鼠标事件交给 AppKit 罩子**（理由见 `TopBarControlShieldButton`）。
///
/// 高亮为什么自己画、不用 `HoverHighlightButtonStyle`：
/// 罩子是命中视图，SwiftUI 的 `onHover` 收不到事件，**悬停状态只能由罩子回报**。
/// 这里的参数（圆角 8 / 外扩 8×4 / `secondary.opacity(0.12)`）**照抄**该样式的默认值，
/// 保证和全 App 其他按钮长得一样。
struct TopBarButton<Label: View>: View {
    @Environment(AppModel.self) private var app
    let action: () -> Void
    @ViewBuilder var label: Label

    @State private var hovered = false

    /// 有浮层开着（弹窗 / 素材库抽屉 / 任务抽屉 / 历史版本面板）—— 四种都要算上。
    private var overlayOpen: Bool {
        app.activeModal != nil || app.showLibraryDrawer || app.showTaskDrawer || app.showHistoryDrawer
    }

    /// 有浮层时**只关浮层**，不触发按钮自己（全 App 规则：点外面只关掉它）。
    ///
    /// ⚠️ **不要改成"让罩子穿透"**（`hitTest → nil`）：罩子一旦不命中，
    /// ① 它的 `NSControl` 身份就没了 → `NSThemeFrame` 又把这一片当标题栏拖动区 → **窗口又能被拖走**；
    /// ② 点击会被下面的 `WindowDragBackground`（AppKit 视图）接走 → **浮层也关不掉**。
    /// 实测这两个症状会同时出现。**罩子永远保持命中，只换点击的语义**才对。
    private func handleTap() {
        guard overlayOpen else { return action() }
        // ⚠️ **必须带 `withAnimation`**：抽屉的滑动/淡入淡出全靠调用点这一句提供
        //（`showTaskDrawer` 本身不带动画，这是既有约定）。漏掉的话状态是改了，
        // 但**动画直接跳到终点** —— 表现为"弹回动画没了"（用户实测）。
        // 状态逻辑和 `RootView.closeTopmostOverlay()` **共用 `AppModel` 那一份** —— 别抄回来。
        withAnimation(.easeInOut(duration: 0.2)) { app.dismissTopmostOverlay() }
    }

    var body: some View {
        label
            // 对应 `HoverHighlightButtonStyle` 的 `expandX: 8` / `expandY: 4`
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    // 有浮层时不给高亮 —— 那一下点击的语义是"关浮层"，不是"按这个按钮"
                    .fill(hovered && !overlayOpen ? Color.secondary.opacity(0.12) : Color.clear)
            )
            .overlay {
                TopBarControlShield(
                    onClick: handleTap,
                    onHoverChange: { hovered = $0 }
                )
            }
    }
}

/// 窗口关闭拦截：工作区时叉号/Cmd+W = 返回主页（不关窗）；主页时正常关闭退出。Cmd+Q 不经此路径，始终直退。
@MainActor
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var app: AppModel?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let app, app.isInWorkspace {
            AppLog.write("windowClose", "工作区叉号 → 返回主页")
            app.goHome()
            return false
        }
        // 还有任务在跑：**关窗之前**先问（2026-10-15 用户：点「取消」一直反复弹）。原来是窗口先关掉、退出时才问——
        // 这时已经没有窗口了，点「取消」后确认框自己一关，又算「最后一个窗口关了」→ 又去退出 → 又弹，停不下来。
        // 取消 = 窗口留着什么都不做；仍然退出 = 记下「已经确认过」，后面退出时不再问
        if !AppTermination.forced, let busy = AppAttention.model?.busyWorkSummary() {
            guard AppTermination.confirmQuit(busy: busy) else {
                AppLog.write("windowClose", "主页叉号 → 有任务在跑，取消退出")
                return false
            }
            AppTermination.forced = true
        }
        // 软件退出：**先渐隐、再真的关**（2026-09-13 用户要求，与启动的内容淡入对称）。
        // 返回 `false` 阻止这次立即关闭，等动画播完在 completion 里真的 `close()`
        //（关掉最后一个窗口后由 `applicationShouldTerminateAfterLastWindowClosed` 结束进程）。
        AppLog.write("windowClose", "主页叉号 → 渐隐后退出")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            sender.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { sender.close() }
        })
        return false
    }

    /// 用户用**系统方式**退出全屏（绿按钮 / Esc / ⌃⌘F）时，同步撤掉预览的"全屏"状态。
    /// 否则浮层会继续铺满窗口、而窗口已经不是全屏了 —— 看着像卡在全屏里出不来。
    func windowDidExitFullScreen(_ notification: Notification) {
        app?.previewFullscreen = false
    }
}


/// 删除分镜的确认弹窗（时间轴垃圾桶用，2026-09-17）——基于通用 ModalShell 模板
struct ConfirmDeleteShotView: View {
    @Environment(AppModel.self) private var app
    let shotID: UUID
    var onClose: () -> Void

    var body: some View {
        ModalShell(
            title: "是否确认删除？",
            subtitle: "删除后，已填写信息将不做保存，是否确认删除？",
            confirmLabel: "确认删除",
            confirmRole: .destructive,
            confirmTint: Theme.danger,
            cancelLabel: "取消",
            onConfirm: {
                app.deleteShot(id: shotID)
                onClose()
            },
            onCancel: onClose
        )
        .frame(width: 380, alignment: .leading)
    }
}

/// 删除生图条目的确认弹窗（图片垃圾桶用）——基于通用 ModalShell 模板
struct ConfirmDeleteImageView: View {
    @Environment(AppModel.self) private var app
    let itemID: UUID
    var onClose: () -> Void

    var body: some View {
        ModalShell(
            title: "是否确认删除？",
            subtitle: "删除后，图片条目及其提示词、生成结果都将删除且无法恢复，是否确认删除？",
            confirmLabel: "确认删除",
            confirmRole: .destructive,
            confirmTint: Theme.danger,
            cancelLabel: "取消",
            onConfirm: {
                app.removeImageItem(id: itemID)
                onClose()
            },
            onCancel: onClose
        )
        .frame(width: 380, alignment: .leading)
    }
}


/// 全片全屏播放层（2026-09-17）：从当前选中分镜开始**按顺序连播**（空白段跳过），铺满窗口。
/// 点画面 / Esc 退出；底部用**和弹窗同款的播放条**（`VideoControlBar`）。
/// ⚠️ 独立于预览弹窗（那边是"单镜详情 + 版本列表"）——这是"全片预览"，两个入口职责不同。
/// 退出时把当前分镜写回 `app.timelineShotID`，时间轴的选中位置对得上。
/// 连播用 `AVQueuePlayer` **预载下一段**（普通 AVPlayer 逐段 replaceCurrentItem 会黑闪一下）。
struct CinemaPlaybackLayer: View {
    @Environment(AppModel.self) private var app

    // **双播放器 A/B 轮换**（2026-09-17）：跨段要换视频源，单播放器（哪怕 AVQueuePlayer）
    // 换源瞬间会黑一下。用两个：往空闲的那个加载/预载，**渲染出帧再切显示层**，黑帧完全藏掉。
    @State private var playerA = AVPlayer()
    @State private var playerB = AVPlayer()
    @State private var activeIsA = true
    @State private var currentShotID: UUID?
    /// **当前播放器里真正装着的段**。跨段切换是异步的（`currentShotID` 立刻改、层要等 seek 完成才切），
    /// 退出时若按 `currentShotID` 写回，会把"下一段的起始 + 上一段的播放时间"算进时间轴 ——
    /// 播放头就跑到下一段里去了（用户 2026-09-18 报"播放头和全屏又不一样"）。写回只认它。
    @State private var activeShotID: UUID?
    @State private var escMonitor: Any?
    @State private var enteredFullscreen = false
    /// 鼠标是否在窗口里 —— 控制条**悬停才浮出**（2026-09-23 用户定：平时整屏只有画面）
    @State private var controlsVisible = false
    /// 播放/暂停**图标**的状态。
    ///
    /// ⚠️ **必须靠定时器刷新，不能直接读 `activePlayer.timeControlStatus`**（2026-09-23 用户报"全屏后
    /// 播放按钮一直是三角"）：`timeControlStatus` 是 AVPlayer 的**普通属性**，SwiftUI 观察不到它 ——
    /// 视图不重绘，图标就一直停在初始值（只在换段那种"别的原因触发重绘"时才偶然更新）。
    /// `VideoControlBar` 那边是同一个坑、同一套解法（0.2s 一跳 + 乐观更新）。
    @State private var isPlayingIcon = false
    /// 只用来切换播放/暂停图标，不需要高频
    private let stateTick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    /// 判据用 `timeControlStatus` 而不是 `rate`：`play()` 是**异步**的，刚调完那一刻 rate 仍是 0
    private var isActuallyPlaying: Bool {
        activePlayer.timeControlStatus == .playing
            || activePlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
    /// 代次：跨段切换是异步的（等 seek 完成再切层），旧任务回来时用它作废
    @State private var generation = 0
    /// 拖动中跨段切换的节流时间戳（≥0.2s 一次）
    @State private var lastCrossSwitchAt = Date.distantPast

    private var shots: [ShotDraft] { app.currentShots }
    private var activePlayer: AVPlayer { activeIsA ? playerA : playerB }
    private var idlePlayer: AVPlayer { activeIsA ? playerB : playerA }

    var body: some View {
        ZStack {
            Color.black.opacity(0.97)
            AVPlayerContainer(player: playerA)
                .opacity(activeIsA ? 1 : 0)
            AVPlayerContainer(player: playerB)
                .opacity(activeIsA ? 0 : 1)
            // 控制条：**悬停才浮出**（2026-09-23 用户定）—— 平时整屏只有画面。
            // ⚠️ **进度条已去掉**（用户："已经有时间轴的播放头了"）：全屏只负责看画面，
            // 需要定位就退出全屏去拖播放头。这里只留「播放/暂停 + 退出全屏」。
            if controlsVisible {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            togglePlayPause()
                        } label: {
                            Image(systemName: isPlayingIcon ? "pause.fill" : "play.fill")
                                .font(.system(size: 14))
                                .frame(width: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverHighlightButtonStyle(expandX: 5, expandY: 3))
                        .help(isPlayingIcon ? "暂停" : "播放")

                        Button {
                            close()
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 12))
                                .frame(width: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverHighlightButtonStyle(expandX: 5, expandY: 3))
                        .help("退出全片播放（Esc）")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassPanel(cornerRadius: 14)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // **点任意位置 = 播放 / 暂停**（2026-09-23 用户定）。
        // ⚠️ 原来是 `.onTapGesture { close() }` —— **点哪都退出全屏**，和"点击播放/暂停"冲突，已改
        .onTapGesture { togglePlayPause() }
        .onHover { controlsVisible = $0 }
        // 图标跟播放器真实状态对齐（见 `isPlayingIcon` 的说明）
        .onReceive(stateTick) { _ in isPlayingIcon = isActuallyPlaying }
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }   // 53 = Esc
                close()
                return nil
            }
            // **真全屏**：进层就切窗口全屏，退出时还原
            if NSApp.mainWindow?.styleMask.contains(.fullScreen) != true {
                enteredFullscreen = true
                NSApp.mainWindow?.toggleFullScreen(nil)
            }
            start()
            // 图标初始值（之后由 `stateTick` 校正）
            isPlayingIcon = isActuallyPlaying
        }
        .onDisappear {
            playerA.pause()
            playerB.pause()
            if let escMonitor { NSEvent.removeMonitor(escMonitor) }
            escMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            // 只认**当前活动**那段播完（预载的那个是暂停的，不会触发）
            guard let item = note.object as? AVPlayerItem, item === activePlayer.currentItem else { return }
            advanceToPreloaded()
        }
    }

    // MARK: 数据

    private func videoPath(_ shot: ShotDraft) -> String? {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID),
              let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// 段时长：**必须和时间轴同一口径**（用任务里提交时的时长，不是可编辑的草稿时长）。
    /// ⚠️ 之前用 `shot.duration`（草稿）—— 时间轴用 `task.duration`，两套基准不同，
    /// 段边界/播放头位置对不上（2026-09-18 用户实测"播放头位置和全屏后不一样"）
    private func duration(_ shot: ShotDraft) -> Int {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID) else { return 10 }
        return max(1, task.duration)
    }

    private func nextPlayableShot(after shot: ShotDraft) -> ShotDraft? {
        guard let idx = shots.firstIndex(where: { $0.id == shot.id }), idx + 1 < shots.count else { return nil }
        return shots[(idx + 1)...].first(where: { videoPath($0) != nil })
    }

    /// ⚠️ 原来这里还有 `currentOffset` / `totalSeconds`（全屏进度条用的），
    /// 2026-09-23 去掉全屏进度条后一并删掉 —— 现在全片位置只由时间轴的播放头负责

    private func offsetSeconds(of shot: ShotDraft) -> Double {
        guard let idx = shots.firstIndex(where: { $0.id == shot.id }) else { return 0 }
        return Double(shots[..<idx].reduce(0) { $0 + duration($1) })
    }

    /// 某个时间点落在哪个分镜上（逐段累计；超出末尾算最后一段）
    private func shot(atTimelineSeconds seconds: Double) -> ShotDraft? {
        // ⚠️ **半开区间 [start, end)**：正好等于边界那一秒属于**下一段**（同 GenerateView，off-by-one 修复）
        var acc = 0
        for shot in shots {
            let d = duration(shot)
            if seconds < Double(acc + d) { return shot }
            acc += d
        }
        return shots.last
    }

    // MARK: 播放流程

    private func start() {
        // **从时间轴"当前帧"接着播**（用户 2026-09-18 定）：
        // 直接拿预览播放器登记的（视频 + 段内秒数）—— 不做任何时长/偏移换算，帧级准确。
        let clock = app.timelineClock
        if let path = clock.livePath, clock.liveSeconds.isFinite,
           let shot = shots.first(where: { videoPath($0) == path }) {
            currentShotID = shot.id
            activeShotID = shot.id
            activeIsA = true
            loadInto(playerA, shot: shot, seekTo: clock.liveSeconds)
            if let next = nextPlayableShot(after: shot) {
                loadInto(playerB, shot: next, seekTo: 0)
            }
            return
        }
        // 兜底（还没播过任何一帧）：选中段（没视频就往后找第一个能播的）从段首开始
        let startIndex = shots.firstIndex(where: { $0.id == app.timelineShotID }) ?? 0
        guard let shot = shots[startIndex...].first(where: { videoPath($0) != nil }) else { close(); return }
        currentShotID = shot.id
        activeShotID = shot.id
        activeIsA = true
        loadInto(playerA, shot: shot, seekTo: 0)
        if let next = nextPlayableShot(after: shot) {
            loadInto(playerB, shot: next, seekTo: 0)
        }
    }

    /// 把某段载入指定播放器（不自动播）
    private func loadInto(_ player: AVPlayer, shot: ShotDraft, seekTo: Double) {
        guard let path = videoPath(shot) else { return }
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        if seekTo > 0 {
            player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 往空闲播放器预载下一段（自然连播不黑的关键）
    private func preloadNext(after shot: ShotDraft) {
        guard let next = nextPlayableShot(after: shot) else { return }
        loadInto(idlePlayer, shot: next, seekTo: 0)
    }

    /// 自然播完 → 切到预载好的那个并继续播；没有下一段就退出
    private func advanceToPreloaded() {
        guard let id = currentShotID, let shot = shots.first(where: { $0.id == id }) else { close(); return }
        guard let next = nextPlayableShot(after: shot) else { close(); return }
        currentShotID = next.id
        activeShotID = next.id
        activeIsA.toggle()
        activePlayer.play()
        preloadNext(after: next)
    }

    /// ⚠️ 原来这里还有 `scrubTimeline` / `commitSeekTimeline`（全屏进度条拖动用的），
    /// 2026-09-23 去掉全屏进度条后一并删掉 —— 全屏现在只负责播放/暂停，
    /// 定位统一回时间轴拖播放头（用户定）。`crossSwitch` 仍然保留：跨段推进要用它。

    /// 跨段切换（双播放器核心）：往空闲播放器加载目标段并 seek 到位，等渲染出来再切层。
    /// `generation` 防旧任务回来捣乱。
    private func crossSwitch(to target: ShotDraft, within: Double, resumePlaying: Bool) {
        currentShotID = target.id
        generation += 1
        let gen = generation
        activePlayer.pause()
        loadInto(idlePlayer, shot: target, seekTo: 0)
        idlePlayer.seek(to: CMTime(seconds: within, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard gen == generation else { return }
                activeShotID = target.id     // 层真切了才算"现在播的是这段"
                activeIsA.toggle()          // 切到已渲染好目标帧的那个（黑帧藏掉了）
                if resumePlaying { activePlayer.play() }
                preloadNext(after: target)
            }
        }
    }

    /// 播放 / 暂停 —— 点画面、点控制条上的按钮都走这里（2026-09-23）
    ///
    /// ⚠️ 判据用 `timeControlStatus` 而不是 `rate`：`play()` 是**异步**的，刚调完那一刻 rate 仍是 0，
    /// 拿它当判据会读到中间态（和 `VideoControlBar.isActuallyPlaying` 是同一个坑）。
    /// 图标**乐观更新**，随后由 0.2s 的 `stateTick` 校正。
    private func togglePlayPause() {
        let playing = isActuallyPlaying
        if playing {
            activePlayer.pause()
        } else {
            activePlayer.play()
        }
        isPlayingIcon = !playing
    }

    private func close() {
        playerA.pause()
        playerB.pause()
        if let id = activeShotID ?? currentShotID {
            app.timelineShotID = id   // 退出时把选中写回时间轴
            // **播放头写回全局秒数**：不写的话时间轴播放头停在全屏播放前的位置（2026-09-18 用户实测）
            let t = activePlayer.currentTime().seconds
            let offset = shots.first(where: { $0.id == id }).map { offsetSeconds(of: $0) } ?? 0
            app.timelineClock.playhead = offset + max(0, t.isFinite ? t : 0)
            // 只动了时钟（非观察）→ 得让时间轴强制重算一次，否则播放头不重画
            app.timelinePlayheadRevision &+= 1
        }
        if enteredFullscreen, NSApp.mainWindow?.styleMask.contains(.fullScreen) == true {
            NSApp.mainWindow?.toggleFullScreen(nil)
        }
        enteredFullscreen = false
        app.cinemaPlaying = false
    }
}
