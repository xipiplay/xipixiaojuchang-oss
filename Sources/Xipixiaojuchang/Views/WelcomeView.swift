import SwiftUI
import AppKit
import AVFoundation

/// 主页：开始创作 + 最近项目（真实建项与项目选择）
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("projectSortField") private var sortFieldRaw = SortField.updatedAt.rawValue
    @AppStorage("projectSortOrder") private var sortOrderRaw = SortOrder.descending.rawValue
    @AppStorage("projectDisplayMode") private var displayModeRaw = DisplayMode.grid.rawValue
    @State private var pendingDelete: (key: String, count: Int)?
    @State private var showClearAllConfirm = false
    /// 多选删除：已勾选的项目 key（非空 = 处于选择模式）
    @State private var selectedKeys: Set<String> = []
    @FocusState private var homeSelectionFocused: Bool
    /// 拖动框选的选框矩形（命名坐标空间 `homeMarquee` 里；nil = 没在拖）——2026-09-26 用户定
    @State private var homeMarqueeRect: CGRect?
    /// 拖动框选用的卡片 frame 缓存（普通 class，写入不触发重算）
    @State private var homeMarqueeFrames = MarqueeFrameStore<String>()
    /// 批量删除的确认弹窗
    @State private var showBatchDeleteConfirm = false
    @Environment(\.colorScheme) private var colorScheme

    enum DisplayMode: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
    }

    enum SortField: String, CaseIterable, Identifiable {
        case createdAt, updatedAt
        var id: String { rawValue }
        var displayName: String { self == .createdAt ? "创建时间" : "更新时间" }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case descending, ascending
        var id: String { rawValue }
        var displayName: String { self == .descending ? "降序" : "升序" }
    }

    private var sortField: SortField { SortField(rawValue: sortFieldRaw) ?? .updatedAt }
    private var sortOrder: SortOrder { SortOrder(rawValue: sortOrderRaw) ?? .descending }
    private var displayMode: DisplayMode { DisplayMode(rawValue: displayModeRaw) ?? .grid }

    private var sortFieldBinding: Binding<SortField> {
        Binding(get: { SortField(rawValue: sortFieldRaw) ?? .updatedAt }, set: { sortFieldRaw = $0.rawValue })
    }
    private var sortOrderBinding: Binding<SortOrder> {
        Binding(get: { SortOrder(rawValue: sortOrderRaw) ?? .descending }, set: { sortOrderRaw = $0.rawValue })
    }
    private var displayModeBinding: Binding<DisplayMode> {
        Binding(get: { DisplayMode(rawValue: displayModeRaw) ?? .grid }, set: { displayModeRaw = $0.rawValue })
    }

    /// 勾选 / 取消勾选一个项目（勾选框与"选择模式下点整卡"共用）
    /// 拖动框选的选框外观（半透明 + 描边；跟随手势矩形）
    @ViewBuilder
    private var homeMarqueeOverlay: some View {
        if let r = homeMarqueeRect {
            Rectangle()
                .fill(Theme.accent.opacity(0.12))
                .overlay { Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1) }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// 拖动框选手势（**任何位置可起拖**，移动 >4pt 才算拖）：**每次替换** ——
    /// 选择 = 与选框相交的卡片（2026-09-26 用户定）。
    private var homeMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("homeMarquee"))
            .onChanged { value in
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                homeMarqueeRect = rect
                selectedKeys = homeMarqueeFrames.hit(rect)
            }
            .onEnded { _ in
                homeMarqueeRect = nil
            }
    }

    private func toggleSelection(_ key: String) {
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    /// 排序结果**缓存在 @State，只在主页可见时刷新**。
    /// ⚠️ 不能每次 body 现算：点进项目会 `touchProject`（更新 updatedAt）→ 该项目被排到最前 →
    /// `ForEach` 顺序变 → LazyVGrid 的格子全部重建/重排，主线程 ~700ms 卡顿（sample 实锤：
    /// 卡顿栈全在 responder 的 deinit）。进项目时顺序保持不动，回主页时再应用新顺序。
    @State private var orderedProjects: [AppModel.ProjectSummary] = []
    /// 进入/返回主页时拍快照；不随 touchProject 或大图悬停重排项目、重复汇总图片。
    @State private var continueProject: HomeContinueProject?

    private func refreshContinueProject() {
        guard !app.isInWorkspace else { return }
        guard let project = app.projects.first else {
            continueProject = nil
            return
        }
        let archive = app.pipelineArchive(for: project.key)
        let epCount = archive?.episodes.count ?? 0
        var lastEdit: String?
        if let archive, epCount > 0 {
            let index = archive.episodes.indices.contains(archive.epIndex) ? archive.epIndex : 0
            let board = app.workbenchBoard(project: project.key, archive: archive)
            lastEdit = HomeContinueProject.lastEditText(episodeCount: epCount, episodeIndex: archive.epIndex,
                                                        stageTitle: board.episodes.indices.contains(index) ? board.episodes[index].stage.title : nil)
        }
        continueProject = HomeContinueProject(
            key: project.key,
            name: app.projectName(for: project.key),
            episodeCount: epCount,
            shotCount: project.shotCount,
            imageCount: app.imageItems.reduce(0) { $0 + ($1.projectKey == project.key ? 1 : 0) },
            coverPath: app.projectThumbnailPaths[project.key],
            lastEdit: lastEdit
        )
    }

    private func sortedProjects() -> [AppModel.ProjectSummary] {
        app.projects.sorted {
            let a = sortField == .createdAt ? $0.createdAt : $0.updatedAt
            let b = sortField == .createdAt ? $1.createdAt : $1.updatedAt
            if a != b { return sortOrder == .descending ? a > b : a < b }
            // **并列必须定序**，否则 `sorted`（非稳定排序）会让顺序随机跳 ——
            // 见 AppModel.projects 里的同款说明。
            return $0.key < $1.key
        }
    }

    private var projects: [AppModel.ProjectSummary] { orderedProjects }

    private var creationHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("开始创作")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("从剧本到成片，让好故事被看见。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button {
                    app.startNewProject()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("新建项目")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(QuietButtonStyle(hover: .brighten))
                .accessibilityLabel("新建项目")
            }
            .padding(.top, 6)
        }
    }

    private var recentProjectsHeader: some View {
        HStack(spacing: 12) {
            Text(selectedKeys.isEmpty ? "最近项目" : "已选 \(selectedKeys.count)")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)

            if selectedKeys.isEmpty {
                Spacer()
                if !projects.isEmpty {
                    IconDropdown(
                        icon: "arrow.up.arrow.down",
                        labelWidth: 64,
                        labelFont: .system(size: 14, weight: .semibold),
                        options: SortField.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                        selection: sortFieldBinding,
                        // ⚠️ 这一行高度固定 32：按钮默认的上下内边距（6）+ 悬停撑开（4）= 37 > 32，
                        // 标签的 `minimumScaleFactor` 会把字压到 0.7 倍（用户：「更新时间 / 降序」字变得很小）。
                        // 内边距收到 2，字就按 14pt 正常显示。
                        verticalPadding: 2
                    )
                    Divider().frame(height: 14)
                    IconDropdown(
                        icon: "arrow.up",
                        labelWidth: 40,
                        labelFont: .system(size: 14, weight: .semibold),
                        options: SortOrder.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                        selection: sortOrderBinding,
                        verticalPadding: 2
                    )
                    Picker("显示方式", selection: displayModeBinding) {
                        Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                        Image(systemName: "list.bullet").tag(DisplayMode.list)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            } else {
                SelectBox(
                    title: "全选",
                    titleFont: .system(size: 17, weight: .semibold),
                    titleColor: .primary,
                    isChecked: selectedKeys.count == projects.count
                ) {
                    if selectedKeys.count == projects.count {
                        selectedKeys.removeAll()
                    } else {
                        selectedKeys = Set(projects.map(\.key))
                    }
                }
                Spacer()
            }
        }
        // 选择模式只换控件，不改变行高，避免卡片上下跳动。
        .frame(height: 32)
    }

    private func projectFrameReporter(_ key: String) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    homeMarqueeFrames.update(key, geo.frame(in: .named("homeMarquee")))
                }
                .onChange(of: geo.frame(in: .named("homeMarquee"))) { _, rect in
                    homeMarqueeFrames.update(key, rect)
                }
        }
    }

    private func projectCollection(thumbs: [String: String]) -> some View {
        VStack(spacing: 0) {
            if displayMode == .grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 330), spacing: 20)], spacing: 22) {
                    ForEach(projects) { project in
                        ProjectGridCell(
                            project: project,
                            thumbPath: thumbs[project.key],
                            selectionMode: !selectedKeys.isEmpty || homeMarqueeRect != nil,
                            isSelected: selectedKeys.contains(project.key),
                            onToggleSelect: { toggleSelection(project.key) }
                        ) {
                            app.openProject(project.key)
                        } onDelete: {
                            pendingDelete = (project.key, project.shotCount + project.taskCount)
                        }
                        .background { projectFrameReporter(project.key) }
                    }
                }
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(projects) { project in
                        ProjectCard(
                            project: project,
                            thumbPath: thumbs[project.key],
                            selectionMode: !selectedKeys.isEmpty || homeMarqueeRect != nil,
                            isSelected: selectedKeys.contains(project.key),
                            onToggleSelect: { toggleSelection(project.key) }
                        ) {
                            app.openProject(project.key)
                        } onDelete: {
                            pendingDelete = (project.key, project.shotCount + project.taskCount)
                        }
                        .background { projectFrameReporter(project.key) }
                    }
                }
            }
        }
        // 坐标空间与选框同属项目区，随整页一起滚动；标题和建项按钮不参与框选。
        .contentShape(Rectangle())
        .coordinateSpace(.named("homeMarquee"))
        .overlay { homeMarqueeOverlay }
        .simultaneousGesture(homeMarqueeGesture)
    }

    var body: some View {
        // 路径表只在父级取一次，继续复用现有缓存，不让每张卡扫描全部任务。
        let thumbs = app.projectThumbnailPaths
        ScrollView {
            // 竖向节奏（2026-10-10 用户：看着松松散散）：块与块 22、「最近项目」标题到卡片 12、名字和时间贴在一起
            VStack(alignment: .leading, spacing: 22) {
                creationHeader
                if let project = continueProject {
                    HomeContinueBanner(
                        project: project,
                        isHomeVisible: !app.isInWorkspace,
                        interactionEnabled: !app.isInWorkspace && app.activeModal == nil &&
                            pendingDelete == nil && !showBatchDeleteConfirm && !showClearAllConfirm
                    ) {
                        selectedKeys.removeAll()
                        homeMarqueeRect = nil
                        app.openProject(project.key)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    recentProjectsHeader
                    if projects.isEmpty {
                        Text("还没有项目，点击右上方「新建项目」开始")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 180)
                            .frame(maxWidth: .infinity)
                    } else {
                        projectCollection(thumbs: thumbs)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 32)
            .padding(.bottom, selectedKeys.isEmpty ? 32 : 120)
        }
        .scrollIndicators(.hidden)
        .background(SolidTheme.background(colorScheme))
        // 最小内容尺寸扣除常驻外框，整窗仍保持 1160×678，避免加栏后撑大窗口。
        .frame(minWidth: AppWindowShellLayout.contentMinimumWidth,
               minHeight: AppWindowShellLayout.contentMinimumHeight)
        .focusable(!selectedKeys.isEmpty)
        .focusEffectDisabled()
        .focused($homeSelectionFocused)
        .onAppear {
            // 诊断（临时，验完删）：启动打点 ⑤（主页出现）
            AppLog.write("startup", "⑤ WelcomeView.onAppear @ \(StartupClock.ms())ms")
            orderedProjects = sortedProjects()
            refreshContinueProject()
        }
        .onChange(of: sortField) { _, _ in orderedProjects = sortedProjects() }
        .onChange(of: sortOrder) { _, _ in orderedProjects = sortedProjects() }
        .onChange(of: displayMode) { _, _ in
            homeMarqueeRect = nil
            homeMarqueeFrames = MarqueeFrameStore<String>()
        }
        .onChange(of: selectedKeys.isEmpty) { _, empty in
            homeSelectionFocused = !empty && !app.isInWorkspace
        }
        .onChange(of: projects.map(\.key)) { _, keys in
            let remaining = Set(keys)
            selectedKeys.formIntersection(remaining)
            homeMarqueeFrames.keepOnly(remaining)
        }
        .onExitCommand {
            guard !app.isInWorkspace else { return }
            homeMarqueeRect = nil
            selectedKeys.removeAll()
        }
        // **项目集合变了（新建/删除）→ 立刻刷新列表**（2026-09-19 修"删了项目变成未命名项目"）：
        // 原来只在 onAppear / 回主页时刷新，删完项目那张卡还留在页面上，而卡上的名字是实时查的
        // → meta 已删 → 显示成"未命名项目"；进别的项目再出来才消失（用户实测）。
        // ⚠️ **只比 key 集合**，不能直接 `onChange(of: app.projects)`：只改 updatedAt 的
        //    `touchProject`（进项目必经）也会让 projects 变 → 会在离开主页那一刻重排 → 700ms 卡顿
        //    （见 `orderedProjects` 上面的注释）。
        .onChange(of: Set(app.projects.map(\.key))) { _, keys in
            orderedProjects = sortedProjects()
            // 新建会直接进入工作区；删除当前大图项目才需要在主页换卡。
            if continueProject == nil || !keys.contains(continueProject!.key) {
                refreshContinueProject()
            }
        }
        .onChange(of: app.projectName(for: continueProject?.key ?? "")) { _, name in
            guard !app.isInWorkspace, continueProject != nil else { return }
            continueProject?.name = name
        }
        // 回到主页才接受新顺序（进项目时 touchProject 改了 updatedAt，别在离开主页那一刻重排）
        .onChange(of: app.isInWorkspace) { _, inWs in
            homeSelectionFocused = !inWs && !selectedKeys.isEmpty
            if !inWs {
                orderedProjects = sortedProjects()
                refreshContinueProject()
            }
        }
        // 诊断（临时，验完删）：启动打点 ⑥（主页首帧渲染完 —— `.task` 在视图出现后才跑）
        .task {
            AppLog.write("startup", "⑥ 主页首帧完成 @ \(StartupClock.ms())ms")
        }
        // 诊断：项目顺序一变就记一条 —— 用于定位"顺序会乱跳"。
        // 排序已加"并列按 key 定序"保证确定性；若日志里仍出现顺序变化，
        // 说明真正的原因不在排序，而在数据（updatedAt 变了）或视图身份，届时按日志继续查。
        .onChange(of: projects.map(\.key)) { old, new in
            AppLog.write("projectOrder", "顺序变化 → \(new.joined(separator: ","))（原本 \(old.joined(separator: ","))）")
        }
        // 选择模式：底部主题浮层（左：删除图标；右：「退出」）。
        // ZStack 是**常驻**的：它承载 .animation(value:)，条件分支的 transition 才有动画可挂。
        // 动画只挂浮层，避免标题行「最近项目 ↔ 已选 n」的控件一起移动。
        .overlay(alignment: .bottom) {
            ZStack {
                if !selectedKeys.isEmpty {
                    // 2026-10-08 用户："主页多选条怎么和项目里的不一样"——现在就是项目里那条工具条胶囊（同形状、同材质、
                    // 同按钮盒子、同间距、贴底 12pt），在整个窗口里居中（同项目里的工具条）。「退出」改叫「取消」，和项目里一致。
                    ToolbarRow {
                        HStack(spacing: 16) {
                            SelectionBarIconButton(icon: "trash", color: Theme.danger, help: "删除选中") {
                                showBatchDeleteConfirm = true
                            }
                            SelectionBarCancelButton { selectedKeys.removeAll() }
                        }
                    }
                    // 「弹出」：从底边略微放大弹出（锚点在底边，像从下方弹出来），收起时缩回去
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.86, anchor: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity)
                        )
                    )
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.74), value: selectedKeys.isEmpty)
        }
        .alert("删除所选项目", isPresented: $showBatchDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除 \(selectedKeys.count) 个项目", role: .destructive) {
                for key in selectedKeys { app.deleteProject(key: key) }
                selectedKeys.removeAll()
            }
        } message: {
            Text("将删除所选 \(selectedKeys.count) 个项目下的全部分镜、任务记录及整个缓存文件夹（含图片/视频文件），此操作不可撤销。")
        }
        .alert("删除项目", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let key = pendingDelete?.key { app.deleteProject(key: key) }
                pendingDelete = nil
            }
        } message: {
            if let count = pendingDelete?.count {
                Text("将删除该项目下的 \(count) 个分镜和任务记录，项目文件夹（含图片/视频文件）会移到废纸篓。")
            }
        }
        .alert("清除所有项目", isPresented: $showClearAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) { app.clearAllProjects() }
        } message: {
            Text("将删除全部 \(app.projects.count) 个项目及其分镜、任务记录，此操作不可撤销。")
        }
    }
}

/// 大图只读取现有项目数据；集数来自该项目绑定的剧本流水线存档。
struct HomeContinueProject: Equatable {
    let key: String
    var name: String
    let episodeCount: Int
    let shotCount: Int
    let imageCount: Int
    let coverPath: String?
    /// 「第 3 集 · 待出图」：上次停在哪一集、这一集现在到哪一步；没有分集的项目是 nil（不显示这一行）
    var lastEdit: String? = nil

    /// `episodeIndex`：存档里记的上次选中的集（0 起，越界按第 1 集）；`stageTitle`：这一集现在的阶段（`WorkbenchStatus.Stage.title`）
    static func lastEditText(episodeCount: Int, episodeIndex: Int, stageTitle: String?) -> String? {
        guard episodeCount > 0 else { return nil }
        let index = (0..<episodeCount).contains(episodeIndex) ? episodeIndex : 0
        return "第 \(index + 1) 集" + (stageTitle.map { " · \($0)" } ?? "")
    }
}

/// 点击后锁住（防重复触发）；返回主页再清理。
private enum HomeBannerInteraction: Equatable {
    case resting
    case opening

    var isOpening: Bool { self == .opening }

    mutating func beginOpening() -> Bool {
        guard !isOpening else { return false }
        self = .opening
        return true
    }
}

/// 大图的交互状态留在这个子视图中，避免刷新主页网格与项目统计。
private struct HomeContinueBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let project: HomeContinueProject
    let isHomeVisible: Bool
    let interactionEnabled: Bool
    let onOpen: () -> Void
    @State private var interaction = HomeBannerInteraction.resting
    @State private var onScreen = true
    /// 悬停：只用来把封面缩略图轻微放大（其余画面不变）。
    @State private var hovering = false

    private func resetInteraction() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            interaction = .resting
            hovering = false
        }
    }

    private func statBlock(_ label: String, _ value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
        .frame(minWidth: 62, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var statDivider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 30)
    }

    private var readingContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Capsule().fill(Theme.accent).frame(width: 22, height: 2)
                Text("最近创作")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.bottom, 12)
            Text(project.name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 18) {
                if project.episodeCount > 0 {
                    statBlock("集数", "\(project.episodeCount)", unit: "集")
                } else {
                    statBlock("集数", "—")
                }
                statDivider
                statBlock("分镜", "\(project.shotCount)", unit: "条")
                statDivider
                statBlock("图片", "\(project.imageCount)", unit: "张")
            }
            .padding(.top, 18)
            // 上次停在哪：辅助信息，用白字（不用橙色、不加底色胶囊）；橙色留给下面的操作按钮
            if let lastEdit = project.lastEdit {
                Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
                    .frame(maxWidth: 340)
                    .padding(.top, 20)
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 14))
                    Text("上次编辑：\(lastEdit)").font(.system(size: 14))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 13)
            }
            // 仅是样式块，唯一点击入口是外层整卡 Button。
            HStack {
                Text("继续创作")
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium))
            }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 16)
                .frame(width: 168, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent))
                .padding(.top, project.lastEdit == nil ? 24 : 19)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    var body: some View {
        Button {
            guard interaction.beginOpening() else { return }
            onOpen()
        } label: {
            ZStack {
                // 封面 + 渐变先合成一张、**一起**裁成圆角，再叠文字（2026-10-10 用户：渐变和图片一起裁切圆角，避免边缘出现方形黑块）：
                // 渐变不再是一块独立的方形图层，淡入淡出 / 悬停放大时圆角外不会漏出方形的黑
                ZStack {
                    HomeBannerCover(path: project.coverPath, isActive: isHomeVisible)
                        // 悬停时缩略图（封面）轻微放大；整卡裁切，文字不动。
                        .scaleEffect(hovering ? 1.03 : 1)
                        .animation(.easeOut(duration: 0.25), value: hovering)
                    // 封面与文字之间的黑色渐变（2026-10-10）：左深右透——文字区有稳定的底，右侧保留原图亮度；换亮封面也看得清
                    LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0),
                                           .init(color: .black.opacity(0.80), location: 0.22),
                                           .init(color: .black.opacity(0.45), location: 0.45),
                                           .init(color: .black.opacity(0.10), location: 0.70),
                                           .init(color: .black.opacity(0), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                readingContent
            }
            // 整张先渲染成一张图再整体淡入淡出（2026-10-10 用户：进出项目大图左边的黑色渐变会闪）。
            // ⚠️ 必须是 `drawingGroup`，`compositingGroup` 不行：主页淡出时透明度是逐层叠的，封面、渐变、文字各自变透明，
            // 深色模式下左边那块黑色渐变在半透明的几帧里会先被封面「透」出亮来再暗回去（实测左侧亮度 0.06 → 0.24 → 0.09，
            // `compositingGroup` 没拦住；`drawingGroup` 整张栅格化后亮度稳定在 0.06~0.09）
            .drawingGroup()
            .frame(height: 292)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        // 禁用只是挡点击（进 / 出项目、弹窗盖着时），不要变淡——变淡会让封面上的黑色渐变闪一下
        .buttonStyle(QuietButtonStyle(dimsWhenDisabled: false, hover: .none))
        .disabled(!interactionEnabled)
        .allowsHitTesting(!interaction.isOpening)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("继续创作，\(project.name)，\(project.episodeCount > 0 ? "集数 \(project.episodeCount) 集" : "集数暂无")，分镜 \(project.shotCount) 条，图片 \(project.imageCount) 张\(project.lastEdit.map { "，上次编辑 \($0)" } ?? "")")
        .background(HomeBannerCursor(enabled: interactionEnabled && onScreen && !interaction.isOpening))
        .onHover { inside in
            guard isHomeVisible else { return }
            hovering = inside && interactionEnabled && onScreen
        }
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            onScreen = visible
            if !visible && isHomeVisible && !interaction.isOpening { resetInteraction() }
        }
        .onChange(of: interactionEnabled) { _, enabled in
            // 路由会在主页淡出前禁用点击；此时保留画面。弹窗屏蔽则正常复原。
            if !enabled && isHomeVisible && !interaction.isOpening { resetInteraction() }
        }
        .onChange(of: isHomeVisible) { _, visible in
            if visible { resetInteraction() }
        }
        .onChange(of: project.key) { _, _ in resetInteraction() }
        .onDisappear { resetInteraction() }
    }
}

/// 与网格的 640×360 缓存独立：只解当前大图的首帧，最多 2048×2048，两张/32MB 内存上限。
@MainActor
private enum HomeBannerCoverCache {
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static func cached(path: String) -> NSImage? { images.object(forKey: path as NSString) }

    static func load(path: String) async -> NSImage? {
        if let image = cached(path: path) { return image }
        guard let frame = await decode(path: path), !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: frame, size: .zero)
        images.setObject(image, forKey: path as NSString, cost: frame.bytesPerRow * frame.height)
        return image
    }

    nonisolated static func decode(path: String) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let request = HomeBannerFrameRequest(path: path)
        return await withTaskCancellationHandler { @Sendable in
            guard let frame = await request.frame(),
                  !Task.isCancelled else { return nil }
            return frame
        } onCancel: {
            request.cancel()
        }
    }
}

/// AVFoundation 的旧类型未标注 Sendable。配置只在 init 写入，发布后仅使用其异步生成/取消接口。
private final class HomeBannerFrameRequest: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(path: String) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 2048, height: 2048)
    }
    func frame() async -> CGImage? { try? await generator.image(at: .zero).image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

private struct HomeBannerCover: View {
    @Environment(\.colorScheme) private var colorScheme
    let path: String?
    let isActive: Bool
    @State private var image: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        // 占位一直可用，不等待解码，也不添加项目文件或永久缓存。
        Rectangle()
            .fill(SolidTheme.inset(colorScheme))
            .overlay {
                if let image, loadedPath == path {
                    Image(nsImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "film.stack")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: isActive ? path : nil) {
                guard isActive else { return }
                guard let path else { image = nil; loadedPath = nil; return }
                // 已经是这一张就不重载：原来每次回主页都先清空再装，装不上（缓存被挤掉）就先露出一下占位图（2026-10-10 排查「大图闪」）
                if loadedPath == path, image != nil { return }
                if loadedPath != path { image = nil; loadedPath = nil }
                let loaded = await HomeBannerCoverCache.load(path: path)
                guard !Task.isCancelled else { return }
                // 图装好是淡入，不是一下子冒出来（启动时占位 → 封面那一下，2026-10-10「重启也闪」）
                withAnimation(.easeOut(duration: 0.3)) {
                    image = loaded
                    loadedPath = path
                }
            }
    }
}

/// 窗口管理 cursor rect 的生命周期，不 push/pop 全局光标栈；滚出屏幕、遮挡、离开主页会自动失效。
private struct HomeBannerCursor: NSViewRepresentable {
    let enabled: Bool
    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        guard view.enabled != enabled else { return }
        view.enabled = enabled
        view.updateTrackingAreas()
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var enabled = false
        private var cursorTrackingArea: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            if enabled { addCursorRect(visibleRect, cursor: .pointingHand) }
        }
        override func updateTrackingAreas() {
            if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
            cursorTrackingArea = nil
            if enabled {
                let area = NSTrackingArea(rect: .zero,
                    options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .enabledDuringMouseDrag],
                    owner: self)
                addTrackingArea(area)
                cursorTrackingArea = area
            }
            super.updateTrackingAreas()
        }
        override func cursorUpdate(with event: NSEvent) {
            if enabled { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
        }
    }
}

/// 历史项目卡片：整卡点击打开（除垃圾桶），项目名可重命名
struct ProjectCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let project: AppModel.ProjectSummary
    /// 缩略图路径：由主页统一算好传进来（见 WelcomeView.body 的说明）。
    /// 原来这里是 body 里现算的计算属性（遍历全部任务 + 逐个 `fileExists`），
    /// `sample` 实测那正是窗口缩放的卡顿热点。
    let thumbPath: String?
    /// 多选：是否处于选择模式（勾选框常驻）、本卡是否已勾选、点勾选框的回调
    let selectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var showRename = false
    @State private var editingName = ""
    /// 本卡是否被鼠标悬停（悬停时露出勾选框）
    @State private var hovered = false
    /// 悬停预绑的延时任务（离开卡片要取消）
    @State private var preBindWork: DispatchWorkItem?

    /// 点击打开：先作废这次预绑（理由见 ProjectCard.openCard）
    private func openCard() {
        preBindWork?.cancel()
        onOpen()
    }


    /// 右键菜单：用自绘弹层（`DropdownPanel`），行为与下拉一致 ——
    /// **已打开时再右键（或点别处）就是关闭并吞掉那一下**，不会把菜单又弹一遍。
    private func showContextMenu() {
        DropdownPanel.shared.show(
            owner: "projectMenu-\(project.key)",
            anchorWindowRect: CGRect(origin: mousePointInWindow(), size: .zero)
        ) {
            ProjectMenuContent(
                onRename: {
                    editingName = app.projectName(for: project.key)
                    showRename = true
                },
                onDelete: onDelete
            )
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 打开区域：整卡可点（除垃圾桶）
            HStack(spacing: 12) {
                if let path = thumbPath {
                    VideoThumbnailView(path: path)
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "film.stack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 96, height: 54)
                        .background(RoundedRectangle(cornerRadius: 10).fill(SolidTheme.inset(colorScheme)))
                }

                // 项目名 + 更新时间**同一行**（时间放名字右边）
                HStack(spacing: 8) {
                    Text(app.projectName(for: project.key))
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if project.updatedAt != .distantPast {
                        Text("更新于 \(Formatters.taskDate.string(from: project.updatedAt))")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .padding(.vertical, 6)
        // 选中高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底 + 蓝框（仅勾选时；平时仍然不加背景）
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.14))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Theme.accent : (hovered ? Theme.accent.opacity(0.8) : Color.clear),
                              lineWidth: isSelected ? 2 : 1.5)
        }
        // ⚠️ **不要给卡片加背景**（同网格卡片，见那边的注释：加过又被撤了）
        .contentShape(Rectangle())
        // 选择模式下点整行 = 勾选/取消（避免误开项目）；平时点行 = 打开
        .onTapGesture { selectionMode ? onToggleSelect() : openCard() }
        // 🧪 2026-10-03 性能实验：每卡勾选框已删（同工作区四卡，滚动卡顿的大头）；
        //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边
        // hover 挂在**包含勾选框**的这一层上：光标移到勾选框上也不会被判成"离开卡片"
        .onHover { hovering in
            // **滚动中冻结悬停**（2026-09-18 CPU 采样：滚动时热点全在 AttributeGraph 的脏传播
            // —— 卡片划过光标会反复写 `hovered`、整棵子树重算）。滚动期间只处理"离开"，
            // 进入一律忽略；滚动停下后重新悬停才生效。
            if !hovering {
                hovered = false
                preBindWork?.cancel()
                return
            }
            // 🧪 2026-10-03 实验 B：去掉滚动冻结（勾选框删后 hover 很轻）——滚动中也响应悬停；变卡就回退
            hovered = true
            // **悬停预绑**（2026-09-18）：停 0.45 秒就把这个项目的内容换绑做掉（工作区还隐藏着），
            // ⚠️ 0.25 → 0.45（2026-09-18）：滚动时光标停在卡片上，卡片划过会在 0.25s 内触发预绑
            //（整块换绑 = 重活）→ 滚动顿挫、CPU 窜高。拉长后滚动中基本不会误触发。
            // 真正点击时内容已就绪 → 翻页立刻发生、第一帧就是真实内容（抵消"先换绑再翻页"的等待）。
            preBindWork?.cancel()
            guard hovering, !selectionMode else { return }
            let work = DispatchWorkItem {
                // 🆕 2026-10-03：**滚动中不预绑**——v1.8.98 拆掉滚动冻结后，卡片在光标下
                // 停留 >0.45s 就会在滚动中触发"整块换绑"（重活）→ 主页滑动"有时卡一下"（用户实测）。
                // 悬停视觉照旧放行，只拦这个预绑；滚动停下后重新悬停即恢复。
                guard !ScrollActivity.shared.isScrolling else { return }
                app.preBindProject(project.key)
            }
            preBindWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        .onDisappear { preBindWork?.cancel() }
        // 重命名 / 删除改到**右键菜单**（原来是行内的小铅笔 + 垃圾桶按钮）。
        // 用自绘弹层而非系统 .contextMenu —— 原因见 ProjectMenuContent 的注释。
        // ⚠️ 必须放 **overlay（前面）** 而不是 background：SwiftUI 命中测试是从前往后，
        //    卡片内容先接住事件，背景层永远轮不到；放前面后由 CatcherView.hitTest
        //    把非右键事件返回 nil 让给下面。
        .overlay(RightClickCatcher { showContextMenu() })
        .alert("重命名项目", isPresented: $showRename) {
            TextField("项目名称", text: $editingName)
            Button("保存") { app.renameProject(project.key, to: editingName) }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 选择框（**小白边框**）：卡片左上角的勾选框 与 标题栏的「全选」共用同一套样式。
struct SelectBox: View {
    /// nil = 只有方框（卡片用）；有值 = 方框 + 文字（「全选」用）
    var title: String? = nil
    /// 文字样式可调：标题栏的「全选」要和「历史项目/已选 n」同字号同颜色
    var titleFont: Font = .system(size: 13)
    var titleColor: Color = .primary
    let isChecked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    // 底色：选中时主题色，未选中时半透明黑（保证白边框在浅色卡片上也能看清）
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isChecked ? Theme.accent : Color.black.opacity(0.22))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white, lineWidth: 2)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 18, height: 18)

                if let title {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(titleColor)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }
}

/// 项目卡片的右键菜单内容。
/// **刻意不用系统 `.contextMenu`**：系统菜单给不了「已打开时再右键 = 关闭」——
/// 它会把新菜单重新弹出来。这里用 `DropdownPanel`（下拉面板那套），
/// 于是自动获得统一行为：点外关闭**并吞掉那一下**、鼠标移开关闭、入场有动画。
private struct ProjectMenuContent: View {
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("重命名项目", icon: "pencil", action: onRename)
            row("删除项目", icon: "trash", destructive: true, action: onDelete)
        }
        .padding(.vertical, 4)
        .frame(width: 150)
        // 装在 NSPanel 里 → shadow: false（阴影由面板自己画，避免圆角处被裁出印子）
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    private func row(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            action()
            DropdownPanel.shared.dismiss()   // 选完立刻收起
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Theme.danger : Color.primary)
        }
        .buttonStyle(HoverHighlightButtonStyle(cornerRadius: 6, expandX: 8, expandY: 4))
    }
}

/// 历史项目宫格卡片：大缩略图 + 项目名 + 时间，右上角删除
struct ProjectGridCell: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let project: AppModel.ProjectSummary
    /// 缩略图路径：由主页统一算好传进来（同 ProjectCard，原因见那边的注释）
    let thumbPath: String?
    /// 多选：是否处于选择模式（勾选框常驻）、本卡是否已勾选、点勾选框的回调
    let selectionMode: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var showRename = false
    @State private var editingName = ""
    /// 本卡是否被鼠标悬停（悬停时露出勾选框）
    @State private var hovered = false
    /// 悬停预绑的延时任务（离开卡片要取消）
    @State private var preBindWork: DispatchWorkItem?

    /// 点击打开：先作废这次预绑（理由见 ProjectCard.openCard）
    private func openCard() {
        preBindWork?.cancel()
        onOpen()
    }

    /// 右键菜单：同 `ProjectCard.showContextMenu()`（自绘弹层，行为与下拉一致）
    private func showContextMenu() {
        DropdownPanel.shared.show(
            owner: "projectMenu-\(project.key)",
            anchorWindowRect: CGRect(origin: mousePointInWindow(), size: .zero)
        ) {
            ProjectMenuContent(
                onRename: {
                    editingName = app.projectName(for: project.key)
                    showRename = true
                },
                onDelete: onDelete
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 缩略图统一 **16:9**。原来是"高度固定 120、宽度随格子走"——格子宽度一变比例就变，
            // 视频会被拉成各种长宽比。这里用一个 16:9 的空盒子定比例，内容叠上去。
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let path = thumbPath {
                        VideoThumbnailView(path: path)
                    } else {
                        Image(systemName: "film.stack")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(SolidTheme.inset(colorScheme)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // 选中高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底 + 蓝框
                .overlay {
                    if isSelected {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.18))
                        }
                    }
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Theme.accent : (hovered ? Theme.accent.opacity(0.8) : SolidTheme.cardStroke(colorScheme)),
                                      lineWidth: isSelected ? 2 : (hovered ? 1.5 : 1))
                }

            // 项目名 + 更新时间**各占一行**（2026-09-12 用户要求：时间挪到名字下面）。
            //
            // ⚠️ 原来两段在同一个 HStack 里并排，**两段宽度加起来会超过格子宽** ——
            // 而格子里的缩略图是 `aspectRatio(16/9, contentMode: .fit)`、**按宽度定高**：
            // 内容一撑宽，缩略图就跟着变高，**整张卡片就被撑大了**
            //（用户实测："有个项目卡片变大了"，就是名字长 + 有更新时间的那张）。
            // 拆成两行之后，总宽只由最长的一段决定 ✓
            // 名字和时间是一组：两行之间只留 3（原来和上面的图一样隔 9，三者等距，看着松）
            VStack(alignment: .leading, spacing: 3) {
                Text(app.projectName(for: project.key))
                    .font(.system(size: 14, weight: .medium))
                    // **单行、超出直接截断**（不换行）—— 用户明确要求"不得分行，超过的不显示"
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 允许被压缩：不给它留"撑宽父容器"的余地
                    .layoutPriority(-1)
                if project.updatedAt != .distantPast {
                    Text("更新于 \(Formatters.taskDate.string(from: project.updatedAt))")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // ⚠️ **不要给卡片加背景**（2026-09-12 踩过）：曾按"不要玻璃效果"的理解给它加了一层
        // `Color.appBackground` 实底，结果多出一个**可见的底板** —— 用户："项目卡片的背景怎么又出来了"。
        // 卡片本来就没有背景（更早就是按用户要求去掉 `.glassCard` 的），**保持透明**。
        .contentShape(Rectangle())
        // 选择模式下点整张卡 = 勾选/取消（避免误开项目）；平时点卡 = 打开
        .onTapGesture { selectionMode ? onToggleSelect() : openCard() }
        // 🧪 2026-10-03 性能实验：每卡勾选框已删（同工作区四卡，滚动卡顿的大头）；
        //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边
        // hover 挂在**包含勾选框**的这一层上：光标移到勾选框上也不会被判成"离开卡片"
        .onHover { hovering in
            // **滚动中冻结悬停**（2026-09-18 CPU 采样：滚动时热点全在 AttributeGraph 的脏传播
            // —— 卡片划过光标会反复写 `hovered`、整棵子树重算）。滚动期间只处理"离开"，
            // 进入一律忽略；滚动停下后重新悬停才生效。
            if !hovering {
                hovered = false
                preBindWork?.cancel()
                return
            }
            // 🧪 2026-10-03 实验 B：去掉滚动冻结（勾选框删后 hover 很轻）——滚动中也响应悬停；变卡就回退
            hovered = true
            // **悬停预绑**（2026-09-18）：停 0.45 秒就把这个项目的内容换绑做掉（工作区还隐藏着），
            // ⚠️ 0.25 → 0.45（2026-09-18）：滚动时光标停在卡片上，卡片划过会在 0.25s 内触发预绑
            //（整块换绑 = 重活）→ 滚动顿挫、CPU 窜高。拉长后滚动中基本不会误触发。
            // 真正点击时内容已就绪 → 翻页立刻发生。⚠️ 网格是默认视图，之前只加到了列表卡片上 ✗
            preBindWork?.cancel()
            guard hovering, !selectionMode else { return }
            let work = DispatchWorkItem {
                // 🆕 2026-10-03：**滚动中不预绑**——v1.8.98 拆掉滚动冻结后，卡片在光标下
                // 停留 >0.45s 就会在滚动中触发"整块换绑"（重活）→ 主页滑动"有时卡一下"（用户实测）。
                // 悬停视觉照旧放行，只拦这个预绑；滚动停下后重新悬停即恢复。
                guard !ScrollActivity.shared.isScrolling else { return }
                app.preBindProject(project.key)
            }
            preBindWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
        .onDisappear { preBindWork?.cancel() }
        // 重命名 / 删除改到**右键菜单**（原来是名字旁的小铅笔 + 缩略图右上角的垃圾桶）。
        // 用自绘弹层而非系统 .contextMenu —— 原因见 ProjectMenuContent 的注释。
        // 放 overlay（前面），见 ProjectCard 同名处的说明。
        .overlay(RightClickCatcher { showContextMenu() })
        .alert("重命名项目", isPresented: $showRename) {
            TextField("项目名称", text: $editingName)
            Button("保存") { app.renameProject(project.key, to: editingName) }
            Button("取消", role: .cancel) {}
        }
    }
}
