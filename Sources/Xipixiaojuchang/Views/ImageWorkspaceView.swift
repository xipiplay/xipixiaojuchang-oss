import SwiftUI

/// 图片生成工作区：批量粘贴解析 / 生成 / 入库。
/// **素材库已改成左侧抽屉浮窗**（`LibraryDrawerLayer`），不再占常驻栏位。
struct ImageWorkspaceView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ImageGenPanel()
            .frame(maxWidth: .infinity)
        // ⚠️ 最小窗口尺寸（1160×640）**已挪到 RootView 的共享页壳上**（2026-09-27）：
        // 右栏现在是页壳里独立的一列，挂在页面里会把最小宽度变成 1160 + 400。
    }
}

/// 中栏：批量粘贴区 + 解析清单 + 生成/入库
private struct ImageGenPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.mediaWorkspaceContext) private var mediaContext
    @State private var itemInput = MediaWorkspaceInput<[ImageGenItem]>()

    private var displayedItems: [ImageGenItem] {
        itemInput.value(active: mediaContext?.isActive(.image) ?? true) { app.currentImageItems }
    }
    /// 选中操作条的底色要跟随「玻璃效果」设置（2026-09-26 用户："这个弹窗怎么默认是玻璃态，
    /// 不应该跟随设置的那个嘛"）——同 `ToolbarRow` / `AppModal` 的做法
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme

    // 弹窗开关已统一到 `AppModel.activeModal`（改成浮层后由 RootView 呈现）；
    // 「批量解析」的粘贴文本也已移到 `AppModel.imagePasteText`（浮层跨不到原来的 Binding）
    /// 缩略图模式的状态筛选（2026-09-19；2026-09-26 用户定：**放在类型标签右边、带计数、
    /// 点一下筛 / 再点一下取消**——没有单独的「全部」状态）
    enum ThumbStatusFilter: String, CaseIterable, Identifiable {
        case all, pending, generating, completed, failed
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: "全部"
            case .pending: "待生成"
            case .generating: "生成中"
            case .completed: "已完成"
            case .failed: "失败"
            }
        }
    }
    @State private var thumbStatusFilter: ThumbStatusFilter = .all
    /// ⚠️ 多选集合已提到 `AppModel.app.selectedImageItemIDs`（2026-09-27：共享底栏要随选中态换内容）
    /// 拖动框选的选框矩形（命名坐标空间 `imageThumbMarquee` 里；nil = 没在拖）
    @State private var imageThumbMarqueeRect: CGRect?
    /// 拖动框选用的卡片 frame 缓存（普通 class，写入不触发重算）
    @State private var imageThumbFrames = MarqueeFrameStore<UUID>()
    /// 双击监听（缩略图 / 卡片各一份）+ 各自的容器全局 frame
    @State private var dblThumbMonitor: Any?
    @State private var dblThumbFrame: CGRect = .zero
    @State private var dblThumbViewport: CGRect = .zero
    @State private var dblCardMonitor: Any?
    @State private var dblCardFrame: CGRect = .zero
    @State private var dblCardViewport: CGRect = .zero

    // MARK: 🎯 双击 → 打开编辑提示词弹窗（NSEvent 监听；2026-10-01 用户要求）
    // ⚠️ 不用 SwiftUI 的 `onTapGesture(count: 2)`：它会让**单击等双击超时**（用户实测"切卡片慢一拍"）。
    // 监听按 `clickCount == 2` 判、命中复用框选的 frame 缓存，单击完全不受影响。

    private func dblLocal(_ frame: CGRect, _ window: NSWindow, _ p: NSPoint) -> CGPoint {
        let h = window.contentView?.bounds.height ?? window.frame.height
        return CGPoint(x: p.x - frame.minX, y: h - p.y - frame.minY)
    }
    private func dblInside(_ frame: CGRect, _ window: NSWindow, _ p: NSPoint) -> Bool {
        let local = dblLocal(frame, window, p)
        return local.x >= 0 && local.y >= 0 && local.x <= frame.width && local.y <= frame.height
    }

    private func installDblThumbMonitor() {
        guard dblThumbMonitor == nil else { return }
        dblThumbMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.clickCount == 2, let w = event.window, !(w is NSPanel),
                                    app.activeModal == nil, !app.showLibraryDrawer, !app.showTaskDrawer, !app.showHistoryDrawer,
                  app.isProductionWorkspaceVisible,
                  app.workspaceMode == .image, app.viewStyle == .thumbnails,
                  dblInside(dblThumbFrame, w, event.locationInWindow),
                  DoubleClickRegion.isOnVisibleGrid(viewport: dblThumbViewport, toolbar: app.workspaceToolbarFrame,
                                                    window: w, point: event.locationInWindow) else { return event }
            if let id = imageThumbFrames.hit(CGRect(x: dblLocal(dblThumbFrame, w, event.locationInWindow).x,
                                                    y: dblLocal(dblThumbFrame, w, event.locationInWindow).y,
                                                    width: 1, height: 1)).first {
                // 🆕 2026-10-03（用户定）：**双击 = 看大图**（编辑弹窗改从详情提示词进；选择模式下双击不动作）
                AppLog.write("dblClick", "生图缩略图双击 → 看大图 id=\(id)")
                if app.selectedImageItemIDs.isEmpty,
                   let target = app.imageItems.first(where: { $0.id == id }),
                   let r = target.results.first(where: { $0.id == target.selectedResultID }) ?? target.latestResult,
                   r.localPath != nil {
                    app.previewingImageResultID = r.id
                    app.previewingImageItemID = target.id
                }
                return nil
            }
            return event
        }
    }
    private func removeDblThumbMonitor() { if let m = dblThumbMonitor { NSEvent.removeMonitor(m) }; dblThumbMonitor = nil }

    private func installDblCardMonitor() {
        guard dblCardMonitor == nil else { return }
        dblCardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard event.clickCount == 2, let w = event.window, !(w is NSPanel),
                                    app.activeModal == nil, !app.showLibraryDrawer, !app.showTaskDrawer, !app.showHistoryDrawer,
                  app.isProductionWorkspaceVisible,
                  app.workspaceMode == .image, app.viewStyle == .cards,
                  dblInside(dblCardFrame, w, event.locationInWindow),
                  DoubleClickRegion.isOnVisibleGrid(viewport: dblCardViewport, toolbar: app.workspaceToolbarFrame,
                                                    window: w, point: event.locationInWindow) else { return event }
            if let id = imageCardMarqueeFrames.hit(CGRect(x: dblLocal(dblCardFrame, w, event.locationInWindow).x,
                                                          y: dblLocal(dblCardFrame, w, event.locationInWindow).y,
                                                          width: 1, height: 1)).first {
                AppLog.write("dblClick", "生图卡片双击 → 编辑弹窗 id=\(id)")
                ImagePreviewOnTap.shared.cancelPending()   // 🆕 取消"双击第一下"触发的看大图
                app.activeModal = .editImagePrompt(itemID: id)
                return nil
            }
            return event
        }
    }
    private func removeDblCardMonitor() { if let m = dblCardMonitor { NSEvent.removeMonitor(m) }; dblCardMonitor = nil }

    /// 卡片列表的拖动框选（2026-09-26 用户定："勾选和按住选择那套也放到卡片"）——
    /// 与网格共用 `app.selectedImageItemIDs`，只是坐标空间/缓存各一套
    @State private var imageCardMarqueeRect: CGRect?
    @State private var imageCardMarqueeFrames = MarqueeFrameStore<UUID>()
    /// ⚠️ 「右栏正在看的条目」已提到 `AppModel.inspectedImageItemID`（2026-09-27：右栏搬到 RootView 的
    /// 共享右侧栏，选中态不能再放在页面里）；历史条可视锚点也搬到 RootView。
    @State private var thumbnailSearchText = ""
    /// 缩略图网格可用宽度（ScrollView 宽度，只跟窗口尺寸变）——🧪 **实验 6b（2026-09-27）**：
    /// 用它算一次**固定列宽**给网格（原来 `.adaptive` 让每格尺寸靠布局引擎反复协商，
    /// 滑动采样里 `sizeThatFits` 家族是最大头）。
    @State private var thumbnailGridWidth: CGFloat = 0
    /// 🧪 **实验 7B（2026-09-27）**：视口高度（只跟窗口变）——算"可见几行"用。
    @State private var thumbnailViewportHeight: CGFloat = 0
    /// 🧪 实验 7B：单格内容实测高度（池里的格子回填一次；所有格同高）
    @State private var thumbnailCellHeight: CGFloat = 0
    /// 🧪 实验 7B：窗口起始行 —— **只有跨行才更新**；其余滚动帧 SwiftUI 什么都不做
    /// （格子位置是绝对坐标，NSScrollView 自己搬内容）。
    @State private var thumbnailWindowStartRow = 0

    /// 🧪 实验 7B：总开关（true = 固定池+窗口网格；false = LazyVGrid 老实现，方便 A/B）
    /// ⚠️ 2026-09-27 用户定：**先关掉**（与视频侧同步——"文字烤图+老网格"才是顺的那个形态）。
    private static let usePooledThumbGrid = false
    /// 🧪 实验 7B：行距（= 6b 时代 LazyVGrid spacing，视觉必须一致）
    private static let thumbGridSpacing: CGFloat = 12
    /// 🧪 实验 7B：格内容高实测前的估值（名字行+状态行 ≈45pt，实测后立即校正）
    private static let thumbCellTextEstimate: CGFloat = 45

    /// 🧪 实验 6b/7B：列数与格宽（与旧 `.adaptive(210...320)` 同口径：最小 210 / 最大 320 /
    /// 间距 12；留白同下方的 padding：左 16 · 右 4）。宽度还没量到时返回 (0, 0)。
    private var thumbnailGridSpec: (cols: Int, cellW: CGFloat) {
        let spacing: CGFloat = Self.thumbGridSpacing
        let available = thumbnailGridWidth - 16 - 4
        guard available >= 210 else { return (0, 0) }
        let count = max(1, Int((available + spacing) / (210 + spacing)))
        let width = min(320, floor((available - spacing * CGFloat(count - 1)) / CGFloat(count)))
        return (count, width)
    }

    /// ⚠️ **2026-09-27：列改回 `.adaptive`（与主页一致）** —— 固定列宽（实验 6b）把网格内容宽度
    /// 钉在"当时量到的宽度"上；双击缩放缩回时那个状态不更新 → 内容被旧列数撑宽 → **整个布局锁死在
    /// 放大时的宽度、两边被裁**（日志实证：缩回 1160 后网格宽还停在 1253）。
    /// `.adaptive` 由 SwiftUI 按当时的实际宽度自己排，不依赖状态（主页一直如此、缩放拖动都正常）。
    /// `cellWidth` 仍按量到的宽度给格子用（文字烤图要精确宽度；与 adaptive 的算法同口径）。
    private var thumbnailGridLayout: (columns: [GridItem], cellWidth: CGFloat) {
        ([GridItem(.adaptive(minimum: 210, maximum: 320), spacing: Self.thumbGridSpacing)],
         thumbnailGridSpec.cellW)
    }

    // MARK: 🧪 实验 7B：固定池 + 窗口（原型）——滚动成本与素材总量无关

    /// 池子参数（一次算好，body 里只用）
    private struct ThumbPoolMetrics {
        var cols = 1
        var cellW: CGFloat = 0
        var cellH: CGFloat = 0
        var rowPitch: CGFloat = 0
        var totalRows = 0
        var windowRows = 0
        var slotCount = 0
        var spacerHeight: CGFloat = 0
    }

    private var thumbnailPoolMetrics: ThumbPoolMetrics {
        var m = ThumbPoolMetrics()
        let spec = thumbnailGridSpec
        m.cellW = spec.cellW
        m.cols = max(1, spec.cols)
        guard spec.cols > 0 else { return m }
        m.cellH = thumbnailCellHeight > 0 ? thumbnailCellHeight : (m.cellW + Self.thumbCellTextEstimate)
        m.rowPitch = m.cellH + Self.thumbGridSpacing
        m.totalRows = max(0, Int(ceil(Double(thumbFilteredItems.count) / Double(m.cols))))
        let visibleRows = max(1, Int(ceil(thumbnailViewportHeight / max(m.rowPitch, 1))) + 1)
        m.windowRows = min(m.totalRows, visibleRows + 2)   // 上下各留一行余量（换数据都在屏外）
        m.slotCount = m.windowRows * m.cols
        m.spacerHeight = max(0, CGFloat(m.totalRows) * m.rowPitch
                             - Self.thumbGridSpacing + Self.bottomContentPadding)
        return m
    }

    /// 🧪 实验 7B：按当前滚动偏移刷新窗口起点 —— **只有跨行才写 @State**（别的帧什么都不做）。
    private func refreshThumbnailPoolWindow(offsetY: CGFloat? = nil) {
        guard Self.usePooledThumbGrid else { return }
        let m = thumbnailPoolMetrics
        guard m.totalRows > 0, m.slotCount > 0 else { return }
        let y = offsetY ?? app.scrollAnchors.liveImageThumbOffset
        let first = max(0, Int(floor(y / m.rowPitch)))
        let maxStart = max(0, m.totalRows - m.windowRows)
        let target = min(max(0, first - 1), maxStart)
        if target != thumbnailWindowStartRow {
            thumbnailWindowStartRow = target
        }
    }

    /// 🧪 实验 7B：槽位 → 条目索引（**环形映射** `i % slotCount`：每个条目一辈子只认一个槽位，
    /// 窗口滑动时只有"滚出去的那一行"的槽位换新数据，而且发生在屏外）。
    private func pooledThumbItemIndex(forSlot slot: Int, metrics m: ThumbPoolMetrics) -> Int? {
        let n = m.slotCount
        guard n > 0 else { return nil }
        let start = thumbnailWindowStartRow * m.cols
        let d = ((slot - start) % n + n) % n
        let i = start + d
        guard i < start + m.windowRows * m.cols, i < thumbFilteredItems.count else { return nil }
        return i
    }
    /// 搜索框焦点（2026-09-26 用户："点了之后鼠标再点其他地方，光标还在闪"→手动收）
    @FocusState private var searchFocused: Bool
    /// 类型标签页（nil = 全部）
    @State private var thumbTypeFilter: ImageSubjectType? = nil

    /// 恢复卡片 / 缩略图模式离开时的滚动位置。
    @State private var restorePosition = ScrollPosition(idType: Never.self)
    /// 只在图片面板初次出现时从 AppModel 恢复；同一面板内切换卡片/缩略图依靠父级 ScrollPosition 状态续接。
    @State private var shouldRestoreImageCardOffset = true
    @State private var shouldRestoreImageThumbOffset = true
    private var scrollPositionBinding: Binding<ScrollPosition> {
        Binding(get: { restorePosition }, set: { restorePosition = $0 })
    }

    /// 悬浮工具条会盖住内容区底部 —— 列表/网格底部留出这么多（同生视频侧）
    private static let bottomContentPadding: CGFloat = 80

    private var allReadyItems: [ImageGenItem] {
        displayedItems.filter { $0.status == .pending || $0.status == .failed }
    }

    // ⚠️ 选中相关的一切（`selectedImageItems` / `prepareBatchSubmit` / 删除与提交的确认框 /
    //    信息提示）都搬到了 **RootView 的共享底栏**（2026-09-27 用户定：选中后工具条换成四个按钮）。

    var body: some View {
        let _ = BodyEvalCounter.bump("ImageGenPanel")
        // 页面壳（2026-09-27 方案 A）：空态 / 头部容器 / 卡片-网格切换都在 `thumbnailWorkspace` 里的
        // `WorkspacePage`（生图与生视频共用一份实现）；工具条与右栏在 RootView 的共享层。
        thumbnailWorkspace
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 切项目：滚动位置清零（原来挂在底栏上；底栏搬到 RootView 页壳后挪到这里，2026-09-27）
        .onChange(of: mediaContext?.projectKey ?? app.currentProjectKey) { _, _ in
            // ScrollPosition 状态随 ImageGenPanel 保留；切项目时显式清零，避免把上个项目的位置带过来。
            restorePosition = ScrollPosition(idType: Never.self)
            restoreThumbPosition = ScrollPosition(idType: Never.self)
            shouldRestoreImageCardOffset = true
            shouldRestoreImageThumbOffset = true
            app.inspectedImageItemID = nil
        }
        // 「批量设置参数」已改成应用内浮层，由 **RootView** 统一呈现（见 AppModal 的注释）
        // 「批量解析」已改成应用内浮层，由 **RootView** 统一呈现
        // 删除 / 提交的确认框也都搬到了 RootView 的共享底栏（2026-09-27）
    }

    /// 缩略图工作区与其批量选择操作条作为一个常驻层，与视频侧的双视图切换方式对齐。
    // 选中操作条已**并入共享底栏**（2026-09-27 用户定：选中后工具条整个换成四个按钮）。
    // 删/设置/提交/取消的实现都在 RootView 的 `sharedToolbar`。

    // MARK: 顶部工具条
    // ⚠️ 工具条已搬到 **RootView 的共享页壳**（2026-09-27 用户定：四个页面共用一个底栏，
    //    按当前模式换按钮）。原来的 `bottomBar` 已删；切项目清滚动位置那段 `.onChange`
    //    挪到了 body 的 HStack 上。想加按钮去 RootView 的 `sharedToolbar`。

    // ⚠️ `isModelConfigured` / `showInfoAlert` / `submitImageBatch` 都搬到了 RootView 的共享底栏（2026-09-27）

    // MARK: 生图卡片列表

    /// 生图卡片列表。只在卡片模式构建；切换模式前由 `AppModel.setImageViewStyle` 保存滚动位置，
    /// 回到卡片模式时再从快照恢复。
    private var imageCardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 缩略图页与卡片页同时常驻以保留滚动位置。这里必须惰性创建：
                // 普通 VStack 会在缩略图页滚动时仍创建、测量全部提示词卡片，
                // 造成不可见的重视图也参与布局；主页网格与视频卡片列表都按可见范围惰性布局。
                LazyVStack(spacing: 16) {
                    // 头部筛选对卡片列表**也生效**（2026-09-26 用户定："一直显示并生效"）；
                    // 勾选 / 拖动框选与网格同一套（选择状态共用）；点卡片的非控件区域 → 右栏切到这条
                    ForEach(thumbFilteredItems) { item in
                        ImageGenItemRow(
                            item: item,
                            selectionMode: !app.selectedImageItemIDs.isEmpty || imageCardMarqueeRect != nil,
                            isSelected: app.selectedImageItemIDs.contains(item.id),
                            isCurrent: app.inspectedImageItemID == item.id,
                            onToggleSelect: {
                                searchFocused = false
                                toggleThumbSelection(item.id)
                            }
                        )
                        .equatable()
                        .id("imgrow-\(item.id)")
                        // 上报卡片 frame（拖动框选用；普通 class 缓存，写入不触发重算）。
                        // ⚠️ **别用 `.background { GeometryReader }`**：在 LazyVStack/LazyVGrid 里
                        // 每格一个测量容器会引发逐格 layout 连锁（2026-09-27 深夜采样）。
                        // 2026-09-27 实验 1 验证过：去掉它对滚动**没有帮助**（别再折腾它来治卡顿）。
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named("imageCardMarquee"))
                        } action: { rect in
                            imageCardMarqueeFrames.update(item.id, rect)
                        }
                        .onTapGesture {
                            searchFocused = false
                            if app.selectedImageItemIDs.isEmpty {
                                // 点条目 → 右栏切到生图侧（右栏只跟点击走，2026-09-27）
                                app.inspectorKind = .image
                                app.inspectedImageItemID = item.id
                            } else {
                                toggleThumbSelection(item.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, Self.bottomContentPadding)
                // 拖动框选（2026-09-26 用户定）：任何位置可起拖、**每次替换**（选择状态与网格共用）
                .coordinateSpace(.named("imageCardMarquee"))
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblCardFrame = f }
                })
                .onAppear { installDblCardMonitor() }
                .onDisappear { removeDblCardMonitor() }
                .overlay { imageCardMarqueeOverlay }
                .simultaneousGesture(imageCardMarqueeGesture)
            }
            .scrollIndicators(.hidden)
            // 双击只认滚动区看得见的那一块（见 `DoubleClickRegion`）：量的是 ScrollView 本身，不是它那份很高的内容
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblCardViewport = f }
            })
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                app.scrollAnchors.liveImageOffset = y
            }
            .scrollPosition(scrollPositionBinding)
            .scrollDisabled(app.assetLibraryHovering)
            .onAppear {
                guard shouldRestoreImageCardOffset else { return }
                shouldRestoreImageCardOffset = false
                guard let saved = app.scrollAnchors.savedImageOffset else { return }
                AppLog.write("viewStyle", "生图卡片恢复滚动 y=\(Int(saved))")
                DispatchQueue.main.async {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        restorePosition = ScrollPosition(idType: Never.self, y: saved)
                    }
                }
            }
            .onChange(of: app.scrollToImageItemID) { _, newID in
                guard let newID else { return }
                // 缩略图页新增时，隐藏的卡片列表不跟着跳转。
                guard app.imageViewStyle == .cards else { return }
                let isLastVisibleItem = thumbFilteredItems.last?.id == newID
                DispatchQueue.main.async {
                    if isLastVisibleItem {
                        // 新增条目总在末尾。此时 ScrollViewReader 对新行的 scrollTo
                        // 已实测调用但未滚动；用本列表已有的 ScrollPosition 直接到底。
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            restorePosition = ScrollPosition(idType: Never.self, edge: .bottom)
                        }
                        AppLog.write("imageJump", "卡片视图滚到底部 item.id=\(newID)")
                    } else {
                        proxy.scrollTo("imgrow-\(newID)", anchor: .top)
                    }
                    clearScrollToImageItemID()
                }
            }
        }
    }

    // MARK: 缩略图模式（2026-09-17，与生视频侧同款）


    /// 缩略图模式的滚动位置恢复（同卡片侧：只认 saved 快照；逐帧记录走非观察缓存）
    @State private var restoreThumbPosition = ScrollPosition(idType: Never.self)

    private var thumbScrollPositionBinding: Binding<ScrollPosition> {
        Binding(get: { restoreThumbPosition }, set: { restoreThumbPosition = $0 })
    }

    /// 只读缩略图网格：16:9 缩略图 + 名称 + 类型/版本角标。
    /// 缩略图模式同样使用连续滚动，不显示分页控件。
    /// 单击选中条目并更新右侧详情；多选时单击仍用于批量勾选。
    /// 缩略图模式的条目（**只按名称搜索** + 类型 + 状态筛选）。
    /// 2026-09-26 用户定："只搜名称"——原来提示词也参与，搜「方」会被「正前方 / 运镜方式 /
    /// 长方形」这类词带出一堆无关条目（全库 30+ 条）。
    private var thumbFilteredItems: [ImageGenItem] {
        displayedItems.filter { item in
            let query = thumbnailSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty,
               !item.name.localizedCaseInsensitiveContains(query) { return false }
            if let type = thumbTypeFilter, item.type != type { return false }
            switch thumbStatusFilter {
            case .all: return true
            case .pending: return item.status == .pending
            case .generating: return item.status == .queued || item.status.isBusy
            case .completed: return item.status == .success
            case .failed: return item.status == .failed
            }
        }
    }

    /// 缩略图工作区：左侧图库选择条目，右侧详情面板始终对应同一个条目。
    private var thumbnailWorkspace: some View {
        // 页面壳（2026-09-27 方案 A）：空态 / 头部容器 / 卡片-网格切换都在 `WorkspacePage` 里，
        // 生图与生视频共用这一份实现；右栏在 RootView 的共享层。
        WorkspacePage(
            mode: .image,
            isEmpty: displayedItems.isEmpty,
            searchText: $thumbnailSearchText,
            searchPlaceholder: "搜索名称",
            searchFocus: $searchFocused
        ) {
            // 空态：整块虚线投放区（点击建卡片 / 用工具条「批量解析」从文本识别）
            DropZone(action: { app.addImageItem() }) {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("点击此处新建图片卡片")
                        .font(.callout)
                }
            }
            // 四边一样留 14（2026-10-12 用户："虚线框跑到顶上了"）：2026-09-18 时为了「到顶」把顶部留边去掉，
            // 那时上面没有卡片边框；内容区改成带边框的圆角卡片之后，顶部 0 就是贴着卡片上沿
            .padding(14)
        } filters: {
            // 筛选区：类型标签 + 细竖线 + 状态；勾选后换成「已选 N + 全选」
            if app.selectedImageItemIDs.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 20) {
                        thumbTypeTab("全部", nil)
                        thumbTypeTab("角色", .character)
                        thumbTypeTab("场景", .scene)
                        thumbTypeTab("道具", .prop)
                    }
                    // 类型 ↔ 状态：细竖线分组（2026-09-26 用户定**方案 2**：保持字号层级，用分隔线把两组分开）
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 18)
                    thumbStatusChips
                }
            } else {
                // 选中模式：筛选区换成「已选 N + 全选」（同视频侧）
                thumbSelectedRow
            }
        } gridContent: {
            imageThumbnailGrid
        } cardsContent: {
            imageCardList
        }
        // 首次出现把选中兜底到第一条（右栏在共享层，用 AppModel 的 id；2026-09-27）
        .onAppear {
            if !thumbFilteredItems.contains(where: { $0.id == app.inspectedImageItemID }) {
                app.inspectedImageItemID = thumbFilteredItems.first?.id
            }
        }
        .onChange(of: thumbFilteredItems.map(\.id)) { _, ids in
            let visible = Set(ids)
            // 🎯 2026-09-27 用户定方案 B：多选只按筛选后的可见列表算 ——
            // 被筛掉/搜掉的条目自动取消选中（同视频侧，别让「已选 N」与可见选中对不上）。
            if !app.selectedImageItemIDs.isEmpty, !app.selectedImageItemIDs.isSubset(of: visible) {
                app.selectedImageItemIDs.formIntersection(visible)
            }
            // 🧹 幽灵 frame（2026-09-27 用户实测："删 图片35、选中顶上来的那条 → 已选 2"）：
            // 被删条目的 frame 还留在框选缓存里、和新条目占同一个位置，`hit()` 会把两个都算上。
            // 列表一变就清掉不在列表里的 frame（在屏格子会重新上报，不受影响）。
            imageThumbFrames.keepOnly(visible)
            imageCardMarqueeFrames.keepOnly(visible)
            if let selected = app.inspectedImageItemID, ids.contains(selected) { return }
            app.inspectedImageItemID = ids.first
        }
    }

    // `selectedImageResultBinding` / `imageHistoryScrollBinding` / `inspectedImageItem` 都搬到
    // RootView 的**共享右侧栏**里了（2026-09-27）。

    /// 缩略图模式顶部：类型标签页（全部 / 角色 / 场景 / 道具）+ **状态（带计数）** + 搜索框。
    /// **勾选后：左边换成「已选 N + 全选」**（2026-09-26 用户定："应该在全部、角色那里"）。
    // ⚠️ 头部（筛选横滑区 + 搜索框）已收进 **`WorkspacePage`**（2026-09-27 方案 A：四个页面一套实现）——
    //    这里不再有 `thumbnailHeader`；筛选/搜索内容现在直接写在 `thumbnailWorkspace` 的 `filters:` 插槽里。

    /// 状态（带计数）——类型标签右边（2026-09-26 用户定："已完成 / 待生成 / 生成中 / 失败，带上数字"）。
    /// 点一下 = 只看该状态；再点一下 = 取消筛选（没有单独的「全部」状态）。
    private var thumbStatusChips: some View {
        HStack(spacing: 8) {
            // 「全部」在最前（2026-09-27 用户："生图侧的状态少了个全部"）——点它 = 取消筛选；
            // 不筛时它就是亮的（与视频侧同一套）。
            ForEach([ThumbStatusFilter.all, .completed, .pending, .generating, .failed]) { f in
                Button {
                    searchFocused = false
                    thumbStatusFilter = f       // f == .all 即取消筛选
                } label: {
                    HStack(spacing: 4) {
                        Text(f.displayName)
                        Text("\(thumbStatusCount(f))")
                            .foregroundStyle(thumbStatusFilter == f
                                             ? Theme.accent.opacity(0.85)
                                             : Color.secondary)
                    }
                    .font(.callout)
                    // 胶囊底（2026-09-27 用户："加上胶囊底我看看效果"）——同视频侧：
                    // 选中 accent 0.22 / 未选 secondary 0.1，文字选中 accent、未选 primary；
                    // 点区吃满整个胶囊（含"文字↔数字"的 4pt 间隙）。
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(thumbStatusFilter == f
                                               ? Theme.accent.opacity(0.22)
                                               : Color.secondary.opacity(0.1)))
                    .foregroundStyle(thumbStatusFilter == f ? Theme.accent : Color.primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(QuietButtonStyle(hover: .capsule))
                .help(f == .all
                      ? "显示全部"
                      : (thumbStatusFilter == f ? "取消状态筛选" : "只看「\(f.displayName)」"))
            }
        }
    }

    /// 选中模式：「已选 N + 全选」——**直接放在类型标签那一行**（2026-09-26 用户定）。
    private var thumbSelectedRow: some View {
        HStack(spacing: 16) {
            Text("已选 \(app.selectedImageItemIDs.count)")
                .font(.callout.weight(.semibold))
            SelectBox(
                title: "全选",
                titleFont: .callout.weight(.semibold),
                isChecked: app.selectedImageItemIDs.count == thumbFilteredItems.count
            ) {
                if app.selectedImageItemIDs.count == thumbFilteredItems.count {
                    app.selectedImageItemIDs.removeAll()
                } else {
                    app.selectedImageItemIDs = Set(thumbFilteredItems.map(\.id))
                }
            }
        }
    }

    private func toggleThumbSelection(_ id: UUID) {
        if app.selectedImageItemIDs.contains(id) {
            app.selectedImageItemIDs.remove(id)
        } else {
            app.selectedImageItemIDs.insert(id)
        }
    }

    /// 拖动框选的选框外观（半透明 + 描边；跟随手势矩形）
    @ViewBuilder
    private var imageThumbMarqueeOverlay: some View {
        if let r = imageThumbMarqueeRect {
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
    private var imageThumbMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("imageThumbMarquee"))
            .onChanged { value in
                searchFocused = false
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                imageThumbMarqueeRect = rect
                app.selectedImageItemIDs = imageThumbFrames.hit(rect)
            }
            .onEnded { _ in
                imageThumbMarqueeRect = nil
            }
    }

    /// 卡片列表拖动框选的选框外观（同网格那套）
    @ViewBuilder
    private var imageCardMarqueeOverlay: some View {
        if let r = imageCardMarqueeRect {
            Rectangle()
                .fill(Theme.accent.opacity(0.12))
                .overlay { Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1) }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// 卡片列表拖动框选手势：**任何位置可起拖**、**每次替换**（2026-09-26 用户定：卡片也要那套）
    private var imageCardMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("imageCardMarquee"))
            .onChanged { value in
                searchFocused = false
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                imageCardMarqueeRect = rect
                app.selectedImageItemIDs = imageCardMarqueeFrames.hit(rect)
            }
            .onEnded { _ in
                imageCardMarqueeRect = nil
            }
    }

    private func thumbTypeTab(_ title: String, _ type: ImageSubjectType?) -> some View {
        let active = thumbTypeFilter == type
        return Button {
            searchFocused = false   // 点标签也收掉搜索框焦点（2026-09-26 用户）
            thumbTypeFilter = type
        } label: {
            HStack(spacing: 6) {
                Text(title)
                // 数字从状态胶囊行挪到类型标签上（2026-09-26 用户定）——同款灰、小一号
                Text("\(thumbTypeCount(type))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // 2026-09-26 定稿：类型 = 原来那个大字号（title3 20pt），状态 = callout 14pt，竖线分组
            .font(.title3.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            // 🎯 2026-09-29 用户："只能点文字才点中" → 把**整块 label** 声明成矩形命中区
            //（布局不变；字与字之间的缝、数字那截、上下一点都算；要再多一圈就加 padding，
            //  但那会改标签间距 —— 见 `thumbTypeTab` 调用处的间距）
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }

    /// 状态计数（**只在当前类型范围内数**，不随搜索框变——与原来胶囊行的口径一致）。
    private func thumbStatusCount(_ f: ThumbStatusFilter) -> Int {
        displayedItems.filter { item in
            if let type = thumbTypeFilter, item.type != type { return false }
            switch f {
            case .all: return true
            case .pending: return item.status == .pending
            case .generating: return item.status == .queued || item.status.isBusy
            case .completed: return item.status == .success
            case .failed: return item.status == .failed
            }
        }.count
    }

    /// 类型标签上的数字（2026-09-26 用户定：数字从状态胶囊行挪到「全部 / 角色 / 场景 / 道具」上）。
    /// 口径与原来胶囊行一致：**只看类型、不随搜索框变**。
    private func thumbTypeCount(_ type: ImageSubjectType?) -> Int {
        displayedItems.filter { type == nil || $0.type == type }.count
    }

    /// 缩略图区：筛选/搜索结果为 0 条时，空态占位显示在**左网格区**（2026-09-26 用户：
    /// "他的位置怎么在右边啊"）——右栏这时留空。
    private var imageThumbnailGrid: some View {
        Group {
            if thumbFilteredItems.isEmpty {
                // 空态：**图标和文字都不要**（2026-09-26 用户定）——左区完全空着，什么都不显示
                Color.clear
            } else {
                imageThumbnailScroll
            }
        }
    }

    /// 缩略图滚动网格本体（空态由 `imageThumbnailGrid` 换成占位）。
    private var imageThumbnailScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if Self.usePooledThumbGrid {
                        pooledThumbnailGrid
                    } else {
                        lazyThumbnailGrid
                    }
                }
                // 拖动框选（2026-09-26 用户定：任何位置可起拖、**每次替换**）
                .coordinateSpace(.named("imageThumbMarquee"))
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblThumbFrame = f }
                })
                .onAppear { installDblThumbMonitor() }
                .onDisappear { removeDblThumbMonitor() }
                .overlay { imageThumbMarqueeOverlay }
                .simultaneousGesture(imageThumbMarqueeGesture)
            }
            .scrollIndicators(.hidden)
            // 双击只认滚动区看得见的那一块（见 `DoubleClickRegion`）：量的是 ScrollView 本身，不是它那份很高的内容
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblThumbViewport = f }
            })
            // 🧪 实验 6b/7B：只量**这一次** ScrollView 尺寸（跟窗口变），别在格子里再量。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if abs(size.width - thumbnailGridWidth) > 0.5 { thumbnailGridWidth = size.width }
                if abs(size.height - thumbnailViewportHeight) > 0.5 {
                    thumbnailViewportHeight = size.height
                    refreshThumbnailPoolWindow()   // 🧪 7B
                }
            }
            // 逐帧记录滚动偏移（恢复时就靠它）—— 写非观察缓存，不标脏 ✓（同卡片侧）
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                app.scrollAnchors.liveImageThumbOffset = y
                refreshThumbnailPoolWindow(offsetY: y)   // 🧪 7B：只有跨行才写状态
            }
            .scrollPosition(thumbScrollPositionBinding)
            .onAppear {
                guard shouldRestoreImageThumbOffset else { return }
                shouldRestoreImageThumbOffset = false
                // 恢复上次离开缩略图模式时的位置（同卡片侧：读 saved 快照 + 关动画 + async）
                if let saved = app.scrollAnchors.savedImageThumbOffset {
                    AppLog.write("viewStyle", "生图缩略图恢复滚动 y=\(Int(saved))")
                    DispatchQueue.main.async {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            restoreThumbPosition = ScrollPosition(idType: Never.self, y: saved)
                        }
                    }
                }
            }
            // ⚠️ **这里不再存滚动位置**（2026-09-17，同生视频侧）——
            // 改为切换视图时由 `AppModel.setImageViewStyle` 显式快照。
            .onChange(of: thumbFilteredItems.count) { _, _ in
                refreshThumbnailPoolWindow()   // 🧪 7B：筛选/搜索后重算窗口
            }
            .onChange(of: thumbnailGridSpec.cols) { _, _ in
                refreshThumbnailPoolWindow()   // 🧪 7B：宽度变化（列数变）重算窗口
            }
            .onChange(of: thumbnailCellHeight) { _, _ in
                refreshThumbnailPoolWindow()   // 🧪 7B：格高实测回来了，重算窗口
            }
            // ⚠️ **不做预载**（2026-09-27 用户定终，实验 11/15 已否）：全量顺序预载（读盘 + 解码 + 烤字）
            //     只是把"滑到才加载"提前付，几百次后台操作反而拖累进项目；现在只留"格子出现自己加载
            //     + 磁盘缓存"（滚到就有）。别再把这套加回来。
            // 点任务抽屉行：网格内直接定位。
            .onChange(of: app.scrollToImageItemID) { _, newID in
                guard let newID else { return }
                if Self.usePooledThumbGrid {
                    scrollPooledThumbGrid(to: newID)   // 🧪 7B：算行号 → 直接设滚动位置
                } else {
                    proxy.scrollTo(newID, anchor: .center)
                }
                // ⚠️ 清标志**必须延后一拍**（见 `clearScrollToImageItemID`）
                clearScrollToImageItemID()
            }
        }
    }

    /// 🧪 **实验 7B（2026-09-27）固定池 + 窗口网格**（原型 · 只接生图缩略图）：
    /// 屏幕上永远只有 `slotCount`（≈可见行 + 2）× 列数 个格子视图；滚出窗口的格子**换数据、不销毁重建**；
    /// 窗口只在跨行时更新，其余滚动帧 NSScrollView 自己搬内容（SwiftUI 零工作）。
    /// 目标：滚动成本与素材总量无关（1 万条也一样顺）。
    private var pooledThumbnailGrid: some View {
        let m = thumbnailPoolMetrics
        return ZStack(alignment: .topLeading) {
            // 撑出真实内容高度（滚动条 / 恢复定位 / 跳转都靠它）
            Color.clear.frame(height: m.spacerHeight)

            ForEach(0..<m.slotCount, id: \.self) { slot in
                if let i = pooledThumbItemIndex(forSlot: slot, metrics: m) {
                    pooledThumbCell(item: thumbFilteredItems[i], index: i, metrics: m)
                }
            }
        }
    }

    /// 池子里的一个格子（**身份 = 槽位**：环形映射保证"条目 ↔ 槽位"一辈子只绑一次，
    /// 换数据时视图不销毁重建）。
    @ViewBuilder
    private func pooledThumbCell(item: ImageGenItem, index i: Int, metrics m: ThumbPoolMetrics) -> some View {
        ImageAssetRow(
            item: item,
            displayedResultID: item.selectedResultID,
            selectionMode: !app.selectedImageItemIDs.isEmpty || imageThumbMarqueeRect != nil,
            isSelected: app.selectedImageItemIDs.contains(item.id),
            isCurrent: app.inspectedImageItemID == item.id,
            cellWidth: m.cellW,
            onToggleSelect: {
                searchFocused = false
                toggleThumbSelection(item.id)
            },
            onOpen: {
                searchFocused = false
                // 点条目 → 右栏切到生图侧（右栏只跟点击走，2026-09-27）
                app.inspectorKind = .image
                app.inspectedImageItemID = item.id
            }
        )
        .equatable()
        // 上报卡片 frame（拖动框选用；普通 class 缓存，写入不触发重算）
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("imageThumbMarquee"))
        } action: { rect in
            imageThumbFrames.update(item.id, rect)
        }
        // 实测格高（所有格同高，回填一次；窗口数学靠它）
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if h > 1, abs(h - thumbnailCellHeight) > 0.5 { thumbnailCellHeight = h }
        }
        // 绝对坐标：条目 i 一辈子落在同一个位置（窗口滑动不挪它）
        .offset(x: 16 + CGFloat(i % m.cols) * (m.cellW + Self.thumbGridSpacing),
                y: CGFloat(i / m.cols) * m.rowPitch)
    }

    /// LazyVGrid 老实现（A/B 对照用；`usePooledThumbGrid = false` 时走这条）。
    private var lazyThumbnailGrid: some View {
        LazyVGrid(
            columns: thumbnailGridLayout.columns,   // 🧪 实验 6b：固定列宽（原来 .adaptive）
            spacing: Self.thumbGridSpacing
        ) {
            ForEach(thumbFilteredItems) { item in
                ImageAssetRow(
                    item: item,
                    displayedResultID: item.selectedResultID,
                    selectionMode: !app.selectedImageItemIDs.isEmpty || imageThumbMarqueeRect != nil,
                    isSelected: app.selectedImageItemIDs.contains(item.id),
                    isCurrent: app.inspectedImageItemID == item.id,
                    cellWidth: thumbnailGridLayout.cellWidth,   // 🧪 实验 6b
                    onToggleSelect: {
                        searchFocused = false
                        toggleThumbSelection(item.id)
                    },
                    onOpen: {
                        searchFocused = false
                        app.inspectorKind = .image
                        app.inspectedImageItemID = item.id
                    }
                )
                .equatable()
                .id(item.id)
                // 上报卡片 frame（拖动框选用）
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("imageThumbMarquee"))
                } action: { rect in
                    imageThumbFrames.update(item.id, rect)
                }
            }
        }
        // 右侧只留 4pt（2026-09-26 用户定）——同池子路径：左 16 · 右 4
        .padding(.leading, 16)
        .padding(.trailing, 4)
        // 留出悬浮工具条的高度（池子路径把它算进 spacer 高度里了）
        .padding(.bottom, Self.bottomContentPadding)
    }

    /// 🧪 实验 7B：跳转到某条（原 `proxy.scrollTo` 的等价物：算出行号 → 直接设滚动位置，居中）。
    private func scrollPooledThumbGrid(to itemID: UUID) {
        guard let idx = thumbFilteredItems.firstIndex(where: { $0.id == itemID }) else { return }
        let m = thumbnailPoolMetrics
        guard m.cols > 0 else { return }
        let row = idx / m.cols
        let y = max(0, CGFloat(row) * m.rowPitch - max(0, (thumbnailViewportHeight - m.cellH) / 2))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            restoreThumbPosition = ScrollPosition(idType: Never.self, y: y)
        }
    }

    // （实验 11「进项目后顺序预载」已删 —— 2026-09-27 用户定终：只留格子自加载 + 磁盘缓存。）

    /// 双击缩略图 → 切回卡片模式并定位到该条目。
    /// 滚动位置通过 offset 快照恢复；显式定位由卡片列表直接滚到目标条目。
    private func showImageInCards(itemID: UUID) {
        AppLog.write("viewStyle", "双击生图缩略图 → 卡片模式定位 item.id=\(itemID)")
        app.scrollToImageItemID = itemID
        app.setImageViewStyle(.cards)
    }

    /// 清掉"跳转请求"。延后一拍，确保当前模式的 ScrollView 已处理定位请求。
    private func clearScrollToImageItemID() {
        DispatchQueue.main.async { app.scrollToImageItemID = nil }
    }

}

/// 批量设置图片参数弹窗：模型 + 画幅 + 分辨率档位
/// 批量设置图片参数。**不再是 private**：改成应用内浮层后由 `RootView` 呈现
/// （要挂在根视图才能盖住整窗），跨文件可见。
struct BatchImageParamView: View {
    @Environment(AppModel.self) private var app
    /// 关闭回调（原来是 `@Environment(\.dismiss)`，改成浮层后失效，由外部传入）
    var onClose: () -> Void

    /// "" = **不改**（默认项）；选了某个模型才批量应用
    // 🆕 2026-10-03（用户定）：初值跟随设置里的「默认参数（新建时套用）」——
    // 直接在声明处读 UserDefaults（与 AppModel 的 defaultImage* 同键）；"不指定"时保持原初值。
    // 弹窗每次打开都会新建实例，所以这里读到的就是最新保存的默认参数（用户实测"保存后不同步"已修）。
    @State private var model: String = UserDefaults.standard.string(forKey: "defaultImageModel") ?? ""
    @State private var aspect: ImageAspect =
        ImageAspect(rawValue: UserDefaults.standard.string(forKey: "defaultImageAspect") ?? "") ?? .ratio16x9
    @State private var quality: ImageQuality =
        ImageQuality(rawValue: UserDefaults.standard.string(forKey: "defaultImageQuality") ?? "") ?? .k2

    /// 模型下拉：默认项「请选择模型」（value = ""，**语义不变 = 不批量改模型**）+ 配置里所有图片模型
    private var modelOptions: [DropdownOption<String>] {
        var options = [DropdownOption(label: "请选择模型", value: "")]
        for name in app.imageModelNames {
            options.append(DropdownOption(label: name, value: name))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("批量设置参数")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 12`：分割线拿走后面向内容那侧要收掉，否则头 12 + 内容 14 叠成死白
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 标题下**不加分割线**（同其余三个弹窗）

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Text("模型")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "cube",
                        labelWidth: 90,
                        options: modelOptions,
                        selection: $model,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
                HStack(spacing: 12) {
                    Text("画幅")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "aspectratio",
                        labelWidth: 44,
                        options: ImageAspect.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                        selection: $aspect,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
                HStack(spacing: 12) {
                    Text("分辨率")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "sparkles",
                        labelWidth: 32,
                        options: ImageQuality.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                        selection: $quality,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 14`：同理，面向被删线的那两侧收掉
            .padding(.top, 8)
            .padding(.bottom, 8)

            // 底部按钮上方也**不加分割线**（同标题下那条）

            HStack {
                Text("应用到选中的 \(app.batchImageScopeIDs.count) 个条目，再确认提交")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onClose() }
                Button("应用") {
                    // 只对**选中的**生效（2026-09-26 用户定）；模型为空（默认项「请选择模型」）= 不改模型
                    app.batchSetImageParams(
                        ids: app.batchImageScopeIDs,
                        model: model.isEmpty ? nil : model,
                        aspect: aspect,
                        quality: quality
                    )
                    onClose()
                    app.batchParamsAppliedForSubmit += 1       // 接着弹提交确认（见 RootView 底部工具条）
                }
                .buttonStyle(AccentButtonStyle())
                .tint(Theme.accent)
            }
            // 原 `.padding(12)`：上侧朝向被删的那条线，收掉
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        // **只固定宽度，不固定高度**：sheet 会贴着内容的高度，不会多出一片空白。
        // 原来写死 `height: 280` —— 那个数是"还有分割线、padding 也更大"的时候定的，
        // 分割线和多余 padding 拿掉后内容矮了一截，多出来的高度就被 VStack 上下居中成空白
        // （用户实测："批量参数上边和应用下边都有空白"）。**高度别再写死，让它自己贴。**
        .frame(width: 420)
    }
}

/// 批量解析弹窗：粘贴提示词文本，右下角「解析」按钮识别成多条生图条目
/// 批量解析。**不再是 private**：改成应用内浮层后由 `RootView` 呈现，跨文件可见。
struct BatchImageParseView: View {
    @FocusState private var pasteFocused: Bool
    @Environment(AppModel.self) private var app
    /// 关闭回调（原来是 `@Environment(\.dismiss)`，改成应用内浮层后没有 presentation 上下文）
    var onClose: () -> Void
    /// 素材页复用解析输入和规则，结果写入当前集。
    var onParse: ((String) -> Bool)? = nil

    /// 拖入的 txt 路径读不出来时的提示（正常情况下底部显示的是用法说明）
    @State private var dropError: String?

    var body: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            HStack {
                Text("批量解析")
                    .font(.title3.weight(.semibold))
                Spacer()
                // 叉号已按用户要求移除；这个弹窗是 sheet、点外边关不掉，靠底部的「取消」关
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 12`：分割线拿走后面向内容那侧收掉
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 标题下**不加分割线**（同其余三个弹窗）
            // 说明文字不在这里 —— 它和底部两个按钮**同一行**（见下）

            TextEditor(text: $app.imagePasteText)
                .focused($pasteFocused)
                .font(.system(size: 13))
                // ⚠️ **必须隐藏 TextEditor 自带的内容背景**：它在 macOS 上是一块**不透明的方形**，
                // 会盖住下面那个圆角底 → 表现为「里面是方角、外面边线是圆角」，两者对不上。
                // （和设置页 `Form` 那个是同一个病：macOS 的文本/滚动容器自带内容背景。
                //   另外两个「编辑提示词」弹窗用的是自绘 `PromptEditor`，它设了 `drawsBackground = false`，
                //   所以那边没这个问题。）
                // 位置必须在 `.background` **之前**，否则盖不住。
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.insetFill)
                )
                .inputChrome(focused: pasteFocused, radius: 14)
                // 拖入 .txt → 把**路径文本**还原成**文件正文**。
                //
                // ⚠️ 为什么不用 `.dropDestination`：`TextEditor` 底层是 `NSTextView`，它**自己**注册了
                // 文件拖放，优先级高于 SwiftUI 的 drop 目标。2026-09-22 实测：加了 `dropDestination`
                // 后**完全不触发**（`isTargeted` 也不亮），而输入框里被插进了一行路径
                // （`~/Desktop/1.txt`）—— 说明拖放被 NSTextView 吃掉了。
                //
                // 所以改成"不抢、接住"：监听输入框内容，发现是**一个存在的 txt 路径**就换成正文。
                // 判定从严（单行 + txt/text 扩展名 + 文件真实存在），见 `TextFileReader.loadIfPath`。
                //
                // ⚠️ 不会死循环：替换后的正文带换行，`loadIfPath` 会返回 nil，不再触发。
                .onChange(of: app.imagePasteText) { _, newValue in
                    guard TextFileReader.looksLikeTextFilePath(newValue) else { return }
                    if let content = TextFileReader.loadIfPath(newValue), !content.isEmpty {
                        app.imagePasteText = content
                        dropError = nil
                    } else {
                        // 长得像 txt 路径却读不出来 → 明确提示，别让用户对着一行路径发愣
                        let name = (newValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
                        dropError = "读取失败：\(name)"
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // 底部按钮上方也**不加分割线**（同标题下那条）

            // 说明文字与按钮**同一行**：左说明、右两个按钮（取消紧挨在解析左边）
            HStack(spacing: 8) {
                if let dropError {
                    Text(dropError)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                Button("取消") { onClose() }
                Button("解析") {
                    if let onParse {
                        guard onParse(app.imagePasteText) else { return }
                    } else {
                        app.parseImagePrompts(app.imagePasteText)
                    }
                    app.imagePasteText = ""     // 解析完清空（原来靠 sheet 的 onDisappear）
                    onClose()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(app.imagePasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // 左侧 16 = 与上方输入框左边缘对齐（原来是 12；说明文字挪进这一行后会差 4pt）
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(width: 520, height: 340)
    }
}

/// 单条图片生成条目行（提示词、参数与历史版本入口）
private struct ImageGenItemRow: View, Equatable {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    /// 多选（2026-09-26 用户定：卡片列表也要勾选 + 拖动框选）——勾选框常驻视图树，悬停/选择模式时显示
    var selectionMode: Bool = false
    var isSelected: Bool = false
    /// 是不是**右栏正在看的那条**（点击卡片 → 蓝框标记；2026-09-26 用户定）
    var isCurrent: Bool = false
    var onToggleSelect: () -> Void = {}

    /// ⚠️ `nonisolated`：SwiftUI 的 View 类型是 main-actor 隔离的，`Equatable.==` 是非隔离协议要求
    ///（Swift 6 会报"conformance crosses into main actor"）。只比较 Sendable 的字段即可（同 `CardRowView`）。
    /// 门控的意义（2026-09-27 日志实测）：切样式/切模式时**可见行不再重算**。
    nonisolated static func == (a: ImageGenItemRow, b: ImageGenItemRow) -> Bool {
        a.item == b.item && a.selectionMode == b.selectionMode
            && a.isSelected == b.isSelected && a.isCurrent == b.isCurrent
    }

    /// 本卡是否被鼠标悬停（悬停时露出勾选框）
    @State private var hovered = false

    /// 提交前的校验提示（模型未配 / 没提示词）——**非 nil 就弹 popover**
    ///（2026-09-19 用户要求：没提示词时点「提交生成」也弹提示，别空着发出去）
    @State private var submitHint: String?
    // 「编辑提示词」弹窗的开关已统一到 `AppModel.activeModal`

    init(item: ImageGenItem,
         selectionMode: Bool = false,
         isSelected: Bool = false,
         isCurrent: Bool = false,
         onToggleSelect: @escaping () -> Void = {}) {
        self.item = item
        self.selectionMode = selectionMode
        self.isSelected = isSelected
        self.isCurrent = isCurrent
        self.onToggleSelect = onToggleSelect
    }

    /// 参考图槽位：把提示词里的「图N」渲染成缩略图。
    /// 与分镜卡片做法一致——**卡片上不加素材行**，只在提示词里内联显示，
    /// 这样两张卡片的默认尺寸仍然保持一致（间距 14/10 是对齐过的，加一行就破坏了）。
    private var slotItems: [SlotItem] {
        item.imageRefs.enumerated().map { i, ref in
            let lib = app.libraryItem(ref.libraryItemID)
            return SlotItem(
                token: "图\(i + 1)",
                name: lib?.matchName ?? "图\(i + 1)",
                thumbnailURL: lib?.existingLocalImageURL,
                remoteThumbnailURL: lib?.remoteURL.flatMap { URL(string: $0) }
            )
        }
    }

    /// 参数 chips（模型 / 类型 / 画幅 / 分辨率）—— 抽出来给 `ViewThatFits` 的两个分支共用
    private var imageParamChips: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            IconDropdown(
                icon: "cube",
                labelWidth: 90,
                options: modelOptions,
                selection: modelBinding,
                hasModels: !app.imageModelNames.isEmpty,
                emptyHint: "还没有可用的图片模型。请到「设置 → 模型渠道」添加渠道与图片模型。"
            )
            IconDropdown(
                icon: "tag",
                labelWidth: 48,
                options: typeOptions,
                selection: typeBinding
            )
            IconDropdown(
                icon: "aspectratio",
                labelWidth: 44,
                options: ImageAspect.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                selection: aspectBinding
            )
            IconDropdown(
                icon: "sparkles",
                labelWidth: 32,
                options: ImageQuality.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                selection: qualityBinding
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        let _ = BodyEvalCounter.bump("ImageGenItemRow")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                ReadonlyPromptText(
                    text: item.prompt.isEmpty ? "（无提示词，点此编辑）" : item.prompt,
                    slots: slotItems,
                    isPlaceholder: item.prompt.isEmpty
                )
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
                .drawingGroup()
                // 点卡片 = 选中到右栏（单击，2026-09-26 用户定）
                // ⚠️ 双击走 **NSEvent 监听**（`onTapGesture(count: 2)` 会让单击等双击超时）
                .contentShape(Rectangle())

                // 参数条 + 提交 + 垃圾桶**整行已去掉**（2026-09-26 用户定）——右栏详情面板常驻之后，
                // 这些都在面板里；卡片只管名字/状态/提示词。
                //（`imageParamChips` / `actionButtons` 的定义留着，想恢复就把这一行加回来。）
            }
        }
        .padding(14)
        .materialCard()
        // 选中高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底 + 蓝框（圆角 20 同卡片）
        .overlay {
            if isSelected {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.18))
                    RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
        }
        // 当前查看的蓝框（点击卡片 = 右栏切到它；2026-09-26 用户定，同视频侧缩略图卡片）
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isCurrent ? Theme.accent : Color.clear, lineWidth: 2)
        }
        // 🧪 2026-10-03 性能实验：每卡勾选框已删（每卡控件是滚动卡顿的大头，
        //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边）
        .onHover { hovering in
            // 滚动中冻结悬停（同网格卡片：卡片划过光标反复写状态会让滚动卡）
            guard !app.showLibraryDrawer, !app.showTaskDrawer else {
                if hovered { hovered = false }
                return
            }
            if !hovering { hovered = false; return }
            // 🧪 2026-10-03 实验 B：去掉滚动冻结（勾选框删后 hover 很轻）——滚动中也响应悬停；变卡就回退
            hovered = true
        }
        .onChange(of: app.showLibraryDrawer) { _, isOpen in if isOpen { hovered = false } }
        .onChange(of: app.showTaskDrawer) { _, isOpen in if isOpen { hovered = false } }
    }

    /// 模型下拉：**只列配置里现有的图片模型**（不再有「默认」项，也不塞旧模型名）。
    /// 未选过（`item.model == nil`）时显示第一个图片模型**真名**（见 `modelBinding`）。
    private var modelOptions: [DropdownOption<String>] {
        app.imageModelNames.map { DropdownOption(label: $0, value: $0) }
    }

    /// 模型绑定：`item.model` 为空 = 用配置里第一个图片模型，**界面上显示那个真名**；
    /// ⚠️ 数据仍保持 nil（不要在显示时自动写入），用户选了才写。
    private var modelBinding: Binding<String> {
        Binding(
            get: { item.model.flatMap { $0.isEmpty ? nil : $0 } ?? app.imageModelNames.first ?? "" },
            set: { app.updateImageItemModel(item.id, model: $0) }
        )
    }

    /// 模型与配置对账通过：没配任何图片模型 → 未选；`item.model` 为空 = 用第一个（有效）；
    /// 非空必须在现有图片模型里
    private var isModelConfigured: Bool {
        guard !app.imageModelNames.isEmpty else { return false }
        guard let m = item.model, !m.isEmpty else { return true }
        return app.imageModelNames.contains(m)
    }

    /// 画幅绑定
    private var aspectBinding: Binding<ImageAspect> {
        Binding(
            get: { item.aspectRatio },
            set: { app.updateImageItemAspect(item.id, aspect: $0) }
        )
    }

    /// 分辨率档位绑定
    private var qualityBinding: Binding<ImageQuality> {
        Binding(
            get: { item.quality },
            set: { app.updateImageItemQuality(item.id, quality: $0) }
        )
    }

    /// 类型下拉选项：默认（nil 不挂徽章）+ 角色/场景/道具
    private var typeOptions: [DropdownOption<ImageSubjectType?>] {
        [
            DropdownOption(label: "默认", value: nil),
            DropdownOption(label: "角色", value: .character),
            DropdownOption(label: "场景", value: .scene),
            DropdownOption(label: "道具", value: .prop),
        ]
    }

    /// 类型绑定：默认（nil）→ 不挂徽章，角色/场景/道具 → 挂对应类型
    private var typeBinding: Binding<ImageSubjectType?> {
        Binding(
            get: { item.type },
            set: { app.updateImageItemType(item.id, type: $0) }
        )
    }

    /// 跟生视频卡片一致：参数占用弹性空间，提交和删除紧跟在参数右侧。
    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button {
                generate()
            } label: {
                Group {
                    if item.status.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if item.status == .success {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        Text(item.status == .failed ? "重试" : "提交生成")
                    }
                }
                .frame(minWidth: 40)
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(item.status.isBusy)
            // 校验提示（模型未配 / 没提示词）：点提交先弹提示（不发送）
            .dropdownPopover(isPresented: Binding(
                get: { submitHint != nil },
                set: { if !$0 { submitHint = nil } }
            ), onClose: { submitHint = nil }) {
                Text(submitHint ?? "")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    // 自绘面板能贴内容走：**别写死宽度**（写死的话短提示右边拖一大片空，
                    // 看着像"文字偏了"）。用 maxWidth 兜底，长提示才会换行。
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(12)
            }

            Button {
                AppLog.write("imageGenButton", "请求删除确认 name=\(item.name)")
                app.activeModal = .confirmDeleteImage(itemID: item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .foregroundStyle(.secondary)
        }
        .zIndex(2)
    }

    private func generate() {
        // 模型对账失败（没配图片模型 / 旧模型被删）→ 先提示，不发出去
        guard isModelConfigured else {
            submitHint = app.imageModelNames.isEmpty
                ? "还没有可用的图片模型，请先到设置里添加渠道与图片模型"
                : "请先选择模型"
            return
        }
        // 没提示词也先提示（2026-09-19 用户要求）：空提示词发出去只会失败
        guard !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            submitHint = "请先填写提示词"
            return
        }
        submitHint = nil
        AppLog.write("imageGenButton", "点击生成/重试 name=\(item.name) status=\(item.status.rawValue)")
        app.requestImageGeneration(item.id)
    }
}

/// 🧪 **实验 11（生图侧）**：文字烤图的**唯一口径** —— 格子和"进项目预载"共用，保证缓存键一致。
extension ImageGenItem {
    var thumbStatusTitle: String {
        switch status {
        case .pending: "待生成"
        case .queued: "排队中"
        case .generating: "生成中"
        case .downloading: "下载中"
        case .success: "已完成"
        case .failed: "失败"
        }
    }

    var thumbStatusColorTag: Int {
        switch status {
        case .pending: 0
        case .queued, .generating, .downloading: 1
        case .success: 2
        case .failed: 3
        }
    }

    /// 卡片上的生成参数（模型 · 比例 · 尺寸；模型没选就跳过）
    var thumbParamLabel: String {
        var parts: [String] = []
        if let model, !model.isEmpty { parts.append(model) }
        parts.append(aspectRatio.displayName)
        parts.append(quality.displayName)
        return parts.joined(separator: " · ")
    }

    func thumbTextState(width: CGFloat) -> ThumbTextState {
        ThumbTextState(
            title: name,
            countText: "\(results.count + failures.count) 版",      // 失败的也算一版（2026-10-16，和生视频卡片一样）
            statusTitle: thumbStatusTitle,
            statusColorTag: thumbStatusColorTag,
            paramsText: thumbParamLabel,
            showsParams: paramsDirty || !results.isEmpty,
            paramsDirty: paramsDirty,
            width: width
        )
    }
}

/// 生图图库卡片：图像总览 + 条目状态 + 版本计数；选中后右侧详情跟随。
private struct ImageAssetRow: View, Equatable {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    var displayedResultID: UUID? = nil
    /// 选择模式（有选中项时常驻显示勾选框）；点整行 = 勾选/取消（避免误开详情）
    var selectionMode: Bool = false
    var isSelected: Bool = false
    /// 是不是**右栏正在看的那条**（点击卡片 → 蓝框标记；2026-09-26 用户定，同视频侧缩略图卡片）
    var isCurrent: Bool = false
    /// 🧪 实验 6b：网格层算好的固定格子宽（0 = 还没量到，退回老行为）
    var cellWidth: CGFloat = 0
    var onToggleSelect: () -> Void = {}
    let onOpen: () -> Void

    /// 🧪 实验 4（2026-09-27）：缩略图**初始值就查内存缓存**（照抄 `VideoThumbnailView` 的做法）——
    /// 原来第一帧总是先渲染占位图标、`.task` 里才补图，滚动时表现为"闪一下"。
    /// 缓存命中时现在直接以图起手，中间没有占位帧 ✓
    @MainActor
    init(item: ImageGenItem,
         displayedResultID: UUID? = nil,
         selectionMode: Bool = false,
         isSelected: Bool = false,
         isCurrent: Bool = false,
         cellWidth: CGFloat = 0,
         onToggleSelect: @escaping () -> Void = {},
         onOpen: @escaping () -> Void) {
        self.item = item
        self.displayedResultID = displayedResultID
        self.selectionMode = selectionMode
        self.isSelected = isSelected
        self.isCurrent = isCurrent
        self.cellWidth = cellWidth
        self.onToggleSelect = onToggleSelect
        self.onOpen = onOpen
        let result = item.results.first(where: { $0.id == displayedResultID }) ?? item.latestResult
        _thumbImage = State(initialValue: result?.localPath.flatMap { LocalImageCache.memoryThumb(atPath: $0) })
    }

    /// ⚠️ `nonisolated`：SwiftUI 的 View 类型是 main-actor 隔离的，`Equatable.==` 是非隔离协议要求
    ///（Swift 6 会报"conformance crosses into main actor"）。只比较 Sendable 的字段即可（同 `CardRowView`）。
    /// 门控的意义（2026-09-27 日志实测）：切样式/切模式时**可见格子不再重算**。
    nonisolated static func == (a: ImageAssetRow, b: ImageAssetRow) -> Bool {
        a.item == b.item && a.displayedResultID == b.displayedResultID
            && a.selectionMode == b.selectionMode && a.isSelected == b.isSelected
            && a.isCurrent == b.isCurrent && a.cellWidth == b.cellWidth
    }

    @State private var thumbImage: NSImage?
    @State private var hovered = false

    private var displayedResult: ImageGenResult? {
        item.results.first(where: { $0.id == displayedResultID }) ?? item.latestResult
    }

    /// 🧪 **实验 17（2026-09-27，诊断）**：格子内容逐项加回，定位吃时间的那一项。
    /// `0` = 全内容（正常）· `1` = 只缩略图 · `2` = **只文字**（本次）· `3` = 空壳（秃格子）。
    /// 网格 / 滚动 / 尺寸链全不动。验完改回 `0`。
    private static let cellContentMode = 0  // 🧪 本次：全内容（烤图文字）

    var body: some View {
        // 文字在方形内部（见 `thumbnail` 里贴底的 `ThumbTextRows`）——格子只剩一个方形。
        thumbnail
        // 🧪 实验 6b：整格宽度给死（网格已给固定列宽，这里显式固定，布局引擎不用再协商）
        .frame(width: cellWidth > 0 ? cellWidth : nil, alignment: .leading)
        // 🧪 2026-10-03 性能实验：每卡勾选框已删（每卡控件是滚动卡顿的大头，
        //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边）
        .contentShape(Rectangle())
        .onTapGesture { selectionMode ? onToggleSelect() : onOpen() }
        .onHover { hovering in
            // 滚动中冻结悬停（同主页/任务列表：卡片划过光标反复写状态会让滚动卡）
            // 抽屉打开时底栏区域仍可交互，鼠标追踪也可能落到底层卡片；禁止底卡勾选框
            // 在工具条下方反复显隐，避免玻璃材质每次重采样都闪一下。
            guard !app.showLibraryDrawer, !app.showTaskDrawer else {
                if hovered { hovered = false }
                return
            }
            if !hovering { hovered = false; return }
            // 🧪 2026-10-03 实验 B：去掉滚动冻结（勾选框删后 hover 很轻）——滚动中也响应悬停；变卡就回退
            hovered = true
        }
        .onChange(of: app.showLibraryDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        .onChange(of: app.showTaskDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        // 悬停提示已按用户要求去掉（2026-09-29：原来这里 .help("选择条目并查看详情"/"点击勾选")）
        .task(id: displayedResult?.localPath) {
            // 🧪 实验 17：只文字/空壳时不加载图
            guard Self.cellContentMode != 2 && Self.cellContentMode != 3 else { return }
            guard let path = displayedResult?.localPath else {
                thumbImage = nil
                return
            }
            // 先查内存（纯查表、主线程安全），没有走异步加载 ——
            // ⚠️ 别用 `image(atPath:)`：那是**主线程同步读盘 + 解码**（详情视图一屏几十行一起调会卡，
            // 见 LocalImageCache 里那条注释）。2026-09-19 与卡片侧对齐。
            if let cached = LocalImageCache.memoryThumb(atPath: path) {
                thumbImage = cached
                return
            }
            // 🧪 实验 10 同款（生图侧同步）：async + **取消感知**——格子滚走了，排队中的活儿直接作废
            if let img = await LocalImageCache.loadThumbImage(atPath: path) {
                guard !Task.isCancelled else { return }
                LocalImageCache.storeThumb(img, atPath: path)
                thumbImage = img
            }
        }
        // 🧪 实验 7B：池子复用槽位（视图不重建）——路径一变**立即**换成新缓存图/占位，
        // 不残留上一条的缩略图（`.task(id:)` 要等一拍，不够）。
        .onChange(of: displayedResult?.localPath) { _, newPath in
            thumbImage = newPath.flatMap { LocalImageCache.memoryThumb(atPath: $0) }
        }
    }

    /// ⚠️ **实验 3（2026-09-27 深夜）验证过：结构归一（子视图常驻 + 只切 opacity）在这个网格里
    /// 反而更卡** ✗ —— "视图数固定"的收益抵不过"常驻视图变多"的代价（实测：更卡）。
    /// 已还原成条件分支。别再拿这条去治滚动。
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.insetFill)
            // 🧪 实验 17（诊断）：按 mode 决定格子内容 —— 0 全 / 1 只图 / 2 只文字 / 3 空壳
            if Self.cellContentMode == 3 {
                Color.gray.opacity(0.25)
            } else {
                if Self.cellContentMode != 2 {
                    // 🎯 2026-09-29 用户定（对齐生视频侧）：**生成中不显示旧图** —— 视频侧再生成时
                    // 「当前任务」没有视频帧、格子就是灰底 + 环；生图侧同款：旧结果先藏起来，
                    // 整格交给环形进度（不然环会压在照片上、白字看不清）。
                    if item.status != .generating, let img = thumbImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else if item.status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    } else if item.status != .generating && item.status != .downloading {
                        // 生成中/下载中的转圈**不画在这里**：它在 `.drawingGroup()` 之后的 overlay 里
                        //（AppKit 进度指示器被 Metal 光栅化时会被系统占位图顶替，见 drawingGroup 那里的注释）
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                if Self.cellContentMode != 1 {
                    // 文字**放进方形里**（贴底；颜色跟随界面深 / 浅，没有渐变底衬也没有阴影）——默认走"后台烤图"（`BakedThumbText`）；
                    // 诊断模式 2 用实时 Text 对照。都放在 `drawingGroup()` 之前，方形与文字拍成同一张纹理。
                    if Self.cellContentMode == 2 {
                        ThumbTextRows(state: textState)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    } else {
                        BakedThumbText(state: textState)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        // 🧪 **实验 6b（2026-09-27）**：尺寸**给死**（网格层已算好固定列宽）——不再每格靠
        // maxWidth/aspectRatio 协商（滑动采样里 sizeThatFits 是最大头）。没量到宽度时退回老行为。
        .frame(width: cellWidth > 0 ? cellWidth : nil,
               height: cellWidth > 0 ? cellWidth : nil)
        .frame(maxWidth: cellWidth > 0 ? nil : .infinity)
        .aspectRatio(1, contentMode: .fit)
        // 🧪 **实验 2（2026-09-27 深夜）**：图块**一次栅格化成纹理**再给滚动合成（社区那条
        // "复杂内容 drawingGroup() 明显更快"）。
        // 🎯 2026-09-29 用户定：图块**不再"拍平成纹理"** —— 采样显示主线程大量时间在等 GPU
        // 表面（`SurfacePool::alloc → wait_image_queue`），每格一张离屏纹理正是"每帧向管线
        // 申请 surface"的大户；撤掉后用户实测"手感好一点" ✓ 保留此状态（别再随手加回来）。
        // .drawingGroup()
        // 🎨 2026-09-27 用户定："生图侧不要转圈，没有进度就写 0，样式跟视频侧一样"：
        // 生成中 → 视频侧同款的**环形进度**（生图接口没有百分比 → 传 0）；下载中 → 不摆指示器
        //（底部烤字已经写着"下载中"）。
        // ⚠️ **生成中不显示旧图、整格给环**（2026-09-29 用户定，对齐生视频侧：视频侧再生成时
        // 格子背景变灰 + 环，旧版本画面不会显示）—— 先前的"有旧图就不压环"理解错了，已改回。
        // ⚠️ 依然**不能把指示器放回拍平层**：`ProgressView` 被 `drawingGroup()` 光栅化会被系统
        //「黄方块 + 禁止符」占位图顶替（用户截图 + 最小复现实锤）；`GenerationProgressView` 是
        // SwiftUI 自绘的，放 overlay（实时层）没问题。
        .overlay {
            if item.status == .generating {
                GenerationProgressView(progress: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // 选中高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底 + 蓝框
        .overlay {
            if isSelected {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.18))
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let type = item.type {
                Text(type.displayName)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.88)))
                    .foregroundStyle(Theme.onAccent)
                    .padding(6)
            }
        }
        // 悬停淡灰边框 + **当前查看**的蓝框（2026-09-26 用户："点击卡片高亮，现在只有
        // 视频侧的缩略图卡片能做到"——这里补上；同 `ShotThumbCell` 的规则）
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Theme.accent
                              : (hovered ? Color.secondary.opacity(0.45) : Color.clear),
                              lineWidth: isCurrent ? 2 : 1)
        }
    }

    private var statusTitle: String { item.thumbStatusTitle }

    private var statusColorTag: Int { item.thumbStatusColorTag }

    /// 🧪 实验 11：文字行烤图的状态键（**与预载共用同一口径** `ImageGenItem.thumbTextState`）
    private var textState: ThumbTextState {
        item.thumbTextState(width: cellWidth > 0 ? cellWidth : 264)   // 宽度没量到时给个保守值
    }

    private var statusColor: Color {
        switch item.status {
        case .pending: .secondary
        case .queued: Theme.warning
        case .generating, .downloading: Theme.accent
        case .success: Theme.success
        case .failed: Theme.danger
        }
    }

    /// 卡片上的生成参数（模型 · 比例 · 尺寸；模型没选就跳过）——🧪 实验 11 起走共用口径
    private var paramLabel: String { item.thumbParamLabel }
}

private struct ImageThumbCellView: View {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    let onPreview: () -> Void
    let onShowInCards: () -> Void

    @State private var thumbImage: NSImage?
    @State private var hovered = false

    private var isPreviewing: Bool { app.previewingImageItemID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            Text(item.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        // ⚠️ 双击必须写在单击**前面**（SwiftUI 按声明顺序定优先级）
        .onTapGesture(count: 2) { onShowInCards() }   // 双击回卡片模式（恢复原样；编辑弹窗改走 NSEvent 监听）
        .onTapGesture { onPreview() }
        .onHover { hovering in
            // 滚动中冻结悬停状态：滚动经过鼠标下方的网格卡片时，AppKit 会连续发 hover，
            // 每次写 @State 都会让卡片重新绘制（和素材库行的处理保持一致）。
            // 抽屉打开时同样停掉底层卡片悬停，避免工具条下方的内容变化触发玻璃材质闪烁。
            guard !app.showLibraryDrawer, !app.showTaskDrawer else {
                if hovered { hovered = false }
                return
            }
            if !hovering { hovered = false; return }
            guard !ScrollActivity.shared.isScrolling else { return }
            if hovered != hovering { hovered = hovering }
        }
        .onChange(of: app.showLibraryDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        .onChange(of: app.showTaskDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        .help("单击预览 · 双击回到卡片编辑")
        // 缩略图异步加载：先查内存，没了从原图降采样（同卡片里的做法）
        .task(id: item.latestResult?.localPath) {
            guard item.status == .success, let path = item.latestResult?.localPath else {
                thumbImage = nil
                return
            }
            if let cached = LocalImageCache.memoryThumb(atPath: path) {
                thumbImage = cached
                return
            }
            LocalImageCache.loadThumbnail(atPath: path) { img in
                thumbImage = img
            }
        }
    }

    private var thumbnail: some View {
        // 同生视频侧 `ThumbnailCellView`：`Color.clear` 撑 16:9（网格列宽由 LazyVGrid 决定）
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { thumbnailContent }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { versionBadge }
            .overlay(alignment: .bottomLeading) { typeBadge }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(borderColor, lineWidth: isPreviewing ? 2 : 1)
            }
    }

    private var borderColor: Color {
        if isPreviewing { return Theme.accent }
        return hovered ? Color.secondary.opacity(0.45) : .clear
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if item.status == .success, let ns = thumbImage {
            Image(nsImage: ns)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle()
                .fill(.insetFill)
                .overlay {
                    if item.status.isBusy {
                        ProgressView().controlSize(.small)
                    } else if item.status == .failed {
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title3)
                                .foregroundStyle(Theme.warning)
                            Text("生成失败")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
        }
    }

    @ViewBuilder
    private var versionBadge: some View {
        if item.results.count + item.failures.count > 1 {
            Text("共 \(item.results.count + item.failures.count) 版")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent))
                .foregroundStyle(Theme.onAccent)
                .padding(4)
        }
    }

    @ViewBuilder
    private var typeBadge: some View {
        if let type = item.type {
            Text(type.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent.opacity(0.85)))
                .foregroundStyle(Theme.onAccent)
                .padding(5)
        }
    }
}

/// 生图条目的提示词编辑弹窗：与分镜的 `EditPromptSheet` 同款交互
/// （卡片上只读展示 + 点开弹窗编辑）。
///
/// **素材区 = 参考图**：挂上的图在生成时走 `/v1/images/edits`（multipart）传给模型，**按数组顺序**即「图1/图2…」。
/// 与分镜弹窗的两处刻意差异：**没有「自动匹配」**（生图提示词是短句手写的，按素材名匹配命中率低）、
/// **没有角色徽章**（首帧/尾帧是视频模型的语义，生图没有这个概念）。
/// 编辑图片提示词。**不再是 private**：改成应用内浮层后由 `RootView` 呈现，跨文件可见。
struct EditImagePromptSheet: View {
    @State private var promptFocused = false
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    /// 关闭回调（原来是 `@Environment(\.dismiss)`，改成应用内浮层后没有 presentation 上下文）
    var onClose: () -> Void
    var onSave: ((String) -> Bool)?
    var showsMaterialSection: Bool
    @State private var editPrompt: String
    /// 打开时的条目备份：素材区、参数的操作是**实时写数据层**的（便于即时看到效果），没提交就关掉时用它回滚（只回滚这几样，见 `rollbackImageItemEdits`）
    @State private var backup: ImageGenItem?
    /// 已经提交 / 保存了：关闭时不再回滚
    @State private var finished = false
    @State private var showSubmitHint = false
    @State private var submitHint = ""

    // ⚠️ 自定义 init 必须显式接收并赋值 `onClose`（成员初始化器被它取代了）
    init(item: ImageGenItem, onClose: @escaping () -> Void,
         onSave: ((String) -> Bool)? = nil, showsMaterialSection: Bool = true) {
        self.item = item
        self.onClose = onClose
        self.onSave = onSave
        self.showsMaterialSection = showsMaterialSection
        _editPrompt = State(initialValue: item.prompt)
    }

    /// 数据层里的**实时**条目。弹窗持有的 `item` 是打开时的快照，
    /// 增删参考图后快照不更新 → chip 缩略图和槽位都会显示旧内容（关掉重开才对）。
    private var liveItem: ImageGenItem { app.imageItems.first(where: { $0.id == item.id }) ?? item }

    /// 参考图槽位（编辑器 @ 弹窗、提示词里「图N」的缩略图共用）
    private var slotItems: [SlotItem] {
        liveItem.imageRefs.enumerated().map { i, ref in
            let lib = app.libraryItem(ref.libraryItemID)
            return SlotItem(
                token: "图\(i + 1)",
                name: lib?.matchName ?? "图\(i + 1)",
                thumbnailURL: lib?.existingLocalImageURL,
                remoteThumbnailURL: lib?.remoteURL.flatMap { URL(string: $0) }
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑提示词")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 12`：分割线拿走后面向内容那侧收掉
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 素材区（参考图）：与分镜弹窗同款外观，但无「自动匹配」、无角色徽章（理由见类型注释）
            if showsMaterialSection {
            MaterialSection(
                imageRefs: liveItem.imageRefs,
                showsAutoMatch: false,
                emptyHint: "从素材库添加参考图，提示词用 @ 引用（生成时按顺序传给模型）",
                // 同分镜：打开素材库抽屉并带上宿主
                onAdd: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        app.toggleLibraryDrawer(target: .imageItem(item.id))
                    }
                },
                onRemove: { refID, prefix, index in
                    app.removeImageItemMaterial(itemID: item.id, refID: refID)
                    editPrompt = AppModel.removeTokenAndRenumber(editPrompt, prefix: prefix, removedIndex: index)
                },
                onClear: {
                    app.clearImageItemMaterials(itemID: item.id)
                    editPrompt = AppModel.stripAllTokens(editPrompt)
                },
                onDrop: { app.addImageItemMaterial(itemID: item.id, libraryItemID: $0) }
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            }

            PromptEditor(
                text: $editPrompt,
                slots: slotItems,
                isEditable: true,
                scrollable: true,               // 固定高度 + 内部滚动（弹窗是独立浮层，不影响列表性能）
                clickToEdit: true,              // 平时只读（箭头），点一下才编辑——和剧本页的框一样
                onFocusChange: { promptFocused = $0 }
                // 在提示词里删掉内嵌缩略图：只删字，素材区不动（2026-10-16 用户定：提示词里删素材不删素材区的；素材区删了才清提示词）
            )
            // 2026-09-29 用户：提示词框**顶上去**（260 → 340）+ 去掉上面那条横线
            .frame(height: 340)
            .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
            .inputChrome(focused: promptFocused, radius: 14)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            // 原 `.padding(16)`：下侧朝向被删的那条线，收掉
            .padding(.bottom, 6)

            if let onSave {
                // 旧页面（剧本里的素材编辑）自己管保存：保留原来的「取消 / 保存」
                HStack {
                    Spacer()
                    Button("取消") {
                        finished = true
                        if let backup { app.rollbackImageItemEdits(to: backup) }
                        onClose()
                    }
                    Button("保存") {
                        guard onSave(editPrompt) else { return }
                        finished = true
                        onClose()
                    }
                    .buttonStyle(AccentButtonStyle())
                    .tint(Theme.accent)
                }
                .padding(12)
            } else {
                // 生图页的编辑提示词（2026-10-10 用户定）：下面一行就是生成参数 + 提交生成。
                // 点外面 / Esc 关掉 = 取消（提示词、参考图、参数都回到打开时的样子）；提交生成 = 保存 + 提交。
                HStack(spacing: 10) {
                    ImageParamControls(item: liveItem, compact: false)
                    Spacer(minLength: 8)
                    Button { submit() } label: { Text("提交生成").lineLimit(1).fixedSize() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(liveItem.status.isBusy)
                        .help("保存提示词和参数，并提交生成（⌘↩）")
                        .dropdownPopover(isPresented: $showSubmitHint) {
                            Label(submitHint, systemImage: "exclamationmark.triangle.fill").font(.caption).padding(12)
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                // ⌘S：只保存、不生成（生成要花钱）。没有按钮，只有快捷键
                .background {
                    Button("") { saveWithoutSubmitting() }
                        .keyboardShortcut("s", modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
                }
            }
        }
        // **只固定宽度**（同 EditPromptSheet）：里面的 `PromptEditor` 已写死 `.frame(height: 260)`，
        // 内容高度固定，外层钉死 420 只会多出空白。
        .frame(width: 620)
        .onAppear {
            // 打开时备份条目（提示词、参考图、参数），没提交就关掉时回滚
            backup = app.imageItems.first { $0.id == item.id }
        }
        // 没提交 / 没保存就关掉（点外面、Esc、旧页面的取消）：撤销弹窗期间改的
        .onDisappear {
            if !finished, let backup { app.rollbackImageItemEdits(to: backup) }
        }
    }

    /// 提交生成 = 保存 + 提交。检查项和工具条里的「提交生成」一样；不满足就只提示、什么都不写、弹窗不关
    private func submit() {
        let current = liveItem
        if app.imageModelNames.isEmpty { return hint("请先到设置里添加图片模型") }
        if let model = current.model, !model.isEmpty, !app.imageModelNames.contains(model) { return hint("请先重新选择当前可用的图片模型") }
        if editPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return hint("请先填写提示词") }
        app.updateImageItemPrompt(item.id, prompt: editPrompt)
        finished = true
        app.applyImageResult(item.id, resultID: nil)          // 重新生成后自动回到最新结果
        app.requestImageGeneration(item.id)
        onClose()
    }

    private func hint(_ text: String) {
        submitHint = text
        showSubmitHint = true
    }

    private func saveWithoutSubmitting() {
        app.updateImageItemPrompt(item.id, prompt: editPrompt)
        finished = true
        onClose()
    }
}

/// 缩略图工作区右侧详情：选中图库条目后，就地查看结果、提示词、参数、参考图和版本。
/// ⚠️ 2026-09-27：它挂在 **RootView 的共享右侧栏**里（四页共用、切换不拆建），所以不再是 private。

// 🆕 2026-10-03（用户定）：生图侧"点击看大图"——延迟 0.25s 触发，
// 双击（开编辑弹窗）会把这它取消，避免"双击第一下先弹出大图"
final class ImagePreviewOnTap: @unchecked Sendable {
    static let shared = ImagePreviewOnTap()
    private var work: DispatchWorkItem?

    func schedule(_ action: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: action)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    func cancelPending() {
        work?.cancel()
        work = nil
    }
}

struct ImageItemInspector: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let item: ImageGenItem
    @Binding var selectedResultID: UUID?
    @Binding var historyScrollAnchorID: UUID?

    private var selectedResult: ImageGenResult? {
        item.results.first(where: { $0.id == selectedResultID }) ?? item.latestResult
    }

    /// 历史版本里高亮哪一项：在看失败的那一版就是它，否则是显示的那张图
    private func isPicked(_ entry: ImageVersionEntry) -> Bool {
        if let failureID = item.viewingFailureID { return entry.id == failureID }
        return entry.result != nil && entry.id == selectedResult?.id
    }

    private var isViewingOlderVersion: Bool {
        guard let selectedResult, let latestResult = item.latestResult else { return false }
        return selectedResult.id != latestResult.id
    }

    private var slots: [SlotItem] {
        item.imageRefs.enumerated().map { index, ref in
            let asset = app.libraryItem(ref.libraryItemID)
            return SlotItem(
                token: "图\(index + 1)",
                name: asset?.matchName ?? "图\(index + 1)",
                thumbnailURL: asset?.existingLocalImageURL,
                remoteThumbnailURL: asset?.remoteURL.flatMap(URL.init(string:))
            )
        }
    }

    private var statusTitle: String {
        switch item.status {
        case .pending: "待生成"
        case .queued: "排队中"
        case .generating: "生成中"
        case .downloading: "下载中"
        case .success: "已完成"
        case .failed: "失败"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .pending: .secondary
        case .queued: Theme.warning
        case .generating, .downloading: Theme.accent
        case .success: Theme.success
        case .failed: Theme.danger
        }
    }

    /// B 款视觉：分节小标题（轻量、次要色；纯视觉）
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// 点预览：看大图（没有图就什么都不做）
    private func openBigPreview() {
        guard let result = selectedResult, result.localPath != nil else { return }
        app.previewingImageResultID = result.id
        app.previewingImageItemID = item.id
    }

    /// 这一版的参数小标签
    private var paramChips: [String] {
        let result = selectedResult
        // 在看失败的那一版：写那一次的设置和时间
        let failure = item.viewingFailure
        var chips: [String] = []
        if let model = (failure?.model ?? result?.model).flatMap({ $0.isEmpty ? nil : $0 }) ?? item.model.flatMap({ $0.isEmpty ? nil : $0 }) ?? app.imageModelNames.first {
            chips.append(model)
        }
        chips.append((failure?.aspectRatio ?? result?.aspectRatio ?? item.aspectRatio).displayName)
        chips.append((failure?.quality ?? result?.quality ?? item.quality).displayName)
        if let created = failure?.createdAt ?? result?.createdAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            chips.append(formatter.string(from: created))
        }
        return chips
    }

    var body: some View {
        let _ = BodyEvalCounter.bump("ImageItemInspector")
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 🆕 2026-10-05（B 款视觉）：名称/状态标题行回归（纯视觉，行为不变；觉得多余可撤）
                    headerOverlay
                        .padding(.bottom, 2)

                    // 当前这一版的大图（2026-10-10：右栏原来提示词下面整片空白）。点一下看大图
                    resultPreview
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                        .hoverHighlight(radius: 14, clickable: selectedResult?.localPath != nil)
                        .onTapGesture { openBigPreview() }
                        .help(selectedResult?.localPath == nil ? "" : "点一下看大图")

                    // 「入库 / 在访达」按钮**已挪到预览弹窗底部**（2026-09-26 用户要求）——
                    // 点图看大图后，弹窗右栏底部那排（保存到素材库 / 在访达中显示）负责这两件事，
                    // 面板里不再重复。别加回来。

                    // 历史版本（2026-09-26：**0 版也显示**占位，与视频侧统一）
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("历史版本（\(item.versionEntries.count)）")
                        if item.versionEntries.isEmpty {
                            // 空态占位：**和真版本卡同尺寸同结构**（实测真卡 = 82×71pt：
                            // 小图区 72×44 + 内距 5 + 间距 4 + 「第 1 版」标签行）——2026-09-26 用户定：
                            // 尺寸固定=跟真卡一样，不能是另一个形状。
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.insetFill)
                                    .frame(width: 72, height: 44)
                                    .overlay {
                                        Text("暂无任务")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                Text("第 1 版")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal) {
                                    HStack(spacing: 8) {
                                        // 最新的在前，失败的那几次也是一版（2026-10-16 和生视频统一）
                                        ForEach(item.versionEntries.reversed()) { entry in
                                            let picked = isPicked(entry)
                                            Button {
                                                if let failure = entry.failure {
                                                    app.applyImageFailure(item.id, failureID: failure.id)
                                                } else {
                                                    selectedResultID = entry.id
                                                }
                                            } label: {
                                                VStack(spacing: 4) {
                                                    if let path = entry.result?.localPath {
                                                        AsyncThumbImage(path: path)
                                                            .frame(width: 72, height: 44)
                                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                                    } else {
                                                        RoundedRectangle(cornerRadius: 6)
                                                            .fill(.insetFill)
                                                            .frame(width: 72, height: 44)
                                                            .overlay {
                                                                if entry.failure != nil {
                                                                    Image(systemName: "xmark.circle").foregroundStyle(Theme.danger)
                                                                }
                                                            }
                                                    }
                                                    HStack(spacing: 3) {
                                                        Text("第 \(entry.number) 版")
                                                        if entry.failure != nil { Text("失败").foregroundStyle(Theme.danger) }
                                                    }
                                                    .font(.caption2)
                                                }
                                                .padding(5)
                                                .background(RoundedRectangle(cornerRadius: 8).fill(
                                                    picked ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.06)
                                                ))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .strokeBorder(picked ? Theme.accent : .clear, lineWidth: 1.5)
                                                }
                                            }
                                            .buttonStyle(QuietButtonStyle())
                                            .help(entry.failure.map { "失败：\($0.error)（点一下换回这一次的提示词和参数，改好再生成）" } ?? "")
                                            .id(entry.id)
                                        }
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .scrollPosition(id: $historyScrollAnchorID, anchor: .leading)
                                .onAppear {
                                    // 第一次打开时定位到当前版本；后续模式切换使用父视图保存的可视锚点。
                                    guard historyScrollAnchorID == nil,
                                          let id = item.viewingFailureID ?? selectedResult?.id ?? item.latestResult?.id else { return }
                                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .leading) }
                                }
                                .onChange(of: item.versionEntries.map(\.id)) { _, ids in
                                    // 最新的在最前：生成完成（或失败）后回到最前面
                                    guard let id = ids.last else { return }
                                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .leading) }
                                }
                            }
                        }
                        // 看的是旧版本时的提示（原来在右栏底部的「生成参数」块里；参数搬进工具条后跟着历史版本走）
                        if isViewingOlderVersion, item.viewingFailureID == nil, let result = selectedResult, result.model == nil {
                            Text("此旧版本没有保存生成参数；应用时保留当前参数。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isViewingOlderVersion, item.viewingFailureID == nil, selectedResult?.imageRefs == nil {
                            Text("此旧版本没有保存参考图记录；当前参考图未更改。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 这一版的参数：模型 · 比例 · 质量 · 生成时间（旧版本没有保存的就用卡片现在的）
                    InspectorChips(items: paramChips)

                    // 哪些分段用到了这张卡 + 有没有入库（2026-10-11 用户：放上面。提示词可以很长，原来放在它下面要滚到底才看得到）
                    CardUsageSection(card: item, resultID: selectedResult?.localPath == nil ? nil : selectedResult?.id)

                    // 阶段 / 起始集（名字只放基础名，这两样不进提示词）
                    CardVersionSection(card: item)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("提示词")
                        if isViewingOlderVersion, selectedResult?.prompt == nil {
                            Text("此旧版本没有保存提示词快照；当前编辑器保留条目现有提示词。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ReadonlyPromptText(
                            text: item.prompt.isEmpty ? "（无提示词，点此编辑）" : item.prompt,
                            slots: selectedResult?.imageRefs != nil || selectedResult?.id == item.latestResult?.id || selectedResult == nil ? slots : [],
                            isPlaceholder: item.prompt.isEmpty
                        )
                        // 随提示词内容自然增高；超出右栏的部分由外层详情 ScrollView 滚动。
                        // ⚠️ 空着时也要有**最小高度**（2026-09-29 用户："空的时候提示词框高度太少"）
                        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.insetFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .contentShape(Rectangle())
                    .hoverHighlight(radius: 10)
                    .onTapGesture {
                        app.activeModal = .editImagePrompt(itemID: item.id)
                    }
                    .help("点击编辑当前已应用版本的提示词")

                    // 生成设置 + 提交生成已挪到**面板底部固定组件**（2026-09-26 用户定）：不参与滚动；
                    // 标题「生成设置」字样也去掉了。
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            // 底部留出工具条的高度：工具条整窗居中，会盖住右栏下半部分，长提示词要能滚到它上面
            .contentMargins(.bottom, ToolbarRowLayout.clearance, for: .scrollContent)
        }
        .frame(maxHeight: .infinity)
    }

    /// 名称 / 状态 / 第 N 版（叠在方形预览顶部；2026-09-26 从独立一行挪进来，方形上移）
    private var headerOverlay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.displayName).font(.title3.weight(.semibold)).lineLimit(1)
            Text(statusTitle)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(statusColor.opacity(0.14)))
                .foregroundStyle(statusColor)
            Spacer(minLength: 4)
            if let id = item.viewingFailureID ?? selectedResult?.id, let number = item.versionNumber(of: id) {
                Text("第 \(number) 版")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // ⚠️ 别挡点图看大图
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var resultPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.insetFill)
            // 🎯 2026-09-29 用户定（对齐生视频侧详情）：**再生成时不显示上一版** ——
            // 视频侧详情同款：当前版本还没有视频帧时，预览就是灰底 + 环（旧画面不显示）。
            if item.status == .generating {
                GenerationProgressView(progress: 0)
            } else if let failure = item.viewingFailure {
                // 点了历史版本里失败的那一版：写这一次的失败原因（2026-10-16）
                VStack(spacing: 6) {
                    Image(systemName: "xmark.circle").font(.title2).foregroundStyle(Theme.danger)
                    Text("这一版生成失败").font(.caption).foregroundStyle(.secondary)
                    Text(Formatters.errorSummary(failure.error))
                        .font(.caption2).foregroundStyle(Theme.danger.opacity(0.9))
                        .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 10)
                        .help(failure.error)
                    Text("提示词和参数已换回这一次的，改好再生成").font(.caption2).foregroundStyle(.secondary)
                }
            } else if let path = selectedResult?.localPath {
                // 预览框内使用 .fit：保留整张图，不裁掉横图或竖图边缘。
                // 用缩略图缓存（640 像素）、不解码原图：右栏常驻，点一张卡就换一张，4K 原图每次解码太重（要看清点一下看大图）
                AsyncThumbImage(path: path, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 下载中 = 不转圈、只给文案；失败 = 红叉 + 原因摘要；空闲 = photo + "暂无图片"。
                VStack(spacing: 6) {
                    if item.status == .downloading {
                        Text("正在下载图片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if item.status == .failed {
                        // 生视频侧失败态同款：红叉 + "生成失败" + 失败原因摘要（悬停看全文）
                        Image(systemName: "xmark.circle").font(.title2).foregroundStyle(Theme.danger)
                        Text("生成失败").font(.caption).foregroundStyle(.secondary)
                        if let raw = item.errorMessage, !raw.isEmpty {
                            Text(Formatters.errorSummary(raw))
                                .font(.caption2)
                                .foregroundStyle(Theme.danger.opacity(0.9))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .help(raw)
                        }
                    } else if item.status == .queued, let waiting = item.errorMessage, !waiting.isEmpty {
                        // 变化版同时提交、在等基础版入库一版定妆图（2026-10-11）：写出在等什么
                        Image(systemName: "hourglass").font(.title2).foregroundStyle(Theme.warning)
                        Text("排队中").font(.caption).foregroundStyle(.secondary)
                        Text(waiting).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 10)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                        Text("暂无图片").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(InspectorPreview.ratio(selectedResult?.aspectRatio ?? item.aspectRatio), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // ⚠️ 生成中的呼吸光晕**已去掉**（2026-09-27 用户："太卡了"）——连续动画挂在常驻面板上开销大。
        //    状态反馈继续走转圈 / 状态徽章；想再加请用**非连续**效果（比如一次性闪一下）。
    }
}

/// 生图预览弹窗（RootView overlay 按窗口比例渲染）：左大图 + 右版本列表/保存/访达
// 🆕 2026-10-03（用户定）：右栏去掉提示词与历史版本（按钮靠 Spacer 钉底；原来「版本列表撑满」的定形方式作废）
struct ImagePreviewSheet: View {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem

    /// 实时的卡片（`item` 是打开时的快照；在右边版本列里换了版本要跟得上）
    private var live: ImageGenItem { app.imageItems.first(where: { $0.id == item.id }) ?? item }

    var body: some View {
        // 🆕 2026-10-03（用户定）：**去掉右侧那一列**——大图占满整宽；
        //   名称/版本 + 底部按钮改做浮层（原来提示词/历史版本已删，右栏只剩空白）
        ZStack(alignment: .topLeading) {
            Group {
                if let failure = live.viewingFailure {
                    // 版本列里点了失败的那一版（2026-10-16）：写失败原因，提示词和参数已换回那一次的
                    VStack(spacing: 8) {
                        Image(systemName: "xmark.circle").font(.title).foregroundStyle(Theme.danger)
                        Text("这一版生成失败").foregroundStyle(.secondary)
                        Text(Formatters.errorSummary(failure.error)).font(.caption).foregroundStyle(Theme.danger.opacity(0.9))
                            .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 40).help(failure.error)
                        Text("提示词和参数已换回这一次的，改好再生成").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let path = selectedResult?.localPath {
                    AsyncFullImage(path: path)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if live.results.isEmpty {
                    Color.clear.overlay {
                        Text(live.status == .failed ? "生成失败"
                             : live.status == .generating ? "生成中…" : "暂无图片")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear.overlay {
                        Text("图片加载失败")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 左上浮层：名称 · 第 N 版
            HStack(spacing: 6) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let id = live.viewingFailureID ?? selectedResult?.id, let number = live.versionNumber(of: id) {
                    Text("第 \(number) 版")
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)

            // 右下浮层：操作按钮（悬浮胶囊，同工具条口径）
            HStack(spacing: 8) {
                if item.type != nil, selectedResult != nil, live.viewingFailureID == nil {
                    let saved = app.isImageResultSaved(app.previewingImageResultID ?? item.latestResult?.id)
                    Button(saved ? "已入库" : "保存到素材库") {
                        _ = app.saveImageItemToLibrary(item.id, resultID: app.previewingImageResultID)
                        app.previewingImageItemID = nil
                    }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(saved)
                }
                if let path = selectedResult?.localPath, FileManager.default.fileExists(atPath: path) {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            }
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onExitCommand {
            if let close = app.previewCloseRequest {
                close()
            } else {
                app.previewingImageItemID = nil
            }
        }
    }

    /// 当前选中版本（默认最新）
    private var selectedResult: ImageGenResult? {
        live.results.first(where: { $0.id == app.previewingImageResultID }) ?? live.latestResult
    }

    /// 提示词文本（空时给占位文案，与分镜预览一致）
    /// 提示词：**取选中版本的**（版本级提示词，2026-09-19 用户要求，与生视频侧一致）。
    /// 当前版本缺少旧数据快照时回退到条目提示词；老历史版本无快照时显示缺失提示。
    private var promptText: String {
        if let p = selectedResult?.prompt, !p.isEmpty { return p }
        if selectedResult == nil || selectedResult?.id == item.latestResult?.id {
            return item.prompt.isEmpty ? "（无提示词）" : item.prompt
        }
        return "（该版本未记录提示词）"
    }

    /// 参考图槽位：把提示词里的「图N」渲染成缩略图（与生图卡片同一套规则）。
    /// 取**实时**数据：弹窗持有的 `item` 是打开时的快照，素材变动后用它会导致缩略图陈旧。
    private var slotItems: [SlotItem] {
        let live = app.imageItems.first(where: { $0.id == item.id }) ?? item
        return live.imageRefs.enumerated().map { i, ref in
            let lib = app.libraryItem(ref.libraryItemID)
            return SlotItem(
                token: "图\(i + 1)",
                name: lib?.matchName ?? "图\(i + 1)",
                thumbnailURL: lib?.existingLocalImageURL,
                remoteThumbnailURL: lib?.remoteURL.flatMap { URL(string: $0) }
            )
        }
    }

}
