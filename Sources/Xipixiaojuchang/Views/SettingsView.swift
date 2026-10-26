import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    /// 关闭回调。原来用 `@Environment(\.dismiss)` —— 改成应用内浮层后没有
    /// presentation 上下文了，`dismiss` 会失效，只能由外部传进来。
    var onClose: () -> Void

    @State private var cacheDirPath = FileLocations.projectsRoot.path
    /// 渠道页第一次点开才建（它常驻挂载，每个渠道的编辑器都很重；不点开就不建，打开设置快一截，2026-10-10）
    @State private var channelsMounted = false
    /// 更换项目文件夹：选好的新位置、它里面本来有几个项目、现有几个项目（见 `chooseProjectsRoot`）
    @State private var rootCandidate: URL?
    @State private var rootCandidateExisting = 0
    @State private var rootCandidateMine = 0
    @State private var showRootConfirm = false
    @State private var rootError: String?
    @State private var showRootError = false

    /// 🆕 2026-10-05（B 款视觉改版）：设置分类页签（仅导航分组 + 观感；各区内容与行为不变）
    @State private var settingsTab: SettingsTab = .appearance

    /// 打开设置默认落在第一页「界面」（2026-10-07 用户定；原来是「服务渠道」，从剧本页打开是「剧本流水线」）
    init(onClose: @escaping () -> Void, initialTab: SettingsTab = .appearance) {
        self.onClose = onClose
        _settingsTab = State(initialValue: initialTab)
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance = "界面"
        case channels = "服务渠道"
        case pipeline = "剧本流水线"
        case prompts = "提示词"
        case defaults = "默认参数"
        case upload = "素材上传"
        case cache = "缓存"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance: "circle.lefthalf.filled"
            case .channels: "point.3.connected.trianglepath.dotted"
            case .pipeline: "text.book.closed"
            case .prompts: "text.alignleft"
            case .defaults: "slider.horizontal.3"
            case .upload: "icloud.and.arrow.up"
            case .cache: "externaldrive"
            }
        }

    }

    // 文字服务商列表（2026-10-11）：每张卡片自己有草稿和「保存」，改了就存盘；这里持有整个列表。
    @State private var pipelineBook = PipelineProviderBook()
    @State private var pipelineLoadError: String?
    // 提示词（独立一页）：草稿由设置页持有，切分类不丢；关闭弹层时整体丢弃，保存才持久化。
    @State private var promptsDraft = PipelinePromptSettings()
    @State private var promptsSaved = PipelinePromptSettings()
    @State private var promptsMessage: String?

    private var promptsDirty: Bool { promptsDraft != promptsSaved }

    private func seedPipelineSettings() {
        let loaded = PipelineProviderStore.load()
        pipelineBook = loaded.book
        pipelineLoadError = loaded.error
        seedPrompts()
    }

    /// 服务商列表变了（新增 / 保存卡片 / 切当前使用 / 删除 / 接力开关）：存盘，接力开 / 关立刻生效
    private func persistPipelineBook() {
        let before = PipelineAISettingsStore.load().config
        do {
            try PipelineProviderStore.save(pipelineBook)
            pipelineLoadError = nil
            // 在用的配置变了（换模型 / 换服务商 / 改地址……）：左栏 AI 图标之前的结果不算数了
            if before != pipelineBook.resolved { app.resetAIProbe() }
        } catch {
            pipelineLoadError = error.localizedDescription
        }
        AgentBridge.shared.refresh(app: app)
    }

    private func addPipelineProvider() {
        let provider = PipelineProvider(name: "新服务商")
        pipelineBook.providers.append(provider)
        if pipelineBook.providers.count == 1 { pipelineBook.activeID = provider.id }
        persistPipelineBook()
    }

    /// 提示词草稿显示"当前生效"的文本：有自定义用自定义，否则用内置默认。
    private func seedPrompts() {
        let overrides = PipelinePromptSettingsStore.load()
        promptsDraft = PipelinePromptSettings(
            split: PipelinePromptStore.effective(overrides.split, fallback: PipelinePromptStore.splitPromptDefault),
            segments: PipelinePromptStore.effective(overrides.segments, fallback: PipelinePromptStore.segmentDefault),
            role: PipelinePromptStore.effective(overrides.role, fallback: PipelinePromptStore.roleDefault),
            scene: PipelinePromptStore.effective(overrides.scene, fallback: PipelinePromptStore.sceneDefault),
            prop: PipelinePromptStore.effective(overrides.prop, fallback: PipelinePromptStore.propDefault),
            storyboard: PipelinePromptStore.effective(overrides.storyboard, fallback: PipelinePromptStore.shotsDefault),
            naming: PipelinePromptStore.effective(overrides.naming, fallback: PipelinePromptStore.namingDefault),
            voice: PipelinePromptStore.effective(overrides.voice, fallback: PipelinePromptStore.voiceDefault)
        )
        promptsSaved = promptsDraft
    }

    private func savePromptsClicked() {
        savePrompts()
        promptsMessage = "已保存"
    }

    /// 与内置默认一致的条目存空串（= 跟随默认）；改动过的才存覆盖。
    private func savePrompts() {
        PipelinePromptSettingsStore.save(PipelinePromptSettings(
            split: promptsDraft.split == PipelinePromptStore.splitPromptDefault ? "" : promptsDraft.split,
            segments: promptsDraft.segments == PipelinePromptStore.segmentDefault ? "" : promptsDraft.segments,
            role: promptsDraft.role == PipelinePromptStore.roleDefault ? "" : promptsDraft.role,
            scene: promptsDraft.scene == PipelinePromptStore.sceneDefault ? "" : promptsDraft.scene,
            prop: promptsDraft.prop == PipelinePromptStore.propDefault ? "" : promptsDraft.prop,
            storyboard: promptsDraft.storyboard == PipelinePromptStore.shotsDefault ? "" : promptsDraft.storyboard,
            naming: promptsDraft.naming == PipelinePromptStore.namingDefault ? "" : promptsDraft.naming,
            voice: promptsDraft.voice == PipelinePromptStore.voiceDefault ? "" : promptsDraft.voice
        ))
        promptsSaved = promptsDraft
    }

    /// OSS 兜底开关：用 @AppStorage（和 `OSSConfigStore.isEnabled` 同一个 key）——
    /// 直接读写 UserDefaults 界面不会刷新（用户实测"勾号取消不了"）✗
    @AppStorage("ossEnabled") private var ossEnabled = true

    // 🎯 默认参数（2026-10-01 用户定）：**草稿态**，改完点「保存」才写入（只作新建条目/分镜的初始值）
    @State private var defImageModel = ""
    @State private var defImageType = ""
    @State private var defImageAspect = ""
    @State private var defImageQuality = ""
    @State private var defVideoModel = ""
    @State private var defVideoDuration = 0
    @State private var defVideoAspect = ""
    @State private var defVideoResolution = ""

    private func seedDefaultParams() {
        defImageModel = app.defaultImageModel ?? ""
        defImageType = app.defaultImageType ?? ""
        defImageAspect = app.defaultImageAspect ?? ""
        defImageQuality = app.defaultImageQuality ?? ""
        defVideoModel = app.defaultVideoModel ?? ""
        defVideoDuration = app.defaultVideoDuration ?? 0
        defVideoAspect = app.defaultVideoAspect ?? ""
        defVideoResolution = app.defaultVideoResolution ?? ""
    }

    /// 保存反馈（用户 2026-10-01："点保存后没有反馈"）
    @State private var defSavedHint = false

    /// 有没有改动（没改动时「保存」不可点 —— 也算一种反馈）
    private var defDirty: Bool {
        defImageModel != (app.defaultImageModel ?? "")
            || defImageType != (app.defaultImageType ?? "")
            || defImageAspect != (app.defaultImageAspect ?? "")
            || defImageQuality != (app.defaultImageQuality ?? "")
            || defVideoModel != (app.defaultVideoModel ?? "")
            || (defVideoDuration == 0 ? nil : defVideoDuration) != app.defaultVideoDuration
            || defVideoAspect != (app.defaultVideoAspect ?? "")
            || defVideoResolution != (app.defaultVideoResolution ?? "")
    }

    private func saveDefaultParams() {
        app.defaultImageModel = defImageModel.isEmpty ? nil : defImageModel
        app.defaultImageType = defImageType.isEmpty ? nil : defImageType
        app.defaultImageAspect = defImageAspect.isEmpty ? nil : defImageAspect
        app.defaultImageQuality = defImageQuality.isEmpty ? nil : defImageQuality
        app.defaultVideoModel = defVideoModel.isEmpty ? nil : defVideoModel
        app.defaultVideoDuration = defVideoDuration == 0 ? nil : defVideoDuration
        app.defaultVideoAspect = defVideoAspect.isEmpty ? nil : defVideoAspect
        app.defaultVideoResolution = defVideoResolution.isEmpty ? nil : defVideoResolution
        // 反馈：短暂显示「已保存 ✓」
        withAnimation(.easeInOut(duration: 0.15)) { defSavedHint = true }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeInOut(duration: 0.25)) { defSavedHint = false }
        }
    }
    /// 主题（和 App 层同一个 key）
    @AppStorage("appTheme") private var appThemeRaw = AppTheme.dark.rawValue
    @State private var catboxHash = ""
    @State private var catboxMessage: String?
    @State private var isTestingCatbox = false
    /// 玻璃效果开关（2026-09-19 用户要求）：关掉后全软件变纯色；默认开、持久化
    @AppStorage("glassEffectEnabled") private var glassEffectEnabled = true
    /// 外框浓度（2026-10-12 用户：外边框看不出玻璃态）：毛玻璃上盖的那层底色有多浓；拖的时候窗口实时变
    @AppStorage(AppWindowShellLayout.frostedTintKey) private var frostedTint = AppWindowShellLayout.frostedTintOpacity
    /// 后台完成时发系统通知（带提示音）：默认关
    @AppStorage(AppAttention.notificationsKey) private var completionNotifications = false
    @State private var ossAK = ""
    @State private var ossSK = ""
    @State private var ossBucket = ""
    @State private var ossEndpoint = ""
    @State private var ossMessage: String?
    @State private var isTestingOSS = false
    /// 素材上传位置（2026-09-19 用户要求）：开哪个，素材就传到哪里
    @State private var materialHost: MaterialUploadHost = MaterialUploadHostStore.load()

    /// 版本号文案：短版本 + 构建号（如 "1.8.33 (39)"），从 Info.plist 读
    private static var appVersionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    private func setMaterialHost(_ host: MaterialUploadHost) {
        materialHost = host
        MaterialUploadHostStore.save(host)
        app.uploadProbe = .unknown      // 换了上传位置，之前测的那条不算数了
        AppLog.write("upload", "素材上传位置 → \(host == .oss ? "阿里云 OSS" : "免费图床（catbox/litterbox）")")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            VStack(spacing: 0) {
                SettingsPageHeader(title: settingsTab.rawValue) {
                    if settingsTab == .channels {
                        Button {
                            app.saveChannel(ModelChannel(name: "新渠道", baseURL: "", apiKey: ""))
                        } label: {
                            Label("添加渠道", systemImage: "plus")
                        }
                        .buttonStyle(OutlineButtonStyle())
                    }
                    if settingsTab == .pipeline {
                        Button { addPipelineProvider() } label: { Label("添加服务商", systemImage: "plus") }
                            .buttonStyle(OutlineButtonStyle())
                            .disabled(pipelineBook.agentMode == true)
                            .accessibilityIdentifier("pipeline-add-provider")
                    }
                }
                // ⚠️ **不用 `Form`**（实测结论）：macOS 的 `Form` 在**首次实例化**时要花约 1.9s 布局
                // —— 表现为"每次启动 App 后第一次打开设置卡一下"，之后正常
                // （看门狗实测 1840~2015ms，去掉 `.formStyle(.grouped)` 也复现，所以与分组样式无关）。
                // 而且它自带一层材质背景，还会盖住弹窗自己的毛玻璃底。
                // 所以用 `ScrollView + VStack`，各段用 `SettingsGroup`（见 SettingsComponents.swift）。
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // 渠道页**常驻挂载**（透明度切换）：ChannelEditor 的未保存草稿 / 展开态切页不丢；
                        // 但第一次点开渠道页才挂上（没点开过就没有草稿可丢）
                        if channelsMounted {
                            channelsPage
                                .opacity(settingsTab == .channels ? 1 : 0)
                                .frame(height: settingsTab == .channels ? nil : 0, alignment: .top)
                                .clipped()
                                .allowsHitTesting(settingsTab == .channels)
                        }
                        switch settingsTab {
                        case .pipeline: pipelineSettingsPage
                        case .prompts: EmptyView()
                        case .defaults: defaultsPage
                        case .appearance: appearancePage
                        case .upload: uploadPage
                        case .cache: cachePage
                        case .channels: EmptyView()
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 只准上下滑（见 `VerticalScrollLock`：不是内容撑宽，是 SwiftUI 滚动区自己的横向橡皮筋）
                    .background(VerticalScrollLock())
                }
                .scrollIndicators(.hidden)
                .onChange(of: settingsTab, initial: true) { _, tab in if tab == .channels { channelsMounted = true } }
                // 提示词子页（2026-10-09）：铺满设置弹窗剩下的高度、页面本身不滚，只有里面那一个编辑框能滚。
                // 叠在 ScrollView 上面而不是替换它：渠道页等常驻挂载的页面（未保存的草稿）不能因此被拆掉。
                .opacity(showsPromptsPage ? 0 : 1)
                .allowsHitTesting(!showsPromptsPage)
                .overlay {
                    if showsPromptsPage {
                        pipelinePromptsPage
                            .padding(.horizontal, 28)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // 2026-10-05：默认参数草稿在弹窗打开时**只播种一次**（不能挂在某一页上——
            // 否则切页回来会重新播种、覆盖未保存的草稿）
            seedDefaultParams()
            seedPipelineSettings()
            cacheDirPath = FileLocations.projectsRoot.path
            // 占用空间在后台算（原来是在 body 里现算，冷缓存时卡 1.5~2s，见 cacheSizeText 的注释）
            refreshCacheSize()
            catboxHash = CatboxConfigStore.load() ?? ""
            if let config = OSSConfigStore.load() {
                ossAK = config.accessKeyId
                ossSK = config.accessKeySecret
                ossBucket = config.bucket
                ossEndpoint = config.endpoint
            }
        }
    }

    // MARK: 左侧导航

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("设置")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .padding(.bottom, 12)
            ForEach(SettingsTab.allCases) { tab in
                let selected = settingsTab == tab
                Button {
                    settingsTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13.5))
                            .frame(width: 20)
                            .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.14) : Color.clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            // 版本号（2026-09-21 用户要求：设置弹窗底下显示；不跟内容滚动）
            // + AI 辅助创作声明（2026-10-08 用户要求：版本号下面加一行）
            VStack(alignment: .leading, spacing: 3) {
                Text("版本 \(Self.appVersionText)")
                    .textSelection(.enabled)
                Text("本软件由AI辅助创作")
                    .accessibilityIdentifier("settings-ai-notice")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        .frame(width: 188)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: 各页

    private var channelsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if app.channels.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("还没有渠道")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius)
                    .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            } else {
                ForEach(app.channels) { channel in
                    ChannelEditor(channel: channel)
                }
            }
        }
    }

    /// 当前是不是在「提示词」页（独立的一页，2026-10-11 起不再藏在剧本流水线里）
    private var showsPromptsPage: Bool { settingsTab == .prompts }

    private var pipelineSettingsPage: some View {
        PipelineProvidersEditor(book: $pipelineBook, loadError: pipelineLoadError, onPersist: persistPipelineBook)
    }

    private var pipelinePromptsPage: some View {
        PipelinePromptsEditor(draft: $promptsDraft,
                              dirty: promptsDirty,
                              message: promptsMessage,
                              isError: false,
                              onSave: savePromptsClicked)
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                // 主题（2026-09-18 用户要求：深色/浅色/跟随系统）
                SettingsRow("主题") {
                    // 预览卡（2026-10-10 用户：别用分段按钮，做成配色那样的方形）：每张固定尺寸，不会随系统控件变大小
                    HStack(spacing: 8) {
                        ForEach([AppTheme.system, .light, .dark]) { choice in
                            AppearanceChoiceCard(title: choice.displayName, accessibilityText: "主题：\(choice.displayName)",
                                                 selected: appThemeRaw == choice.rawValue,
                                                 style: themePreviewStyle(choice)) { setAppTheme(choice.rawValue) }
                        }
                    }
                }
                SettingsDivider()
                // 界面材质（2026-09-19 用户要求）：玻璃态 = 毛玻璃 / 材质（默认）；纯色 = 全软件不透明纯色
                SettingsRow("界面材质") {
                    HStack(spacing: 8) {
                        AppearanceChoiceCard(title: "玻璃态", accessibilityText: "界面材质：玻璃态",
                                             selected: glassEffectEnabled,
                                             style: .glass(previewMode(dark: effectiveDark))) { setGlass(true) }
                        AppearanceChoiceCard(title: "纯色", accessibilityText: "界面材质：纯色",
                                             selected: !glassEffectEnabled,
                                             style: .solid(previewMode(dark: effectiveDark))) { setGlass(false) }
                    }
                }
                // 只有玻璃态才有「透出来多少」可调；纯色时窗口外框本来就不透
                if glassEffectEnabled {
                    SettingsDivider()
                    SettingsRow("外框浓度") {
                        HStack(spacing: 10) {
                            Text("透").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Slider(value: $frostedTint, in: AppWindowShellLayout.frostedTintRange)
                                .frame(width: 180)
                                .accessibilityIdentifier("settings-frosted-tint")
                            Text("浓").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Text("\(Int((frostedTint * 100).rounded()))%")
                                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            if abs(frostedTint - AppWindowShellLayout.frostedTintOpacity) > 0.005 {
                                Button("恢复默认") { frostedTint = AppWindowShellLayout.frostedTintOpacity }
                                    .buttonStyle(OutlineButtonStyle()).controlSize(.small)
                            }
                        }
                        .help("窗口外边框（左边栏和四周那一圈）的毛玻璃上盖着一层底色：越浓越接近纯色，越透越能看到窗口后面的桌面。拖的时候窗口实时变")
                    }
                }
            }

            // 配色主题（2026-10-07 用户要求）：整套色系——页面底、卡片、浮层、主色——一起换；和上面的深 / 浅色互相独立
            SettingsGroup(title: "配色") {
                HStack(spacing: 12) {
                    ForEach(ColorTheme.allCases) { theme in
                        ColorThemeCard(theme: theme, selected: ColorThemeStore.shared.current == theme,
                                       dark: effectiveDark) { setColorTheme(theme) }
                    }
                }
                .padding(SettingsStyle.rowHorizontal)
            }
            SettingsGroup(title: "提醒") {
                SettingsRow("后台完成时发系统通知") {
                    Toggle("", isOn: $completionNotifications)
                        .labelsHidden().toggleStyle(.switch)
                        .help("软件不在前台时，视频、生图、批量任务做完或失败，发一条系统通知（带提示音）。Dock 图标跳动和角标不受这个开关影响")
                        .onChange(of: completionNotifications) { _, on in if on { AppAttention.requestNotificationPermission() } }
                }
            }
            // 🎯 2026-09-29 用户定：**「底栏悬停放大」设置项已撤**（悬停放大动画本身已去掉）。
        }
    }

    // MARK: 外观切换
    // 2026-10-10 用户：切主题 / 材质会卡一下，「直接把那个动画去掉」——原来的幕布过渡（盖一层新底色淡入 → 切换 → 淡出）
    // 在用户机器上根本没在播（日志实测：淡入 140ms 的设计值 10~20ms 就结束、透明度读出来是 NaN，选对了主窗口也一样），
    // 只剩「瞬间盖上、卡约 100ms、瞬间撤掉」，所以整套拿掉，改成直接切。

    /// 设置页自己现在是深色还是浅色（配色卡片按它画预览）
    private var effectiveDark: Bool { colorScheme == .dark }

    /// 主题 / 材质预览用当前配色主题的色板
    private func previewMode(dark: Bool) -> ColorTheme.Mode { ColorThemeStore.shared.current.mode(dark: dark) }

    private func themePreviewStyle(_ choice: AppTheme) -> MiniInterfaceStyle {
        switch choice {
        case .light: .solid(previewMode(dark: false))
        case .dark: .solid(previewMode(dark: true))
        case .system: .split(light: previewMode(dark: false), dark: previewMode(dark: true))
        }
    }

    private func setAppTheme(_ raw: String) {
        guard raw != appThemeRaw else { return }
        appThemeRaw = raw
        AppThemeStore.apply()          // AppKit 侧（输入框、窗口 appearance）和 SwiftUI 侧在同一时刻换
    }

    private func setGlass(_ on: Bool) {
        guard on != glassEffectEnabled else { return }
        glassEffectEnabled = on
    }

    private func setColorTheme(_ theme: ColorTheme) {
        guard theme != ColorThemeStore.shared.current else { return }
        ColorThemeStore.shared.current = theme
    }

    private var defaultsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "生成开关") {
                SettingsRow("默认生成音频") {
                    Toggle("", isOn: Binding(get: { app.generateAudioDefault }, set: { app.generateAudioDefault = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow("默认添加水印") {
                    Toggle("", isOn: Binding(get: { app.watermarkDefault }, set: { app.watermarkDefault = $0 }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            // 🆕 2026-10-05（用户定）：控制样式对齐「批量设置参数」弹窗 —— 自绘下拉；值语义不变
            HStack(alignment: .top, spacing: 16) {
                SettingsGroup(title: "生图") {
                    defRow("模型", icon: "cube", options: defImageModelOptions, selection: $defImageModel)
                    SettingsDivider()
                    defRow("类型", icon: "tag", options: defImageTypeOptions, selection: $defImageType)
                    SettingsDivider()
                    defRow("比例", icon: "aspectratio", options: defImageAspectOptions, selection: $defImageAspect)
                    SettingsDivider()
                    defRow("质量", icon: "sparkles", options: defImageQualityOptions, selection: $defImageQuality)
                }
                SettingsGroup(title: "生视频") {
                    defRow("模型", icon: "cube", options: defVideoModelOptions, selection: $defVideoModel)
                    SettingsDivider()
                    defRow("时长", icon: "timer", options: defVideoDurationOptions, selection: $defVideoDuration)
                    SettingsDivider()
                    defRow("比例", icon: "aspectratio", options: defVideoAspectOptions, selection: $defVideoAspect)
                    SettingsDivider()
                    defRow("分辨率", icon: "rectangle.on.rectangle", options: defVideoResolutionOptions, selection: $defVideoResolution)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                if defSavedHint {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.success)
                        .transition(.opacity)
                }
                Button("保存") { saveDefaultParams() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!defDirty)          // 没改动就点不动（也能看出"当前没保存的东西"）
            }
        }
    }

    private var uploadPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            // **素材上传位置**（2026-09-19 用户要求）：二选一 —— 选哪个，素材（含提交前补传、一键重传）就传到哪里。
            SettingsGroup(title: "素材上传到哪里") {
                hostRow(.freeHost, title: "免费图床（catbox / litterbox）")
                SettingsDivider()
                hostRow(.oss, title: "阿里云 OSS")
            }

            SettingsGroup(title: "免费图床") {
                SettingsRow("测试上传") {
                    HStack(spacing: 8) {
                        if isTestingCatbox { ProgressView().controlSize(.small) }
                        Button("测试上传") { testCatbox() }
                            .disabled(isTestingCatbox)
                    }
                }
                if let catboxMessage {
                    SettingsDivider()
                    SettingsNote(text: catboxMessage)
                        .padding(.horizontal, SettingsStyle.rowHorizontal)
                        .padding(.vertical, 10)
                }
            }

            SettingsGroup(title: "阿里云 OSS") {
                // ⚠️ 历史：OSS 兜底开关已去掉（2026-09-18 用户："失败了不要自动切 OSS，直接显示失败"）。
                SettingsRow("AccessKey ID") { SecureField("", text: $ossAK).settingsField() }
                SettingsDivider()
                SettingsRow("AccessKey Secret") { SecureField("", text: $ossSK).settingsField() }
                SettingsDivider()
                SettingsRow("Bucket") { TextField("如 my-bucket", text: $ossBucket).settingsField() }
                SettingsDivider()
                SettingsRow("Endpoint") { TextField("如 oss-cn-hangzhou.aliyuncs.com", text: $ossEndpoint).settingsField() }
                SettingsDivider()
                HStack(spacing: 8) {
                    if isTestingOSS { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("测试上传") { testOSS() }
                        .disabled(!currentOSSConfig().isValid || isTestingOSS)
                    Button("清除") { clearOSS() }
                        .disabled(ossAK.isEmpty && ossSK.isEmpty && ossBucket.isEmpty && ossEndpoint.isEmpty)
                    Button("保存") { saveOSS() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(!currentOSSConfig().isValid)
                }
                .padding(.horizontal, SettingsStyle.rowHorizontal)
                .padding(.vertical, 10)
                if let ossMessage {
                    SettingsDivider()
                    SettingsNote(text: ossMessage)
                        .padding(.horizontal, SettingsStyle.rowHorizontal)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private var cachePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup {
                SettingsRow("项目文件夹") {
                    HStack(spacing: 10) {
                        Text(verbatim: cacheDirPath)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 280, alignment: .trailing)
                            .textSelection(.enabled)
                        Button("打开") {
                            try? FileManager.default.createDirectory(at: FileLocations.projectsRoot, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(FileLocations.projectsRoot)
                        }
                        Button("更换…") { chooseProjectsRoot() }
                            .accessibilityIdentifier("settings-change-projects-root")
                    }
                }
                SettingsDivider()
                SettingsRow("占用空间") {
                    Text(verbatim: cacheSizeText)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .alert("更换项目文件夹", isPresented: $showRootConfirm) {
            if rootCandidateExisting > 0 {
                Button("使用它里面的 \(rootCandidateExisting) 个项目并重启") { applyProjectsRoot(move: false) }
                if rootCandidateMine > 0 {
                    Button("把现有 \(rootCandidateMine) 个项目也移过去并重启") { applyProjectsRoot(move: true) }
                }
            } else if rootCandidateMine > 0 {
                Button("移动 \(rootCandidateMine) 个项目并重启") { applyProjectsRoot(move: true) }
            } else {
                Button("使用这个文件夹并重启") { applyProjectsRoot(move: false) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(rootConfirmMessage)
        }
        .alert("没能更换项目文件夹", isPresented: $showRootError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(rootError ?? "")
        }
    }

    /// 选一个新的项目文件夹（2026-10-10 用户：只有「打开」，没法更换）。选好先查能不能用，再问怎么处理现有项目
    private func chooseProjectsRoot() {
        let current = FileLocations.projectsRoot
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectsRootMover.validate(old: current, new: url)
        } catch {
            rootError = error.localizedDescription
            showRootError = true
            return
        }
        rootCandidate = url
        rootCandidateExisting = ProjectsRootMover.projectFolders(in: url).count
        rootCandidateMine = ProjectsRootMover.projectFolders(in: current).count
        showRootConfirm = true
    }

    private func applyProjectsRoot(move: Bool) {
        guard let url = rootCandidate else { return }
        Task {
            do { try await app.changeProjectsRoot(to: url, moveExisting: move) }
            catch {
                rootError = error.localizedDescription
                showRootError = true
            }
        }
    }

    private var rootConfirmMessage: String {
        let path = rootCandidate?.path ?? ""
        if rootCandidateExisting > 0 {
            let tail = rootCandidateMine > 0 ? "选「使用」：现在的 \(rootCandidateMine) 个项目留在原处，软件不再显示它们；选「也移过去」：两边合在一起。" : ""
            return "「\(path)」里已经有 \(rootCandidateExisting) 个项目。" + tail
        }
        if rootCandidateMine > 0 {
            return "现有 \(rootCandidateMine) 个项目（占用 \(cacheSizeText)）会移到「\(path)」，完成后软件自动重启。"
        }
        return "软件会改用「\(path)」存放项目，并自动重启。"
    }

    /// 上传位置的一行：整行可点，右边打勾表示当前选中
    private func hostRow(_ host: MaterialUploadHost, title: LocalizedStringKey) -> some View {
        Button { setMaterialHost(host) } label: {
            SettingsRow(title) {
                Image(systemName: materialHost == host ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(materialHost == host ? Theme.accent : Color.secondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityAddTraits(materialHost == host ? .isSelected : [])
    }

    /// 单个渠道编辑器。
    ///
    /// **折叠**时是一行摘要：名称（+ 未保存标记）+ 地址 + 规范 + 模型数，右侧删除；整条摘要可点切换展开/收起。
    /// Key 只在展开后的编辑区可见/可编辑（摘要行不显示，连掩码也不显示）。
    /// **展开**后编辑名称 / 地址 / Key 与模型，点「保存」才写回 `AppModel`。
    ///
    /// ⚠️ **不要改回"每次按键即保存"**（旧版 `.onChange(of: draft) { saveChannel }`）：
    /// 那样每敲一个字都会 `persistChannels` + `resumeAllInProgress`，既无谓又打断轮询。
    /// 现在编辑只改本地 `draft`，落盘集中在 `save()` 一处；未保存时摘要行标「未保存」。
    struct ChannelEditor: View {
        @Environment(AppModel.self) private var app
        let channel: ModelChannel
        @State private var draft: ModelChannel
        @State private var isExpanded: Bool
        @State private var showDeleteConfirm = false
        @State private var showSaved = false
        @State private var savedTask: Task<Void, Never>?
        @State private var errors: [ValidationIssue: String] = [:]
        @State private var newModelName = ""
        @State private var newModelCapability: ModelCapability = .image

        /// 校验失败定位：字段级，或某个模型行
        private enum ValidationIssue: Hashable {
            case name
            case baseURL
            case apiKey
            case model(UUID)
        }

        init(channel: ModelChannel) {
            self.channel = channel
            _draft = State(initialValue: channel)
            // 新建（地址或 Key 还空着）的渠道默认展开，直接引导填写
            _isExpanded = State(initialValue: channel.baseURL.isEmpty || channel.apiKey.isEmpty)
        }

        /// 有未落盘的改动
        private var isDirty: Bool { draft != channel }

        /// 校验失败的轻提示（红字之外的汇总，避免静默）
        private var validationHint: String? {
            errors.isEmpty ? nil : "还有 \(errors.count) 项未填，见红字"
        }

        var body: some View {
            SettingsCard(highlighted: isExpanded) {
                summaryRow
                    .padding(.horizontal, SettingsStyle.rowHorizontal)
                    .padding(.vertical, 12)
                if isExpanded {
                    SettingsDivider()
                    editor
                        .transition(.opacity)
                }
            }
            .onChange(of: draft) { _, _ in
                // 报过错之后边改边消错（只重算校验，不落盘）
                if !errors.isEmpty { errors = validate(cleanedDraft()) }
            }
            .onDisappear { savedTask?.cancel() }
            .alert("删除渠道", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) { app.removeChannel(id: channel.id) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("删除「\(channel.name)」及其下的所有模型？此操作不可撤销。")
            }
        }

        // MARK: 摘要行

        private func pill(_ text: String) -> some View {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }

        private var summaryRow: some View {
            HStack(alignment: .center, spacing: 8) {
                // **整条摘要可点**切换展开/收起；箭头只作状态指示（不再是按钮）。
                // 删除按钮放在这个可点区之外，点它不会被行点击吞掉。
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isExpanded)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(draft.name.isEmpty ? "未命名渠道" : draft.name)
                                .font(.system(size: 14, weight: .medium))
                            if isDirty {
                                Text("未保存")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.warning)
                            }
                        }
                        Text(draft.baseURL.isEmpty ? "未填地址" : draft.baseURL)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    pill(draft.apiFormat.displayName)
                    if !draft.models.isEmpty {
                        pill("\(draft.models.count) 个模型")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .hoverHighlight(radius: 8)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
                .help(isExpanded ? "点此收起" : "点此展开编辑")

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger.opacity(0.85))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .help("删除渠道")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: 展开编辑

        /// 一行输入：左名称，右输入框（报错时红字在输入框下面）
        private func fieldRow(_ title: LocalizedStringKey, prompt: String, text: Binding<String>,
                              issue: ValidationIssue, secure: Bool = false) -> some View {
            SettingsRow(title) {
                VStack(alignment: .trailing, spacing: 3) {
                    Group {
                        if secure {
                            SecureField(prompt, text: text)
                        } else {
                            TextField(prompt, text: text)
                        }
                    }
                    .onSubmit { save() }
                    .settingsField(width: 320)
                    fieldError(issue)
                }
            }
        }

        private var capabilityPicker: some View {
            SegmentedBar(options: [(ModelCapability.image.displayName, ModelCapability.image), (ModelCapability.video.displayName, ModelCapability.video)],
                         selection: $newModelCapability)
                .frame(width: 116, height: 26)
        }

        private var editor: some View {
            VStack(spacing: 0) {
                fieldRow("渠道名", prompt: "如 我的中转", text: $draft.name, issue: .name)
                SettingsDivider()
                fieldRow("API 地址", prompt: "如 https://api.example.com", text: $draft.baseURL, issue: .baseURL)
                SettingsDivider()
                fieldRow("API Key", prompt: "sk-…", text: $draft.apiKey, issue: .apiKey, secure: true)
                SettingsDivider()

                // 接入规范：同一地址 + Key，按哪种内置协议发请求
                VStack(alignment: .leading, spacing: 8) {
                    Text("接入规范").font(.system(size: 13))
                    // 自绘分段条（2026-10-10 用户：一切换就变宽）：各段等宽、铺满这一行，宽度和选中哪一段无关；
                    // 系统的分段 Picker 宽度跟着里面的字走，切换时会变
                    SegmentedBar(options: [ChannelProtocol.openAI, .newAPI].map { ($0.shortName, $0) },
                                 selection: $draft.apiFormat)
                        .frame(height: 28)
                        .accessibilityIdentifier("channel-protocol-picker")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, SettingsStyle.rowHorizontal)
                .padding(.vertical, 10)
                SettingsDivider()

                // 素材引用语法（2026-09-26）：上游要求 @image1 时才打开
                SettingsRow("提示词用 @image1 语法引用素材") {
                    Toggle("", isOn: $draft.useAtImageSyntax)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()

                // 模型
                VStack(alignment: .leading, spacing: 8) {
                    Text("模型").font(.system(size: 13))
                    ForEach($draft.models) { $model in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                TextField("模型名（如 gpt-image-2.5）", text: $model.name)
                                    .settingsField(width: nil)
                                SegmentedBar(options: [(ModelCapability.image.displayName, ModelCapability.image), (ModelCapability.video.displayName, ModelCapability.video)],
                                             selection: $model.capability)
                                    .frame(width: 116, height: 26)
                                Button {
                                    draft.models.removeAll { $0.id == model.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(Theme.danger.opacity(0.85))
                                }
                                .buttonStyle(QuietButtonStyle())
                                .help("移除该模型")
                            }
                            fieldError(.model(model.id))
                        }
                    }
                    // 添加模型：先填名称、选能力，再点添加
                    HStack(spacing: 8) {
                        TextField("新模型名（如 minimax-h3）", text: $newModelName)
                            .onSubmit(addModel)
                            .settingsField(width: nil)
                        capabilityPicker
                        Button {
                            addModel()
                        } label: {
                            Label("添加", systemImage: "plus")
                        }
                        .disabled(newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, SettingsStyle.rowHorizontal)
                .padding(.vertical, 10)
                SettingsDivider()

                HStack(spacing: 10) {
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .buttonStyle(AccentButtonStyle())

                    if let validationHint {
                        Label(validationHint, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                    } else if showSaved {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.success)
                            .transition(.opacity)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("删除渠道", systemImage: "trash")
                    }
                }
                .padding(.horizontal, SettingsStyle.rowHorizontal)
                .padding(.vertical, 12)
            }
        }

        // MARK: 辅助

        @ViewBuilder
        private func fieldError(_ issue: ValidationIssue) -> some View {
            if let message = errors[issue] {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }
        }

        private func cleanedDraft() -> ModelChannel {
            var cleaned = draft
            cleaned.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.models = draft.models.map { model in
                var copy = model
                copy.name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }
            return cleaned
        }

        private func validate(_ channel: ModelChannel) -> [ValidationIssue: String] {
            var issues: [ValidationIssue: String] = [:]
            if channel.name.isEmpty { issues[.name] = "渠道名不能为空" }
            if channel.baseURL.isEmpty { issues[.baseURL] = "地址不能为空" }
            if channel.apiKey.isEmpty { issues[.apiKey] = "Key 不能为空" }
            for model in channel.models where model.name.isEmpty {
                issues[.model(model.id)] = "模型名不能为空"
            }
            return issues
        }

        private func save() {
            // 「新模型名」框里还有没点「添加模型」的内容 → 先按当前能力收进草稿，再一起保存
            let pendingName = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !pendingName.isEmpty {
                draft.models.append(ChannelModel(name: pendingName, capability: newModelCapability))
                newModelName = ""
            }
            let cleaned = cleanedDraft()
            let issues = validate(cleaned)
            errors = issues
            guard issues.isEmpty else { return }
            draft = cleaned
            if cleaned != channel { app.saveChannel(cleaned) }
            flashSaved()
        }

        private func addModel() {
            let name = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }   // 按钮在空名时已禁用，这里兜底
            draft.models.append(ChannelModel(name: name, capability: newModelCapability))
            newModelName = ""
        }

        private func flashSaved() {
            savedTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showSaved = true }
            savedTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { showSaved = false }
            }
        }
    }

    // MARK: 默认参数：选项与行样式（2026-10-05 用户定：对齐「批量设置参数」弹窗；值语义不变）

    private var defImageModelOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")] + app.imageModelNames.map { DropdownOption(label: $0, value: $0) }
    }

    private var defImageTypeOptions: [DropdownOption<String>] {
        [DropdownOption(label: "默认（无类型）", value: "")]
            + ImageSubjectType.allCases.map { DropdownOption(label: $0.displayName, value: $0.rawValue) }
    }

    private var defImageAspectOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")]
            + ImageAspect.allCases.map { DropdownOption(label: $0.displayName, value: $0.rawValue) }
    }

    private var defImageQualityOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")]
            + ImageQuality.allCases.map { DropdownOption(label: $0.displayName, value: $0.rawValue) }
    }

    private var defVideoModelOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")] + app.videoModelNames.map { DropdownOption(label: $0, value: $0) }
    }

    private var defVideoDurationOptions: [DropdownOption<Int>] {
        [DropdownOption(label: "不指定", value: 0)]
            + [5, 10, 15, 30].map { DropdownOption(label: "\($0) 秒", value: $0) }
    }

    private var defVideoAspectOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")]
            + [AspectRatio.ratio16x9, .ratio9x16, .ratio1x1, .ratio4x3, .ratio3x4]
                .map { DropdownOption(label: $0.rawValue, value: $0.rawValue) }
    }

    private var defVideoResolutionOptions: [DropdownOption<String>] {
        [DropdownOption(label: "不指定", value: "")]
            + Resolution.allCases.map { DropdownOption(label: $0.displayName, value: $0.rawValue) }
    }

    /// 一行：左名称 + 右自绘下拉——和批量设置参数弹窗同款下拉
    private func defRow<V: Hashable>(
        _ label: LocalizedStringKey,
        icon: String,
        options: [DropdownOption<V>],
        selection: Binding<V>
    ) -> some View {
        SettingsRow(label) {
            // 下拉本身没有「这是个选项框」的外观（按用户要求去掉了箭头），在设置里给它套一个输入框的壳
            IconDropdown(
                icon: icon,
                labelWidth: 0,
                options: options,
                selection: selection,
                fillsRow: true,
                verticalPadding: 4
            )
            .padding(.leading, 9)
            .padding(.trailing, 24)
            .frame(width: 168)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 9)
                    .allowsHitTesting(false)
            }
        }
    }

    private func currentOSSConfig() -> OSSConfig {
        OSSConfig(
            accessKeyId: ossAK.trimmingCharacters(in: .whitespacesAndNewlines),
            accessKeySecret: ossSK.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: ossBucket.trimmingCharacters(in: .whitespacesAndNewlines),
            endpoint: ossEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func testCatbox() {
        isTestingCatbox = true
        Task {
            defer { isTestingCatbox = false }
            let result = await ConnectionProbe.freeHostUpload(progress: { catboxMessage = $0 })
            catboxMessage = result.message
            // 现在选的上传位置就是图床：左栏上传图标跟着亮 / 变红
            if materialHost == .freeHost { reportUploadProbe(result) }
        }
    }

    private func reportUploadProbe(_ result: ProbeResult) {
        app.uploadProbeHost = materialHost
        app.uploadProbe = result.ok ? .ok : .failed
        app.uploadProbeMessage = result.message
    }

    private func saveOSS() {
        let config = currentOSSConfig()
        guard config.isValid else { ossMessage = "请填写完整的 OSS 配置"; return }
        OSSConfigStore.save(config)
        ossMessage = "已保存 OSS 配置"
    }

    private func clearOSS() {
        OSSConfigStore.delete()
        ossAK = ""; ossSK = ""; ossBucket = ""; ossEndpoint = ""
        ossMessage = "已清除 OSS 配置"
    }

    private func testOSS() {
        let config = currentOSSConfig()
        guard config.isValid else { return }
        isTestingOSS = true
        Task {
            defer { isTestingOSS = false }
            let result = await ConnectionProbe.oss(config: config)
            ossMessage = result.message
            if materialHost == .oss { reportUploadProbe(result) }
        }
    }

    /// 缓存占用文本。**由 `refreshCacheSize()` 在后台算好后写进来。**
    ///
    /// ⚠️ **绝对不要改回"body 里现算的计算属性"**。它做的事是：遍历整个视频缓存目录、
    /// 逐个文件取大小（`FileManager.enumerator` + `resourceValues`），**同步、在主线程**。
    /// 实测后果（看门狗 + sample 定位）：冷文件系统缓存时一次要 **1.5~2 秒**，
    /// 表现为"**每次启动 App 后第一次打开设置卡一下**，之后正常"（因为 OS 的文件元数据缓存热了）。
    /// 栈里能看到 `__open` / `getattrlistbulk` 混在 SwiftUI 布局栈中——这就是证据。
    ///
    /// 排查过程：`Form` → `ScrollView`、材质底、`textSelection`、`LabeledContent`、文本控件
    /// **全部排除**，最后靠"栈里为什么有文件系统调用"这一句反推出来的。
    /// 这与项目里 `projectThumbnailPaths`（2026-09-11）**是同一个病**：`body` 里放重计算属性。
    @State private var cacheSizeText = "计算中…"

    /// 后台算缓存占用（绝不放回 body，见 `cacheSizeText` 的说明）
    @MainActor
    private func refreshCacheSize() {
        let dir = FileLocations.projectsRoot
        Task {
            cacheSizeText = await Task.detached(priority: .utility) {
                Self.computeDirectorySizeText(at: dir)
            }.value
        }
    }

    /// 同步遍历目录求和。**必须是同步函数**：`FileManager` 的目录枚举器
    /// 在 async 上下文里不可迭代（`makeIterator` is unavailable from asynchronous contexts）。
    /// 由调用方保证它在后台线程上跑。
    nonisolated private static func computeDirectorySizeText(at dir: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "0 KB"
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
