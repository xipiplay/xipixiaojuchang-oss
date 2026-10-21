import SwiftUI
import UniformTypeIdentifiers

/// 总素材库：拖入图片/视频/音频 → 缩略图 + 预上传为直链，供分镜 @ 引用。
///
/// **挂载方式**：由 `RootView` 的 `RightWorkspaceDrawerLayer` 渲染在右侧，与任务抽屉共用位置。
/// 可拖/双击进素材区；内部不对父容器宽度做假设。
struct LibraryView: View {
    @FocusState private var searchFocused: Bool
    @Environment(AppModel.self) private var app
    @State private var showImporter = false
    @State private var displayMode: DisplayMode = .grid
    @State private var searchText = ""
    /// 分类筛选（全部 / 角色 / 场景 / 道具）。与任务抽屉的「筛选」行对应。
    @State private var category: LibraryCategory = .all

    enum DisplayMode: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
    }

    /// 素材库的分类切换条（全部 / 角色 / 场景 / 道具）。
    ///
    /// 分类**不直接存在 `LibraryItem` 上**，而是记在它的**来源生图条目**上
    /// （`LibraryItem.imageGenItemID` → `ImageGenItem.type`）。用户自己拖进来的文件没有来源，
    /// 所以只出现在「全部」里 —— 这是对的，它们本来就不属于角色/场景/道具任何一类。
    enum LibraryCategory: String, CaseIterable, Identifiable {
        case all, character, scene, prop
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: "全部"
            case .character: "角色"
            case .scene: "场景"
            case .prop: "道具"
            }
        }

        /// 对应的生图条目类型（nil = 不筛）
        var subjectType: ImageSubjectType? {
            switch self {
            case .all: nil
            case .character: .character
            case .scene: .scene
            case .prop: .prop
            }
        }
    }

    private var source: [LibraryItem] {
        app.currentProjectLibrary
    }

    private var filteredLibrary: [LibraryItem] {
        var items = source

        // 分类筛选：先建一张「生图条目 id → 类型」的表再用。
        // ⚠️ 别在 `filter` 里逐条 `app.imageItems.first(where:)` —— 那是 O(素材数 × 条目数)
        //（实测数据规模：178 张素材 × 196 条条目 ≈ 3.5 万次比较），滚动时每帧都算会掉帧。
        if let type = category.subjectType {
            var typeOf: [UUID: ImageSubjectType] = [:]
            for gen in app.imageItems {
                if let t = gen.type { typeOf[gen.id] = t }
            }
            items = items.filter { item in
                // 两级回退（来源条目 → 名字前缀），理由见 `LibraryItem.subjectType(sourceType:)`
                let resolved = item.subjectType(sourceType: item.imageGenItemID.flatMap { typeOf[$0] })
                return resolved == type
            }
        }

        guard !searchText.isEmpty else { return items }
        return items.filter { ($0.fileName ?? "").localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 分类切换条 —— **与任务抽屉的「筛选」行对应**：同一位置、同一个 segmented 样式，
            // 两个抽屉并排时头部结构完全一致。
            // 用 `SegmentedBar`（包了 `NSSegmentedControl` + `fillEqually`）而不是原生 `Picker`：
            // 原生那条只按内容自适应宽度（实测固有宽 188），跟任务抽屉那条对不齐。详见组件注释。
            // 宽度 244 = 抽屉 260 − 两侧各 8pt。**三条切换条共用这一个数**。
            SegmentedBar(options: LibraryCategory.allCases.map { ($0.displayName, $0) },
                         selection: $category)
                .frame(width: 244, height: 24)
                .padding(8)

            // 搜索行 —— 与任务抽屉的「排序」行对应（用户要求：搜索放在切换条下面）。
            // 显示方式切换顺手放同一行右侧；原来那行标题「素材库」去掉了 ——
            // 抽屉本身就是素材库，任务抽屉也没有标题，去掉之后两边更像。
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索文件名", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
                .inputChrome(focused: searchFocused, radius: 14)

                Picker("显示方式", selection: $displayMode) {
                    Image(systemName: "square.grid.2x2").tag(DisplayMode.grid)
                    Image(systemName: "list.bullet").tag(DisplayMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            if source.isEmpty {
                // 空白素材库：整块虚线投放区（点击选文件 / 直接拖入），不用按钮
                DropZone(action: { showImporter = true }) {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("拖入图片 / 视频 / 音频")
                            .font(.callout)
                        Text("或点击此处选择文件")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            } else if filteredLibrary.isEmpty {
                // 分两种空：搜索没命中 / 分类下没有素材。说清是哪一种，否则用户不知道是搜错了还是真没有
                Spacer()
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "「\(category.displayName)」下还没有素材",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("切到「全部」看看，或往素材库里加一些")
                    )
                } else {
                    ContentUnavailableView(
                        "无匹配素材",
                        systemImage: "magnifyingglass",
                        description: Text("没有文件名包含「\(searchText)」的素材")
                    )
                }
                Spacer()
            } else if displayMode == .grid {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredLibrary) { item in
                            LibraryItemRow(item: item, isGrid: true)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredLibrary) { item in
                            LibraryItemRow(item: item, isGrid: false)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }

            // 底部：**检查链接 / 一键重传**（2026-09-18 用户要求放抽屉底部，别挤搜索行）
            // 批量入库时一两百张同时在传：这里显示一共几个、传完几个、失败几个
            if app.libraryUploadBatch.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(app.libraryUploadBatch.label)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(app.libraryUploadBatch.failed > 0 ? Theme.warning : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .accessibilityIdentifier("library-upload-count")
            }
            if let note = app.libraryLinkCheckNote, !app.checkingLibraryLinks {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            HStack(spacing: 8) {
                if app.checkingLibraryLinks {
                    ProgressView().controlSize(.small)
                    Text("检查中 \(app.libraryLinkProgress.done)/\(app.libraryLinkProgress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // 2026-10-08 用户："检查链接按钮太小、太不显眼了"：原来是 .caption 的无边框小字，现在是描边按钮（常规尺寸，和别处的操作按钮一样）
                    Button {
                        Task { await app.checkLibraryLinks() }
                    } label: {
                        Label("检查链接", systemImage: "arrow.triangle.2.circlepath")
                            .lineLimit(1)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .layoutPriority(1)                   // 抽屉只有 260 宽：这个按钮先拿够宽度，挤的是旁边的重传按钮（字略缩小，不折行）
                    .help("逐个检查素材的上传链接是否还有效")
                }
                Spacer(minLength: 0)
                if app.deadLibraryLinkCount > 0 {
                    // 有失效链接是需要处理的状态：实心主按钮，一眼能看到
                    Button {
                        Task { await app.reuploadFailedLinks() }
                    } label: {
                        Text(app.reuploadingLibrary ? "重传中…" : "重传失效（\(app.deadLibraryLinkCount)）")
                            .lineLimit(1)                // 折成两行会比旁边的「检查链接」高出一截（2026-10-09 用户：看着靠下、没对齐）
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(app.reuploadingLibrary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.image, .movie, .video, .audio],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            app.addLibraryFiles(urls)
        }
        // ⚠️ **换项目时清掉筛选状态**：素材库抽屉现在是**根级常驻视图**（不再随工作区销毁重建），
        // `searchText` / `category` 会一直留着 —— 用户实测"关掉项目后搜索框里的字还在"。
        // 这些是**项目内**的浏览状态，换项目就该归零（显示方式属于个人习惯，保留）。
        .onChange(of: app.currentProjectKey) { _, _ in
            searchText = ""
            category = .all
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            // 快速返回让拖拽预览消失动画立即开始，实际处理异步执行
            Task { @MainActor in
                app.addLibraryFiles(urls)
            }
            return true
        }
    }
}

/// 素材预览弹窗：图片大图 / 视频播放 / 音频播放
struct PreviewSheet: View {
    @Environment(AppModel.self) private var app
    let item: LibraryItem

    var body: some View {
        if item.kind == .image {
            imageLayout
        } else {
            playerLayout
        }
    }

    /// 本地文件真的还在才给「在访达中显示」（与生图 / 分镜预览弹窗一致）——
    /// 素材库里有相当一部分条目的本地文件早已不在了（见 `existingLocalImageURL` 那段的注释）。
    private var revealablePath: String? {
        guard let path = item.localPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// 图片：**整张图占满弹窗、真正居中**，名字 / 按钮做成浮层（与生图大图 `ImagePreviewSheet` 同一套）。
    /// ⚠️ 2026-10-08 用户报"图片贴顶"：原来图片在「底栏上面那块」里居中，竖图顶满那块 → 上沿贴着弹窗顶边、
    /// 下面却还留着一条底栏，视觉上整体偏上。浮层不占布局，图片就能按整个弹窗居中。
    private var imageLayout: some View {
        ZStack(alignment: .topLeading) {
            imagePreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 左上浮层：素材名
            Text(item.fileName ?? "预览")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(12)

            // 右下浮层：在访达中显示（悬浮胶囊，同生图大图）
            if let path = revealablePath {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .buttonStyle(OutlineButtonStyle())
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 视频 / 音频：播放器自带控制条在底部，浮层会压在上面 → 仍用「内容 + 底栏」。
    private var playerLayout: some View {
        VStack(spacing: 0) {
            // 内容占满。
            // ⚠️ 原来上面还有一条"文件名 + `Divider()`"的标题栏，2026-09-13 按用户要求
            // **把素材名挪到底部**（和「在访达中显示」同一行）—— 顶部这条连同它的分割线一起去掉了。
            switch item.kind {
            case .image:
                EmptyView()
            case .video:
                if let player = app.mediaPlayer {
                    AVPlayerContainer(player: player)
                }
            case .audio:
                ZStack {
                    if let player = app.mediaPlayer {
                        AVPlayerContainer(player: player)
                    }
                    VStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary.opacity(0.6))
                        Text("音频播放中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }

            // 底栏：素材名 + 在访达中显示。
            HStack(spacing: 10) {
                Text(item.fileName ?? "预览")
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let path = revealablePath {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .controlSize(.small)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var imagePreview: some View {
        if let localURL = item.existingLocalImageURL {
            AsyncFullImage(path: localURL.path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let urlString = item.remoteURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("图片加载失败", systemImage: "photo")
                }
            }
        } else {
            ContentUnavailableView("图片加载失败", systemImage: "photo")
        }
    }
}

/// 素材库条目：卡片（大缩略图）或列表（小缩略图横排），音频/视频可播放
struct LibraryItemRow: View {
    @Environment(AppModel.self) private var app
    let item: LibraryItem
    let isGrid: Bool

    @State private var showRename = false
    @State private var editingName = ""

    private var isPlaying: Bool { app.playingLibraryItemID == item.id }
    private var isPlayable: Bool { item.kind != .image }

    /// 素材名 + 重命名按钮（名字点击预览，铅笔点击重命名）
    private func nameLabel(font: Font = .caption) -> some View {
        HStack(spacing: 4) {
            Text(item.matchName)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { app.previewLibraryItem(item.id) }
            Button {
                editingName = item.matchName
                showRename = true
            } label: {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(HoverHighlightButtonStyle())
        }
    }

    var body: some View {
        Group {
            if isGrid {
                gridBody
            } else {
                listBody
            }
        }
        // ⚠️ payload 用自定义的 `MaterialTransfer`，**不能改成 `item.id.uuidString`** ——
        // 纯字符串会被提示词编辑器（NSTextView）当文本接收走，拖过去变成往提示词里插 UUID。
        // 详见 `MaterialTransfer` 的注释。
        .draggable(MaterialTransfer(id: item.id)) {
            // 拖拽预览：小缩略图，避免原尺寸挡视野
            thumbnail
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.85)
        }
        .alert("重命名素材", isPresented: $showRename) {
            TextField("素材名（用于提示词匹配）", text: $editingName)
            Button("保存") { app.renameLibraryItem(item.id, to: editingName) }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: 卡片模式

    private var gridBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 缩略图统一 16:9：用 `Color.clear` 按 16/9 撑出外框（宽度随抽屉，高度 = 宽度 × 9/16），
            // 图片本体放 overlay —— 只换外框比例，缩略图内部的 `.fill` 逻辑保持不变。
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { thumbnail }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
                // ⚠️ **双击手势只"挑素材"时才挂**（`including:` 控制）。
                //
                // 挂了双击之后，SwiftUI 的单击必须**先等一段看你会不会点第二下**才触发 ——
                // 表现就是"点素材、预览弹窗慢了半拍"（用户实测反馈"弹出时长你怎么改了"）。
                // 而挑素材时单击本来就被抑制（见下面那条），等多久都无所谓；
                // 纯浏览时把它整个摘掉，单击预览恢复**即时**。
                .gesture(
                    TapGesture(count: 2).onEnded { _ in
                        app.addToDrawerTarget(item.id)
                    },
                    including: app.libraryDrawerTarget != nil ? .all : .none
                )
                .onTapGesture {
                    // ⚠️ **挑素材场景（带着宿主）下不弹预览**：预览浮层挂在 `RootModals` **之下**，
                    // 而抽屉在它之上、提示词弹窗的遮罩又在预览之上 —— 弹出来也看不见，只会像卡住。
                    // 纯浏览（没宿主）时保持原来的预览语义。
                    guard app.libraryDrawerTarget == nil else { return }
                    app.previewLibraryItem(item.id)
                }

            HStack(spacing: 6) {
                nameLabel()
                Spacer()
                uploadStatus
                Button {
                    app.removeLibraryItem(id: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 列表模式

    private var listBody: some View {
        HStack(spacing: 10) {
            // 列表缩略图同样 16:9：宽 `listThumbWidth` → 高 = 宽 × 9/16。
            // 2026-10-08 用户："素材库的列表太小了"：原来宽 44（高 ~25）、名字 .caption（10pt），在 300 宽的抽屉里只占一小条；
            // 放大到宽 88（高 ~50）、名字 .callout。嫌大嫌小改这一个数。
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(width: Self.listThumbWidth)
                .overlay { thumbnail }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                // 同 gridBody：双击仅在挑素材时挂、单击浏览时即时预览（理由见那边注释）
                .gesture(
                    TapGesture(count: 2).onEnded { _ in
                        app.addToDrawerTarget(item.id)
                    },
                    including: app.libraryDrawerTarget != nil ? .all : .none
                )
                .onTapGesture {
                    guard app.libraryDrawerTarget == nil else { return }
                    app.previewLibraryItem(item.id)
                }

            // layoutPriority：名字先拿够宽度、放不下才截断。不加的话它和 `Spacer` 平分剩余宽度，
            // 字一大（.callout）就明明有空位也被截成「角色-…夏-1」。
            nameLabel(font: .callout)
                .layoutPriority(1)

            Spacer(minLength: 0)

            uploadStatus

            Button {
                app.removeLibraryItem(id: item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(HoverHighlightButtonStyle())
        }
        .padding(.vertical, 5)
    }

    /// 列表模式缩略图宽度（16:9，高 = 宽 × 9/16）
    static let listThumbWidth: CGFloat = 88

    // MARK: 缩略图与状态

    @ViewBuilder
    private var thumbnail: some View {
        Group {
        switch item.kind {
        case .image:
            // 与下面 video 分支一致：**文件真的还在**才用本地图（localPath 字段可能指向已被删掉的文件）
            if let localURL = item.existingLocalImageURL {
                AsyncThumbImage(path: localURL.path)
            } else if let urlString = item.remoteURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        icon("photo")
                    }
                }
            } else {
                icon("photo")
            }
        case .video:
            if let path = item.localPath, FileManager.default.fileExists(atPath: path) {
                VideoThumbnailView(path: path)
            } else {
                icon("film")
            }
        case .audio:
            icon("waveform")
        }
        }
        // 「检查链接」发现失效 → 红角标（2026-09-18）
        .overlay(alignment: .topTrailing) {
            if app.libraryLinkStatus[item.id] == false {
                Text("失效")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.danger))
                    .padding(4)
            }
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.1))
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch item.uploadState {
        case .pending, .uploading:
            // 有进度就显示百分比（2026-09-19：catbox/litterbox 上传能拿到 didSendBodyData）；
            // 拿不到（还没开始 / 其它服务）就还是转圈
            if let p = app.libraryUploadProgress[item.id], p > 0 {
                Text("\(Int(p * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.warning)
        }
    }
}
