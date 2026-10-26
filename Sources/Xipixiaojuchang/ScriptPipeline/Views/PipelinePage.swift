import SwiftUI
import UniformTypeIdentifiers

/// 剧本流水线工作台：剧本导入、分集、时长分割、提取素材、推理分镜。
struct PipelinePage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @State private var episodeQuery = ""

    @State private var showReimportAlert = false
    @State private var showClearAlert = false
    @State private var showErrorAlert = false
    @State private var pendingScriptURL: URL?
    @State private var pendingScriptText = ""
    @State private var pendingProjectKey: String?
    @State private var showImportSplitConfirm = false
    /// 待导入的剧本里认出了几处「第 N 集」标题（≥2 才会本地按标题分集；0 = 要让 AI 分集）
    @State private var pendingLocalEpisodeCount = 0
    @State private var errorMessage = ""

    // 分集状态
    @State private var selectedEpIndex = 0
    // 本集剧本（2026-10-07 起直接可编辑，没有「编辑 / 保存」模式）：草稿 + 停手后自动保存
    @State private var episodeDraftTitle = ""
    @State private var episodeDraftText = ""
    /// 草稿属于哪个项目 / 哪一集（nil = 还没分集的整篇剧本）。保存时用这里记的，不读当前选中的
    /// （切项目 / 切集的瞬间，当前值已经变了，草稿还是上一个的）
    @State private var draftProject: String?
    @State private var draftEpisodeID: UUID?
    /// 草稿最近一次和存档对齐时的「集 ID | 标题 | 原文」。存档的内容和它不一样 = 存档被别处改了（重新导入、AI 分集……）
    @State private var lastSyncedKey = ""
    @State private var episodeSaveTask: Task<Void, Never>?
    @FocusState private var episodeSearchFocused: Bool
    @FocusState private var titleFocused: Bool
    /// 剧本文本框 / 集标题：平时只读，点一下才进入编辑（见 `ScriptEditMode`）；点外面回到只读并存盘
    @State private var scriptEditing = false
    @State private var titleEditing = false
    /// 卡片里看的是原文还是「批量分割」的结果（导入分集后默认原文；批量分割跑完自动跳到时长分割）
    @State private var scriptField: EpisodeScriptEdit.Field = .original
    /// 草稿对应的是哪一份（切换时先把上一份存掉）
    @State private var draftField: EpisodeScriptEdit.Field = .original
    /// 工作台里这一集看哪一块：原文 / 分段（一段一张卡片）/ 时长分割（整集文本，可编辑）。
    /// 用户没手动选过时自动挑：这一集有分割结果就看「分段」，没有就看「原文」；选过之后就按他选的
    @State private var showSegments = false
    @State private var userPickedPane = false
    /// 「分段」里点开了哪一段（段号，1 起）；nil = 看卡片网格。换集 / 换标签 / 换项目时回到网格
    @State private var openSegment: Int?
    /// 刚从详情退回网格时，网格该停在哪一段：弹窗**打开时**的那一段（在弹窗里翻到别的段不算，
    /// 2026-10-13 用户定：从第一段翻到最后一段再关，网格不跟着跳到最后）
    @State private var lastOpenedSegment: WorkbenchSegmentGrid.Spot?
    /// 这次弹窗是从哪一段打开的（之后上一段 / 下一段翻页不改它）
    @State private var segmentDetailEntry: WorkbenchSegmentGrid.Spot?
    /// 「其他分镜」（不属于任何一集，2026-10-14）里点开了第几个（1 起）；nil = 没开。和 `openSegment` 分开记：它不属于任何一集
    @State private var openOther: Int?
    /// 网格滑到了「其他分镜」那一节：左边那一行亮着（集列表不跟着换集）
    @State private var viewingOthers = false
    /// 分镜网格正在滑、滑到了哪一集（只给左边集列表亮那一行用，见 `ScrolledEpisode`）
    @State private var scrolledEpisode = ScrolledEpisode()
    /// 空项目点一下：选「自由创作」还是「导入剧本」（2026-10-14 用户：软件分剧本模式和自由创作模式）
    @State private var showModeChooser = false
    /// 右键「删除这一集」要删的那一集（见 `EpisodeEdit`）
    @State private var deletingEpisode: Int?
    /// 拖进来的 txt 认出是分镜：等确认导入
    @State private var pendingDroppedShots: [String] = []
    @State private var pendingDroppedName = ""
    /// 左边点了一集、而且正在看「分镜」：让网格滑到那一集开头（所有集连着滑，2026-10-13）
    @State private var episodeRequest: WorkbenchSegmentGrid.EpisodeRequest?
    /// 滑动换集后还没存进存档的「看到第几集」（哪个项目、第几集）。离开这一页 / 换项目时才存：
    /// 存档一变，所有看存档的地方（包括藏着的生视频页整列卡片）都要重算，滑动中途存会卡一大下（2026-10-13 实测 500～700 ms）
    @State private var pendingEpIndex: (key: String, index: Int)?
    /// 整页的大小：分段弹窗按它定尺寸
    @State private var pageSize: CGSize = .zero

    // 词典清单状态

    private var currentArchive: ProjectPipelineArchive? {
        app.currentPipelineArchive
    }

    private var hasLoadedScript: Bool {
        guard let a = currentArchive else { return false }
        return !a.wholeScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            // 还没导入剧本：不放集列表，虚线框铺满整页，和生图 / 生视频的空项目一样（2026-10-12 用户定）
            if hasLoadedScript { sidebar.frame(width: 220) }
            // 流水线各步在底部胶囊里（`WorkbenchCapsule`），原来页头右上角那个「批量分割」并进了胶囊
            scriptEpisodesPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(ModeDialogs(showChooser: $showModeChooser, droppedShots: $pendingDroppedShots, droppedName: pendingDroppedName,
                                      // 自由创作：建一张空分镜，项目就成了自由创作模式——工作台这一页换成生视频那一套，右栏选中它
                                      onFree: { app.addShotAndInspect() }, onScript: { openScriptFilePicker() },
                                      onImportShots: { shots in _ = app.importShots(shots) }))
                // 挂在这里而不是整页那条长修饰链上：那条链再长一截编译器就推断不过来
                .onChange(of: app.isScriptPageVisible) { _, visible in if visible { didShow() } else { didHide() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if hasLoadedScript {
                // 胶囊浮在卡片上面；卡片里的内容给它让位，见 `PipelinePageLayout.capsuleClearance`。
                // ⚠️ 位置和生图 / 生视频页的工具条完全一样（离内容区底边 12，`ToolbarRow` 自带），**别再额外加底边距**
                // （2026-10-10 用户：工作台的胶囊比那两页的高一截——原来这里多垫了 10）
                WorkbenchCapsule(currentEpisode: currentArchive.flatMap { $0.episodes.isEmpty ? nil : safeEpIndex(for: $0) })
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
        // 点开某一段：居中大弹窗盖在分镜网格上（2026-10-12 用户定）。点外面 / Esc 关；上一段 / 下一段在弹窗顶栏。
        // Esc 走 `RootView` 的统一路由（`app.closeWorkbenchSegmentDetail`），这里不自己装监听
        // 2026-10-26 起交给窗口那一层弹（盖住整个窗口，和生视频页点开的一样大），见 `windowModal`
        .windowModal(isPresented: segmentDetailPresented, pageVisible: app.isScriptPageVisible, pageSize: pageSize,
                     size: Self.segmentDetailSize(in:)) {
            if let number = openOther {
                WorkbenchSegmentDetail(episodeIndex: WorkbenchSegmentGrid.otherEpisode, segmentNumber: number,
                                       onSelect: { spot in openOther = spot?.episode == WorkbenchSegmentGrid.otherEpisode ? spot?.segment : nil })
            } else if let archive = currentArchive, !archive.episodes.isEmpty, let number = openSegment {
                WorkbenchSegmentDetail(episodeIndex: safeEpIndex(for: archive), segmentNumber: number,
                                       onSelect: { selectDetailSpot($0) })
            }
        }
        .onChange(of: segmentDetailShown, initial: true) { old, shown in
            syncSegmentDetailCloser()
            // 从大预览「编辑分镜」打开的：关掉二级页面回到大预览
            if old, !shown { app.reopenShotPreviewAfterSegmentDetail() }
        }
        .onAppear { syncSegmentDetailCloser() }
        .onDisappear { app.closeWorkbenchSegmentDetail = nil; app.shotPreviewReturn = nil }
        .onChange(of: currentArchive?.projectId, initial: true) { _, _ in
            persistEpIndex()          // 上一个项目滑到的那一集（按它自己的 key 存）
            flushEpisodeDraft()
            userPickedPane = false
            app.shotPreviewReturn = nil   // 换了项目：别把上个项目的大预览放回来
            openSegment = nil
            openOther = nil
            viewingOthers = false
            guard let archive = currentArchive else { loadEpisodeDraft(); return }
            selectedEpIndex = archive.epIndex
            if !archive.episodes.indices.contains(selectedEpIndex) {
                selectedEpIndex = 0
            }
            applyAutoPane(in: archive)
            restoreWorkbenchLocation(in: archive)
            loadEpisodeDraft()
        }
        // 记下点开的是哪一段：离开去生图 / 生视频再回来，接着回到这一段（见 `AppModel.workbenchLocations`）
        .onChange(of: openSegment) { old, segment in
            if old == nil, let segment { segmentDetailEntry = .init(episode: selectedEpIndex, segment: segment) }
            guard let key = app.currentProjectKey else { return }
            if let segment { app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: selectedEpIndex, segment: segment) }
            else { app.workbenchLocations[key] = nil }
        }
        // 存档里的这一集被别处改了（重新导入 / AI 分集 / 切集）而且这边没有没存的输入：草稿跟着换
        .onChange(of: episodeSourceKey) { _, key in
            if key != lastSyncedKey, episodeSaveTask == nil { loadEpisodeDraft() }
        }
        .onChange(of: episodeDraftText) { _, _ in scheduleEpisodeSave() }
        .onChange(of: episodeDraftTitle) { _, _ in scheduleEpisodeSave() }
        // 换一集 / 换一份（原文 ↔ 时长分割）：回到只读
        .onChange(of: draftEpisodeID) { _, _ in scriptEditing = false; titleEditing = false }
        .onChange(of: draftField) { _, _ in scriptEditing = false }
        // 设置弹窗之类用键盘打开（⌘,）时，编辑中的文本框先放手回到只读
        .onChange(of: app.activeModal == nil) { _, noModal in if !noModal { endScriptEditing(); endTitleEditing() } }
        // 批量分割跑完 → 跳到「分割」看结果；推理分镜跑完 → 跳到「分镜」（2026-10-10 用户定：流程顺着走，
        // 添加剧本后在「原文」，分割之后到「分割」，推理分镜之后才是「分镜」）。只在当前这一集真有这一步的结果时才跳
        .onChange(of: currentBatch?.finished) { _, finished in
            guard finished == true, let batch = currentBatch, batch.succeeded > 0,
                  let archive = currentArchive, !archive.episodes.isEmpty,
                  let target = Self.paneAfterBatch(batch.kind, episode: archive.episodes[safeEpIndex(for: archive)]) else { return }
            flushEpisodeDraft()
            scriptField = .split
            showSegments = target == .segments
            if target != .segments { openSegment = nil; lastOpenedSegment = nil }       // 退出分段详情；要去「分镜」时不打扰正开着的那一段
        }
        .onDisappear { flushEpisodeDraft(); persistEpIndex() }
        .alert(pendingLocalEpisodeCount > 0 ? "分集" : "让 AI 分集", isPresented: $showImportSplitConfirm) {
            Button("确定") { confirmImportAndSplit() }
            Button("取消", role: .cancel) { pendingScriptURL = nil; pendingScriptText = ""; pendingLocalEpisodeCount = 0 }
        } message: {
            if pendingLocalEpisodeCount > 0 {
                // 2026-10-09：有「第 N 集」标题就本地切，不调用 AI（见 `PipelineFlow.splitScript`）
                Text("已读取「\(pendingScriptURL?.lastPathComponent ?? "剧本")」，识别到 \(pendingLocalEpisodeCount) 集的标题。确定后按标题自动分集（不调用 AI，标题行保留在每集开头）。")
            } else if pendingScriptText.count > 40000 {
                Text("已读取「\(pendingScriptURL?.lastPathComponent ?? "剧本")」（全文 \(pendingScriptText.count) 字，篇幅较大，AI 分集可能较慢或超时；失败可重试或拆成几个文件分批导入）。确定后由 AI 整理分集。")
            } else {
                Text("已读取「\(pendingScriptURL?.lastPathComponent ?? "剧本")」。确定后由 AI 整理分集。")
            }
        }
        .alert("重新导入剧本", isPresented: $showReimportAlert) {
            Button("继续选择", role: .destructive) {
                openScriptFilePicker()
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let a = currentArchive {
                Text("当前项目已导入剧本「\(a.loadedFileName.isEmpty ? "未命名" : a.loadedFileName)」（\(a.wholeScript.count) 字）。重新导入将替换现有剧本内容与分集进度，是否继续？")
            } else {
                Text("重新导入将替换现有剧本内容，是否继续？")
            }
        }
        .alert("清空剧本", isPresented: $showClearAlert) {
            Button("清空", role: .destructive) {
                clearScript()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定清空当前项目的剧本与流水线进度吗？此操作不可撤销。")
        }
        .alert("提示", isPresented: $showErrorAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 分集侧栏与横向流程

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                QuietSearchField(placeholder: "搜索集号或标题", text: $episodeQuery, focus: $episodeSearchFocused)
                    .accessibilityIdentifier("pipeline-episode-search")
                if !episodeQuery.isEmpty {
                    Button { episodeQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(QuietButtonStyle()).help("清空分集搜索")
                }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .onReceive(NotificationCenter.default.publisher(for: .focusPageSearch)) { _ in      // ⌘F
                if app.isInWorkspace, app.projectPage == .script { episodeSearchFocused = true }
            }
            .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            // 搜索框平时不画边线（2026-10-10 用户：这附近的线可以去掉），点进去输入时才亮一圈主色
            .overlay {
                if episodeSearchFocused {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 1.5).allowsHitTesting(false)
                }
            }
            .padding(12)
            ScrollView {
                LazyVStack(spacing: 6) {
                    if let archive = currentArchive, !archive.episodes.isEmpty {
                        let matches = matchingEpisodeIndices(in: archive)
                        if matches.isEmpty {
                            Text("没有匹配的分集").font(.callout).foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                        // 每集的「下一步」只在这个壳里算：分镜 / 生图卡 / 视频任务变化时只重画这一列
                        WorkbenchBoardReader { board in
                            ForEach(matches, id: \.self) { index in
                                episodeRow(index, in: archive, status: board?.episodes.indices.contains(index) == true ? board?.episodes[index] : nil)
                            }
                            // 最下面「添加集」：末尾加一个空集（2026-10-15 用户）。搜索时不显示
                            if episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { addEpisodeButton }
                            // 最下面「其他分镜」：不属于任何一集的分镜（有才显示）。点一下滑到网格最后那一节
                            if let count = board?.otherShotIDs.count, count > 0,
                               episodeQuery.isEmpty || "其他分镜".contains(episodeQuery.trimmingCharacters(in: .whitespaces)) {
                                EpisodeRow(number: 0, title: "其他分镜", summary: "\(count) 个分镜", tone: .normal, selected: viewingOthers,
                                           numberText: "··") { showOthers() }
                                    .equatable()
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "film.stack").font(.title2)
                            Text("还没有分集").font(.callout)
                            Text("导入剧本并分集后\n各集会显示在这里")
                                .font(.caption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("pipeline-episode-list")
            .alert("删除这一集？", isPresented: Binding(get: { deletingEpisode != nil }, set: { if !$0 { deletingEpisode = nil } })) {
                Button("删除", role: .destructive) { if let index = deletingEpisode { deleteEpisode(index) } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这一集还没有分割，删掉后原文也一起删掉。")
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func matchingEpisodeIndices(in archive: ProjectPipelineArchive) -> [Int] {
        let query = episodeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return archive.episodes.indices.filter { index in
            query.isEmpty || archive.episodes[index].title.localizedCaseInsensitiveContains(query) ||
            "第\(index + 1)集".contains(query) || String(format: "%02d", index + 1).contains(query)
        }
    }

    private func episodeRow(_ index: Int, in archive: ProjectPipelineArchive, status: WorkbenchStatus.EpisodeStatus?) -> some View {
        let episode = archive.episodes[index]
        // 一句话：这一集下一步该做什么（「待提取素材 · 缺 3 张卡」）；算不出来时退回字数
        let tone: EpisodeRow.Tone = status?.hasFailure == true ? .warning : (status?.stage == .done ? .done : .normal)
        let row = { (selected: Bool) in
            EpisodeRow(number: index + 1, title: episode.title.isEmpty ? "第 \(index + 1) 集" : episode.title,
                       summary: status?.line ?? "\(episode.text.count) 字", tone: tone, selected: selected) {
                // 点的时候再取存档（这一行没变就不重画，闭包里留着的可能是旧的那份）
                if let latest = currentArchive { selectEpisode(index, in: latest) }
            }
        }
        return ScrolledEpisodeRow(index: index, committed: viewingOthers ? nil : safeEpIndex(for: archive),
                                  scrolled: scrolledEpisode, row: row)
        // 只有最后一集、还没分割、没有分镜卡的能删（加错了的空集）；删中间的会让后面各集改号
        .contextMenu {
            if EpisodeEdit.canDelete(index, in: archive) {
                Button("删除这一集", role: .destructive) { deletingEpisode = index }
            }
        }
    }

    private var addEpisodeButton: some View {
        Button { addEpisode() } label: {
            Label("添加集", systemImage: "plus").font(.callout)
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(hover: .fill()))
        .foregroundStyle(.secondary)
        .help("在最后加一个空集，点进「原文」粘贴这一集的剧本")
        .accessibilityIdentifier("pipeline-add-episode")
    }

    /// 末尾加一个空集，选中它、停在「原文」
    private func addEpisode() {
        flushEpisodeDraft()
        guard let key = app.currentProjectKey, let latest = app.pipelineArchive(for: key) else { return }
        let (next, index) = EpisodeEdit.appending(to: latest)
        app.savePipelineArchive(next, for: key)
        selectEpisode(index, in: next)
        if pane != .original { setPane(.original) }
    }

    private func deleteEpisode(_ index: Int) {
        deletingEpisode = nil
        flushEpisodeDraft()
        guard let key = app.currentProjectKey, let latest = app.pipelineArchive(for: key),
              let next = EpisodeEdit.deleting(index, from: latest) else { return }
        if selectedEpIndex >= next.episodes.count { selectedEpIndex = next.episodes.count - 1 }
        app.savePipelineArchive(next, for: key)
    }

    private var currentBatch: PipelineFlow.BatchState? {
        app.currentProjectKey.flatMap { app.pipelineFlow.batches[$0] }
    }

    /// 当前阶段先落地剧本分集页；其余三个入口保留统一导航位置，逐页接入。
    @ViewBuilder
    private var scriptEpisodesPage: some View {
        if let archive = currentArchive, hasLoadedScript {
            episodeScriptEditorPage(archive)
        } else {
            emptyScriptContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)            // 四边一样，和生图 / 生视频的空项目一致（2026-10-12；原来顶部 0、其余 20）
        }
    }

    @ViewBuilder
    private func episodeScriptEditorPage(_ archive: ProjectPipelineArchive) -> some View {
        let index = safeEpIndex(for: archive)
        let episode = archive.episodes.indices.contains(index) ? archive.episodes[index] : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(episode == nil ? "剧本原文" : "本集剧本")
                    .font(.title3.weight(.semibold))
                if episode != nil {
                    // 集标题：平时是一行字（没有输入框的指针），点一下才变成输入框（点外面存盘并变回去）
                    Group {
                        if titleEditing {
                            TextField("集标题", text: $episodeDraftTitle)
                                .textFieldStyle(.plain)
                                .focused($titleFocused)
                        } else {
                            Text(episodeDraftTitle.isEmpty ? "集标题" : episodeDraftTitle)
                                .foregroundStyle(episodeDraftTitle.isEmpty ? .tertiary : .secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .hoverHighlight(radius: 6)
                                .onTapGesture { beginTitleEditing() }
                                .help("点一下编辑集标题")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .inputChrome(focused: titleFocused, radius: Theme.Radius.chip)
                    .frame(minWidth: 160, maxWidth: 360)            // 最窄 160：右边的失败提示再长也不会把它挤没
                    .onChange(of: titleFocused) { _, focused in
                        if !focused { titleEditing = false; flushEpisodeDraft() }
                    }
                    .accessibilityIdentifier("pipeline-script-title-editor")
                }
                Spacer()
                // 原文 / 分段 / 时长分割：这一集有分割结果默认看「分段」（一段一张卡片）；「时长分割」是整集文本，可以直接改。
                // 点开某一段是盖在网格上的弹窗（2026-10-12），这一行不变；视频失败提示在弹窗的顶栏里
                if episode != nil {
                    // 自绘分段条：宽度固定，切换时不变（系统分段按钮的宽度跟着字走）
                    SegmentedBar(options: ScriptPane.allCases.map { ($0.rawValue, $0) },
                                 selection: Binding(get: { pane }, set: { setPane($0) }))
                        .frame(width: 200, height: 28)
                        .accessibilityIdentifier("pipeline-script-field-picker")
                }
                // 还没分集（整篇剧本）时才有「剧本分集」；分集之后这里不放按钮
                if episode == nil {
                    Button("剧本分集") { handleStartSplit(archive) }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(app.pipelineFlow.active(project: app.currentProjectKey ?? "", episode: nil))
                        .pipelineActivityGlow(app.pipelineFlow.glowing(.script, project: app.currentProjectKey ?? ""))
                        .accessibilityIdentifier("pipeline-script-next")
                }
            }
            .frame(height: PipelinePageLayout.headerContentHeight).padding(.horizontal, 14).padding(.vertical, 8)

            Divider().opacity(0.2)

            // 剧本直接在这里改：停手 1 秒自动存，切集 / 点到别处 / 离开页面时马上存
            // 平时只读、点一下才编辑、点外面回到只读并存盘（见 `ScriptTextEditor`）
            if episode != nil, pane == .segments {
                // 点开某一段 = 盖在网格上的居中弹窗（见 `body` 里的 `.appModal`），网格一直在后面
                WorkbenchSegmentGrid(currentEpisode: index, scrollTo: lastOpenedSegment, episodeRequest: episodeRequest,
                                     holdsPosition: segmentDetailShown, projectKey: app.currentProjectKey,
                                     onOpen: { openSegmentFromGrid($0) },
                                     onVisibleEpisode: { episode in
                                         // 滑进「其他分镜」那一节：左边那一行亮；集列表不换集
                                         let others = episode == WorkbenchSegmentGrid.otherEpisode
                                         if viewingOthers != others { viewingOthers = others }
                                         // 滑动中只换左边那一行的高亮，手停了再真换集（见 `ScrolledEpisode`）
                                         if !others { scrolledEpisode.index = episode }
                                     },
                                     onScrollSettled: {
                                         if let episode = scrolledEpisode.index { followEpisode(episode) }
                                     })
                    .equatable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
            ScriptTextEditor(text: $episodeDraftText, isEditing: $scriptEditing, bottomInset: PipelinePageLayout.capsuleClearance - 22,
                             onEndEditing: { flushEpisodeDraft() })
                .padding(12)
                .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .help(scriptEditing ? "" : "点一下开始编辑")
                .inputChrome(focused: scriptEditing)
                .padding(10)
                .id("\(draftEpisodeID?.uuidString ?? "whole")-\(draftField.rawValue)")   // 换一集 / 换一份就换一个编辑器（撤销记录不串）
                .overlay(alignment: .topLeading) {
                    if episode != nil, draftField == .split, episodeDraftText.isEmpty {
                        Text("这一集还没有分割结果。点底部的「分割」。")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 36).padding(.top, 36)
                            .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .accessibilityIdentifier("pipeline-script-text-editor")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)       // 四周留白收紧（2026-10-09 用户：空白太多、浪费空间）；底部胶囊浮在卡片上，内容给它让位（见 `capsuleClearance`）
    }

    // MARK: 本集剧本：草稿与自动保存

    /// 存档里「当前这一集」的 集 ID | 标题 | 原文（没分集就是整篇剧本）
    private var episodeSourceKey: String {
        guard let archive = currentArchive else { return "" }
        let index = safeEpIndex(for: archive)
        if archive.episodes.indices.contains(index) {
            let e = archive.episodes[index]
            let text = scriptField == .original ? e.text : (e.splitText ?? "")
            return "\(e.id)|\(e.title)|\(scriptField.rawValue)|\(text)"
        }
        return "whole|\(archive.wholeScript)"
    }

    /// 从存档装入草稿
    private func loadEpisodeDraft() {
        guard let archive = currentArchive else {
            draftProject = nil; draftEpisodeID = nil
            episodeDraftTitle = ""; episodeDraftText = ""
            lastSyncedKey = ""
            return
        }
        let index = safeEpIndex(for: archive)
        draftProject = app.currentProjectKey
        if archive.episodes.indices.contains(index) {
            let e = archive.episodes[index]
            draftEpisodeID = e.id
            draftField = scriptField
            episodeDraftTitle = e.title
            episodeDraftText = scriptField == .original ? e.text : (e.splitText ?? "")
        } else {
            draftField = .original
            draftEpisodeID = nil
            episodeDraftTitle = ""
            episodeDraftText = archive.wholeScript
        }
        lastSyncedKey = episodeSourceKey
    }

    private func scheduleEpisodeSave() {
        // 草稿和存档一致（刚装入 / 刚存完）时什么都不用做
        let key = draftKey(title: episodeDraftTitle, text: episodeDraftText)
        guard key != lastSyncedKey else { return }
        episodeSaveTask?.cancel()
        episodeSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            flushEpisodeDraft()
        }
    }

    private func draftKey(title: String, text: String) -> String {
        if let id = draftEpisodeID { return "\(id)|\(title.trimmingCharacters(in: .whitespacesAndNewlines))|\(draftField.rawValue)|\(text)" }
        return "whole|\(text)"
    }

    /// 立刻把草稿写回存档（没改动就什么都不做）
    // MARK: 点一下才编辑（见 `ScriptEditMode`）

    /// 回到只读并存盘（打开弹窗时用；点文本框外面 / 换到别的输入框由文本框自己处理）
    /// 切到生图 / 生视频页时这一页只是藏起来（不再拆掉，见 RootView 的 `scriptPageMaterialized`），`onDisappear` 不会来：
    /// 正在编辑的文本框先放手（走它自己的存盘），没存的草稿马上存
    private func didHide() {
        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.keyWindow?.makeFirstResponder(nil) }
        endScriptEditing()
        endTitleEditing()
        flushEpisodeDraft()
        persistEpIndex()
    }

    private func endScriptEditing() {
        guard scriptEditing else { return }
        scriptEditing = false          // 文本框收到后会放掉焦点，并走 onEndEditing 存盘
        flushEpisodeDraft()
    }

    private func beginTitleEditing() {
        titleEditing = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private func endTitleEditing() {
        guard titleEditing else { return }
        titleEditing = false
        titleFocused = false
        flushEpisodeDraft()
    }

    private func flushEpisodeDraft() {
        episodeSaveTask?.cancel()
        episodeSaveTask = nil
        guard let projectKey = draftProject, let archive = app.pipelineArchive(for: projectKey),
              let updated = EpisodeScriptEdit.applying(title: episodeDraftTitle, text: episodeDraftText,
                                                       episodeID: draftEpisodeID, field: draftField, to: archive) else { return }
        app.savePipelineArchive(updated, for: projectKey)
        guard app.pipelineArchive(for: projectKey) == updated else {
            errorMessage = "剧本保存失败，请重试。"
            showErrorAlert = true
            return
        }
        lastSyncedKey = draftKey(title: episodeDraftTitle, text: episodeDraftText)
    }

    private func safeEpIndex(for archive: ProjectPipelineArchive) -> Int {
        if archive.episodes.isEmpty { return 0 }
        if archive.episodes.indices.contains(selectedEpIndex) { return selectedEpIndex }
        return archive.episodes.indices.contains(archive.epIndex) ? archive.epIndex : 0
    }

    // MARK: 原文 / 分割 / 分镜

    /// 顺着流程走：原文 → 分割（时长分割的文本）→ 分镜（推理分镜之后，一段一张卡）。
    /// 2026-10-10 用户定：标签叫「原文 / 分割 / 分镜」（原来叫「原文 / 时长分割 / 分段」），和底部胶囊的步骤名一致
    enum ScriptPane: String, CaseIterable { case original = "原文", split = "分割", segments = "分镜" }

    /// 一集默认看哪一页：已经推理出分镜 → 分镜；只有分割 → 分割；都没有 → 原文
    static func autoPane(for episode: Episode?) -> ScriptPane {
        guard let episode else { return .original }
        if !(episode.shotIDs ?? []).isEmpty { return .segments }
        if !(episode.splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .split }
        return .original
    }

    /// 一个批量任务跑完后，当前这一集该跳到哪一页：分割 → 「分割」，推理分镜 → 「分镜」；这一集没有对应结果（这次没轮到它）、
    /// 或是提取素材，就不跳
    static func paneAfterBatch(_ kind: PipelineFlow.BatchState.Kind, episode: Episode) -> ScriptPane? {
        switch kind {
        case .split, .naming: return autoPane(for: episode) == .original ? nil : .split      // 命名的结果（头行）就写在分割的文字里
        case .infer: return autoPane(for: episode) == .segments ? .segments : nil
        case .extract: return nil
        }
    }

    private var pane: ScriptPane {
        showSegments ? .segments : (scriptField == .original ? .original : .split)
    }

    private func setPane(_ new: ScriptPane) {
        flushEpisodeDraft()
        userPickedPane = true
        openSegment = nil
        lastOpenedSegment = nil
        showSegments = new == .segments
        switch new {
        case .original: scriptField = .original
        case .split, .segments: scriptField = .split      // 「分段」只看不改，草稿放的还是时长分割那份，改完这一集回来内容不丢
        }
    }

    /// 用户没手动选过时，按这一集做到哪一步自动挑（见 `autoPane`）
    private func applyAutoPane(in archive: ProjectPipelineArchive, episode index: Int? = nil) {
        guard !userPickedPane else { return }
        let i = index ?? safeEpIndex(for: archive)
        let target = Self.autoPane(for: archive.episodes.indices.contains(i) ? archive.episodes[i] : nil)
        flushEpisodeDraft()
        showSegments = target == .segments
        scriptField = target == .original ? .original : .split
    }

    /// 分段弹窗现在开着没有：点开了某一段、而且正在看「分镜」网格
    private var segmentDetailShown: Bool {
        if openOther != nil { return true }
        guard openSegment != nil, pane == .segments, let archive = currentArchive else { return false }
        return !archive.episodes.isEmpty
    }

    private var segmentDetailPresented: Binding<Bool> {
        Binding(get: { segmentDetailShown }, set: { if !$0 { setOpenSegment(nil); openOther = nil } })
    }

    /// 弹窗大小：四周各留出一圈，背后看得见；太宽的屏幕上不再变宽。
    /// 拿窗口内容区算（2026-10-26 起弹在整个窗口上，生视频页点开的段落详情也用这个，见 `RootModals.size`）
    static func segmentDetailSize(in available: CGSize) -> CGSize {
        CGSize(width: max(min(available.width - 72, 1440), 600), height: max(available.height - 56, 480))
    }

    /// 弹窗开着时把「关掉它」交给 Esc 统一路由，关着时收回
    private func syncSegmentDetailCloser() {
        app.closeWorkbenchSegmentDetail = segmentDetailShown ? { setOpenSegment(nil); openOther = nil } : nil
    }

    /// 点开 / 切换 / 退出某一段。退出（nil）时记下这次弹窗是从哪一段打开的：网格停在那里，不跟着翻页跳
    private func setOpenSegment(_ new: Int?) {
        if new == nil, let old = openSegment {
            lastOpenedSegment = segmentDetailEntry ?? .init(episode: selectedEpIndex, segment: old)
            // 弹窗里翻到了别的集：关掉时左边集列表 / 页头也回到打开时那一集（网格本来就停在那里，见 `holdsPosition`）
            if let entry = segmentDetailEntry, entry.episode != selectedEpIndex { followEpisode(entry.episode) }
        }
        openSegment = new
    }

    /// 上次离开时点开着某一段（而且这一集和这一段还在）：回到「分段」标签、点开那一段
    private func restoreWorkbenchLocation(in archive: ProjectPipelineArchive) {
        guard let key = app.currentProjectKey, let saved = app.workbenchLocations[key],
              saved.episodeIndex == selectedEpIndex, archive.episodes.indices.contains(saved.episodeIndex),
              SplitSegments.parse(archive.episodes[saved.episodeIndex].splitText ?? "").contains(where: { $0.number == saved.segment }) else { return }
        userPickedPane = true
        showSegments = true
        scriptField = .split
        openSegment = saved.segment
    }

    private func selectEpisode(_ index: Int, in archive: ProjectPipelineArchive) {
        guard archive.episodes.indices.contains(index) else { return }
        scrolledEpisode.index = nil
        flushEpisodeDraft()   // 上一集改到一半的先存
        viewingOthers = false
        selectedEpIndex = index
        openSegment = nil
        lastOpenedSegment = nil
        if pane == .segments {
            // 「分镜」是所有集连着的一整列：不换页，滑到那一集开头（还没分割的集也在列里，不自动跳去「原文」）
            episodeRequest = .init(episode: index)
        } else {
            applyAutoPane(in: archive, episode: index)
        }
        pendingEpIndex = nil
        // 用刚存完的最新存档（传进来的 `archive` 是点击前的快照，拿它存会把刚存的剧本改动盖回去）
        if let projectKey = app.currentProjectKey, var updated = app.pipelineArchive(for: projectKey), updated.epIndex != index {
            updated.epIndex = index
            app.savePipelineArchive(updated, for: projectKey)
        }
    }

    /// 在「分镜」里滑到了别的集（那一集的节头滑到了顶上）：左边集列表、页头、底部胶囊跟着换成这一集；
    /// 「看到第几集」先记着，离开这一页时再存（见 `pendingEpIndex`）
    private func followEpisode(_ index: Int) {
        scrolledEpisode.index = nil
        guard let archive = currentArchive, archive.episodes.indices.contains(index), index != selectedEpIndex else { return }
        let started = Date()
        flushEpisodeDraft()
        selectedEpIndex = index
        if let key = app.currentProjectKey { pendingEpIndex = (key, index) }
        // 换一集这一下花了多久（页面跟着重算完）：超过 30 ms 记一笔，看滑动卡不卡在这里
        DispatchQueue.main.async {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if ms > 30 { AppLog.write("workbench", "滑到第 \(index + 1) 集：页面跟着换用了 \(ms) ms") }
        }
    }

    /// 把滑动换集时记下的「看到第几集」存进存档（离开这一页 / 换项目 / 页面拆掉时）
    private func persistEpIndex() {
        guard let pending = pendingEpIndex else { return }
        pendingEpIndex = nil
        guard var archive = app.pipelineArchive(for: pending.key), archive.episodes.indices.contains(pending.index),
              archive.epIndex != pending.index else { return }
        archive.epIndex = pending.index
        app.savePipelineArchive(archive, for: pending.key)
    }

    /// 弹窗里翻页（可以翻到别的集）/ 关掉（nil）
    private func selectDetailSpot(_ spot: WorkbenchSegmentGrid.Spot?) {
        guard let spot else { setOpenSegment(nil); return }
        let crossed = spot.episode != selectedEpIndex
        if crossed { followEpisode(spot.episode) }
        setOpenSegment(spot.segment)
        // 换了集、段号却碰巧一样时 `openSegment` 没变，记位置的 onChange 不会来：这里补记
        if crossed, let key = app.currentProjectKey {
            app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: spot.episode, segment: spot.segment)
        }
    }

    /// 网格上点开了某一段（可能是别的集的）：先认那一集，再打开
    private func openSegmentFromGrid(_ spot: WorkbenchSegmentGrid.Spot) {
        if spot.episode == WorkbenchSegmentGrid.otherEpisode { openOther = spot.segment; return }
        if spot.episode != selectedEpIndex { followEpisode(spot.episode) }
        openSegment = spot.segment
    }

    /// 这一页藏着时别处要它打开某一集某一段（生图页「用到它的分段」，见 `AppModel.workbenchOpenSegment`）：
    /// 这一页常驻、回来时不会重新出现，在这里接上
    private func didShow() {
        guard let archive = currentArchive, let key = app.currentProjectKey, let saved = app.workbenchLocations[key],
              archive.episodes.indices.contains(saved.episodeIndex),
              saved.episodeIndex != selectedEpIndex || saved.segment != openSegment,
              SplitSegments.parse(archive.episodes[saved.episodeIndex].splitText ?? "").contains(where: { $0.number == saved.segment }) else { return }
        flushEpisodeDraft()
        selectedEpIndex = saved.episodeIndex
        userPickedPane = true
        showSegments = true
        scriptField = .split
        openSegment = saved.segment
    }

    // MARK: - 剧本导入为空时的视图

    // MARK: 其他分镜（不属于任何一集，2026-10-14 把生视频并进工作台）

    /// 左边点「其他分镜」：换到「分镜」网格、滑到最后那一节
    private func showOthers() {
        if pane != .segments { setPane(.segments) }
        viewingOthers = true
        episodeRequest = .init(episode: WorkbenchSegmentGrid.otherEpisode)
    }


    /// 空项目：点一下选「自由创作」还是「导入剧本」；拖 txt 进来自动认是分镜还是剧本（2026-10-14 用户）
    private var emptyScriptContent: some View {
        DropZone(action: { showModeChooser = true }) {
            VStack(spacing: 10) {
                Image(systemName: "doc.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("点击开始").font(.callout)
                Text("或将 TXT 拖到这里（剧本、分镜都认）").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .accessibilityIdentifier("pipeline-script-drop-zone")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            handleDroppedFile(url)
            return true
        }
    }

    /// 拖进来的 txt：有 `[场景][角色][道具]` 开头的行就是分镜（先确认再导入，进自由创作）；没有就当剧本（走原来的分集确认）
    private func handleDroppedFile(_ url: URL) {
        if let text = TextFileReader.read(url), let shots = ShotScriptParser.storyboardShots(text) {
            pendingDroppedName = url.lastPathComponent
            pendingDroppedShots = shots
        } else {
            prepareScriptImport(url)
        }
    }

    // MARK: - 交互操作

    private func openScriptFilePicker() {
        guard app.currentProjectKey != nil else {
            errorMessage = "未在项目中，请先选择或创建一个项目。"
            showErrorAlert = true
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "选择剧本文本（支持 TXT、UTF-8 / GBK 编码）"
        var types: [UTType] = [.plainText]
        if let utTxt = UTType(filenameExtension: "txt") { types.append(utTxt) }
        panel.allowedContentTypes = types

        panel.begin { response in
            if response == .OK, let url = panel.url { prepareScriptImport(url) }
        }
    }

    private func prepareScriptImport(_ url: URL) {
        if url.pathExtension.lowercased() == "json" {
            errorMessage = "暂不支持导入项目存档 JSON（旧存档导入已移除），请选择 TXT 剧本文件。"
            showErrorAlert = true
            return
        }
        guard let content = EpisodeSplitter.loadText(url), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "无法读取剧本，请选择 TXT 文本文件。"; showErrorAlert = true; return
        }
        pendingScriptURL = url
        pendingScriptText = content
        pendingLocalEpisodeCount = EpisodeSplitter.split(content).count
        pendingProjectKey = app.currentProjectKey
        showImportSplitConfirm = true
    }

    private func confirmImportAndSplit() {
        guard let key = pendingProjectKey, key == app.currentProjectKey, let url = pendingScriptURL else { return }
        let value = ProjectPipelineArchive(projectId: UUID(uuidString: key) ?? UUID(), wholeScript: pendingScriptText,
                                           loadedFileName: url.lastPathComponent)
        app.savePipelineArchive(value, for: key)
        selectedEpIndex = 0
        pendingScriptURL = nil
        pendingScriptText = ""
        pendingLocalEpisodeCount = 0
        pendingProjectKey = nil
        app.pipelineFlow.splitScript(app: app, project: key)
    }

    private func clearScript() {
        guard let projectKey = app.currentProjectKey else { return }
        app.removePipelineArchive(for: projectKey)
        selectedEpIndex = 0
    }

    private func handleStartSplit(_ archive: ProjectPipelineArchive) {
        if let key = app.currentProjectKey { app.pipelineFlow.splitScript(app: app, project: key) }
    }
}

/// 左边集列表的一行。只画传进来的这几个值：数据没变就不重画——滑动时当前集一换整页重画，
/// 原来几十行全都跟着重算，只有新旧两行的高亮真的变了（2026-10-14 用户：分镜滑动还有轻微卡顿）
private struct EpisodeRow: View, Equatable {
    enum Tone: Equatable { case normal, warning, done }
    let number: Int
    let title: String
    let summary: String
    let tone: Tone
    let selected: Bool
    /// 左边那一格不写集号时写什么（「其他分镜」那一行）
    var numberText: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (a: EpisodeRow, b: EpisodeRow) -> Bool {
        a.number == b.number && a.title == b.title && a.summary == b.summary && a.tone == b.tone && a.selected == b.selected
            && a.numberText == b.numberText
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(numberText ?? String(format: "%02d", number))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(tone == .warning ? Theme.warning : (tone == .done ? Theme.success : Color.secondary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background(selected ? SolidTheme.hover(colorScheme) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityIdentifier("pipeline-episode-\(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 空项目的「自由创作 / 导入剧本」选择框，和拖进来认出是分镜时的导入确认（挂在页面上：整页那条修饰链太长，编译器推断不过来）
private struct ModeDialogs: ViewModifier {
    @Binding var showChooser: Bool
    @Binding var droppedShots: [String]
    let droppedName: String
    let onFree: () -> Void
    let onScript: () -> Void
    let onImportShots: ([String]) -> Void

    func body(content: Content) -> some View {
        content
            .alert("开始创作", isPresented: $showChooser) {
                Button("自由创作") { onFree() }
                Button("导入剧本") { onScript() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("自由创作：直接写分镜，一张一张做视频。\n导入剧本：导入剧本后分集、分割、推理分镜。")
            }
            .alert("导入分镜", isPresented: Binding(get: { !droppedShots.isEmpty }, set: { if !$0 { droppedShots = [] } })) {
                Button("导入 \(droppedShots.count) 个") {
                    let shots = droppedShots
                    droppedShots = []
                    onImportShots(shots)
                }
                Button("取消", role: .cancel) { droppedShots = [] }
            } message: {
                Text("「\(droppedName)」里识别到 \(droppedShots.count) 个分镜（每个以 [场景][角色][道具] 开头），导入后在这里一张一张做。")
            }
    }
}

/// 分镜网格滑动中「滑到了第几集」（2026-10-15 用户：滑起来不丝滑，像是左边集列表在打架）。
/// 原来每滑过一集就真换一次集（`selectedEpIndex`）：整页（页头、56 集的列表、底部胶囊、剧本草稿）跟着重算两遍，
/// 真实项目每次 30～86ms，滑过分界就顿一下。现在滑动中只改这里——只有左边列表每一行自己读它、自己换高亮；
/// 手停下来（`onScrollSettled`）才真换集。引用类型、页面本身不读它，改它不会让整页重算
@Observable
final class ScrolledEpisode {
    var index: Int?
}

/// 左边一集：亮不亮看「滑动中滑到的那一集」，没在滑就看页面当前那一集
private struct ScrolledEpisodeRow: View {
    let index: Int
    /// 页面当前那一集（在看「其他分镜」时是 nil）
    let committed: Int?
    let scrolled: ScrolledEpisode
    let row: (Bool) -> EpisodeRow

    var body: some View {
        row((scrolled.index ?? committed) == index).equatable()
    }
}
