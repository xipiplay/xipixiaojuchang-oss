import SwiftUI

/// 点开一张段卡片看到的按段详情（2026-10-09 工作台第 3 步；2026-10-12 改成盖在分镜网格上的居中弹窗，点外面 / Esc 关）。
/// 2026-10-15 用户给的新布局，两栏：
/// - 左边「分镜提示词」占大半：编辑提示词弹窗整个嵌在这里（素材区、提示词点一下就改、参数 + 提交生成），右上角只重新推理这一段；
/// - 右边三个标签：「本段预览」（页面里直接播当前版本，见 `SegmentInlinePlayer`）/「本段剧情」（可以直接改，写回整集的时长分割；只有名字和剧情、占满整栏）/「历史版本」（点一下设为当前版本）；
/// - 「本段预览」下半块「本段素材」：场景 / 角色 / 道具各一个标签，两列小卡（`CompactMaterialCard`），「更换」选完马上挂到分镜上（没入库的先问一句再入库）。
/// 视频生成失败的提示在页头（见 `WorkbenchSegmentFailureNote`）。挂素材用右栏「添加素材」左边的「自动匹配」，出图去生图页 / 素材卡「···」里编辑那张卡。
struct WorkbenchSegmentDetail: View {
    @Environment(AppModel.self) private var app
    /// 测试用：右边一打开就在「本段剧情」标签（默认是「本段预览」）
    nonisolated(unsafe) static var testStartsOnStory = false
    /// 测试用：右边一打开就在「本段预览」标签（没视频时默认是「本段剧情」）
    nonisolated(unsafe) static var testStartsOnPreview = false
    /// 0 起
    let episodeIndex: Int
    let segmentNumber: Int
    /// 传 nil = 关掉弹窗、回到分段卡片；传别的位置 = 切到那一段（可以是别的集，2026-10-14 用户：翻页不限于这一集）
    let onSelect: (WorkbenchSegmentGrid.Spot?) -> Void

    var body: some View {
        WorkbenchBoardReader { board in
            content(board)
        }
    }

    @ViewBuilder
    private func content(_ board: WorkbenchStatus.Board?) -> some View {
        if episodeIndex == WorkbenchSegmentGrid.otherEpisode {
            // 「其他分镜」（不属于任何一集，2026-10-14）：没有剧本段，只有「提示词 | 素材」两栏；上一个 / 下一个在这一组里翻
            let ids = board?.otherShotIDs ?? []
            if ids.indices.contains(segmentNumber - 1) {
                let (shot, neighbors) = inputs(ids: ids, board: board)
                let segment = SplitSegments.Segment(number: segmentNumber, start: nil, end: nil, text: "", roles: [], props: [])
                let other = { (number: Int) in ids.indices.contains(number - 1) ? WorkbenchSegmentGrid.Spot(episode: episodeIndex, segment: number) : nil }
                DetailBody(episodeIndex: episodeIndex, segment: segment, total: ids.count, shot: shot, status: board?.others[ids[segmentNumber - 1]],
                           neighborThumbnails: neighbors, previous: other(segmentNumber - 1), next: other(segmentNumber + 1), onSelect: onSelect)
                    .id("other-\(ids[segmentNumber - 1])")
                    .accessibilityIdentifier("workbench-segment-detail")
            } else {
                missing
            }
        } else if let archive = app.currentPipelineArchive, archive.episodes.indices.contains(episodeIndex) {
            let episode = archive.episodes[episodeIndex]
            let segments = SplitSegments.parse(episode.splitText ?? "")
            if let segment = segments.first(where: { $0.number == segmentNumber }) {
                let ids = episode.pairedShotIDs
                let (shot, neighbors) = inputs(ids: ids, board: board)
                // 这一段有卡位、卡却不在了（在生视频页被删了）：「重新推理」可以补一张
                let slotWithoutCard = shot == nil && ids.indices.contains(segmentNumber - 1)
                let status = shot.flatMap { s in board?.episodes.indices.contains(episodeIndex) == true ? board?.episodes[episodeIndex].shots[s.id] : nil }
                let (previous, next) = Self.neighbors(of: .init(episode: episodeIndex, segment: segmentNumber), in: archive)
                DetailBody(episodeIndex: episodeIndex, segment: segment, total: segments.count, shot: shot, status: status,
                           neighborThumbnails: neighbors, slotWithoutCard: slotWithoutCard, staleStoryboard: episode.storyboardIsStale,
                           previous: previous, next: next, onSelect: onSelect)
                    .id("\(episodeIndex)-\(segmentNumber)")           // 换一段就换一份状态（正在改的文字、没应用的选择都不串）
                    .accessibilityIdentifier("workbench-segment-detail")
            } else {
                missing
            }
        } else {
            missing
        }
    }

    /// 这一段的分镜 + 相邻两段的缩略图路径。工作台藏着（从这里跳去了生图 / 生视频页）时交出上一次的，
    /// 不去读分镜 / 生图卡——否则那边每次视频轮询、出图进度都让藏着的弹窗重算一遍（2026-10-12 实测每次约 10ms）
    private final class InputCache {
        var key: String?
        var shot: ShotDraft?
    }
    @State private var inputCache = InputCache()

    /// 相邻两段的缩略图路径**不在这里算**（2026-10-15 用户：有素材的段打开 / 翻页慢）：交出一个「用的时候再算」的闭包，
    /// 页面显示出来之后才去算、去预加载，不占打开这一帧
    private func inputs(ids: [UUID], board: WorkbenchStatus.Board?) -> (ShotDraft?, () -> [String]) {
        let key = "\(episodeIndex)-\(segmentNumber)"
        let neighbors = { neighborThumbnailPaths(ids: ids, board: board) }
        if !app.isScriptPageVisible, inputCache.key == key { return (inputCache.shot, neighbors) }
        inputCache.key = key
        inputCache.shot = ids.indices.contains(segmentNumber - 1) ? app.shots.first { $0.id == ids[segmentNumber - 1] } : nil
        return (inputCache.shot, neighbors)
    }

    /// 上一段、下一段要显示的缩略图（素材行的图、提示词里「图N」的参考图）的本地路径。
    /// 当前这一段显示出来之后就在后台把它们解码进缓存：点「上一段 / 下一段」切过去时，图是现成的，不用再等一遍解码
    private func neighborThumbnailPaths(ids: [UUID], board: WorkbenchStatus.Board?) -> [String] {
        let cards = app.currentImageItems
        var paths: [String] = []
        for number in [segmentNumber - 1, segmentNumber + 1] where ids.indices.contains(number - 1) {
            guard let shot = app.shots.first(where: { $0.id == ids[number - 1] }) else { continue }
            for ref in shot.imageRefs {
                if let path = app.libraryItem(ref.libraryItemID)?.existingLocalImageURL?.path { paths.append(path) }
            }
            guard let status = board?.episodes.indices.contains(episodeIndex) == true ? board?.episodes[episodeIndex].shots[shot.id] : nil else { continue }
            for name in status.names where name.state != .missing {
                if let id = WorkbenchVersions.currentCardID(kind: name.kind, name: name.name, shot: shot, episode: episodeIndex + 1, cards: cards, app: app),
                   let card = cards.first(where: { $0.id == id }), let path = WorkbenchVersions.displayedResult(of: card)?.localPath { paths.append(path) }
            }
        }
        return paths
    }

    /// 上一段 / 下一段：同一集里前后一段；到了一集的头 / 尾就接上一集的最后一段 / 下一集的第一段（还没分割的集跳过）
    static func neighbors(of spot: WorkbenchSegmentGrid.Spot, in archive: ProjectPipelineArchive)
        -> (previous: WorkbenchSegmentGrid.Spot?, next: WorkbenchSegmentGrid.Spot?) {
        func numbers(_ episode: Int) -> [Int] { SplitSegments.parse(archive.episodes[episode].splitText ?? "").map(\.number) }
        guard archive.episodes.indices.contains(spot.episode) else { return (nil, nil) }
        let here = numbers(spot.episode)
        var previous: WorkbenchSegmentGrid.Spot?
        var next: WorkbenchSegmentGrid.Spot?
        if let i = here.firstIndex(of: spot.segment) {
            if i > 0 { previous = .init(episode: spot.episode, segment: here[i - 1]) }
            if i + 1 < here.count { next = .init(episode: spot.episode, segment: here[i + 1]) }
        }
        if previous == nil {
            for e in stride(from: spot.episode - 1, through: 0, by: -1) {
                if let last = numbers(e).last { previous = .init(episode: e, segment: last); break }
            }
        }
        if next == nil, spot.episode + 1 < archive.episodes.count {
            for e in (spot.episode + 1)..<archive.episodes.count {
                if let first = numbers(e).first { next = .init(episode: e, segment: first); break }
            }
        }
        return (previous, next)
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Text("这一段已经不在了（分割改过）。").foregroundStyle(.secondary)
            Button("关闭") { onSelect(nil) }.buttonStyle(OutlineButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 正文

private struct DetailBody: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    let episodeIndex: Int
    let segment: SplitSegments.Segment
    let total: Int
    let shot: ShotDraft?
    let status: WorkbenchStatus.ShotStatus?
    /// 相邻两段的缩略图路径：这一段出现后在后台先解码好（见 `WorkbenchSegmentDetail.neighborThumbnailPaths`）
    let neighborThumbnails: () -> [String]
    /// 这一段有卡位、卡在生视频页被删了：「重新推理」补一张
    let slotWithoutCard: Bool
    /// 这一集分割改过、段和分镜卡对不上：要整集重新推理
    let staleStoryboard: Bool
    /// 上一段 / 下一段（可以跨集；没有了是 nil）
    let previous: WorkbenchSegmentGrid.Spot?
    let next: WorkbenchSegmentGrid.Spot?
    let onSelect: (WorkbenchSegmentGrid.Spot?) -> Void

    /// 「其他分镜」（不属于任何一集）：没有剧本段，没有「本段剧情」和「重新推理」
    private var isOther: Bool { episodeIndex == WorkbenchSegmentGrid.otherEpisode }

    /// 「本段剧情」的两个格子（2026-10-11 分段命名）：下面是这 30 秒的正文，上面是它的名字（场景 / 角色 / 道具 / 本段在场）
    @State private var draft: String
    @State private var headDraft: String
    @State private var editing = false
    @State private var headEditing = false
    /// 这一段为每个名字选的版本（名字 → 卡片 ID）；没选就是现在用的那个。点「应用素材」才会真的挂到分镜上
    @State private var choices: [String: UUID] = [:]
    @State private var infoMessage = ""
    @State private var showInfo = false
    @State private var showRerun = false
    /// 这一份（这一段）第一次建出来的时间：打开耗时日志用
    @State private var openedAt = Date()
    static let promptMinWidth: CGFloat = EditPromptSheet.inlineRowMinWidth
    /// 右边上半块看哪个标签（2026-10-15 用户给的新布局）
    enum RightTab: Hashable { case preview, story }
    /// nil = 还没手动点过：有视频看「本段预览」，没视频看「本段剧情」（2026-10-15 用户）
    @State private var rightTab: RightTab?
    /// 右上「历史版本」面板开着没有
    @State private var showVersions = false
    /// 点了某个素材行的删除、等确认的名字
    @State private var removalName: String?
    /// 「应用素材」前还没入库的张数（等确认；0 = 没有在等）
    @State private var libraryPendingCount = 0

    init(episodeIndex: Int, segment: SplitSegments.Segment, total: Int, shot: ShotDraft?, status: WorkbenchStatus.ShotStatus?,
         neighborThumbnails: @escaping () -> [String], slotWithoutCard: Bool = false, staleStoryboard: Bool = false,
         previous: WorkbenchSegmentGrid.Spot? = nil, next: WorkbenchSegmentGrid.Spot? = nil, onSelect: @escaping (WorkbenchSegmentGrid.Spot?) -> Void) {
        self.previous = previous
        self.next = next
        self.neighborThumbnails = neighborThumbnails
        self.slotWithoutCard = slotWithoutCard
        self.staleStoryboard = staleStoryboard
        self.episodeIndex = episodeIndex
        self.segment = segment
        self.total = total
        self.shot = shot
        self.status = status
        self.onSelect = onSelect
        let parts = SplitSegments.splitHead(segment.text)
        _rightTab = State(initialValue: WorkbenchSegmentDetail.testStartsOnStory ? .story : WorkbenchSegmentDetail.testStartsOnPreview ? .preview : nil)
        _draft = State(initialValue: parts.body)
        _headDraft = State(initialValue: parts.head)
    }

    private var project: String { app.currentProjectKey ?? "" }
    /// 从这一段跳去生图 / 生视频页时记下，那边的「返回」用它
    private var jumpOrigin: AppModel.WorkbenchLocation { .init(projectKey: project, episodeIndex: episodeIndex, segment: segment.number) }
    private var reinferring: Bool { app.pipelineFlow.active(project: project, slot: "infer-segment") }
    private var batchRunning: Bool { app.pipelineFlow.batches[project].map { !$0.finished } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            // 各块之间不画分隔线（2026-10-10 用户：这几条区域线可以去掉）：靠框和卡片自己的底色分区
            topBar
            // 两栏（2026-10-15 用户给的新布局）：左边分镜提示词占大半；右边上面是「本段预览 / 本段剧情 / 历史版本」，下面是本段素材
            GeometryReader { geo in
                let spacing: CGFloat = 14
                let inner = geo.size.width - 28
                let right = Self.rightPanelWidth(total: inner - spacing)
                HStack(alignment: .top, spacing: spacing) {
                    column(title: "分镜提示词", actions: { promptActions }) {
                        promptTab(width: inner - spacing - right)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(SolidTheme.inset(colorScheme)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    rightPanel(width: right)
                        .frame(width: right)
                        .frame(maxHeight: .infinity)
                }
                .padding(14)
            }
        }
        // 在别处改了这一段（比如「时长分割」里）：没在这里编辑时跟着换
        .onChange(of: segment.text) { _, new in
            guard !editing, !headEditing else { return }
            let parts = SplitSegments.splitHead(new)
            draft = parts.body
            headDraft = parts.head
        }
        // 把上一段 / 下一段要显示的图提前解码进缓存（已经在缓存里的立刻返回；没有的在后台生成）
        // 页面先出来，再去算 / 预加载上一段、下一段的图（翻过去时图是现成的）
        .onAppear {
            // 打开 / 翻到这一段用了多久（建好这一份到画出来之后）：超过 30ms 记一笔，查「打开慢」用（2026-10-15）
            let started = openedAt, label = "第 \(episodeIndex + 1) 集第 \(segment.number) 段"
            DispatchQueue.main.async {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                if ms > 30 { AppLog.write("detail", "\(label) 打开用了 \(ms) ms") }
            }
            let neighbors = neighborThumbnails
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                for path in neighbors() { LocalImageCache.loadThumbnail(atPath: path) { _ in } }
            }
        }
        // 正改着剧情就关掉弹窗 / 翻到别的段：先存（编辑框没了就不会再有「点外面存盘」）
        .onDisappear { if editing || headEditing { commitDraft() } }
        .alert("提示", isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
        .alert("有 \(libraryPendingCount) 张图还没入库",
               isPresented: Binding(get: { libraryPendingCount > 0 }, set: { if !$0 { libraryPendingCount = 0 } })) {
            Button("入库并应用") { apply(rows) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用前要先存进素材库（后台上传，进度在素材库底部），视频生成才拿得到这些参考图。")
        }
        .alert(removalName.map { "从这一段删掉「\($0)」？" } ?? "",
               isPresented: Binding(get: { removalName != nil }, set: { if !$0 { removalName = nil } })) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { removeMaterial() }
        } message: {
            Text("会从提示词头行去掉这个名字，挂着的参考图一并去掉。生图页的卡不受影响。")
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            Text(isOther ? (shot.map { app.numbering(of: $0).title } ?? "分镜") : "第 \(String(format: "%02d", segment.number)) 段")
                .font(.system(size: 15, weight: .semibold))
            if let range = segment.timeRange {
                Text(range).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(status?.title ?? (segment.scene == nil ? WorkbenchStatus.Stage.toName : WorkbenchStatus.Stage.toInfer).title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            // 这一段视频最近一次生成失败才有（原来在页头右上角，弹窗盖住了页头，挪到这里）
            WorkbenchSegmentFailureNote(episodeIndex: episodeIndex, segmentNumber: segment.number)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(isOther ? "其他分镜 · \(segment.number)/\(total)" : "第 \(episodeIndex + 1) 集 · \(segment.number)/\(total)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // 翻页按钮：带字、有边框、整个框都能点；不许被挤成两行（2026-10-21 用户截图：「上一段」被挤成竖排）
            Button { onSelect(previous) } label: { Label("上一段", systemImage: "chevron.up") }
                .buttonStyle(OutlineButtonStyle()).disabled(previous == nil)
                .keyboardShortcut("[", modifiers: .command)
                .help("上一段（⌘[）")
                .accessibilityIdentifier("workbench-segment-previous")
                .fixedSize()
            Button { onSelect(next) } label: { Label("下一段", systemImage: "chevron.down") }
                .buttonStyle(OutlineButtonStyle()).disabled(next == nil)
                .keyboardShortcut("]", modifiers: .command)
                .help("下一段（⌘]）")
                .accessibilityIdentifier("workbench-segment-next")
                .fixedSize()
            Button { onSelect(nil) } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help("关闭（Esc）")
            .accessibilityIdentifier("workbench-segment-close")
        }
        .padding(.leading, 18).padding(.trailing, 12).padding(.top, 12).padding(.bottom, 4)
    }

    // MARK: 左：分镜提示词

    /// 右栏多宽：两栏总宽的 44%，最宽 620、最窄 320；左边提示词至少留 `promptMinWidth`（参数 + 「提交生成」排成一行）
    static func rightPanelWidth(total: CGFloat) -> CGFloat {
        max(min(min(total * 0.44, 620), total - promptMinWidth), 320)
    }

    /// 一栏：标题行（右边可以放按钮）+ 内容。内容不画边线（2026-10-10 用户：区域的边线可以去掉），靠底色分区
    private func column<Actions: View, Content: View>(title: String, @ViewBuilder actions: () -> Actions = { EmptyView() },
                                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)       // 和右栏「本段素材」同一个样子
                Spacer(minLength: 8)
                actions()
            }
            .frame(minHeight: 24)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// 「本段剧情」：平时只读、点一下才编辑、点外面存盘（和「本集剧本」同一个文本框）；改完写回整集的时长分割里这一段
    private var storyTab: some View {
        VStack(spacing: 8) {
            // 上：这一段的名字。分割只管切，名字由「命名」那一步写在这里；也可以直接改
            VStack(alignment: .leading, spacing: 0) {
                Text("本段名字").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 9)
                ZStack(alignment: .topLeading) {
                    ScriptTextEditor(text: $headDraft, isEditing: $headEditing, bottomInset: 0, onEndEditing: commitDraft)
                        .help(headEditing ? "" : "点一下开始编辑")
                        .accessibilityIdentifier("workbench-segment-head")
                    if headDraft.isEmpty, !headEditing {
                        Text("还没有命名。在分镜页底部点「命名」，或点一下直接写：\n【场景】：地点·区域 日 内\n【角色】：甲、乙\n【道具】：无\n【本段在场】：甲、乙")
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .frame(height: 138)
            .background(RoundedRectangle(cornerRadius: 8).fill(SolidTheme.inset(colorScheme)))
            // 和别的输入框同一套反馈（`InputChrome`）：悬停描边亮一档，正在改是一圈主色描边
            .inputChrome(focused: headEditing, radius: 8)
            // 下：本段剧情
            VStack(alignment: .leading, spacing: 0) {
                Text("本段剧情").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 9)
                ScriptTextEditor(text: $draft, isEditing: $editing, bottomInset: 0, onEndEditing: commitDraft)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .help(editing ? "" : "点一下开始编辑")
                    .accessibilityIdentifier("workbench-segment-text")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(SolidTheme.inset(colorScheme)))
            .inputChrome(focused: editing, radius: 8)
        }
    }

    /// 提示词标签右上角：只重新推理这一段
    private var promptActions: some View {
        HStack(spacing: 8) {
            if !isOther {
            Button {
                showRerun = true
            } label: {
                HStack(spacing: 5) {
                    if reinferring { ProgressView().controlSize(.small) }
                    Text(reinferring ? "推理中…" : "重新推理")
                }
            }
            .buttonStyle(OutlineButtonStyle())
            .controlSize(.small)
            .disabled((shot == nil && !slotWithoutCard) || reinferring || batchRunning)
            .help(staleStoryboard ? "这一集的分割改过了，段和分镜卡对不上，要在底部点「分镜」整集重新推理"
                  : slotWithoutCard ? "这一段的分镜卡被删了，点一下重新推理、补一张"
                  : shot == nil ? "还没有这一段的分镜，先做「分镜」" : "只重新推理这一段的分镜提示词")
            .dropdownPopover(isPresented: $showRerun) {
                RerunForm(
                    title: "重新推理这一段",
                    message: "会覆盖这一段现在的提示词（包括手改的），并清掉挂着的参考图。",
                    placeholder: "比如：这一段镜头再紧凑一点；多给一个程砚的反应镜头。",
                    confirmTitle: "重新推理",
                    onConfirm: { note in
                        app.pipelineFlow.inferSegment(app: app, project: project, episodeIndex: episodeIndex, segmentNumber: segment.number, note: note)
                    },
                    onClose: { DropdownPanel.shared.dismiss() })
            }
            .accessibilityIdentifier("workbench-segment-reinfer")
            }
        }
    }

    /// 「分镜提示词」：编辑提示词弹窗整个搬进来（2026-10-15 用户：不用再点开）——素材区（添加 / 自动匹配 / 清空）、
    /// 提示词（点一下就改、点外面就存）、生成参数 + 提交生成。翻到别的段换一份（`.id`）
    @ViewBuilder
    private func promptTab(width: CGFloat) -> some View {
        if let shot {
            EditPromptSheet(shot: shot, onClose: {}, inline: true, availableWidth: width)
                .id(shot.id)
                .accessibilityIdentifier("workbench-segment-prompt")
        } else {
            Text(staleStoryboard ? "这一集的分割改过了（段落变了），原来的分镜卡和段对不上。在底部点「分镜」整集重新推理。"
                 : slotWithoutCard ? "这一段的分镜卡被删了。点右上角「重新推理」补一张。"
                 : "这一段还没有分镜提示词。先做「分镜」。")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
        }
    }

    /// 改完的剧情写回整集的时长分割（只换这一段的行，时间标号和别的段不动）
    private func commitDraft() {
        // 两个格子合成这一段的文字（名字在上、正文在下）。和原来的比：原来的头行不在最上面也算一样（只是顺序不同，不写）
        let text = SegmentNaming.combine(head: headDraft, body: draft)
        let original = SplitSegments.splitHead(segment.text)
        guard text != SegmentNaming.combine(head: original.head, body: original.body),
              let archive = app.pipelineArchive(for: project), archive.episodes.indices.contains(episodeIndex) else { return }
        guard let updated = SplitSegments.replacing(segment: segment.number, in: archive.episodes[episodeIndex].splitText ?? "", with: text) else {
            infoMessage = "这一段的文字里不能有时间标号行（像 --- 00:00 - 00:30 那样的），改动没有保存。"
            showInfo = true
            let parts = SplitSegments.splitHead(segment.text)
            draft = parts.body
            headDraft = parts.head
            return
        }
        var changed = archive
        changed.episodes[episodeIndex].splitText = updated
        app.savePipelineArchive(changed, for: project)
    }

    // MARK: 右：本段素材

    private var rows: [DetailRowInfo] {
        guard let shot, let status else { return [] }
        let cards = app.currentImageItems
        // 素材库按 ID 查表（一次建好）：原来每个名字、每个参考图都在整个素材库里从头找一遍，有素材的段打开慢（2026-10-15）
        let index = Dictionary(app.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let library = { (id: UUID) in index[id] }
        return status.names.map { name in
            let attached = WorkbenchVersions.attachedCardID(kind: name.kind, name: name.name, shot: shot, cards: cards, app: app, library: library)
            let selectedID = choices[name.name] ?? attached
                ?? WorkbenchVersions.currentCardID(kind: name.kind, name: name.name, shot: shot, episode: episodeIndex + 1, cards: cards, app: app, library: library)
            // 选中的这张角色卡绑了音色：名字旁边一个小喇叭
            let hasVoice = selectedID.flatMap { id in cards.first { $0.id == id } }
                .flatMap { CardVoice.resolve($0, library: library) } != nil
            return DetailRowInfo(name: name,
                    versions: WorkbenchVersions.versions(kind: name.kind, name: name.name, cards: cards),
                    selectedID: selectedID,
                    attachedID: attached,
                    hasVoice: hasVoice)
        }
    }

    /// 「其他分镜」没有剧情；还没有分镜卡的段只有剧情可看
    private var availableTabs: [RightTab] {
        if isOther { return [.preview] }
        return shot == nil ? [.story] : [.story, .preview]       // 剧情在前（2026-10-15 用户）
    }
    /// 这一段生成过能看的视频没有
    private var hasVideo: Bool {
        guard let shot else { return false }
        return shot.taskIDs.contains { id in
            app.store.task(id: id)?.localVideoPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        }
    }
    private var effectiveTab: RightTab {
        if let rightTab, availableTabs.contains(rightTab) { return rightTab }
        let auto: RightTab = hasVideo ? .preview : .story
        return availableTabs.contains(auto) ? auto : availableTabs[0]
    }

    /// 右栏：上面「本段预览 / 本段剧情 / 历史版本」。
    /// 2026-10-16 用户：「本段剧情」只放名字和 30 秒剧情、占满整栏（下面再挂素材，看剧情太挤）；本段素材只跟着「本段预览」
    @ViewBuilder
    private func rightPanel(width: CGFloat) -> some View {
        if effectiveTab == .story {
            VStack(alignment: .leading, spacing: 8) {
                rightTabs
                storyTab.frame(maxHeight: .infinity, alignment: .top)
            }
        } else {
            previewPanel(width: width)
        }
    }

    /// 「本段预览」：上面视频（16:9 画面 + 下面一行字），下面本段素材（两列小卡，只能上下滑）
    private func previewPanel(width: CGFloat) -> some View {
        let rows = rows
        let pending = rows.filter(\.pending).count
        let blockHeight = width * 9 / 16 + 26
        return VStack(alignment: .leading, spacing: 8) {
            rightTabs
            previewTab.frame(height: blockHeight, alignment: .top)
            Divider().opacity(0.5).padding(.vertical, 4)
            materialsHeader(rows)
            ScrollView(.vertical) {
                materialsGrid(rows).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 只许上下滑（2026-10-16 用户录屏：妙控鼠标横划素材区会左右晃）：SwiftUI 的滚动区在竖向上也做横向橡皮筋，见 `VerticalScrollLock`
                    .background(VerticalScrollLock())
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                if pending > 0 { Circle().fill(Theme.warning).frame(width: 7, height: 7) }
                Text(shot == nil ? "" : footerNote(rows, pending: pending))
                    .font(.system(size: 11.5))
                    .foregroundStyle(pending > 0 ? Theme.warning : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(shot == nil ? 0 : 1)
            // 角色音色没挂上（渠道不收参考音频 / 关了生成音频 / 已经 3 段）：说清楚，不悄悄丢（2026-10-26，见 `ShotVoiceSync`）
            if let shot, let skips = app.voiceSyncSkips[shot.id] {
                Label("音色没挂上：\(skips.joined(separator: "；"))", systemImage: "speaker.slash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 和左边「分镜提示词」标题同一行高（24），两边框的上沿对齐。右边是「历史版本」按钮（点开面板，2026-10-15 用户给的图）
    private var rightTabs: some View {
        HStack(spacing: 18) {
            ForEach(availableTabs, id: \.self) { tab in
                let selected = tab == effectiveTab
                Button { rightTab = tab } label: {
                    HStack(spacing: 5) {
                        if tab == .story { Image(systemName: "doc.text").font(.system(size: 12)) }
                        Text(tab == .preview ? "本段预览" : "本段剧情")
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(hover: .none))
                .accessibilityIdentifier("workbench-segment-tab-\(tab == .preview ? "预览" : "剧情")")
            }
            Spacer(minLength: 0)
            if let shot, !shot.taskIDs.isEmpty {
                Button { showVersions = true } label: {
                    Label("历史版本", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 13))
                        .foregroundStyle(showVersions ? Color.primary : Color.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle(hover: .capsule))
                .help("这一段生成过的所有版本")
                .dropdownPopover(isPresented: $showVersions) {
                    SegmentVersionPanel(shotID: shot.id, onClose: { DropdownPanel.shared.dismiss() })
                }
                .accessibilityIdentifier("workbench-segment-versions")
            }
        }
        .frame(minHeight: 24)
    }

    @ViewBuilder
    private var previewTab: some View {
        if let shot {
            VStack(alignment: .leading, spacing: 8) {
                SegmentInlinePlayer(shotID: shot.id).id(shot.id)
                HStack {
                    Text("\(shot.resolution.displayName) · \(shot.aspectRatio.plainLabel) · \(shot.duration) 秒")
                    Spacer(minLength: 8)
                    Text(currentVersionNote(shot))
                }
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        } else {
            Text("这一段还没有分镜。先做「分镜」。").font(.system(size: 12.5)).foregroundStyle(.tertiary)
        }
    }

    /// 「当前预览：第 3 版」/「待生成」/「还没生成」
    private func currentVersionNote(_ shot: ShotDraft) -> String {
        if shot.showsPendingVersion { return "当前：待生成" }
        guard let id = shot.taskID, let task = app.store.task(id: id) else { return shot.taskIDs.isEmpty ? "还没生成" : "" }
        let number = task.versionNumber(in: shot.taskIDs)
        return "当前预览：第 \(number) 版"
    }

    /// 「本段素材 · N」+ 添加（不再按场景 / 角色 / 道具切换，全部排在一起，2026-10-15 用户）。
    /// 「自动匹配」2026-10-15 挪来过这里，2026-10-27 用户又挪回左栏素材那一行：审完提示词就匹配，这里在「本段预览」页里、每段都要切页
    private func materialsHeader(_ rows: [DetailRowInfo]) -> some View {
        HStack(spacing: 14) {
            Text(shot == nil ? "本段素材（预估）" : (rows.isEmpty ? "本段素材" : "本段素材 · \(rows.count)"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            if let shot {
                // 加、删都是直接改这一段分镜提示词的头行，所以提取、状态、应用素材读到的永远是同一份名字
                AddMaterialButton(suggestions: { WorkbenchVersions.suggestions(cards: app.currentImageItems) },
                                  taken: Set(rows.map(\.name.name))) { kind, name in
                    do { try WorkbenchMaterialEdit.add(name: name, kind: kind, shotID: shot.id, app: app); return nil }
                    catch { return error.localizedDescription }
                }
            }
        }
        .frame(minHeight: 26)
    }

    @ViewBuilder
    private func materialsGrid(_ rows: [DetailRowInfo]) -> some View {
        if shot != nil {
            // 场景、角色、道具依次排
            let order = PipelineFlow.ExtractionKind.allCases
            let group = rows.enumerated().sorted { a, b in
                let ka = order.firstIndex(of: a.element.name.kind) ?? 0, kb = order.firstIndex(of: b.element.name.kind) ?? 0
                return ka != kb ? ka < kb : a.offset < b.offset
            }.map(\.element)
            if group.isEmpty {
                Text("这一段的头行里没有列出素材。")
                    .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(group) { row in
                        CompactMaterialCard(
                            info: row,
                            // 更换 = 马上挂上（2026-10-15：「应用素材」按钮去掉了）
                            onChoose: { id in
                                choices[row.name.name] = id
                                prepareApply(self.rows.filter { $0.name.name == row.name.name })
                            },
                            onRemove: { removalName = row.name.name },
                            onOpenCard: { id in
                                // 生视频页打开的段落详情是浮层：跳去生图页前先关掉，不然它盖在生图页上
                                if case .segmentDetail? = app.activeModal { app.activeModal = nil }
                                app.workbenchOpenImageCard(id, from: jumpOrigin)
                            },
                            onEditCard: { id in
                                // 生视频页打开的段落详情本身就占着主浮层：生图弹窗叠在它上面（2026-10-26）
                                if case .segmentDetail? = app.activeModal {
                                    app.stackedImageEditorID = id
                                } else {
                                    app.activeModal = .editImagePrompt(itemID: id)
                                }
                            })
                    }
                }
            }
        } else {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(segment.allScenes + segment.roles + segment.props, id: \.self) { name in
                    Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }

    /// 底部那一行字：没有能挂的 / 有没挂上的（点上面的「自动匹配」）/ 都挂上了
    private func footerNote(_ rows: [DetailRowInfo], pending: Int) -> String {
        if !rows.contains(where: { $0.name.state == .ready }) { return "还没有可以挂的素材：先提取、出图" }
        return pending > 0 ? "有 \(pending) 项素材没挂上，点上面的「自动匹配」" : "这一段的素材都已挂上"
    }

    /// 「应用素材」：选中的版本里有还没入库的 → 先问一句（应用时会存进素材库）；都入库过就直接应用
    private func prepareApply(_ rows: [DetailRowInfo]) {
        let pending = WorkbenchBatch.notInLibrary(cardIDs: rows.filter { $0.name.state == .ready }.map(\.selectedID), app: app)
        if pending.isEmpty { apply(rows) } else { libraryPendingCount = pending.count }
    }

    private func removeMaterial() {
        guard let name = removalName, let shot else { return }
        removalName = nil
        choices[name] = nil
        do { try WorkbenchMaterialEdit.remove(name: name, shotID: shot.id, app: app) }
        catch {
            infoMessage = error.localizedDescription
            showInfo = true
        }
    }

    private func apply(_ rows: [DetailRowInfo]) {
        libraryPendingCount = 0
        guard let shot else { return }
        let report = WorkbenchVersions.apply(
            selections: rows.map { (kind: $0.name.kind, name: $0.name.name, cardID: $0.name.state == .ready ? $0.selectedID : nil) },
            shotID: shot.id, cards: app.currentImageItems, app: app)
        // 全部顺利就不打扰：状态和提示词本身已经变了
        var parts: [String] = []
        let unusable = rows.filter { $0.name.state != .ready }.count
        if unusable > 0 { parts.append("\(unusable) 个还没有图或还没有卡，没有挂（先提取、出图）") }
        if report.noImage > 0 { parts.append("\(report.noImage) 个选中的版本没有图") }
        if report.notInHeadLine > 0 { parts.append("\(report.notInHeadLine) 个在分镜头行里找不到名字") }
        guard !parts.isEmpty else { return }
        infoMessage = "已应用 \(report.applied) 个素材；" + parts.joined(separator: "；") + "。"
        showInfo = true
    }
}

// MARK: - 页头右上角：视频生成失败

/// 失败提示那一行本身：「⚠ 视频生成失败」按钮 +「重试视频」（「在生视频页查看」2026-10-15 去掉）。
/// 原因不再直接铺在页头（2026-10-21 用户：长原因把页头撑坏、翻页按钮被挤变形），点「视频生成失败」看全文：
/// 和任务列表同一个浮层 `TaskErrorDetail`（2026-10-30 用户：不要系统弹窗，任务列表那种就行）
struct FailureNoteRow: View {
    /// 失败原因原文（空 = 没有返回原因）
    let reason: String
    let retryDisabled: Bool
    let onRetry: () -> Void

    @State private var showReason = false

    var body: some View {
        HStack(spacing: 8) {
            Button { showReason = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("视频生成失败").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(Theme.danger)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(QuietButtonStyle(hover: .fill(radius: 6)))
            .help("点开看失败原因")
            .accessibilityIdentifier("workbench-segment-failure-reason")
            .dropdownPopover(isPresented: $showReason) {
                TaskErrorDetail(raw: reason.isEmpty ? "没有返回原因" : reason)
            }
            Button("重试视频", action: onRetry)
                .buttonStyle(OutlineButtonStyle()).controlSize(.small)
                .disabled(retryDisabled)
                .accessibilityIdentifier("workbench-segment-retry-video")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// 分段详情页页头右上角的失败提示（2026-10-10 用户定：原来在页面里单独占一行的横幅，挪到页头右边——进了某一段，
/// 原来放「原文 / 分段 / 时长分割」的位置没用了）。这一段视频最近一次生成失败了才显示：点「视频生成失败」浮层看原因，
/// 旁边是重试；没失败就什么都不画
struct WorkbenchSegmentFailureNote: View {
    @Environment(AppModel.self) private var app
    /// 0 起
    let episodeIndex: Int
    let segmentNumber: Int

    @State private var showRetryConfirm = false
    @State private var infoMessage = ""
    @State private var showInfo = false

    var body: some View {
        // 工作台藏着时什么都不读（这一行看不见；回来那一拍再算）
        if app.isScriptPageVisible {
            WorkbenchBoardReader { board in
                if let shot = shot(board), failed(shot, board) { note(shot) }
            }
        }
    }

    private func shot(_ board: WorkbenchStatus.Board?) -> ShotDraft? {
        let ids: [UUID]
        if episodeIndex == WorkbenchSegmentGrid.otherEpisode {
            ids = board?.otherShotIDs ?? []                    // 「其他分镜」：第几个
        } else {
            guard let archive = app.currentPipelineArchive, archive.episodes.indices.contains(episodeIndex) else { return nil }
            ids = archive.episodes[episodeIndex].pairedShotIDs
        }
        guard ids.indices.contains(segmentNumber - 1) else { return nil }
        return app.shots.first { $0.id == ids[segmentNumber - 1] }
    }

    private func failed(_ shot: ShotDraft, _ board: WorkbenchStatus.Board?) -> Bool {
        guard let board else { return false }
        if episodeIndex == WorkbenchSegmentGrid.otherEpisode { return board.others[shot.id]?.video == .failed }
        guard board.episodes.indices.contains(episodeIndex) else { return false }
        return board.episodes[episodeIndex].shots[shot.id]?.video == .failed
    }

    /// 最近一次失败的那一版的原因
    private func reason(_ shot: ShotDraft) -> String {
        shot.taskIDs.compactMap { app.store.task(id: $0) }.last?.errorMessage ?? ""
    }

    private func note(_ shot: ShotDraft) -> some View {
        FailureNoteRow(reason: reason(shot),
                       retryDisabled: app.submittingShotIDs.contains(shot.id),
                       onRetry: { showRetryConfirm = true })
        .accessibilityIdentifier("workbench-segment-failure")
        .alert("重试这一段的视频？", isPresented: $showRetryConfirm) {
            Button("取消", role: .cancel) {}
            Button("重试") { retry(shot) }
        } message: {
            Text("会按现在的参数重新提交，产生费用。")
        }
        .alert("提示", isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
    }

    /// 重试：按这一段现在的参数重新提交（会花钱，点之前已经确认过）；参数不合格就说明白，不偷偷跳过
    private func retry(_ shot: ShotDraft) {
        let issues = ShotValidator.validate(shot)
        guard issues.isEmpty else {
            infoMessage = issues.joined(separator: "；") + "。"
            showInfo = true
            return
        }
        guard WorkbenchBatch.videoModelConfigured(shot, app: app) else {
            infoMessage = "这一段选的模型「\(shot.model)」已经不在配置里，先在中间的参数里换一个模型。"
            showInfo = true
            return
        }
        app.submitShot(shot.id)
    }
}

// MARK: - 右栏：按类型分组的素材

/// 缩略图按 16:9（生图卡默认的画幅，场景图、角色三视图都是横版的，方形会裁掉大半，2026-10-09 用户定）；没有图就显示类型图标
private struct MaterialThumb: View {
    let path: String?
    let kindIcon: String
    var size = CGSize(width: 72, height: 40.5)

    var body: some View {
        Group {
            if let path, FileManager.default.fileExists(atPath: path) {
                AsyncThumbImage(path: path)
            } else {
                Image(systemName: kindIcon).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// 版本列表：点哪个就选哪个（只是选，点「应用素材」才会挂到分镜上）；没有图的版本选不了
private struct MaterialVersionList: View {
    let info: DetailRowInfo
    let onChoose: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(info.name.name) 的版本").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            ForEach(info.versions) { version in
                Button {
                    DropdownPanel.shared.dismiss()
                    onChoose(version.cardID)
                } label: {
                    HStack(spacing: 10) {
                        MaterialThumb(path: version.imagePath, kindIcon: info.name.kind.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.label).font(.system(size: 13, weight: .medium))
                            Text(version.hasImage ? version.cardName : "\(version.cardName) · 没有图")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if version.cardID == info.selectedID {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .opacity(version.hasImage ? 1 : 0.5)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(!version.hasImage)
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

/// 一行的副标题：选中的版本，有例外才标出来（待应用 / 待提取 / 待出图 / 出图中 / 出图失败）；
/// 都正常（已应用）就只写版本，不再每行都标一遍「已应用」（2026-10-10 评估新布局时定）
private func materialStatus(_ info: DetailRowInfo) -> (text: String, isException: Bool) {
    switch info.name.state {
    case .missing: return ("待提取", true)
    case .noImage:
        let progress = info.name.activity == .running ? "出图中" : (info.name.activity == .failed ? "出图失败" : "待出图")
        return (progress, true)
    case .ready: return info.pending ? ("待应用", true) : ("", false)
    }
}

/// 「···」菜单：去生图页看 / 从这一段删掉（自绘弹层，和项目里别的下拉一致）
private struct MaterialActionsButton: View {
    let info: DetailRowInfo
    let onRemove: () -> Void
    let onOpenCard: (UUID) -> Void
    /// 菜单开着没有（卡片据此在菜单开着时不收起悬停按钮）
    @Binding var showMenu: Bool

    var body: some View {
        Button { showMenu = true } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.primary)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.buttonStroke) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(QuietButtonStyle())
        .help("更多")
        .dropdownPopover(isPresented: $showMenu) {
            VStack(alignment: .leading, spacing: 2) {
                if let id = info.selectedID {
                    item("在生图页看这张卡", icon: "photo") { onOpenCard(id) }
                }
                item("从这一段删掉", icon: "trash", destructive: true) { onRemove() }
            }
            .padding(6)
            .frame(width: 190)
        }
        .accessibilityIdentifier("workbench-material-menu-\(info.name.name)")
    }

    private func item(_ title: String, icon: String, destructive: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button {
            DropdownPanel.shared.dismiss()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13))
                .foregroundStyle(destructive ? Theme.danger : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }
}

/// 整行点一下（2026-10-12 用户定：点缩略图看大图，点这一行别处打开这张卡的编辑提示词；原来整行都是看大图）：
/// 里面的按钮（缩略图、更换、···）照常先吃自己的点击；没有卡就什么都不做，鼠标也不变手形。悬停时整块微微提亮
private struct RowTap: ViewModifier {
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovered && enabled ? 0.045 : 0))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { if enabled { action() } }
            .onHover { hovered = $0 }
            .pointerStyle(enabled ? .link : nil)
            .help(enabled ? help : "")
            .accessibilityAddTraits(enabled ? .isButton : [])
    }
}

/// 本段素材的一张小卡（2026-10-15 新布局：一类一个标签、两列排）：缩略图 + 名字 + 选中的版本（有例外标状态）。
/// 「更换」「···」鼠标移上去才出来（菜单开着时不收）；点整张卡（缩略图也算）编辑这张卡的提示词——看大图在提示词弹窗里点图（2026-10-26 用户）
private struct CompactMaterialCard: View {
    let info: DetailRowInfo
    let onChoose: (UUID) -> Void
    let onRemove: () -> Void
    let onOpenCard: (UUID) -> Void
    let onEditCard: (UUID) -> Void

    @State private var hovered = false
    @State private var showVersions = false
    @State private var showMenu = false

    var body: some View {
        let status = materialStatus(info)
        let thumbSize = CGSize(width: 64, height: 36)
        let showsActions = hovered || showVersions || showMenu
        HStack(spacing: 8) {
            MaterialThumb(path: info.selected?.imagePath, kindIcon: info.name.kind.icon, size: thumbSize)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(info.name.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if info.hasVoice {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                            .help("这张卡绑了音色")
                    }
                }
                HStack(spacing: 4) {
                    if status.isException {
                        Circle().fill(Theme.warning).frame(width: 5, height: 5)
                        Text(status.text).foregroundStyle(Theme.warning)
                    } else if let label = info.selected?.label, !label.isEmpty {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11)).lineLimit(1)
            }
            .layoutPriority(-1)          // 悬停出按钮时名字让位、截短，不和按钮叠在一起（2026-10-15 用户截图）
            Spacer(minLength: 0)
            if showsActions {
                HStack(spacing: 4) {
                    if info.versions.contains(where: \.hasImage) {
                        Button("更换") { showVersions = true }
                            .buttonStyle(OutlineButtonStyle())
                            .controlSize(.small)
                            .dropdownPopover(isPresented: $showVersions) { MaterialVersionList(info: info, onChoose: onChoose) }
                            .help("换这一段用这个名字的哪一版（选完马上挂上）")
                            .accessibilityIdentifier("workbench-change-version-\(info.name.name)")
                    }
                    MaterialActionsButton(info: info, onRemove: onRemove, onOpenCard: onOpenCard, showMenu: $showMenu)
                }
                .fixedSize()
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        .modifier(RowTap(enabled: info.selectedID != nil, help: "编辑这张卡的提示词（可以直接重新出图）") {
            if let id = info.selectedID { onEditCard(id) }
        })
        .onHover { hovered = $0 }
        .accessibilityIdentifier("workbench-material-row-\(info.name.name)")
    }
}

/// 一个素材名一行要显示的东西
private struct DetailRowInfo: Identifiable {
    var id: String { name.name }
    let name: WorkbenchStatus.NameStatus
    let versions: [WorkbenchVersions.Version]
    /// 这一段选中的版本（没手动选就是现在用的那个）
    let selectedID: UUID?
    /// 分镜上现在真挂着的版本
    let attachedID: UUID?
    var selected: WorkbenchVersions.Version? { versions.first { $0.cardID == selectedID } }
    /// 有图可挂、但现在挂着的不是选中的这个（没挂、或挂的是别的版本）
    var pending: Bool { name.state == .ready && selectedID != attachedID }
    /// 选中的卡绑了音色（`CardVoice`）
    var hasVoice = false
}

/// 右栏标题右边的「添加素材」：弹出一个小表单，先在生图页已有的卡里搜、点一下就加；没有的名字直接输入回车
private struct AddMaterialButton: View {
    /// 点开表单时才去算（每次切换段落都算一遍没有意义）
    let suggestions: () -> [WorkbenchVersions.Suggestion]
    /// 这一段头行里已经有的名字
    let taken: Set<String>
    /// 返回 nil = 加成功了；否则是失败的原因
    let onAdd: (PipelineFlow.ExtractionKind, String) -> String?
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            Label("添加素材", systemImage: "plus")
        }
        .buttonStyle(OutlineButtonStyle())
        .controlSize(.small)
        .dropdownPopover(isPresented: $show) {
            AddMaterialForm(suggestions: suggestions(), taken: taken, onAdd: onAdd, onClose: { DropdownPanel.shared.dismiss() })
        }
        .accessibilityIdentifier("workbench-add-material")
    }
}

private struct AddMaterialForm: View {
    let suggestions: [WorkbenchVersions.Suggestion]
    let taken: Set<String>
    let onAdd: (PipelineFlow.ExtractionKind, String) -> String?
    let onClose: () -> Void
    @State private var kind: PipelineFlow.ExtractionKind = .role
    @State private var name = ""
    @State private var error: String?

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [WorkbenchVersions.Suggestion] { WorkbenchVersions.filter(suggestions, kind: kind, query: name) }
    /// 搜索词和已有的哪个名字一模一样（一样就不用再显示「新建」那一行）
    private var hasExactMatch: Bool { matches.contains { $0.name == trimmed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("给这一段加一个素材").font(.system(size: 15, weight: .semibold))
            SegmentedBar(options: PipelineFlow.ExtractionKind.allCases.map { ($0.rawValue, $0) }, selection: $kind)
                .frame(height: 26)
            TextField("搜索生图页已有的\(kind.rawValue)，或直接输入新名字", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .onChange(of: name) { _, _ in error = nil }
                .onChange(of: kind) { _, _ in error = nil }
            list
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// 可以点的列表：点哪个就加哪个；搜不到的名字回车（或点最上面「新建」那行）按这个名字直接加
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !trimmed.isEmpty, !hasExactMatch {
                    row(title: "添加「\(trimmed)」", subtitle: "生图页还没有这张卡，提取时会建", icon: "plus.circle.fill", imagePath: nil, dimmed: false) { add(trimmed) }
                }
                ForEach(matches) { item in
                    let inHead = taken.contains(item.name)
                    row(title: item.name,
                        subtitle: inHead ? "已经在这一段里了"
                            : (item.hasImage ? "\(item.versions) 个版本" : "\(item.versions) 个版本 · 还没出图"),
                        icon: kind.icon, imagePath: item.imagePath, dimmed: inHead) { add(item.name) }
                        .allowsHitTesting(!inHead)          // 不用 disabled：它会再把整行变淡一层，字就看不清了
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 230)
    }

    /// 缩略图按 16:9（和「本段素材」里的一样）；还没出图的显示这一类的图标
    private func thumbnail(imagePath: String?, icon: String) -> some View {
        Group {
            if let imagePath, FileManager.default.fileExists(atPath: imagePath) {
                AsyncThumbImage(path: imagePath)
            } else {
                Image(systemName: icon).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05))
            }
        }
        .frame(width: 56, height: 31.5)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(title: String, subtitle: String, icon: String, imagePath: String?, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                thumbnail(imagePath: imagePath, icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.5 : 1)
        }
        .buttonStyle(QuietButtonStyle())
    }

    private func submit() { if !trimmed.isEmpty { add(trimmed) } }

    private func add(_ value: String) {
        if let failure = onAdd(kind, value) { error = failure } else { onClose() }
    }
}

/// 重跑一项时的小表单：说明这次会覆盖什么，加一个给 AI 打字的框（只对这一次生效，见 `RerunNote`）
private struct RerunForm: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let placeholder: String
    let confirmTitle: String
    let onConfirm: (String) -> Void
    let onClose: () -> Void
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("给 AI 的补充要求（可不填，只对这一次生效）").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $note)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if note.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 12.5)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 84)
                .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
            }
            HStack {
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button(confirmTitle) {
                    onClose()
                    onConfirm(note)
                }
                .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// 生视频页单击分镜打开的段落详情（2026-10-26 用户：要和工作台里点开的一模一样）。
/// 就是 `WorkbenchSegmentDetail` 本身：属于某一集的打开那一集那一段；不属于任何一集的走「其他分镜」。上一段 / 下一段在弹窗里翻
struct ShotSegmentDetailModal: View {
    @Environment(AppModel.self) private var app
    let shotID: UUID
    let onClose: () -> Void
    /// 翻到别的段以后在哪（nil = 还在点开的那一段）
    @State private var spot: WorkbenchSegmentGrid.Spot?

    var body: some View {
        WorkbenchBoardReader { board in
            if let current = spot ?? Self.spot(of: shotID, archive: app.currentPipelineArchive, board: board) {
                WorkbenchSegmentDetail(episodeIndex: current.episode, segmentNumber: current.segment,
                                       onSelect: { next in
                                           if let next { spot = next } else { onClose() }
                                       })
            } else {
                Text("找不到这条分镜").font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 这条分镜在哪：某一集里配对的第几段；不在任何一集里 =「其他分镜」里的第几个
    static func spot(of shotID: UUID, archive: ProjectPipelineArchive?, board: WorkbenchStatus.Board?) -> WorkbenchSegmentGrid.Spot? {
        if let archive {
            for (index, episode) in archive.episodes.enumerated() {
                if let i = episode.pairedShotIDs.firstIndex(of: shotID) { return .init(episode: index, segment: i + 1) }
            }
        }
        if let i = board?.otherShotIDs.firstIndex(of: shotID) { return .init(episode: WorkbenchSegmentGrid.otherEpisode, segment: i + 1) }
        return nil
    }
}
