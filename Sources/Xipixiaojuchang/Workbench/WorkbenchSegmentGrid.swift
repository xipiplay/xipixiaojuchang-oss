import SwiftUI

/// 分段一级页面的筛选（顶上概览条里的小标签）：按每段现在走到哪一步分。没推理分镜的段只在「全部」里
enum SegmentFilter: CaseIterable, Hashable {
    case all, toExtract, toImages, toMatch, problem, done

    var title: String {
        switch self {
        case .all: "全部"
        case .toExtract: "待提取"
        case .toImages: "待出图"
        case .toMatch: "待匹配"
        case .problem: "有问题"
        case .done: "已完成"
        }
    }

    func matches(_ status: WorkbenchStatus.ShotStatus?) -> Bool {
        guard self != .all else { return true }
        guard let status else { return false }
        switch self {
        case .all: return true
        case .toExtract: return status.stage == .toExtract
        case .toImages: return status.stage == .toGenerateImages
        case .toMatch: return status.stage == .toMatch
        case .problem: return status.isProblem
        case .done: return status.stage == .done
        }
    }
}

/// 工作台「分镜」视图（2026-10-09 第 2 步；2026-10-10 改成封面卡；2026-10-13 用户定：**所有集连着滑**，不用再点左边选集）：
/// 一整列，每集一节——节头是一行概览（集号、标题、段数、每段一格的进度条、视频完成数），节头跟着卡片一起滑（不吸顶）；筛选条固定在上面；
/// 最上面一排按状态筛选的小标签，对所有集一起生效。滑到哪一集就告诉页面（`onVisibleEpisode`），左边集列表、页头、底部胶囊跟着换。
/// 每张卡：上半是封面（视频首帧 → 场景图 → 带场景名的色块），叠着段号和状态；下半是角色头像、角色名、剧情摘要，
/// 最底下四个小圆点表示提取 / 出图 / 匹配 / 视频各走到哪一步。点卡片进这一段的详情。
/// 数据都是现成的：段落来自每集的时长分割（`SplitSegments`），状态来自 `WorkbenchStatus`。
struct WorkbenchSegmentGrid: View, Equatable {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    /// 第几集第几段（集 0 起，段 1 起）
    struct Spot: Hashable {
        let episode: Int
        let segment: Int
    }
    /// 「滑到某一集开头」的请求（左边点了一集）。`token` 每次都换：连着点同一集也会再滑一次
    struct EpisodeRequest: Equatable {
        let episode: Int
        let token = UUID()
    }

    /// 页面现在认的是哪一集（0 起）：进来时滑到它那里
    let currentEpisode: Int
    /// 刚从详情退回来时网格该停在哪一段：弹窗打开时的那一段，在弹窗里翻页不算
    var scrollTo: Spot? = nil
    var episodeRequest: EpisodeRequest? = nil
    /// 分段弹窗开着：弹窗里翻到别的集时页面的当前集会变，网格别跟着滑（关掉弹窗要回到打开时的位置）
    var holdsPosition = false
    /// 哪个项目（换项目时才拿新的 `currentEpisode`，见 `==`）
    var projectKey: String? = nil

    /// 页面重画时，网格只在跟它有关的东西变了才重算（2026-10-14 用户：分镜缩略图滑动还有轻微卡顿）：
    /// 滑到别的集 → 页面的当前集跟着变 → 整页重画，原来网格也跟着把几十集重算一遍（实测每次换集 30 多 ms，一集五六段时一秒好几次）。
    /// 当前集是网格自己报上去的，不用回头再重算自己；点左边一集走 `episodeRequest`、弹窗关掉走 `scrollTo`、进页面走 `onAppear`。
    /// 换了项目才认新的当前集（数据本身变了网格自己会重画：它直接读 `app`）
    nonisolated static func == (a: WorkbenchSegmentGrid, b: WorkbenchSegmentGrid) -> Bool {
        a.projectKey == b.projectKey && a.scrollTo == b.scrollTo && a.episodeRequest == b.episodeRequest
            && a.holdsPosition == b.holdsPosition
    }
    /// 「其他分镜」那一节的集号（不属于任何一集的分镜，2026-10-14 把生视频并进工作台）。
    /// 2026-10-15 用户：剧本模式以后不用生视频页，不再新建这种分镜（节头的「新建分镜」去掉）；老项目里已有的照样列出来，能看能删：`Spot(episode: otherEpisode, segment: 第几个)`
    static let otherEpisode = -1
    /// 点开某一段的详情
    var onOpen: (Spot) -> Void = { _ in }
    /// 用户滑到了别的集（那一集的节头滑到了顶上）
    var onVisibleEpisode: (Int) -> Void = { _ in }
    /// 用户滑完、手停了（滑动中换集只换左边高亮，停了页面才真换集）
    var onScrollSettled: () -> Void = {}

    @State private var filter: SegmentFilter = .all
    /// 卡片滚动用的标识。⚠️ 不能直接用段号：节头进度条的每一格也以段号为标识（`ForEach(rows)`），
    /// `scrollTo(段号)` 会找到那一格（2026-10-12 用户碰到「关掉分段弹窗页面自己滑到顶」）；连着滑之后还要带上集号
    static func cardScrollID(_ spot: Spot) -> String { "segment-card-\(spot.episode)-\(spot.segment)" }

    /// 最近一次从网格上点开的是哪一段：弹窗关掉时还是这一段，就不用滚
    @State private var openedSpot: Spot?
    /// 进来时已经滚到当前那一集了（见 `.onAppear`）
    @State private var revealed = false
    /// 滚动区和一张卡的高度（滑到某一集开头时算位置用）。放在引用里、不是 @State：
    /// 量到的时候改 @State 会让网格整个重画，刚滚过去的位置就丢了（实测回到顶上）
    final class Metrics {
        var viewportHeight: CGFloat = 0
        /// 用户正在滑（拖 / 惯性）。程序滑过去（点左边一集、弹窗关掉）时不跟着改「当前集」：
        /// 最后一集很短、节头顶不到最上面时，吸着的还是上一集，跟着改就会把刚点的那一集又改回去。
        /// ⚠️ 不能放 @State：鼠标滚轮每转一格就「开始 / 停止」一次，放 @State 就是每格让整个网格重算两遍（2026-10-13 用户：滑动很卡）
        private(set) var userScrolling = false
        /// 只用于去重，不参与网格排版；换集只让左边的轻量高亮更新。
        var visibleEpisode: Int?
        /// 最近一次几何通知里的滚动位置（窗口缩放重排后按新位置表校准用，2026-10-18）
        var lastOffset: CGFloat = 0
        /// 窗口缩放重采样去重令牌：连续缩放只让最后一次提交
        var resizeToken = 0
        /// 正在走的 `.animating` 动画是不是从用户滚动接过来的（拉过头的回弹 / 收尾）：
        /// 是的话动画停稳也算一次落地；程序主动的跳转（点选集等）不算
        private var animationFollowsUser = false

        struct Update {
            var episode: Int?
            var settled = false
        }

        func moved(to episode: Int, simulated: Bool = false, settleSimulation: Bool = false) -> Update {
            guard userScrolling || simulated else { return Update() }
            let changed = record(episode)
            return Update(episode: changed, settled: changed != nil && !userScrolling && simulated && settleSimulation)
        }

        /// 几何通知可能早于开始、晚于停止，且按集号去重后不会再发同一个值。
        /// 因此阶段切换必须用它自带的真实位置校准，不能只提交上一次几何通知留下的集号。
        func phaseChanged(from old: ScrollPhase, to phase: ScrollPhase, episode: Int) -> Update {
            let wasUserScrolling = old == .interacting || old == .decelerating
            // 回弹 / 收尾动画：记下它是不是从用户滚动接过来的（2026-10-18：滑到最底常以回弹收尾，
            // 原来经过 .animating 的收尾被当成程序滚动，跳过提交，页头停在上一个集）
            if phase == .animating {
                animationFollowsUser = wasUserScrolling
            } else if phase != .idle {
                animationFollowsUser = false
            }
            userScrolling = phase == .interacting || phase == .decelerating
            let userAnimationSettled = old == .animating && phase == .idle && animationFollowsUser
            if phase == .idle { animationFollowsUser = false }
            let settled = (wasUserScrolling && phase == .idle) || userAnimationSettled
            guard userScrolling || settled else { return Update() }
            return Update(episode: record(episode), settled: settled)
        }

        /// 窗口缩放换了列数：内容整个重排，按新位置表把当前集校准一次（当成一次落地提交）
        func resizeSettled(at episode: Int) -> Update {
            userScrolling = false
            return Update(episode: record(episode), settled: true)
        }

        private func record(_ episode: Int) -> Int? {
            guard episode != visibleEpisode else { return nil }
            visibleEpisode = episode
            return episode
        }
    }
    @State private var metrics = Metrics()
    /// 测试用：把程序滑动也当成用户在滑（测试进程里合成的滚轮事件会让 NSScrollView 一直等下一个事件，模拟不了真滑）
    nonisolated(unsafe) static var testTreatsAnyScrollAsUser = false
    nonisolated(unsafe) static var testSettlesEachScroll = true
    /// 测试用：记下建过哪几张卡（核对懒加载还在：不是一次把几百张全建出来）。nil = 不数
    nonisolated(unsafe) static var testBuiltCells: Set<Spot>?
    /// 滚动内容高度按 `SectionLayout.contentHeight` 定死（2026-10-16 A/B 实验 B，默认开）：懒加载网格自己估的总高会随滑动变，
    /// 怀疑它影响妙控鼠标连续滑动 / 惯性的手感。切回 A（让网格自己估）：`defaults write local.xipixiaojuchang workbenchGridStableHeight -bool NO`
    static let stableHeightKey = "workbenchGridStableHeight"
    @AppStorage(WorkbenchSegmentGrid.stableHeightKey) private var stableHeight = true

    var body: some View {
        WorkbenchBoardReader { board in
            content(board)
        }
    }

    private struct Row: Identifiable {
        var id: Int { segment.number }
        let segment: SplitSegments.Segment
        let shot: ShotDraft?
        let status: WorkbenchStatus.ShotStatus?
    }

    /// 一集要画的东西
    private struct Section: Identifiable {
        var id: Int { episode }
        let episode: Int
        let title: String
        let rows: [Row]
        let shotCount: Int
        let stale: Bool
    }

    /// 网格要用的分镜 / 生图卡 / 素材库。工作台藏着（在生图 / 生视频页）时交出上一次的，不去读——
    /// 否则后台每次视频轮询、出图进度都会让藏着的网格整个重算（2026-10-12 实测：20 集 × 30 段，每次约 15ms）
    private final class InputCache {
        var filled = false
        var shotsByID: [UUID: ShotDraft] = [:]
        var cards: [ImageGenItem] = []
        var library: [UUID: LibraryItem] = [:]
    }
    @State private var inputCache = InputCache()

    private func inputs(ids: Set<UUID>) -> (shots: [UUID: ShotDraft], cards: [ImageGenItem], library: [UUID: LibraryItem]) {
        if !app.isScriptPageVisible, inputCache.filled {
            return (inputCache.shotsByID, inputCache.cards, inputCache.library)
        }
        inputCache.filled = true
        inputCache.shotsByID = Dictionary(app.shots.filter { ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        inputCache.cards = app.currentImageItems
        // 素材库按 ID 查表（一次建好，每张卡每个名字都要查；原来是每次在整个素材库里线性找）
        inputCache.library = Dictionary(app.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (inputCache.shotsByID, inputCache.cards, inputCache.library)
    }

    @ViewBuilder
    private func content(_ board: WorkbenchStatus.Board?) -> some View {
        let otherIDs = board?.otherShotIDs ?? []
        if let archive = app.currentPipelineArchive ?? (otherIDs.isEmpty ? nil : ProjectPipelineArchive(wholeScript: "", episodes: [])),
           !archive.episodes.isEmpty || !otherIDs.isEmpty {
            let paired = archive.episodes.map(\.pairedShotIDs)          // 分割改过、对不上时是空的：卡片按「待推理分镜」显示，不拿旧卡硬配
            let (shotsByID, cards, library) = inputs(ids: Set(paired.joined()).union(otherIDs))
            let episodeSections: [Section] = archive.episodes.indices.map { ep in
                let episode = archive.episodes[ep]
                let ids = paired[ep]
                let status = board?.episodes.indices.contains(ep) == true ? board?.episodes[ep] : nil
                let rows: [Row] = SplitSegments.parse(episode.splitText ?? "").map { segment in
                    let shot = ids.indices.contains(segment.number - 1) ? shotsByID[ids[segment.number - 1]] : nil
                    return Row(segment: segment, shot: shot, status: shot.flatMap { status?.shots[$0.id] })
                }
                return Section(episode: ep, title: episode.title, rows: rows, shotCount: ids.count, stale: episode.storyboardIsStale)
            }
            // 最后一节「其他分镜」：不属于任何一集的分镜（有才显示）
            let otherRows: [Row] = otherIDs.enumerated().compactMap { index, id in
                guard let shot = shotsByID[id] else { return nil }
                return Row(segment: SplitSegments.Segment(number: index + 1, start: nil, end: nil, text: "", roles: [], props: []),
                           shot: shot, status: board?.others[id])
            }
            let sections = episodeSections + (otherRows.isEmpty ? [] : [Section(episode: Self.otherEpisode, title: "其他分镜", rows: otherRows,
                                                                                shotCount: otherRows.count, stale: false)])
            let allRows = sections.flatMap(\.rows)
            // 筛选时只留有这种段的集；「全部」时每集都在（还没分割的也占一行节头，告诉人这一集还差什么）
            let shown: [(section: Section, rows: [Row])] = sections.compactMap { section in
                let rows = section.rows.filter { filter.matches($0.status) }
                return filter == .all || !rows.isEmpty ? (section, rows) : nil
            }
            let layout = SectionLayout(rowCounts: shown.map(\.rows.count), episodes: shown.map(\.section.episode),
                                       columns: columns.count, cell: Self.cardHeight)
            if allRows.isEmpty {
                placeholder("还没有时长分割。点底部的「分割」。")
            } else {
                // 筛选条固定在上面不跟着滑（2026-10-14 用户定）
                VStack(spacing: 0) {
                filterBar(allRows)
                    .padding(.horizontal, 14).padding(.bottom, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if shown.isEmpty {
                                VStack(spacing: 10) {
                                    Text("没有「\(filter.title)」的段。").foregroundStyle(.secondary)
                                    Button("显示全部") { filter = .all }.buttonStyle(OutlineButtonStyle()).controlSize(.small)
                                }
                                .frame(maxWidth: .infinity).padding(.top, 40)
                            } else {
                                // 懒加载：只建看得见的那几张（几百张卡）。卡片 = 生视频页的缩略图卡（2026-10-13 用户：先换成它，
                                // 内容和交互再重新设计）。列宽最小 260 / 最大 320 / 间距 12，见 `cellMinimum`
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cellMinimum, maximum: 320), spacing: Self.cellSpacing, alignment: .top)],
                                          alignment: .leading, spacing: Self.cellSpacing) {
                                    ForEach(shown, id: \.section.id) { item in
                                        let ep = item.section.episode
                                        SwiftUI.Section {
                                            ForEach(item.rows) { row in
                                                let spot = Spot(episode: ep, segment: row.segment.number)
                                                cell(row, episode: ep, cards: cards, library: library)
                                                    // 单击 = 打开这一段的二级页面；看视频点画面中间的 ▶ 或按空格（2026-10-15 用户定 A）。
                                                    // 不用双击：`onTapGesture(count: 2)` 让单击等双击超时
                                                    .onTapGesture { tapCard(row, spot: spot) }
                                                    // ⚠️ `.id` 要在最外层：放在别的修饰后面，`scrollTo` 就找不到这张卡了（实测）
                                                    .id(Self.cardScrollID(spot))
                                            }
                                        } header: {
                                            sectionHeader(item.section)
                                                .modifier(HeaderTopProbe(episode: ep))
                                        }
                                    }
                                }
                                // 实验 B：外面给死总高、顶端对齐，滚动区拿到的内容高度不再随懒加载估算变（网格里面照旧懒加载）
                                .frame(height: stableHeight ? layout.contentHeight : nil, alignment: .top)
                            }
                        }
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                    .scrollIndicators(.hidden)
                    // 底部胶囊浮在卡片上面：最后一行能滚到它上面来
                    .contentMargins(.bottom, PipelinePageLayout.capsuleClearance - 14, for: .scrollContent)
                    .onScrollPhaseChange { old, phase, context in
                        let position = layout.position(at: context.geometry.contentOffset.y + context.geometry.contentInsets.top,
                                                       viewport: metrics.viewportHeight)
                        guard layout.episodes.indices.contains(position) else { return }
                        report(metrics.phaseChanged(from: old, to: phase, episode: layout.episodes[position]))
                    }
                    // 现在看的是哪一集：按滚动位置在每集的起点表里查（卡片一样大，起点算得出来）。
                    // 原来是看每集的节头有没有滑到顶上——一集只有两三行时屏幕上同时有好几个节头，刚出现的节头也会报一次，左边集数乱跳（2026-10-14 用户）
                    .onScrollGeometryChange(for: Int.self) { geo in
                        metrics.lastOffset = geo.contentOffset.y + geo.contentInsets.top
                        return layout.position(at: metrics.lastOffset, viewport: metrics.viewportHeight)
                    } action: { _, position in
                        if layout.episodes.indices.contains(position) { reportVisible(layout.episodes[position]) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metrics.viewportHeight = $0 }
                    // 格子宽度跟着页面宽度（只在窗口 / 抽屉改变宽度时变）。
                    // 窗口缩放换了列数 = 内容整个重排：像素偏移没变，但对应的集变了——
                    // 按新位置表把当前集校准一次（2026-10-18 用户：缩放后集号对不上）
                    .onGeometryChange(for: Columns.self) { Self.columns(forWidth: $0.size.width) } action: { new in
                        let columnCountChanged = new.count != columns.count
                        columns = new
                        guard columnCountChanged, revealed else { return }
                        // 等这一轮重排落定再采样（偏移可能被夹住）；连续缩放只让最后一次提交
                        metrics.resizeToken += 1
                        let token = metrics.resizeToken
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            guard token == metrics.resizeToken, revealed else { return }
                            let updated = SectionLayout(rowCounts: shown.map(\.rows.count), episodes: shown.map(\.section.episode),
                                                        columns: new.count, cell: Self.cardHeight)
                            let position = updated.position(at: metrics.lastOffset, viewport: metrics.viewportHeight)
                            guard updated.episodes.indices.contains(position) else { return }
                            report(metrics.resizeSettled(at: updated.episodes[position]))
                        }
                    }
                    // 切了筛选：这一轮的 `shown` 换了，还没落地的那次缩放校准作废
                    // （别拿旧布局算集号；「缩放 + 切筛选」在 0.15s 内连动时才会撞上，2026-10-18）
                    .onChange(of: filter) { _, _ in
                        metrics.resizeToken += 1
                    }
                    // 刚建出来、还没滚到当前那一集之前先不显示：不然先露出整列最上面的第 1 集、下一帧才跳过去，
                    // 切到「分镜」时看着闪一下（2026-10-14 用户录屏）
                    .opacity(revealed ? 1 : 0)
                    .onAppear {
                        metrics.visibleEpisode = currentEpisode
                        let card = scrollTo.flatMap { target in
                            shown.contains(where: { $0.section.episode == target.episode && $0.rows.contains { $0.segment.number == target.segment } }) ? target : nil
                        }
                        let episode = currentEpisode > 0 && shown.contains(where: { $0.section.episode == currentEpisode }) ? currentEpisode : nil
                        guard card != nil || episode != nil else { revealed = true; return }      // 就在最顶上：不用滚，直接显示
                        // 等这一轮排版完再滚（懒加载网格里的卡还没有位置）；滚完同一下显示出来
                        DispatchQueue.main.async {
                            if let card {
                                proxy.scrollTo(Self.cardScrollID(card), anchor: .center)
                            } else if let episode {
                                scrollToEpisode(episode, shown.map(\.rows), episodes: shown.map(\.section.episode), proxy)
                            }
                            revealed = true
                        }
                    }
                    // 分段弹窗关掉时（网格一直在后面，不会重新出现）：`scrollTo` 是弹窗打开时的那一段（在弹窗里翻页不算）。
                    // 从网格上点开的 = 它本来就在眼前，不动；进页面自动接着打开的（网格还在顶上）才滚过去。不带动画：弹窗一关就已经在那里
                    .onChange(of: scrollTo) { _, target in
                        guard let target, target != openedSpot,
                              shown.contains(where: { $0.section.episode == target.episode && $0.rows.contains { $0.segment.number == target.segment } }) else { return }
                        proxy.scrollTo(Self.cardScrollID(target), anchor: .center)
                    }
                    // 页面那边换了集、又不是这里滑过去的（进页面时读出上次看的集、从别的页跳过来）：滑到那一集开头
                    .onChange(of: currentEpisode) { _, episode in
                        guard !holdsPosition, episode != metrics.visibleEpisode else { return }
                        metrics.visibleEpisode = episode
                        guard shown.contains(where: { $0.section.episode == episode }) else { return }
                        DispatchQueue.main.async { scrollToEpisode(episode, shown.map(\.rows), episodes: shown.map(\.section.episode), proxy) }
                    }
                    // 左边点了一集：滑到那一集开头（筛选把它藏了就先回到「全部」）
                    .onChange(of: episodeRequest) { _, request in
                        guard let request else { return }
                        metrics.visibleEpisode = request.episode
                        let wasShown = shown.contains { $0.section.episode == request.episode }
                        if !wasShown { filter = .all }
                        // 筛选刚换回「全部」时这一轮的 `shown` 还是旧的：等下一轮排版完，按全部的段算
                        let rows = wasShown ? shown.map(\.rows) : sections.map(\.rows)
                        let episodes = wasShown ? shown.map(\.section.episode) : sections.map(\.episode)
                        DispatchQueue.main.async { scrollToEpisode(request.episode, rows, episodes: episodes, proxy) }
                    }
                }
                }
                .accessibilityIdentifier("workbench-segment-grid")
            }
        } else {
            placeholder("先导入剧本并分集。")
        }
    }

    /// 滑到某一集开头：节头贴着顶、第一行卡紧跟在它下面。
    /// ⚠️ 节头（Section 的 header）不能当滚动目标（`scrollTo` 找它没反应），只能对准这一集的第一张卡：
    /// 锚点 y = a 时，卡上 a·卡高 那一点对准滚动区 a·区高 那一点，卡顶就落在 a·(区高 − 卡高)；让它等于节头的高度
    private func scrollToEpisode(_ episode: Int, _ rows: [[Row]], episodes: [Int], _ proxy: ScrollViewProxy) {
        guard let position = episodes.firstIndex(of: episode), let first = rows[position].first else { return }
        let target = Self.cardScrollID(Spot(episode: episode, segment: first.segment.number))
        let headerHeight: CGFloat = 8 + 40 + 4 + Self.cellSpacing       // 节头上垫、本身、下垫 + 网格行距（见 `sectionHeader`）
        let room = metrics.viewportHeight - Self.cardHeight
        if room > headerHeight {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: headerHeight / room))
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    static let cellSpacing: CGFloat = 12
    /// 格子最窄多宽。2026-10-14 用户：窗口最小时的卡片大小正好，窗口一大反而变小、看不清——
    /// 原来和生视频页一样最小 210，最大窗口时一行挤 5 张、每张约 218；改成 260 后最小窗口约 269、最大窗口约 276，几乎一样大
    static let cellMinimum: CGFloat = 260
    /// 一格多宽：和 `.adaptive(minimum: cellMinimum, maximum: 320)`、间距 12、左右各留 14 同一算法（生视频页的缩略图卡要精确宽度）
    struct Columns: Equatable {
        var count = 1
        var width: CGFloat = 0
    }
    static func columns(forWidth width: CGFloat) -> Columns {
        let available = width - 28
        guard available >= cellMinimum else { return Columns() }
        let count = max(1, Int((available + cellSpacing) / (cellMinimum + cellSpacing)))
        return Columns(count: count, width: min(320, floor((available - cellSpacing * CGFloat(count - 1)) / CGFloat(count))))
    }
    @State private var columns = Columns()
    private var cellWidth: CGFloat { columns.width }

    /// 每集在网格里从多高开始（卡片一样高 `cardHeight`、节头固定高，所以算得出来，不用量）
    struct SectionLayout {
        /// 节头占的高度（上垫 8 + 本身 40 + 下垫 4，见 `sectionHeader`）
        static let headerHeight: CGFloat = 52
        let starts: [CGFloat]
        let episodes: [Int]
        /// 整个网格多高：最后一节后面没有行距（只有节头的空集也一样，节头后面就是下一节的行距）
        let contentHeight: CGFloat

        init(rowCounts: [Int], episodes: [Int], columns: Int, cell: CGFloat) {
            self.episodes = episodes
            var y: CGFloat = 0
            var starts: [CGFloat] = []
            for count in rowCounts {
                starts.append(y)
                let rows = count == 0 ? 0 : (count + max(columns, 1) - 1) / max(columns, 1)
                // 节头 + 行距，再每行一格高 + 行距（网格里节头和卡片行之间、两行之间、两集之间都是同一个行距）
                y += Self.headerHeight + WorkbenchSegmentGrid.cellSpacing + CGFloat(rows) * (cell + WorkbenchSegmentGrid.cellSpacing)
            }
            self.starts = starts
            self.contentHeight = starts.isEmpty ? 0 : y - WorkbenchSegmentGrid.cellSpacing
        }

        /// 滚到 `offset` 时看的是第几节：起点在 offset 之上（含刚好贴着）的最后一节。
        /// `viewport` 是滚动区高度。最后一节比视口矮时（2026-10-17 用户：第56集块 650 + 底垫 62 = 712pt，
        /// 视口 728pt），滚到底它的起点还差十几点顶不到上面——视口里已经全是最后一集、末尾也露出来了，
        /// 按起点算却还是上一集。这时以「内容末尾进了视口」（滚到底前那 62pt 底垫区）为准，报最后一节。
        /// viewport = 0（不传）保持原算法，供不关心滚动区的调用方使用。
        func position(at offset: CGFloat, viewport: CGFloat = 0) -> Int {
            var low = 0, high = starts.count - 1, answer = 0
            while low <= high {
                let mid = (low + high) / 2
                if starts[mid] <= offset + 2 { answer = mid; low = mid + 1 } else { high = mid - 1 }
            }
            if viewport > 0, let last = starts.indices.last, answer != last,
               contentHeight > viewport, offset + viewport >= contentHeight {
                return last
            }
            return answer
        }
    }

    /// 一段一张段落卡（2026-10-15 用户：工作台不要视频缩略图，视频去生视频页 / 二级页面看）：段号、状态、场景图、角色头像、剧情摘要、四步进度。
    /// 卡片一样高（`cardHeight`），节头的位置才算得出来
    private func cell(_ row: Row, episode: Int, cards: [ImageGenItem], library: [UUID: LibraryItem]) -> some View {
        Self.testBuiltCells?.insert(Spot(episode: episode, segment: row.segment.number))
        let model = SegmentCardModel.make(episodeIndex: episode, segment: row.segment, shot: row.shot, status: row.status,
                                          cards: cards, library: library, app: app)
        return SegmentCard(model: model, width: cellWidth)
            .equatable()
            .frame(height: Self.cardHeight)
    }

    /// 段落卡的固定高度：封面 118 + 下面三块（角色 65、剧情两行 34、四步 28，间距 9×2）+ 上下内边距 12×2
    static let cardHeight: CGFloat = 287

    /// 单击 = 打开这一段的二级页面（视频在二级页面「本段预览」里看，2026-10-15）。
    /// 工作台不再拖选（2026-10-15 用户：去掉），批量匹配 / 生视频走底部胶囊
    private func tapCard(_ row: Row, spot: Spot) {
        openSpot(spot)
    }

    private func openSpot(_ spot: Spot) {
        openedSpot = spot; metrics.visibleEpisode = spot.episode; onOpen(spot)
    }

    /// 滑动中只更新左栏；停止回调先校准集号，再让页面提交当前集。
    private func report(_ update: Metrics.Update) {
        if let episode = update.episode { onVisibleEpisode(episode) }
        if update.settled { onScrollSettled() }
    }

    private func reportVisible(_ episode: Int) {
        report(metrics.moved(to: episode, simulated: Self.testTreatsAnyScrollAsUser,
                             settleSimulation: Self.testSettlesEachScroll))
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 概览条

    private func cellColor(_ status: WorkbenchStatus.ShotStatus?) -> Color {
        guard let status else { return Color.primary.opacity(0.10) }
        if status.isProblem { return Theme.danger }
        if status.stage == .done { return Theme.success }
        if status.stage == .generatingVideo || status.imagesRunning { return Theme.accent }
        return Color.primary.opacity(0.22)
    }

    /// 最上面一排：按状态筛选，对所有集一起生效（数字是整部剧的）
    private func filterBar(_ rows: [Row]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(SegmentFilter.allCases, id: \.self) { item in
                let count = rows.filter { item.matches($0.status) }.count
                if item == .all || count > 0 || item == filter {
                    FilterChip(title: item == .all ? item.title : "\(item.title) \(count)", selected: filter == item) { filter = item }
                }
            }
        }
        .padding(.top, 14)
    }

    /// 每集的节头：一行概览，跟着卡片一起滑
    private func sectionHeader(_ section: Section) -> some View {
        let rows = section.rows
        let videoDone = rows.filter { $0.status?.video == .completed }.count
        let isOther = section.episode == Self.otherEpisode
        return HStack(spacing: 14) {
            Text(isOther ? section.title : "第 \(section.episode + 1) 集").font(.system(size: 13, weight: .semibold)).fixedSize()
            // 标题就是「第 N 集」（没起名）时不再重复一遍
            if !isOther, !section.title.isEmpty, section.title.replacingOccurrences(of: " ", with: "") != "第\(section.episode + 1)集" {
                Text(section.title).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading).fixedSize()      // 标题多长占多宽（最多 260），不撑开
            }
            if rows.isEmpty {
                Text("还没有时长分割").font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize()
                Spacer(minLength: 0)
            } else {
                Text(isOther ? "共 \(rows.count) 个" : "共 \(rows.count) 段").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    .help(isOther ? "不属于任何一集的分镜（早期直接做的、手动新建的）" : "")
                if isOther {
                    EmptyView()
                } else if section.stale {
                    // 分割改过、段和分镜卡对不上（2026-10-12 逻辑审查：原来会拿旧卡硬配，第 3 段显示的可能是原来第 2 段的提示词和视频）
                    Label("分割改过了，要重新做「分镜」", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning).fixedSize()
                        .help("这一集的分割改过了（段落变了），原来的分镜卡和段对不上，先不显示。在底部点「分镜」整集重新推理；旧卡上已经生成的视频还在，内容可能对不上新的段，要重新生成。")
                        .accessibilityIdentifier("workbench-storyboard-stale")
                } else if section.shotCount > 0 && section.shotCount != rows.count {
                    Text("分镜卡 \(section.shotCount) 张，对不上").font(.system(size: 12)).foregroundStyle(Theme.warning).fixedSize()
                        .help("分镜卡有 \(section.shotCount) 张，和分割的 \(rows.count) 段对不上，重新做一次「分镜」")
                } else if section.shotCount == 0 {
                    Text("还没推理分镜").font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize()
                        .help("还没有推理分镜，素材是按分割文本预估的")
                }
                // 每段一格，颜色 = 现在的状态；点一格直接打开那一段。
                // 画成一整条（原来每格一个按钮：一集 30 个按钮 + 30 个悬停提示，节头滑动时每帧都在算）
                let colors = rows.map { cellColor($0.status) }
                GeometryReader { geo in
                    Canvas { context, size in
                        let gap: CGFloat = 3
                        let width = (size.width - gap * CGFloat(colors.count - 1)) / CGFloat(max(colors.count, 1))
                        for (i, color) in colors.enumerated() {
                            let rect = CGRect(x: CGFloat(i) * (width + gap), y: (size.height - 8) / 2, width: max(width, 1), height: 8)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(color))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard geo.size.width > 0, !rows.isEmpty else { return }
                        let index = min(max(Int(tap.location.x / geo.size.width * CGFloat(rows.count)), 0), rows.count - 1)
                        openedSpot = nil
                        metrics.visibleEpisode = section.episode
                        onOpen(Spot(episode: section.episode, segment: rows[index].segment.number))
                    })
                }
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                .pointerStyle(.link)
                .help("每段一格，点一格打开那一段")
                Text("视频 \(videoDone)/\(rows.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        // 节头不吸顶，跟着卡片一起滑走（2026-10-14 用户：不要顶上换来换去）；上下留一点空
        .padding(.top, 8).padding(.bottom, 4)
        .accessibilityIdentifier("workbench-episode-header-\(section.episode + 1)")
    }
}

/// 测试用：记下每集节头离滚动区上沿多远（真实排出来的），用来核对 `SectionLayout` 算的起点。平时不挂任何监听
struct HeaderTopProbe: ViewModifier {
    let episode: Int
    nonisolated(unsafe) static var record: [Int: CGFloat]?

    func body(content: Content) -> some View {
        if Self.record != nil {
            content.onGeometryChange(for: CGFloat.self) { $0.frame(in: .scrollView).minY } action: { Self.record?[episode] = $0 }
        } else {
            content
        }
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.accent : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Theme.accent.opacity(0.12) : Color.clear))
                .overlay(Capsule().strokeBorder(selected ? Theme.accent.opacity(0.4) : Color.primary.opacity(0.14), lineWidth: 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(QuietButtonStyle(hover: .capsule))
    }
}

/// 一张段卡片要显示的全部数据（2026-10-10）。在网格里一次算好，卡片本身只画它：
/// 卡片是 `Equatable` 的，数据没变就不重画——视频轮询、别的段变了都会让整页重新算一遍，原来每张卡每次都跟着重算，退回网格 / 轮询时主线程会卡几百毫秒。
struct SegmentCardModel: Equatable, Identifiable {
    struct Person: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// 这个名字现在用的那张卡显示的图；没有 = nil
        let imagePath: String?
    }
    /// 状态小点的颜色
    enum Tone: Equatable { case idle, running, done, problem }

    var id: Int { number }
    let number: Int
    let timeRange: String?
    let statusText: String
    let statusTone: Tone
    let sceneName: String?
    let scenePath: String?
    let people: [Person]
    let propNames: [String]
    let excerpt: String
    let steps: WorkbenchStatus.ShotStatus.Steps?
    let shotID: UUID?

    @MainActor
    static func make(episodeIndex: Int, segment: SplitSegments.Segment, shot: ShotDraft?, status: WorkbenchStatus.ShotStatus?,
                     cards: [ImageGenItem], library: [UUID: LibraryItem], app: AppModel) -> SegmentCardModel {
        let names = status?.names ?? []
        /// 这个名字这一段现在用的图（挂着的那张；没挂就按这一集该用的版本）
        func imagePath(_ name: WorkbenchStatus.NameStatus) -> String? {
            guard name.state != .missing, let shot,
                  let id = WorkbenchVersions.currentCardID(kind: name.kind, name: name.name, shot: shot, episode: episodeIndex + 1, cards: cards, app: app, library: { library[$0] }),
                  let card = cards.first(where: { $0.id == id }),
                  let path = WorkbenchVersions.displayedResult(of: card)?.localPath, FileManager.default.fileExists(atPath: path) else { return nil }
            return path
        }
        let sceneStatus = names.first { $0.kind == .scene }
        let people: [Person] = status != nil
            ? names.filter { $0.kind == .role }.map { Person(name: $0.name, imagePath: imagePath($0)) }
            : segment.roles.map { Person(name: $0, imagePath: nil) }               // 分镜还没推理：按分割文本预估，没有图
        let tone: Tone = {
            guard let status else { return .idle }
            if status.isProblem { return .problem }
            switch status.stage {
            case .done: return .done
            case .generatingVideo: return .running
            default: return .idle
            }
        }()
        // 剧情：去掉列名字的那几行（场景 / 角色 / 道具 / 本段在场，它们在上面的角色 / 道具里），其余原样
        let lines = SplitSegments.splitHead(segment.text).body.components(separatedBy: "\n")
        return SegmentCardModel(
            number: segment.number, timeRange: segment.timeRange,
            statusText: status?.title ?? (segment.scene == nil ? WorkbenchStatus.Stage.toName : WorkbenchStatus.Stage.toInfer).title, statusTone: tone,
            sceneName: sceneStatus?.name ?? (segment.allScenes.isEmpty ? nil : segment.allScenes.joined(separator: "、")), scenePath: sceneStatus.flatMap(imagePath),
            people: people, propNames: status != nil ? names.filter { $0.kind == .prop }.map(\.name) : segment.props,
            excerpt: lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            steps: status?.steps, shotID: shot?.id)
    }
}

/// 一段一张卡（只画 `SegmentCardModel`，见那边的说明）
private struct SegmentCard: View, Equatable {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    let model: SegmentCardModel
    /// 卡片宽（下半块的字按这个宽画成图）
    let width: CGFloat

    nonisolated static func == (lhs: SegmentCard, rhs: SegmentCard) -> Bool {
        lhs.model == rhs.model && lhs.width == rhs.width
    }

    private var textState: SegmentTextState {
        let steps = model.steps
        let tone: Int
        switch model.statusTone {
        case .idle: tone = 0
        case .running: tone = 1
        case .done: tone = 2
        case .problem: tone = 3
        }
        return SegmentTextState(
            number: model.number, status: model.statusText, statusTone: tone,
            sceneName: model.sceneName, hasPicture: model.scenePath != nil,
            time: model.timeRange ?? "",
            names: model.people.map(\.name).joined(separator: "、"),
            noPeople: model.people.isEmpty,
            props: model.propNames.isEmpty ? "" : "道具 · " + model.propNames.joined(separator: "、"),
            excerpt: model.excerpt.isEmpty ? "（这一段没有剧情文字）" : model.excerpt,
            excerptEmpty: model.excerpt.isEmpty,
            steps: [steps?.extract ?? .pending, steps?.images ?? .pending, steps?.match ?? .pending, steps?.video ?? .pending]
                .map(SegmentTextState.stepCode),
            width: width)
    }

    static let coverHeight: CGFloat = 118

    /// 整张卡点哪都打开二级页面，悬停整卡一起提亮（只挂一个悬停监听：每张卡多出来的监听是滚动卡顿的大头）
    @State private var hovered = false
    @Environment(\.hoverFeedbackEnabled) private var hoverEnabled

    /// 一张卡只剩三层（2026-10-15 用户：段落卡滑动卡）：封面场景图、整张卡的字（段号 / 状态 / 场景名 / 时间 / 角色名 / 道具 / 剧情 / 四步，
    /// 后台画好的一张图，见 `BakedSegmentText`）、角色头像。原来封面上的小标签、渐变、下面每一行字都是单独的视图，滑动时每张新卡都要现建一大堆
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let scene = model.scenePath {
                AsyncThumbImage(path: scene)
                    .frame(maxWidth: .infinity).frame(height: Self.coverHeight)
                    .clipped()
            }
            BakedSegmentText(state: textState)
            avatars.padding(.leading, 14).padding(.top, Self.coverHeight + 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(hovered && hoverEnabled ? 0.05 : 0))
                .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme), lineWidth: 1))
        .accessibilityIdentifier("workbench-segment-\(model.number)")
    }

    // MARK: 角色头像（下半块别的字在烤好的图里）

    private var avatars: some View {
        let people = model.people
        let shown = Array(people.prefix(5))
        return HStack(spacing: -7) {
            ForEach(shown) { person in avatar(person) }
            if people.count > shown.count {
                Text("+\(people.count - shown.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(SolidTheme.card(colorScheme)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
            }
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private func avatar(_ person: SegmentCardModel.Person) -> some View {
        if let path = person.imagePath {
            // 圆形 + 外面一圈卡片底色的描边都画进图里，只剩一张图（原来是裁切 + 圆形遮罩 + 描边三层，每张卡两三个头像，滑动时很费）
            HeadshotThumb(path: path, size: 26, dark: colorScheme == .dark)
        } else {
            Text(String(person.name.prefix(1)))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.04)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])))
                .overlay(Circle().strokeBorder(SolidTheme.card(colorScheme), lineWidth: 2))
        }
    }
}

/// 角色头像：角色图的版式是「左边大头照、右边三视图全身」（2026-10-12 用户：头像里是全身像，想看大头照），
/// 横版图就从左边大头照里裁出脸；不是这种横版（比如一张竖的半身照）就照旧从中间裁
struct HeadshotThumb: View {
    let path: String
    let size: CGFloat
    /// 深色模式（外面那圈描边是卡片底色，跟着明暗变：头像叠在一起时分得开）
    var dark = true
    /// 只用来在图做好之后让自己重画一次
    @State private var loaded = 0

    /// 脸所在的正方形（按图片像素）：以横向 21%、纵向 37% 为中心，边长是图高的 56%——
    /// 按用户项目里几张真实角色图量的（左边 45%～47% 宽是大头照）。不是够宽的横版就返回 nil
    static func faceRect(imageSize: CGSize) -> CGRect? {
        let w = imageSize.width, h = imageSize.height
        guard h > 0, w / h >= 1.4 else { return nil }
        let side = h * 0.56
        let x = min(max(w * 0.21 - side / 2, 0), w - side)
        let y = min(max(h * 0.37 - side / 2, 0), h - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 做好的圆形头像（按 路径 | 尺寸 | 描边色 缓存；几百张卡用的就那十几个角色）
    @MainActor private static var made: [String: NSImage] = [:]
    private var key: String { "\(path)|\(size)|\(dark)" }

    var body: some View {
        // 做好了就只是一张图，什么监听都不挂（滚动时每张卡的视图越少越顺）；没做好时才挂一个加载任务。
        // 读一下 `loaded`：图做好时它变了，这里才会重画（缓存是静态的，SwiftUI 看不到它变）
        let _ = loaded
        if let done = Self.made[key] {
            Image(nsImage: done).resizable().frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
                .task(id: key) { load() }
        }
    }

    /// 和 `AsyncThumbImage` 一样：内存里有就直接用，没有就后台降采样；拿到图后裁出脸、画成圆形带描边，存起来
    private func load() {
        let key = key, size = size
        let ring = NSColor(SolidTheme.card(dark ? .dark : .light))
        let finish: (NSImage) -> Void = { source in
            Self.made[key] = Self.compose(source, size: size, ring: ring)
            loaded += 1
        }
        if let cached = LocalImageCache.memoryThumb(atPath: path) { finish(cached); return }
        LocalImageCache.loadThumbnail(atPath: path) { if let img = $0 { finish(img) } }
    }

    /// 裁脸（不是大头照版式就从中间裁成正方形）→ 圆形 → 外面一圈描边，按 2 倍像素画
    static func compose(_ source: NSImage, size: CGFloat, ring: NSColor) -> NSImage {
        let scale: CGFloat = 2, px = Int(size * scale)
        let srcSize = source.size
        let crop: CGRect = faceRect(imageSize: srcSize) ?? {
            let side = min(srcSize.width, srcSize.height)
            return CGRect(x: (srcSize.width - side) / 2, y: (srcSize.height - side) / 2, width: side, height: side)
        }()
        guard px > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let bounds = CGRect(x: 0, y: 0, width: px, height: px)
        NSBezierPath(ovalIn: bounds).addClip()
        // NSImage 的坐标从左下角起；faceRect 是按从上往下量的，翻一下 y
        let from = CGRect(x: crop.minX, y: srcSize.height - crop.maxY, width: crop.width, height: crop.height)
        source.draw(in: bounds, from: from, operation: .copy, fraction: 1)
        let lineWidth = 2 * scale
        ring.setStroke()
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        path.lineWidth = lineWidth
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}


