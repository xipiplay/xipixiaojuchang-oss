import SwiftUI
import Observation
import AppKit
@preconcurrency import AVFoundation   // 放宽 AVAssetImageGenerator 的 Sendable 检查（异步 image(at:) 官方允许并发用）
import AVKit
import Combine

/// 🧪 **诊断探针（2026-09-27，临时）**：卡片列表「跳转回写」探针。
///
/// **行为不变**：只记录 `.scrollPosition` binding 收到的回写 —— 每笔的
/// `isPositionedByUser` / `viewID` / `y`，外加最近一次滚动几何（内容估算高 / 视口高）。
/// 用来判断「新增分镜 → 下发跳到新卡」之后：
///   ① 是否有一笔系统回写（`user=false`）把刚下发的定位请求覆盖掉；
///   ② 这一跳最终落在哪（配合 `[shotJump]` 收尾日志里的 after/content/目标 frame）。
/// 普通 class：写它不触发任何 SwiftUI 重算（同 `MarqueeFrameStore` 的思路）。
final class ScrollJumpWriteProbe {
    /// 采集窗口是否打开（只在一次跳转后的几秒内为 true）
    var armed = false
    /// 采集到的回写（相邻去重 + 条数封顶，防止用户滚动时刷屏）
    var writes: [String] = []
    /// 最近一次 `onScrollGeometryChange` 报的内容估算高 / 视口高
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    func arm() {
        armed = true
        writes.removeAll()
    }

    /// 记录一笔回写（窗口外什么都不做）
    func record(_ value: ScrollPosition) {
        guard armed, writes.count < 12 else { return }
        let id = value.viewID(type: UUID.self).map { String($0.uuidString.prefix(8)) } ?? "nil"
        let y = value.y.map { String(Int($0)) } ?? "nil"
        let line = "user=\(value.isPositionedByUser) id=\(id) y=\(y)"
        if writes.last != line { writes.append(line) }
    }
}

/// 中间列：可滚动的分镜卡片列表，每卡片独立编辑提交，卡片之间「增加分镜」；底部固定批量工具条
struct GenerateView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.mediaWorkspaceContext) private var mediaContext
    @State private var shotInput = MediaWorkspaceInput<[ShotDraft]>()

    private var displayedShots: [ShotDraft] {
        shotInput.value(active: mediaContext?.isActive(.video) ?? true) { app.currentShots }
    }

    /// 用 `@State` 保存的"导入确认"中间态（`handleScriptImport` 产出，见文件末尾的 alert）。
    /// ⚠️ 工具条按钮的「导入分镜」已改成 `AppModalKind.batchParseShots` 浮层，
    /// 这条只服务于**把 txt 直接拖到分镜列表**那条入口。
    @State private var pendingScriptShots: [String] = []
    @State private var showImportConfirm = false
    // （批量提交的目标/确认状态已搬到 RootView 的共享底栏，2026-09-27）
    // （批量提交的确认 / 校验都搬到 RootView 的共享底栏，2026-09-27）
    // 「批量设置参数」的开关已移到 `AppModel.activeModal`
    // （改成应用内浮层后必须由 RootView 呈现，才能盖住整窗）
    @State private var infoTitle = ""
    @State private var infoMessage = ""
    @State private var showInfo = false
    /// **恢复滚动位置**的目标。只在"要恢复"那一下写一次（见 onAppear），
    /// 逐帧记录走 `.onScrollGeometryChange` + 非观察缓存 ✓
    @State private var restorePosition = ScrollPosition(idType: Never.self)

    /// 🧪 诊断探针（2026-09-27，临时）：跳转回写采集器 —— 行为不变，见 `ScrollJumpWriteProbe` 的说明。
    @State private var scrollJumpProbe = ScrollJumpWriteProbe()

    /// 缩略图页（网格 + 详情面板，2026-09-26）：
    /// ⚠️ 面板播放器的 `inspectorPlaying` 已随右栏搬到 RootView（2026-09-27）
    /// 缩略图页网格的滚动位置恢复（同生图侧：只认 saved 快照；逐帧记录走非观察缓存）
    @State private var restoreShotThumbPosition = ScrollPosition(idType: Never.self)
    @State private var shouldRestoreShotThumbOffset = true

    /// 缩略图页顶部：状态筛选（2026-09-26 与生图侧统一：点一下筛、再点取消）+ 名称搜索
    @State private var shotThumbStatusFilter: ShotThumbStatusFilter = .all
    /// 「按范围选」的小框（2026-10-27）
    @State private var showShotRange = false
    @State private var shotThumbSearchText = ""
    /// 缩略图网格可用宽度（只跟窗口尺寸变）——🧪 **实验 6b（2026-09-27）**：算固定列宽用。
    @State private var shotThumbGridWidth: CGFloat = 0
    /// 🧪 **实验 7B（2026-09-27）**：视口高度（只跟窗口变）——算"可见几行"用。
    @State private var shotThumbViewportHeight: CGFloat = 0
    /// 🧪 实验 7B：单格内容实测高度（池里的格子回填一次；所有格同高）
    @State private var shotThumbCellHeight: CGFloat = 0
    /// 🧪 实验 7B：窗口起始行 —— **只有跨行才更新**；其余滚动帧 SwiftUI 什么都不做
    @State private var shotThumbWindowStartRow = 0

    /// 🧪 实验 7B：总开关（true = 固定池+窗口；false = LazyVGrid 老实现，方便 A/B）
    /// ⚠️ 2026-09-27 用户定：**先关掉**（视频侧"更卡了"，先回老网格）——代码留着，随时可切回。
    private static let usePooledShotGrid = false
    /// 🧪 实验 7B：行距（= 6b 时代 LazyVGrid spacing，视觉必须一致）
    private static let shotThumbGridSpacing: CGFloat = 12
    /// 🧪 实验 7B：格内容高实测前的估值（名字行+状态行 ≈45pt，实测后立即校正）
    private static let shotThumbCellTextEstimate: CGFloat = 45

    /// 🧪 实验 6b/7B：列数与格宽（与旧 `.adaptive(210...320)` 同口径：最小 210 / 最大 320 /
    /// 间距 12；留白同下方的 padding：左 16 · 右 4）。宽度还没量到时返回 (0, 0)。
    private var shotThumbGridSpec: (cols: Int, cellW: CGFloat) {
        let spacing: CGFloat = Self.shotThumbGridSpacing
        let available = shotThumbGridWidth - 16 - 4
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
    private var shotThumbGridLayout: (columns: [GridItem], cellWidth: CGFloat) {
        ([GridItem(.adaptive(minimum: 210, maximum: 320), spacing: Self.shotThumbGridSpacing)],
         shotThumbGridSpec.cellW)
    }

    // MARK: 🧪 实验 7B：固定池 + 窗口（视频侧）——滚动成本与素材总量无关

    private struct ShotPoolMetrics {
        var cols = 1
        var cellW: CGFloat = 0
        var cellH: CGFloat = 0
        var rowPitch: CGFloat = 0
        var totalRows = 0
        var windowRows = 0
        var slotCount = 0
        var spacerHeight: CGFloat = 0
    }

    private var shotThumbPoolMetrics: ShotPoolMetrics {
        var m = ShotPoolMetrics()
        let spec = shotThumbGridSpec
        m.cellW = spec.cellW
        m.cols = max(1, spec.cols)
        guard spec.cols > 0 else { return m }
        m.cellH = shotThumbCellHeight > 0 ? shotThumbCellHeight : (m.cellW + Self.shotThumbCellTextEstimate)
        m.rowPitch = m.cellH + Self.shotThumbGridSpacing
        m.totalRows = max(0, Int(ceil(Double(shotThumbFilteredShots.count) / Double(m.cols))))
        let visibleRows = max(1, Int(ceil(shotThumbViewportHeight / max(m.rowPitch, 1))) + 1)
        m.windowRows = min(m.totalRows, visibleRows + 2)   // 上下各留一行余量（换数据都在屏外）
        m.slotCount = m.windowRows * m.cols
        m.spacerHeight = max(0, CGFloat(m.totalRows) * m.rowPitch
                             - Self.shotThumbGridSpacing + Self.bottomContentPadding)
        return m
    }

    /// 🧪 实验 7B：按当前滚动偏移刷新窗口起点 —— **只有跨行才写 @State**（别的帧什么都不做）。
    private func refreshShotThumbPoolWindow(offsetY: CGFloat? = nil) {
        guard Self.usePooledShotGrid else { return }
        let m = shotThumbPoolMetrics
        guard m.totalRows > 0, m.slotCount > 0 else { return }
        let y = offsetY ?? app.scrollAnchors.liveThumbOffset
        let first = max(0, Int(floor(y / m.rowPitch)))
        let maxStart = max(0, m.totalRows - m.windowRows)
        let target = min(max(0, first - 1), maxStart)
        if target != shotThumbWindowStartRow {
            shotThumbWindowStartRow = target
        }
    }

    /// 🧪 实验 7B：槽位 → 条目索引（环形映射 `i % slotCount`：每个条目一辈子只认一个槽位，
    /// 窗口滑动时只有"滚出去的那一行"的槽位换新数据，而且发生在屏外）。
    private func pooledShotItemIndex(forSlot slot: Int, metrics m: ShotPoolMetrics) -> Int? {
        let n = m.slotCount
        guard n > 0 else { return nil }
        let start = shotThumbWindowStartRow * m.cols
        let d = ((slot - start) % n + n) % n
        let i = start + d
        guard i < start + m.windowRows * m.cols, i < shotThumbFilteredShots.count else { return nil }
        return i
    }
    @FocusState private var shotThumbSearchFocused: Bool
    // （多选集合已提到 `AppModel.app.selectedShotIDs`；删除确认也搬到 RootView 共享底栏，2026-09-27）

    /// 拖动框选的选框矩形（命名坐标空间 `shotThumbMarquee` 里；nil = 没在拖）
    @State private var shotThumbMarqueeRect: CGRect?
    /// 拖动框选用的卡片 frame 缓存（普通 class，写入不触发重算）
    @State private var shotThumbFrames = MarqueeFrameStore<UUID>()
    /// 卡片列表的拖动框选（2026-09-26 用户定："勾选和按住选择那套也放到卡片"）——
    /// 与网格共用 `app.selectedShotIDs`，只是坐标空间/缓存各一套
    @State private var shotCardMarqueeRect: CGRect?
    @State private var shotCardMarqueeFrames = MarqueeFrameStore<UUID>()
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

    /// 单击分镜缩略图 / 卡片 = 打开段落详情（和工作台里点开的同一个；2026-10-26 用户：去掉右边详情，信息都在弹窗里）。
    /// 照样记成「正在看的分镜」：底栏的生成参数跟着它
    private func openShotEditor(_ id: UUID) {
        app.inspectorKind = .video
        app.timelineShotID = id
        ImagePreviewOnTap.shared.markEditorOpened()
        app.activeModal = .segmentDetail(shotID: id)
    }

    private func installDblThumbMonitor() {
        guard dblThumbMonitor == nil else { return }
        dblThumbMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            // 单击已经开了弹窗：双击的第二下别落进刚弹出的弹窗里
            if event.clickCount >= 2, ImagePreviewOnTap.shared.justOpenedEditor { return nil }
            guard event.clickCount == 2, let w = event.window, !(w is NSPanel),
                                    app.activeModal == nil, !app.showLibraryDrawer, !app.showTaskDrawer, !app.showHistoryDrawer,
                  app.isProductionWorkspaceVisible,
                  app.workspaceMode == .video, app.viewStyle == .thumbnails,
                  dblInside(dblThumbFrame, w, event.locationInWindow),
                  DoubleClickRegion.isOnVisibleGrid(viewport: dblThumbViewport, toolbar: app.workspaceToolbarFrame,
                                                    window: w, point: event.locationInWindow) else { return event }
            if let id = shotThumbFrames.hit(CGRect(x: dblLocal(dblThumbFrame, w, event.locationInWindow).x,
                                                   y: dblLocal(dblThumbFrame, w, event.locationInWindow).y,
                                                   width: 1, height: 1)).first {
                // 2026-10-26：双击 = 单击（打开段落详情；原来是大窗口播放，和生图页一样改掉——第一下还没开弹窗时第二下会开大窗口）。
                // 悬停播放照旧；选择模式下双击不动作
                AppLog.write("dblClick", "分镜缩略图双击 → 段落详情 id=\(id)")
                if app.selectedShotIDs.isEmpty { openShotEditor(id) }
                return nil
            }
            return event
        }
    }
    private func removeDblThumbMonitor() { if let m = dblThumbMonitor { NSEvent.removeMonitor(m) }; dblThumbMonitor = nil }

    /// 光标现在压着的那张视频缩略图（要有本地视频文件）。条件和双击监听一致：只认缩略图页上看得见、没被工具条盖住的格子。
    /// 滚动停下后悬停播放靠它重新起播（见 `ThumbVideoPlayback.cursorTarget`）。
    private func shotThumbUnderCursor() -> (shotID: UUID, url: URL)? {
        guard let w = NSApp.mainWindow ?? NSApp.keyWindow, !(w is NSPanel) else { return nil }
        let p = w.mouseLocationOutsideOfEventStream
        guard app.activeModal == nil, !app.showLibraryDrawer, !app.showTaskDrawer, !app.showHistoryDrawer,
              app.previewingShotID == nil, app.selectedShotIDs.isEmpty,
              app.isProductionWorkspaceVisible,
              app.workspaceMode == .video, app.viewStyle == .thumbnails,
              dblInside(dblThumbFrame, w, p),
              DoubleClickRegion.isOnVisibleGrid(viewport: dblThumbViewport, toolbar: app.workspaceToolbarFrame,
                                                window: w, point: p) else { return nil }
        let local = dblLocal(dblThumbFrame, w, p)
        guard let id = shotThumbFrames.hit(CGRect(x: local.x, y: local.y, width: 1, height: 1)).first,
              let shot = app.shots.first(where: { $0.id == id }),
              let taskID = shot.taskID, let task = app.store.task(id: taskID),
              let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return (id, URL(fileURLWithPath: path))
    }

    private func installDblCardMonitor() {
        guard dblCardMonitor == nil else { return }
        dblCardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            if event.clickCount >= 2, ImagePreviewOnTap.shared.justOpenedEditor { return nil }
            guard event.clickCount == 2, let w = event.window, !(w is NSPanel),
                                    app.activeModal == nil, !app.showLibraryDrawer, !app.showTaskDrawer, !app.showHistoryDrawer,
                  app.isProductionWorkspaceVisible,
                  app.workspaceMode == .video, app.viewStyle == .cards,
                  dblInside(dblCardFrame, w, event.locationInWindow),
                  DoubleClickRegion.isOnVisibleGrid(viewport: dblCardViewport, toolbar: app.workspaceToolbarFrame,
                                                    window: w, point: event.locationInWindow) else { return event }
            if let id = shotCardMarqueeFrames.hit(CGRect(x: dblLocal(dblCardFrame, w, event.locationInWindow).x,
                                                         y: dblLocal(dblCardFrame, w, event.locationInWindow).y,
                                                         width: 1, height: 1)).first {
                AppLog.write("dblClick", "分镜卡片双击 → 段落详情 id=\(id)")
                if app.selectedShotIDs.isEmpty { openShotEditor(id) }   // 双击 = 单击（2026-10-26）
                return nil
            }
            return event
        }
    }
    private func removeDblCardMonitor() { if let m = dblCardMonitor { NSEvent.removeMonitor(m) }; dblCardMonitor = nil }


    /// 视频缩略图页的状态筛选（对应 `TaskPhase`；与生图侧同一套交互，无单独「全部」状态）
    enum ShotThumbStatusFilter: String, CaseIterable, Identifiable {
        case all, completed, queued, generating, failed
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: "全部"
            case .completed: "已完成"
            case .queued: "排队中"
            case .generating: "生成中"
            case .failed: "失败"
            }
        }
    }

    private var shotThumbScrollPositionBinding: Binding<ScrollPosition> {
        Binding(get: { restoreShotThumbPosition }, set: { restoreShotThumbPosition = $0 })
    }

    /// 给 `.scrollPosition(_:)` 用的绑定。**按偏移定位**（见 `AppModel.ScrollAnchors` 的注释：
    /// 按条目那种 `.scrollPosition(id:)` 在这两个列表上报不出条目，只会写 nil）
    private var scrollPositionBinding: Binding<ScrollPosition> {
        // ⚠️ **用户的滚动回写要照收**（写进 @State）：实测在 240 次/整个 session 这个量级，
        // 不是每帧；而且必须让这个值跟着实际位置走 —— 否则 getter 一直返回"恢复时的旧值"，
        // SwiftUI 会以为位置被改回去了，跟用户的手抢滚动 ✗（同生图侧）
        Binding(get: { restorePosition }, set: { newValue in
            scrollJumpProbe.record(newValue)   // 🧪 探针：只记录，不改行为
            restorePosition = newValue
        })
    }
    /// 悬浮工具条会盖住内容区底部 —— 列表/网格底部留出这么多
    /// （条高 42 + 下边距 12 + 一点余量 = 80；改工具条高度时这里要跟着改）
    private static let bottomContentPadding: CGFloat = 80

    /// 卡片视图顺序展示当前项目的全部分镜。
    private var allShots: [ShotDraft] { displayedShots }

    // MARK: 卡片列表辅助（2026-09-26）

    /// 材质开关 / 明暗：编进行视图的"环境键"（行做了 `.equatable()` 门控，环境变化要显式带上）
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme

    /// 行枚举项（ForEach 需要 Identifiable：元组不能做 key path，包一层）
    private struct ShotRowItem: Identifiable {
        let index: Int
        let shot: ShotDraft
        var id: UUID { shot.id }
    }

    var body: some View {
        let _ = BodyEvalCounter.bump("GenerateView")
        @Bindable var app = app
        // 页面壳（2026-09-27 方案 A）：空态 / 头部容器 / 卡片-网格切换都在 `shotThumbnailWorkspace` 里的
        // `WorkspacePage`（生图与生视频共用一份实现）；工具条与右栏在 RootView 的共享层。
        // 旧时间轴页 `timelineView` 仍保留（想回去换调用点）。
        shotThumbnailWorkspace
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 「批量设置参数」已改成应用内浮层，由 **RootView** 统一呈现（见 AppModal 的注释）。
        // 这里只留触发按钮（`app.activeModal = .batchParam`）。
        .dropDestination(for: URL.self) { urls, _ in
            guard let txt = TextFileReader.firstTextFile(in: urls) else { return false }
            // 快速返回让拖拽预览消失动画立即开始，实际处理异步执行
            Task { @MainActor in
                handleScriptImport(txt)
            }
            return true
        }
        .alert("导入分镜", isPresented: $showImportConfirm) {
            Button("取消", role: .cancel) { pendingScriptShots = [] }
            Button("确定（新建 \(pendingScriptShots.count) 个分镜）") {
                // 导入成功不弹窗，停留在当前浏览位置；新分镜追加在最后一页
                app.importShots(pendingScriptShots)
                pendingScriptShots = []
            }
        } message: {
            Text(importConfirmMessage)
        }
        // 批量提交的确认框已搬到 RootView 的共享底栏（2026-09-27）
        .alert(infoTitle, isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
        // 删除选中的分镜：确认框搬到 RootView 的共享底栏（2026-09-27）
    }

    // MARK: 卡片列表（常驻视图）

    /// 分镜卡片列表。**常驻**（与缩略图网格靠 opacity 切换，见 body 里的注释）——
    /// 拆掉重建会让滚动位置归零，所以别改回 `if/else`（2026-09-17 实测）。
    ///
    /// **懒渲染（2026-09-26，与生图侧完全同款）**：`LazyVStack` 只创建可视范围内的行，
    /// 滚动时**不重算任何行**、也不需要外面驱动。
    /// ⚠️ 之前"自定义窗口化"（可视区 + 占位行 + 高度表）在滚动时每秒要重排几百个子视图，
    /// 实测 100ms 级卡顿连发；与生图侧对比后整套换掉。别再加窗口/占位那套。
    /// ⚠️ **2026-09-27 实验 16 已否**：试过 `VStack`（v1.8.3 老方案）——卡片全在树里 → 滚动**每帧
    /// 全树布局**（`NSHostingView.layout()` 占主线程 ~27%）、watchdog 100~400ms 卡顿成串（采样实锤），
    /// 别再试；v1.8.3 当年成立的前提是"一页只有 5 张卡"。
    private var cardList: some View {
        // 头部筛选对卡片列表**也生效**（2026-09-26 用户定："一直显示并生效"）——
        // rows 只含筛选结果；index 仍取**全量列表**里的序号（分镜编号不能因为筛选变化）
        let all = displayedShots
        let indexByID = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element.id, $0.offset) })
        let rows = shotThumbFilteredShots.map { ShotRowItem(index: indexByID[$0.id] ?? 0, shot: $0) }
        // 环境键：材质开关 / 明暗 / 视图样式 / 正在预览的版本 —— 变了要让行重画。
        // ⚠️ 行做了 `.equatable()` 门控，"纯环境驱动"的刷新会被挡掉，这些必须显式带上。
        var hasher = Hasher()
        hasher.combine(glassEnabled)
        hasher.combine(colorScheme)
        hasher.combine(app.videoViewStyle.rawValue)
        hasher.combine(app.timelineDisplayTaskID)
        let envKey = hasher.finalize()
        return ScrollViewReader { proxy in
            ScrollView {
                // 与生图侧同款：LazyVStack（可视区惰性创建；滚动不触发任何重算）
                LazyVStack(spacing: 12) {
                    ForEach(rows) { row in
                        // 行做了"内容没变就跳过重渲染"的门控（见 `CardRowView`）
                        CardRowView(shot: row.shot,
                                    index: row.index,
                                    envKey: envKey,
                                    binding: app.shotBinding(row.shot.id),
                                    selectionMode: !app.selectedShotIDs.isEmpty || shotCardMarqueeRect != nil,
                                    isSelected: app.selectedShotIDs.contains(row.shot.id),
                                    isCurrent: (app.timelineShotID ?? displayedShots.first?.id) == row.shot.id,
                                    onToggleSelect: { toggleShotSelection(row.shot.id) })
                            .equatable()
                            // 上报卡片 frame（拖动框选用；普通 class 缓存，写入不触发重算）。
                            // ⚠️ 实验 1 验证过：去掉它对滚动没有帮助（2026-09-27）——别拿它当卡顿原因。
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("shotCardMarquee"))
                            } action: { rect in
                                shotCardMarqueeFrames.update(row.shot.id, rect)
                            }
                            // 点卡片的非控件区域：普通模式 = 右栏切到这条；选择模式 = 勾选/取消
                            .onTapGesture {
                                shotThumbSearchFocused = false
                                if app.selectedShotIDs.isEmpty {
                                    openShotEditor(row.shot.id)
                                } else {
                                    toggleShotSelection(row.shot.id)
                                }
                            }
                            .id(row.shot.id)
                    }
                }
                // ⚠️ **上边距必须为 0**（2026-09-13 用户实测）：这里原来是四面的 `.padding(16)`，
                // 于是**第一张卡上方有 16pt** —— 而两种"到顶"的定义就此分叉：
                //   · 手动滑到顶 = 偏移 0 → 那 16pt 露出来（卡片在下面一点）
                //   · 点任务跳分镜 = `scrollTo(anchor: .top)` → 卡片顶贴视口顶 = 偏移 16
                // 表现就是"点完任务卡片还会往上跳一点"（日志实测：跳转前 0 → 跳转后 16）。
                // 去掉上边距后两者一致。左右保留 16、底部也保留（滚到底时有留白）。
                .padding(.horizontal, 16)
                // 底部要**留出悬浮工具条的高度**（它浮在内容上，不留最后一张卡会被永久压住）
                .padding(.bottom, Self.bottomContentPadding)
                // 拖动框选（2026-09-26 用户定）：任何位置可起拖、**每次替换**（选择状态与网格共用）
                .coordinateSpace(.named("shotCardMarquee"))
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblCardFrame = f }
                })
                .onAppear { installDblCardMonitor() }
                .onDisappear { removeDblCardMonitor() }
                .overlay { shotCardMarqueeOverlay }
                .simultaneousGesture(shotCardMarqueeGesture)
            }
            .scrollIndicators(.hidden)
            // 双击只认滚动区看得见的那一块（见 `DoubleClickRegion`）：量的是 ScrollView 本身，不是它那份很高的内容
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblCardViewport = f }
            })
            // **逐帧记录滚动偏移**（恢复时就靠它）。⚠️ 每帧都在触发，
            // 所以写**非观察缓存**（普通 class），不标脏 ✓（同生图侧）
            // 🧪 2026-09-27 诊断：同一回调顺带抄下内容估算高 / 视口高（普通 class，写入不触发重算）
            .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, geo in
                app.scrollAnchors.liveShotOffset = geo.contentOffset.y
                scrollJumpProbe.contentHeight = geo.contentSize.height
                scrollJumpProbe.viewportHeight = geo.containerSize.height
            }
            // 恢复用（只认 `restorePosition`）
            // ⚠️ 2026-09-13 做过 A/B：**关掉它滚动帧间隔毫无变化**（超50ms 的 0~7 次 vs 基线 2~6 次）
            // → 这个绑定**不是**滚动顿挫的原因 ✓（用户当时怀疑是它）
            .scrollPosition(scrollPositionBinding)

            .onAppear {
                if let saved = app.scrollAnchors.savedShotOffset {
                    AppLog.write("viewStyle", "卡片恢复滚动 y=\(Int(saved))")
                    // ② 没有显式跳转时，恢复上次离开的滚动位置 —— **从生图切回来走的就是这条**
                    //    （视图被整个摘掉重建，滚动位置本来会归零）。
                    //    ⚠️ 读的是 **saved 快照**，不是 live —— 重建后 live 会先被刷成 0
                    //       （ScrollView 先停在顶部），而那次写入发生在 onAppear 之前 ✗
                    //    ⚠️ 必须 `async`：LazyVStack 还没把内容铺到那个高度时，定位会被夹到 0
                    DispatchQueue.main.async {
                        // ⚠️ **必须关掉动画**（同生图侧）：不关的话会以一段滚动动画
                        // 从顶部"演"到目标偏移，用户能看到卡片滑一下 ✗
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            restorePosition = ScrollPosition(idType: Never.self, y: saved)
                        }
                    }
                }
            }
            // ⚠️ **这里不再存滚动位置**（2026-09-17）：视图被拆掉时 live 可能已经被刷成 0
            //（或 onDisappear 根本不触发）→ 存下去就是"切回来跑到第一张"（用户实测）。
            // 现在改为**切换视图时由 `AppModel.setVideoViewStyle` 显式快照**，见那边的注释。
            .onChange(of: app.scrollToShotID) { _, newID in
                guard let newID else { return }
                // 两个视图常驻；缩略图页新增时只让可见的网格定位。
                guard app.videoViewStyle == .cards else { return }
                // ⚠️ **2026-09-27 恢复 v1.8.70 的机制**（用户要求；怀疑项 = v1.8.71 给卡片列表加的
                // id 型 `.scrollPosition` + `.scrollTargetLayout()`：滚动时 ScrollView 会把可见条目的
                // id 回写进 binding → `restorePosition` 这个 @State 被写 → GenerateView 整页重算 →
                // 每滑过一张卡掉一下帧）。现在回到"偏移恢复 + proxy 跳转"；卡片页的新增跳转已在
                // v1.8.72 关闭，这里只需服务「任务抽屉点行」。无效就再撤。
                proxy.scrollTo(newID, anchor: .top)
                clearScrollToShotID()
            }
        }
    }

    /// 行视图（**可比较 + 门控**）：父视图重算时（app 状态变化等），内容与参数没变的行**跳过重渲染**。
    /// ⚠️ `envKey` 把材质开关 / 明暗 / 视图样式 / 正在预览的版本编进来：
    /// `.equatable()` 会把"纯环境驱动"的刷新挡掉，这些变了必须显式带上让行重画。
    private struct CardRowView: View, Equatable {
        @Environment(AppModel.self) private var app
        let shot: ShotDraft
        let index: Int
        let envKey: Int
        let binding: Binding<ShotDraft>
        /// 多选（2026-09-26 用户定：卡片列表也要勾选 + 拖动框选）
        var selectionMode: Bool = false
        var isSelected: Bool = false
        /// 是不是**右栏正在看的那条**（点击卡片 → 蓝框标记；2026-09-26 用户定）
        var isCurrent: Bool = false
        var onToggleSelect: () -> Void = {}

        /// 本行是否被鼠标悬停（悬停时露出勾选框）
        @State private var hovered = false

        /// ⚠️ 必须 `nonisolated`：SwiftUI 的 View 类型整体是 main-actor 隔离的，
        /// 而 `Equatable.==` 是非隔离协议要求（Swift 6 会报"conformance crosses into main actor"）。
        /// 这里只比较 Sendable 的字段，标 nonisolated 即可。
        nonisolated static func == (a: CardRowView, b: CardRowView) -> Bool {
            a.index == b.index
                && a.envKey == b.envKey && a.shot == b.shot
                && a.selectionMode == b.selectionMode && a.isSelected == b.isSelected
                && a.isCurrent == b.isCurrent
        }

        /// 🧪 **实验 17（2026-09-27，诊断）**：`true` = 行内容换成**同尺寸实心占位块**（容器 / 滚动 /
        /// `.equatable()` 门控全不动）——用来一刀切分"**卡内容**的每帧布局/绘制"与"**容器/宿主/焦点**"
        /// 谁在吃时间。
        /// ⚠️ 2026-09-27：**对象搞错了**——用户要测的是**缩略图网格的格子**（见 `ShotThumbCell` /
        /// `ImageAssetRow` 里的 `bareThumbCellDiagnosis`），不是卡片列表。先关（`false`）；
        /// 以后若真要诊断"卡片列表"，再改 `true`。
        private static let bareCardDiagnosis = false

        var body: some View {
            // 行内间距 12（原 `ShotRowLayout.spacing`，窗口化退役后写死）
            VStack(spacing: 12) {
                if Self.bareCardDiagnosis {
                    // 秃卡片：同宽固定高的实心块（高度取卡片常见值；内容全不建）
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.gray.opacity(0.25))
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                } else {
                ShotCardView(shot: binding, index: index)
                    // 当前查看的蓝框（点击卡片 = 右栏切到它；2026-09-26 用户定，同视频侧缩略图卡片）
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(isCurrent ? Theme.accent : Color.clear, lineWidth: 2)
                    }
                    // 选中高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底 + 蓝框（圆角 20 同卡片）
                    .overlay {
                        if isSelected {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.18))
                                RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.accent, lineWidth: 2)
                            }
                        }
                    }
                    // 🧪 2026-10-03 性能实验：每卡勾选框已删（每卡控件是滚动卡顿的大头，
                    //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边）
                }
                // 「增加分镜」按钮已按用户要求**去掉**（2026-09-26）——卡片只留预览/脚本/参数；
                // 想加回来：`app.insertShot(after:)` 还在数据层（`canInsertShot` 同）。
            }
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

    }

    // MARK: 时间轴视图（2026-09-17；原「缩略图网格」改成这个）

    /// 时间轴连播状态：播放中 / 缩放 / 拖动播放头的 seek 目标。
    /// ⚠️ **段内进度不放 @State** —— 见 `TimelineClock`（放 @State 会每 0.1s 重算整条时间轴，播放头一顿一顿）
    @State private var isTimelinePlaying = false
    @State private var timelineZoom: CGFloat = 1
    /// 播放时钟（普通 class：播放器每 1/30 秒写、播放头每帧读，不走 SwiftUI 观察）。
    /// 实体在 `AppModel.timelineClock` —— **全屏连播层也要读写它**，进出全屏位置才对得上
    ///（2026-09-18：原来放这里，全屏层拿不到，退出全屏后播放头停在旧位置）
    private var clock: TimelineClock { app.timelineClock }

    /// 时间轴视图：上 = **选中分镜的详情卡**（三栏：预览 / 脚本 / 资产库），下 = **时间轴**（按时长排段）。
    /// 时间轴视图不使用卡片页的纵向列表。
    /// 交互（用户 2026-09-17 定）：左预览**点击就地播放**（方形 + 全屏按钮）；脚本**限高、超出滑动**；
    /// 资产库条目**点开预览**；时间轴**点段选中**（空白段显示「点此编辑」）+ **按顺序连播** + 缩放。
    private var timelineView: some View {
        // **方案 C（2026-09-17 用户定）：卡片 : 时间轴 ≈ 2 : 1**，两边都跟着窗口高度伸缩；
        // 时间轴有下限（200），再矮就没法看刻度+段了
        GeometryReader { geo in
            // 时间轴区域高度**固定**（用户 2026-09-18：不跟窗口放大缩小；多出来的高度给卡片）
            let timelineHeight: CGFloat = 180
            VStack(spacing: 12) {
                if let shot = selectedTimelineShot {
                    ShotDetailCard(
                        shot: app.shotBinding(shot.id),
                        isPlaying: $isTimelinePlaying,
                        clock: clock,
                        shotOffset: offsetSeconds(of: shot),
                        onTogglePlay: { togglePlayFromDetailCard() },
                        onToggleFullscreen: {
                            // 全屏 = 全片连播，从**当前选中的分镜**开始（`cinemaPlaying` 那边就这么取）
                            isTimelinePlaying = false
                            app.cinemaPlaying = true
                        }
                    )
                    .frame(maxHeight: .infinity)
                }
                ShotTimelineStrip(
                    zoom: $timelineZoom,
                    clock: clock,
                    isPlaying: isTimelinePlaying,
                    shotOffset: { offsetSeconds(of: $0) },
                    onTogglePlay: { toggleTimelinePlayback() },
                    onScrub: { seconds in scrubTimeline(to: seconds) },
                    onScrubEnd: { seconds in endScrubTimeline(to: seconds) }
                )
                .frame(height: timelineHeight)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.horizontal, 16)
        // ⚠️ **顶部不留间距**：卡片要顶到最上面（用户 2026-09-17："卡片没到顶"）
        // 悬浮工具条浮在底部（约 54pt 高）——时间轴要坐在它上面，别被盖住
        .padding(.bottom, 64)
        .onAppear {
            // 选中兜底：nil / 失效 → 选第一个
            if selectedTimelineShot == nil, let first = displayedShots.first {
                app.timelineShotID = first.id
            }
        }
        // 点任务抽屉行：时间轴视图里**选中**该分镜（详情卡直接换成它；卡片列表那条负责切页/滚动）
        .onChange(of: app.scrollToShotID) { _, newID in
            guard let newID else { return }
            AppLog.write("timeline", "任务行跳转 → 选中 shot.id=\(newID)")
            app.timelineShotID = newID
            if let shot = displayedShots.first(where: { $0.id == newID }) {
                clock.playhead = offsetSeconds(of: shot)   // 播放头跟到这一段段首
            }
        }
        // 换选中的分镜 → **清掉"正在看哪一版"**（2026-09-23）：
        // 不清的话会拿着**上一个分镜**的 version id 去查这个分镜 —— 查不到，显示会退化成当前版本，
        // 但"正在看 第N版"的字样还可能残留，看着像坏了
        .onChange(of: app.timelineShotID) { _, _ in
            app.timelineDisplayTaskID = nil
            // 历史面板也跟着收：它是**跟着卡片走的**（盖在那张卡的资产库上），
            // 换了分镜还留着就会出现"面板开着却没有内容"的僵状态（2026-09-23）
            // ⚠️ 带 `withAnimation`：不然它是"啪"地消失，和滑入不对称
            withAnimation(.easeInOut(duration: 0.2)) { app.closeHistoryDrawer() }
        }
        // **播放头自己跑时间**（用户 2026-09-18 定：播放头是时间的主人，视频只是跟随者）：
        // 按真实经过时间推进播放头；跑过当前段末尾 → 推进到下一段（时间驱动，不看视频播到哪）。
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            guard isTimelinePlaying else { return }
            let now = Date()
            let dt = min(0.2, max(0, now.timeIntervalSince(clock.lastPlayTickAt)))
            clock.lastPlayTickAt = now
            clock.playhead += dt
            if let id = app.timelineShotID,
               let shot = displayedShots.first(where: { $0.id == id }),
               clock.playhead >= offsetSeconds(of: shot) + Double(timelineDuration(of: shot)) - 0.02 {
                advanceTimeline()
            }
        }
    }

    /// 时间轴当前选中的分镜（nil / 失效时兜底第一个）
    private var selectedTimelineShot: ShotDraft? {
        if let id = app.timelineShotID, let shot = displayedShots.first(where: { $0.id == id }) {
            return shot
        }
        return displayedShots.first
    }

    // MARK: 时间轴连播（2026-09-17）

    private func hasLocalVideo(_ shot: ShotDraft) -> Bool {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID),
              let path = task.localVideoPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// 时间轴上的时长（秒，与 `ShotTimelineStrip` 同口径）：
    /// **用任务里提交时的时长**——改时长草稿不会带着时间轴变，**提交生成之后才变**（2026-09-17 用户要求）；
    /// 还没提交（没有任务）的空白段固定 10s
    private func timelineDuration(of shot: ShotDraft) -> Int {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID) else { return 10 }
        return max(1, task.duration)
    }

    /// 某分镜在时间轴上的起始秒数（前面所有段的时长和）
    private func offsetSeconds(of shot: ShotDraft) -> Double {
        let shots = displayedShots
        guard let idx = shots.firstIndex(where: { $0.id == shot.id }) else { return 0 }
        return Double(shots[..<idx].reduce(0) { $0 + timelineDuration(of: $1) })
    }

    /// 播放键：没播 → 从**当前选中的段**往后找第一个有视频的段开播；在播 → 暂停
    private func toggleTimelinePlayback() {
        if isTimelinePlaying {
            isTimelinePlaying = false
            return
        }
        // **从播放头那一刻开始播**（播放头是时间的主人）：那一刻所在的段能播就播它，
        // 是空白段就往后再找；播放头落在空白段里就落到目标段段首。**不重置播放头**（用户 2026-09-18）
        guard let current = shot(atTimelineSeconds: clock.playhead) else { return }
        let target = hasLocalVideo(current)
            ? current
            : displayedShots.first(where: { offsetSeconds(of: $0) >= clock.playhead && hasLocalVideo($0) })
        guard let target else { return }
        app.timelineShotID = target.id
        if clock.playhead < offsetSeconds(of: target) {
            clock.playhead = offsetSeconds(of: target)
        }
        clock.scrubbing = false
        clock.lastPlayTickAt = Date()
        isTimelinePlaying = true
    }

    /// 详情卡里点画面：播/停**这一张卡的分镜**（而不是"播放头所在的那一段"）—— 2026-09-23
    ///
    /// ⚠️ 必须先对齐播放头：`toggleTimelinePlayback()` 是"从**播放头那一刻**开始播"，
    /// 而详情卡显示的分镜和播放头所在段**可以不是同一个**（点段只选中、不动播放头）——
    /// 不对齐的话会出现"点这张卡、播的却是另一段"。
    private func togglePlayFromDetailCard() {
        if isTimelinePlaying {
            isTimelinePlaying = false
            return
        }
        guard let target = selectedTimelineShot else { return }
        // 播放头不在本段 → 先跳到本段段首（+1 强制重画，否则"点已选中的段"不会触发重算）
        // ⚠️ 变量别叫 `shot` —— 会遮蔽方法 `shot(atTimelineSeconds:)`
        if shot(atTimelineSeconds: clock.playhead)?.id != target.id {
            clock.playhead = offsetSeconds(of: target)
            app.timelinePlayheadRevision &+= 1
        }
        toggleTimelinePlayback()
    }

    /// 一段播完 → 往后找下一个有视频的段接着播；没有了就停
    private func advanceTimeline() {
        guard isTimelinePlaying else { return }
        let shots = displayedShots
        guard let currentID = app.timelineShotID,
              let idx = shots.firstIndex(where: { $0.id == currentID }),
              let next = shots[(idx + 1)...].first(where: { hasLocalVideo($0) }) else {
            isTimelinePlaying = false   // 播到末尾：停住，播放头就停在末尾（不回段首）
            return
        }
        // **只换选中段，不动播放头**：播放头继续自己走，新段视频自己 seek 过来对齐
        app.timelineShotID = next.id
    }

    /// 拖动播放头（拖动中）：暂停 + 选中该时刻所在的分镜 + 播放头跟着手指走。
    /// 位置**夹在 0...总时长**内（用户 2026-09-17：原来往左能拖出 0，松手才弹回）
    private func scrubTimeline(to rawSeconds: Double) {
        isTimelinePlaying = false
        guard !displayedShots.isEmpty else { return }
        let total = Double(displayedShots.reduce(0) { $0 + timelineDuration(of: $1) })
        let seconds = min(max(0, rawSeconds), total)
        clock.playhead = seconds
        clock.scrubbing = true
        if let target = shot(atTimelineSeconds: seconds) {
            app.timelineShotID = target.id
        }
    }

    /// 松手：把播放器 seek 到段内对应位置（有视频的段才 seek）
    private func endScrubTimeline(to rawSeconds: Double) {
        defer { clock.scrubbing = false }
        guard !displayedShots.isEmpty else { return }
        let total = Double(displayedShots.reduce(0) { $0 + timelineDuration(of: $1) })
        let seconds = min(max(0, rawSeconds), total)
        guard let shot = shot(atTimelineSeconds: seconds) else { return }
        app.timelineShotID = shot.id
        let within = max(0, min(Double(timelineDuration(of: shot)) - 0.05,
                                seconds - offsetSeconds(of: shot)))
        clock.playhead = seconds           // 播放头真值（全局）；段内秒数只给 seek 用
        clock.seekRequest = (shot.id, within)   // 一次性 seek（单击/松手都要出画）
    }

    /// 某个时间点落在哪个分镜上（逐段累计；超出末尾算最后一段）
    private func shot(atTimelineSeconds seconds: Double) -> ShotDraft? {
        // ⚠️ **半开区间 [start, end)**：正好等于边界那一秒属于**下一段**。
        // 用 `<=` 的话边界时刻会返回上一段 —— 播到段尾/从段尾起播时差一个分镜（off-by-one，2026-09-18）
        var acc = 0
        for shot in displayedShots {
            let d = timelineDuration(of: shot)
            if seconds < Double(acc + d) { return shot }
            acc += d
        }
        return displayedShots.last
    }

    /// 清掉"跳转请求"。**必须延后一拍**：卡片列表也常驻、也监听同一个值 ——
    /// 立刻清的话，谁先跑谁把值清成 nil，另一个就收不到这次跳转（2026-09-17 两视图常驻后的坑）。
    private func clearScrollToShotID() {
        DispatchQueue.main.async { app.scrollToShotID = nil }
    }

    // MARK: 缩略图工作区（2026-09-26 取代时间轴页；布局与生图侧缩略图页同款）

    /// 视频缩略图页顶部：状态（带计数、**左边**）+ 名称搜索（右边）——
    /// 2026-09-26 用户定："生视频侧跟这个统一（只要状态和搜索，状态的位置挪到左边）"。
    // ⚠️ 头部（状态筛选横滑区 + 搜索框）已收进 **`WorkspacePage`**（2026-09-27 方案 A）——
    //    这里不再有 `shotThumbnailHeader`；筛选/搜索内容直接写在 `shotThumbnailWorkspace` 的 `filters:` 插槽里。

    /// 选中模式：「已选 N + 全选」——顶到状态那一行（2026-09-26 与生图侧统一）
    private var shotThumbSelectedRow: some View {
        HStack(spacing: 16) {
            Text("已选 \(app.selectedShotIDs.count)")
                .font(.callout.weight(.semibold))
            SelectBox(
                title: "全选",
                titleFont: .callout.weight(.semibold),
                isChecked: app.selectedShotIDs.count == shotThumbFilteredShots.count
            ) {
                if app.selectedShotIDs.count == shotThumbFilteredShots.count {
                    app.selectedShotIDs.removeAll()
                } else {
                    app.selectedShotIDs = Set(shotThumbFilteredShots.map(\.id))
                }
            }
            shotRangeButton
        }
    }

    /// 「按范围选」（2026-10-27 用户：批量提交时要能一次选第几集到第几集、或者先选多少个）。
    /// 没选中时在状态筛选后面，选中后在「已选 N + 全选」后面；选了就**替换**现在的选择（同拖框）
    private var shotRangeButton: some View {
        Button {
            shotThumbSearchFocused = false
            DropdownPanel.shared.dismiss()
            showShotRange = true
        } label: {
            Label("按范围选", systemImage: "checklist")
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.secondary.opacity(0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(QuietButtonStyle(hover: .capsule))
        .disabled(shotThumbFilteredShots.isEmpty)
        .dropdownPopover(isPresented: $showShotRange) {
            ShotRangePanel(episodeCount: app.currentPipelineArchive?.episodes.count ?? 0,
                           count: { rangePick($0).count },
                           onPick: { app.selectedShotIDs = Set(rangePick($0)) },
                           onClose: { DropdownPanel.shared.dismiss() })
        }
        .accessibilityIdentifier("shot-range")
    }

    /// 按范围选出的分镜（在看得见的里面、按显示顺序）
    private func rangePick(_ options: ShotRangeSelection.Options) -> [UUID] {
        let episodes = ShotRangeSelection.episodeIndex(app.currentPipelineArchive)
        return ShotRangeSelection.pick(shotThumbFilteredShots, options: options, episodeOf: { episodes[$0] }) { shot in
            if app.submittingShotIDs.contains(shot.id) { return true }
            switch shotThumbPhase(of: shot) {
            case .completed, .queued, .inProgress: return true
            default: return false
            }
        }
    }

    private func toggleShotSelection(_ id: UUID) {
        if app.selectedShotIDs.contains(id) {
            app.selectedShotIDs.remove(id)
        } else {
            app.selectedShotIDs.insert(id)
        }
    }

    /// 拖动框选的选框外观（半透明 + 描边；跟随手势矩形）
    @ViewBuilder
    private var shotThumbMarqueeOverlay: some View {
        if let r = shotThumbMarqueeRect {
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
    private var shotThumbMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("shotThumbMarquee"))
            .onChanged { value in
                shotThumbSearchFocused = false
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                shotThumbMarqueeRect = rect
                app.selectedShotIDs = shotThumbFrames.hit(rect)
            }
            .onEnded { _ in
                shotThumbMarqueeRect = nil
            }
    }

    /// 卡片列表拖动框选的选框外观（同网格那套）
    @ViewBuilder
    private var shotCardMarqueeOverlay: some View {
        if let r = shotCardMarqueeRect {
            Rectangle()
                .fill(Theme.accent.opacity(0.12))
                .overlay { Rectangle().strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1) }
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
        }
    }

    /// 卡片列表拖动框选手势：**任何位置可起拖**、**每次替换**（2026-09-26 用户定：卡片也要那套）
    private var shotCardMarqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("shotCardMarquee"))
            .onChanged { value in
                shotThumbSearchFocused = false
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                shotCardMarqueeRect = rect
                app.selectedShotIDs = shotCardMarqueeFrames.hit(rect)
            }
            .onEnded { _ in
                shotCardMarqueeRect = nil
            }
    }

    /// 缩略图页的条目（状态 + 名称搜索；2026-09-26 与生图侧同一套规则）
    private var shotThumbFilteredShots: [ShotDraft] {
        displayedShots.filter { shot in
            let query = shotThumbSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty,
               !shotThumbTitle(of: shot).localizedCaseInsensitiveContains(query) { return false }
            switch shotThumbStatusFilter {
            case .all: return true
            case .completed: return shotThumbPhase(of: shot) == .completed
            case .queued: return shotThumbPhase(of: shot) == .queued
            case .generating: return shotThumbPhase(of: shot) == .inProgress
            case .failed: return shotThumbPhase(of: shot) == .failed
            }
        }
    }

    /// 卡片标题（与 `ShotThumbCell` 同一口径：任务文件名带「分镜」前缀，否则编号标题）
    private func shotThumbTitle(of shot: ShotDraft) -> String {
        shotThumbCellTitle(for: shot, task: shot.taskID.flatMap { app.store.task(id: $0) }, app: app)
    }

    private func shotThumbPhase(of shot: ShotDraft) -> TaskPhase? {
        shot.taskID.flatMap { app.store.task(id: $0)?.phase }
    }

    /// 状态计数（只看分镜本身，不随搜索变——与生图侧口径一致）
    private func shotThumbStatusCount(_ f: ShotThumbStatusFilter) -> Int {
        displayedShots.filter { shot in
            switch f {
            case .all: return true
            case .completed: return shotThumbPhase(of: shot) == .completed
            case .queued: return shotThumbPhase(of: shot) == .queued
            case .generating: return shotThumbPhase(of: shot) == .inProgress
            case .failed: return shotThumbPhase(of: shot) == .failed
            }
        }.count
    }

    /// 视频侧「缩略图」页：左 = 分镜缩略图网格（点格选中），右 = 详情面板（播放器 + 卡片 + 历史版本）。
    /// ⚠️ 时间轴（刻度 / 连播 / 播放头 / 缩放）按用户要求下线；`timelineView` 等代码暂时保留，
    ///    想回去只需把 body 里的调用点换回 `timelineView`。
    private var shotThumbnailWorkspace: some View {
        // 页面壳（2026-09-27 方案 A）：空态 / 头部容器 / 卡片-网格切换都在 `WorkspacePage` 里，
        // 生图与生视频共用这一份实现；右栏在 RootView 的共享层。
        WorkspacePage(
            mode: .video,
            isEmpty: displayedShots.isEmpty,
            searchText: $shotThumbSearchText,
            searchPlaceholder: "搜索分镜",
            searchFocus: $shotThumbSearchFocused
        ) {
            // 空态：整块虚线投放区（点击建第一个分镜 / 拖入 txt 剧本）
            DropZone(action: { app.addShotAndInspect() }) {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("点击此处创建第一个分镜")
                        .font(.callout)
                }
            }
            // 四边一样留 14（2026-10-12 用户："虚线框跑到顶上了"）：2026-09-18 时为了「到顶」把顶部留边去掉，
            // 那时上面没有卡片边框；内容区改成带边框的圆角卡片之后，顶部 0 就是贴着卡片上沿
            .padding(14)
        } filters: {
            // 状态筛选（全部 / 已完成 / 排队中 / 生成中 / 失败，带计数）；勾选后换成「已选 N + 全选」
            if app.selectedShotIDs.isEmpty {
                HStack(spacing: 8) {
                    ForEach([ShotThumbStatusFilter.all, .completed, .queued, .generating, .failed]) { f in
                        Button {
                            shotThumbSearchFocused = false
                            shotThumbStatusFilter = f       // f == .all 即取消筛选
                        } label: {
                            HStack(spacing: 4) {
                                Text(f.displayName)
                                Text("\(shotThumbStatusCount(f))")
                                    .foregroundStyle(shotThumbStatusFilter == f
                                                     ? Theme.accent.opacity(0.85)
                                                     : Color.secondary)
                            }
                            .font(.callout)
                            // 胶囊底（2026-09-27 用户："加上胶囊底我看看效果"）——
                            // 沿用 v1.8.28 状态筛选胶囊那版配色（选中 accent 0.22 / 未选 secondary 0.1，
                            // 文字选中 accent、未选 primary）；点区吃满整个胶囊——垫出来的部分、
                            // 以及"文字↔数字"的 4pt 间隙都算命中（`.contentShape(Capsule())`）。
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(shotThumbStatusFilter == f
                                                       ? Theme.accent.opacity(0.22)
                                                       : Color.secondary.opacity(0.1)))
                            .foregroundStyle(shotThumbStatusFilter == f ? Theme.accent : Color.primary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(QuietButtonStyle(hover: .capsule))
                        .help(f == .all
                              ? "显示全部分镜"
                              : (shotThumbStatusFilter == f ? "取消状态筛选" : "只看「\(f.displayName)」"))
                    }
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 18)
                        .padding(.horizontal, 8)
                    shotRangeButton
                }
            } else {
                // 选中模式：筛选区换成「已选 N + 全选」（同生图侧）
                shotThumbSelectedRow
            }
        } gridContent: {
            shotThumbnailGrid
        } cardsContent: {
            cardList
        }
        // 选中兜底：nil / 失效 → 选第一个
        .onAppear {
            if selectedTimelineShot == nil, let first = displayedShots.first {
                app.timelineShotID = first.id
            }
        }
        // 筛选变了以后，选中项被藏起来 → 自动选中筛选结果的第一条（同生图侧规则）
        .onChange(of: shotThumbFilteredShots.map(\.id)) { _, ids in
            let visible = Set(ids)
            // 🎯 2026-09-27 用户定方案 B：多选也**只按筛选后的可见列表算** ——
            // 被筛掉/搜掉的条目自动取消选中。否则顶部会出现"已选 3、只看到 1 张"，
            // 全选框的勾态和批量操作的口径也会对不上。
            if !app.selectedShotIDs.isEmpty, !app.selectedShotIDs.isSubset(of: visible) {
                app.selectedShotIDs.formIntersection(visible)
            }
            // 🧹 幽灵 frame（同生图侧，2026-09-27 用户实测）：删除的分镜 frame 残留在框选缓存里，
            // 顶上来的新条目占同一个位置 → `hit()` 多算一个 →「已选 N」虚高。列表一变就清掉。
            shotThumbFrames.keepOnly(visible)
            shotCardMarqueeFrames.keepOnly(visible)
            if let selected = app.timelineShotID, ids.contains(selected) { return }
            app.timelineShotID = ids.first
        }
        // 切项目：滚动位置归零重来（停播由 RootView 的共享右栏自己处理，2026-09-27）
        .onChange(of: mediaContext?.projectKey ?? app.currentProjectKey) { _, _ in
            restoreShotThumbPosition = ScrollPosition(idType: Never.self)
            shouldRestoreShotThumbOffset = true
        }
        // 换选中的分镜 → 清"正在看哪一版" + 关历史抽屉（停播由 RootView 的共享右栏处理，2026-09-27）
        .onChange(of: app.timelineShotID) { _, _ in
            app.timelineDisplayTaskID = nil
            withAnimation(.easeInOut(duration: 0.2)) { app.closeHistoryDrawer() }
        }
    }

    /// 分镜缩略图网格（与生图侧缩略图网格同款：LazyVGrid + 偏移恢复 + 点任务行跳转）
    /// 缩略图区：没有分镜时，空态占位显示在**左网格区**（2026-09-26 与生图侧同步）——右栏留空。
    private var shotThumbnailGrid: some View {
        Group {
            if shotThumbFilteredShots.isEmpty {
                // 空态：**图标和文字都不要**（2026-09-26 用户定）——左区完全空着，什么都不显示
                Color.clear
            } else {
                shotThumbnailScroll
            }
        }
    }

    /// 缩略图滚动网格本体（空态由 `shotThumbnailGrid` 换成占位）。
    private var shotThumbnailScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if Self.usePooledShotGrid {
                        pooledShotThumbGrid
                    } else {
                        lazyShotThumbGrid
                    }
                }
                // 拖动框选（2026-09-26 用户定：任何位置可起拖、**每次替换**）
                .coordinateSpace(.named("shotThumbMarquee"))
                .background(GeometryReader { g in
                    Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblThumbFrame = f }
                })
                .onAppear {
                    installDblThumbMonitor()
                    ThumbVideoPlayback.shared.cursorTarget = { shotThumbUnderCursor() }
                }
                .onDisappear {
                    removeDblThumbMonitor()
                    ThumbVideoPlayback.shared.cursorTarget = nil
                }
                .overlay { shotThumbMarqueeOverlay }
                .simultaneousGesture(shotThumbMarqueeGesture)
            }
            .scrollIndicators(.hidden)
            // 双击只认滚动区看得见的那一块（见 `DoubleClickRegion`）：量的是 ScrollView 本身，不是它那份很高的内容
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in dblThumbViewport = f }
            })
            // 🧪 实验 6b/7B：只量**这一次** ScrollView 尺寸（跟窗口变），别在格子里再量。
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                if abs(size.width - shotThumbGridWidth) > 0.5 { shotThumbGridWidth = size.width }
                if abs(size.height - shotThumbViewportHeight) > 0.5 {
                    shotThumbViewportHeight = size.height
                    refreshShotThumbPoolWindow()   // 🧪 7B
                }
            }
            // 逐帧记录滚动偏移（恢复时就靠它）—— 写非观察缓存，不标脏 ✓（同生图侧）
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                app.scrollAnchors.liveThumbOffset = y
                refreshShotThumbPoolWindow(offsetY: y)   // 🧪 7B：只有跨行才写状态
            }
            .scrollPosition(shotThumbScrollPositionBinding)
            .onAppear {
                guard shouldRestoreShotThumbOffset else { return }
                shouldRestoreShotThumbOffset = false
                // 恢复上次离开缩略图模式时的位置（同生图侧：读 saved 快照 + 关动画 + async）
                if let saved = app.scrollAnchors.savedThumbOffset {
                    AppLog.write("viewStyle", "视频缩略图恢复滚动 y=\(Int(saved))")
                    DispatchQueue.main.async {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            restoreShotThumbPosition = ScrollPosition(idType: Never.self, y: saved)
                        }
                    }
                }
            }
            .onChange(of: shotThumbFilteredShots.count) { _, _ in
                refreshShotThumbPoolWindow()   // 🧪 7B：筛选/搜索后重算窗口
            }
            .onChange(of: shotThumbGridSpec.cols) { _, _ in
                refreshShotThumbPoolWindow()   // 🧪 7B：宽度变化（列数变）重算窗口
            }
            .onChange(of: shotThumbCellHeight) { _, _ in
                refreshShotThumbPoolWindow()   // 🧪 7B：格高实测回来了，重算窗口
            }
            // ⚠️ **不做预载**（2026-09-27 用户定终，实验 11/15 已否）：全量顺序预载（读盘 + 解码 + 烤字）
            //     只是把"滑到才加载"提前付，几百次后台操作反而拖累进项目；现在只留"格子出现自己加载
            //     + 磁盘缓存"（滚到就有）。别再把这套加回来。
            // 点任务抽屉行：**选中 + 滚到那一格**（卡片页那条负责"切页"；两个视图共用 `scrollToShotID`）
            .onChange(of: app.scrollToShotID) { _, newID in
                guard let newID else { return }
                AppLog.write("timeline", "请求跳转 → 缩略图选中 shot.id=\(newID)")
                app.timelineShotID = newID
                if shotThumbFilteredShots.last?.id == newID {
                    DispatchQueue.main.async {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            restoreShotThumbPosition = ScrollPosition(idType: Never.self, edge: .bottom)
                        }
                    }
                } else if Self.usePooledShotGrid {
                    scrollPooledShotThumbGrid(to: newID)   // 🧪 7B：算行号 → 直接设滚动位置（anchor .top）
                } else {
                    withAnimation(nil) { proxy.scrollTo(newID, anchor: .top) }
                }
                clearScrollToShotID()
            }
        }
    }

    /// 🧪 **实验 7B（2026-09-27）固定池 + 窗口网格**（视频侧）：
    /// 屏幕上永远只有 `slotCount`（≈可见行 + 2）× 列数 个格子视图；滚出窗口的格子**换数据、不销毁重建**；
    /// 窗口只在跨行时更新，其余滚动帧 NSScrollView 自己搬内容（SwiftUI 零工作）。
    /// 目标：滚动成本与素材总量无关（1 万条也一样顺）。
    private var pooledShotThumbGrid: some View {
        let m = shotThumbPoolMetrics
        return ZStack(alignment: .topLeading) {
            // 撑出真实内容高度（滚动条 / 恢复定位 / 跳转都靠它）
            Color.clear.frame(height: m.spacerHeight)

            ForEach(0..<m.slotCount, id: \.self) { slot in
                if let i = pooledShotItemIndex(forSlot: slot, metrics: m) {
                    pooledShotThumbCell(shot: shotThumbFilteredShots[i], index: i, metrics: m)
                }
            }
        }
    }

    /// 池子里的一个格子（**身份 = 槽位**：环形映射保证"条目 ↔ 槽位"一辈子只绑一次，
    /// 换数据时视图不销毁重建）。
    @ViewBuilder
    private func pooledShotThumbCell(shot: ShotDraft, index i: Int, metrics m: ShotPoolMetrics) -> some View {
        ShotThumbCell(
            shot: shot,
            selected: (app.timelineShotID ?? displayedShots.first?.id) == shot.id,
            selectionMode: !app.selectedShotIDs.isEmpty || shotThumbMarqueeRect != nil,
            isSelected: app.selectedShotIDs.contains(shot.id),
            clickPlaying: ThumbVideoPlayback.shared.playingShotID == shot.id,
            playReady: ThumbVideoPlayback.shared.isReady,
            cellWidth: m.cellW,
            onToggleSelect: { toggleShotSelection(shot.id) }
        )
        .equatable()
        // 上报卡片 frame（拖动框选用；普通 class 缓存，写入不触发重算）
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("shotThumbMarquee"))
        } action: { rect in
            shotThumbFrames.update(shot.id, rect)
        }
        // 实测格高（所有格同高，回填一次；窗口数学靠它）
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if h > 1, abs(h - shotThumbCellHeight) > 0.5 { shotThumbCellHeight = h }
        }
        // 点条目：没选中集合 = 右栏切到这个分镜；有选中集合 = 勾选/取消（同 LazyVGrid 路径）
        .onTapGesture {
            shotThumbSearchFocused = false
            if app.selectedShotIDs.isEmpty {
                openShotEditor(shot.id)
            } else {
                toggleShotSelection(shot.id)
            }
        }
        // 绝对坐标：条目 i 一辈子落在同一个位置（窗口滑动不挪它）
        .offset(x: 16 + CGFloat(i % m.cols) * (m.cellW + Self.shotThumbGridSpacing),
                y: CGFloat(i / m.cols) * m.rowPitch)
    }

    /// LazyVGrid 老实现（A/B 对照用；`usePooledShotGrid = false` 时走这条）。
    private var lazyShotThumbGrid: some View {
        LazyVGrid(columns: shotThumbGridLayout.columns, spacing: Self.shotThumbGridSpacing) {
            ForEach(shotThumbFilteredShots) { shot in
                ShotThumbCell(
                    shot: shot,
                    selected: (app.timelineShotID ?? displayedShots.first?.id) == shot.id,
                    selectionMode: !app.selectedShotIDs.isEmpty || shotThumbMarqueeRect != nil,
                    isSelected: app.selectedShotIDs.contains(shot.id),
                    clickPlaying: ThumbVideoPlayback.shared.playingShotID == shot.id,
                    playReady: ThumbVideoPlayback.shared.isReady,
                    cellWidth: shotThumbGridLayout.cellWidth,
                    onToggleSelect: { toggleShotSelection(shot.id) }
                )
                .equatable()
                .id(shot.id)
                // 上报卡片 frame（拖动框选用）
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("shotThumbMarquee"))
                } action: { rect in
                    shotThumbFrames.update(shot.id, rect)
                }
                .onTapGesture {
                    shotThumbSearchFocused = false
                    if app.selectedShotIDs.isEmpty {
                        openShotEditor(shot.id)
                    } else {
                        toggleShotSelection(shot.id)
                    }
                }
            }
        }
        // 右留白 4pt（同生图侧缩略图页）
        .padding(.leading, 16)
        .padding(.trailing, 4)
        // 留出悬浮工具条的高度（池子路径把它算进 spacer 高度里了）
        .padding(.bottom, Self.bottomContentPadding)
    }

    /// 🧪 实验 7B：跳转到某段（原 `proxy.scrollTo(anchor: .top)` 的等价物：算行号 → 直接设位置）。
    private func scrollPooledShotThumbGrid(to shotID: UUID) {
        guard let idx = shotThumbFilteredShots.firstIndex(where: { $0.id == shotID }) else { return }
        let m = shotThumbPoolMetrics
        guard m.cols > 0 else { return }
        let row = idx / m.cols
        let y = max(0, CGFloat(row) * m.rowPitch)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            restoreShotThumbPosition = ScrollPosition(idType: Never.self, y: y)
        }
    }

    // （实验 11「进项目后顺序预载」已删 —— 2026-09-27 用户定终：只留格子自加载 + 磁盘缓存。）

    // MARK: 顶部工具条
    // ⚠️ 工具条已搬到 **RootView 的共享页壳**（2026-09-27 用户定：四个页面共用一个底栏，
    //    按当前模式换按钮）。原来的 `bottomToolbar` 已删；想加按钮去 RootView 的 `sharedToolbar`。

    // MARK: 批量动作

    private func handleScriptImport(_ url: URL) {
        // 编码嗅探（UTF-8 / GBK / UTF-16）见 `TextFileReader`
        guard let text = TextFileReader.read(url), !text.isEmpty else {
            showInfoAlert("导入失败", "无法读取文件内容")
            return
        }
        let shots = ShotScriptParser.parse(text)
        guard !shots.isEmpty else {
            showInfoAlert("导入失败", "没有识别到分镜。请确认文件里每个分镜以「[场景][角色][道具]」行开头。")
            return
        }
        pendingScriptShots = shots
        showImportConfirm = true
    }

    private var importConfirmMessage: String {
        var text = "识别到 \(pendingScriptShots.count) 个分镜：\n"
        for shotText in pendingScriptShots.prefix(3) {
            text += "• \(ShotScriptParser.previewLine(of: shotText))\n"
        }
        if pendingScriptShots.count > 3 { text += "…\n" }
        text += "确定后将为每个分镜新建一张卡片并按顺序填入提示词。"
        return text
    }

    /// 分镜的模型是否与配置对账通过（批量提交用）：配置里没有该视频模型即视为未选
    private func isModelConfigured(_ shot: ShotDraft) -> Bool {
        !app.videoModelNames.isEmpty && app.videoModelNames.contains(shot.model)
    }

    /// 当前项目全部可提交分镜
    /// 点「提交生成（选中）」：**有任何一个不满足条件就直接拦住**（2026-09-26 用户定）
    // ⚠️ `prepareBatchSubmit` / `selectedShots` / `isModelConfigured(_:)` 都搬到了 RootView 的共享底栏（2026-09-27）

    private func showInfoAlert(_ title: String, _ message: String) {
        infoTitle = title
        infoMessage = message
        showInfo = true
    }

    // ⚠️ `shotBinding` 已提到 `AppModel`（2026-09-27）：右栏搬到 RootView 之后，面板和卡片页都要用它。
}

/// 播放时钟（**普通 class，非 `@Observable`**）：播放器每 1/30 秒写、播放头每帧读。
/// 不走 SwiftUI 观察 → **不会每帧重算整条时间轴**（2026-09-17：原来 0.1s 写一次 `@State`，
/// 详情卡 + 整条时间轴跟着重算，播放头一顿一顿、还卡）。
final class TimelineClock {
    /// **播放头的唯一真值：全片秒数（从项目开头算）**。
    /// 原来存的是"段内秒数"，还得配一个"选中段"才有意义 —— 两个值各写各的，换段/删段/异步切段时
    /// 两半会分家，时间轴和全屏各拼一次就对不上（用户 2026-09-18 定案：只留一个全局秒数，
    /// 段内秒数只在"给播放器 seek"这一个边界上换算）。
    var playhead: Double = 0
    /// 正在拖播放头（拖动中本段播放器要持续跟着 seek 出画）
    var scrubbing = false
    /// 播放时"播放头自己跑时间"的上一次 tick 时刻（算真实经过时间用）
    var lastPlayTickAt = Date()
    /// **"当前帧"交接盒**：时间轴预览播放器每拍登记"现在画面上的视频 + 段内秒数"。
    /// 全屏入口直接拿它接着播 —— 不做任何时长/偏移换算，帧级准确（用户 2026-09-18 定）。
    var livePath: String?
    var liveSeconds: Double = 0
    /// 一次性 seek 请求（**哪一段 + 段内秒数**）——单击时间轴/松手时用：
    /// 那种瞬间 `scrubbing` 只存在一帧，30Hz 的持续 seek 可能跑不到（2026-09-17）。
    /// ⚠️ 必须带 shotID：拖动换段时新旧播放器可能同时在树里，不带的话旧播放器会把请求吃掉、新播放器不出画
    var seekRequest: (shotID: UUID, seconds: Double)?
}

/// 视频**按帧取图**（时间轴胶片条用）：内存缓存，键 = 路径 + 0.5s 粒度时间。
/// 后台抽帧、主线程回填；同一帧并发只抽一次。
@MainActor
final class VideoFrameCache {
    static let shared = VideoFrameCache()
    private var images: [String: NSImage] = [:]
    /// 插入顺序（`images` 的 keys 无序，淘汰需要它）
    private var imageOrder: [String] = []
    private var inFlight: Set<String> = []
    /// 每个视频一个 generator（**复用**）：每帧新建要重新解析 asset，进项目时几十帧一起抽会拖慢主线程
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var generatorOrder: [String] = []

    /// **上限（2026-09-18）**：胶片条改成"每视频只抽首/尾两张"后，图片量 ≈ 视频数 × 1（尾帧；
    /// 首帧在 `VideoThumbnailCache`），400 张对上百个分镜绰绰有余；超了就丢最旧的。
    /// generator 同理按"最近使用"淘汰（每个都握着一个 AVURLAsset，不该只增不减）。
    private let maxImages = 400
    private let maxGenerators = 80

    private func generator(for path: String) -> AVAssetImageGenerator {
        if let gen = generators[path] { return gen }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.35, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.35, preferredTimescale: 600)
        // 2026-09-18：限尺寸。原来不设 → 抽的是全尺寸帧（1080p ≈ 8MB/张），
        // 400 张上限能吃掉几个 GB；胶片条一格只要 213×120pt，480×270 足够。
        gen.maximumSize = CGSize(width: 480, height: 270)
        generators[path] = gen
        generatorOrder.append(path)
        while generatorOrder.count > maxGenerators {
            let old = generatorOrder.removeFirst()
            generators.removeValue(forKey: old)
        }
        return gen
    }

    func image(path: String, seconds: Double) async -> NSImage? {
        let key = "\(path)|\(Int((seconds * 2).rounded()))"
        if let img = images[key] { return img }
        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)
        let gen = generator(for: path)
        let cg = try? await gen.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        inFlight.remove(key)
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: .zero)
        images[key] = img
        imageOrder.append(key)
        while imageOrder.count > maxImages {
            let old = imageOrder.removeFirst()
            images.removeValue(forKey: old)
        }
        return img
    }
}

/// 分镜段的**胶片条**（2026-09-17）：按宽度铺 N 格 **16:9** 画面帧，最后一格超出部分裁掉。
///
/// ⚠️ **一张 `Canvas` 自己画**（不是 HStack 摆 N 个帧视图）——原来每段 = N 个视图 + 多层
/// frame/clip/drawingGroup，每次布局都要逐层量尺寸（sample 实锤：主线程栈全在 `sizeThatFits`）；
/// 现在一段 = **一个固定尺寸的 Canvas**，量尺寸 O(1)，帧多少都不影响布局。
/// 帧仍是异步抽 + 缓存（滚动中不抽），帧到位时 Canvas 重绘一次。
private struct SegmentFilmstrip: View {
    let path: String
    /// 视频时长（秒）——按它把帧铺开
    let duration: Double
    let width: CGFloat
    let height: CGFloat

    @State private var firstFrame: NSImage?
    @State private var lastFrame: NSImage?

    /// **画面帧宽度：按 16:9**（帧比例跟分镜一致，不拉伸）
    private var tileWidth: CGFloat { height * 16.0 / 9.0 }

    var body: some View {
        // `rendersAsynchronously`：画布按段宽×缩放可能上万像素，主线程光栅化会卡滑动
        // （同卡片列表"拍平后滚动只搬纹理"的思路；用户 2026-09-18 报"放大后滑动更明显"）
        Canvas(rendersAsynchronously: true) { ctx, size in
            let tw = tileWidth
            let count = max(1, Int(ceil(size.width / max(1, tw))))
            for i in 0..<count {
                let rect = CGRect(x: CGFloat(i) * tw, y: 0, width: tw, height: size.height)
                // **每视频只抽首/尾两张真帧**（2026-09-18 用户方案）：
                // 第 0 格 = 首帧、最后一格 = 尾帧，中间格 = 尾帧按位置带 alpha 叠在首帧上（交叉混合）。
                // 好处：缓存从"每视频 × 每个缩放级别 N 张"降到**每视频 2 张**，和缩放级别无关。
                // 代价：分镜中间若换过场景，胶片条看不出中间内容（用户已确认接受）。
                guard firstFrame != nil || lastFrame != nil else {
                    ctx.fill(Path(rect), with: .color(.secondary.opacity(0.12)))
                    continue
                }
                var layer = ctx
                layer.clip(to: Path(rect))
                let f = count > 1 ? Double(i) / Double(count - 1) : 0
                if let first = firstFrame {
                    layer.draw(Image(nsImage: first), in: fillRect(for: first, in: rect))
                }
                if let last = lastFrame, f > 0 {
                    layer.opacity = f
                    layer.draw(Image(nsImage: last), in: fillRect(for: last, in: rect))
                }
            }
        }
        .frame(width: width, height: height)
        // 首帧缩略图（帧还没抽到之前垫着，不闪空白）
        .task(id: path) {
            if let cached = VideoThumbnailCache.images[path] { firstFrame = cached; return }
            VideoThumbnailCache.loadFromDisk(path: path) { fromDisk in
                if let fromDisk { firstFrame = fromDisk; return }
                Task {
                    guard let generated = await VideoThumbnailCache.generateThumbnail(path: path) else { return }
                    VideoThumbnailCache.store(generated, for: path)
                    firstFrame = generated
                }
            }
        }
        // **尾帧**（2026-09-18 用户方案）：每视频只抽这一张，首帧复用上面的缩略图缓存。
        // 原来每段要顺序抽 N 张（放大后 5～9 张/段，还全进缓存）→ 现在每视频 1 张、缓存封顶。
        // ⚠️ `.utility` 低优先级：别和首帧渲染抢资源（用户 2026-09-18 报"进项目慢"）。
        .task(id: "\(path)-\(duration)", priority: .utility) {
            while ScrollActivity.shared.isScrolling {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
            }
            guard lastFrame == nil, duration > 0.1 else { return }
            // 取 `duration - 0.1`（正好取 duration 会失败/黑帧；generator 有 ±0.35s 容差）
            if let img = await VideoFrameCache.shared.image(path: path, seconds: max(0, duration - 0.1)) {
                lastFrame = img
            }
        }
    }

    /// 图片按比例 fill 进 rect（居中裁切）
    private func fillRect(for image: NSImage, in rect: CGRect) -> CGRect {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = max(rect.width / imgSize.width, rect.height / imgSize.height)
        let w = imgSize.width * scale
        let h = imgSize.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// 详情卡左栏的**就地播放器**（2026-09-17 用户要求：点击播放、不开浮层）。
/// 用项目自绘的透明 `AVPlayerContainer`（`AVPlayerView` 自带一层清不掉的黑底，见预览浮层那条结论）。
///
/// **播放状态由外面管**（`isPlaying` 绑定）：时间轴的播放键、连播推进都通过它控制；
/// 段内进度写进 `clock`（普通 class，播放头每帧读）。播完回调 `onEnded`（由外面决定下一段是谁）。
/// 历史版本列表 —— **盖在资产库上的那块面板**（2026-09-23）。
///
/// 由时间轴详情卡的「查看历史」滑出，尺寸**和资产库完全一致**（同宽同高）——
/// 用户 2026-09-23 定："没必要那么高，只覆盖资产库就差不多"。
///
/// **两段式里的"看"**：点某一版只设 `app.timelineDisplayTaskID` —— 详情卡的播放器 / 脚本 /
/// 参数条换成那一版的显示，但**绝不动 `shot.taskID`**（时间轴那一段的播放源和时长都不变）。
/// 要真正换版本，回详情卡点「应用此版本」。
///
/// ⚠️ 面板只有 **200pt 宽**（资产库的宽度，见 `ShotDetailCard` 的 `assetWidth`）：
/// 行里放不下模型名那种长文本，一列只留「第 N 版 + 日期」
struct HistoryVersionList: View {
    @Environment(AppModel.self) private var app

    /// 面板对应的分镜。⚠️ 关面板时**不清 `historyDrawerShotID`** ——
    /// 清了的话滑出动画期间内容会突然变空（和 `libraryDrawerTarget` 同一套处理）
    private var shot: ShotDraft? {
        guard let id = app.historyDrawerShotID else { return nil }
        return app.shots.first(where: { $0.id == id })
    }

    /// 版本列表：最新的在最上（2026-10-16 和工作台、大预览统一）
    private var versions: [LocalTask] {
        guard let shot else { return [] }
        return shot.taskIDs.compactMap { app.store.task(id: $0) }.reversed()
    }

    private func isCurrent(_ task: LocalTask) -> Bool { shot?.taskID == task.id }
    private func isViewing(_ task: LocalTask) -> Bool { app.timelineDisplayTaskID == task.id }

    var body: some View {
        VStack(spacing: 0) {
            // 标题行（窄面板：不放分镜名，分镜名在卡片首行已经有了）
            HStack(spacing: 6) {
                Text("历史版本")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { app.closeHistoryDrawer() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle(expandX: 2, expandY: 2))
                .help("关闭")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if versions.isEmpty {
                Spacer()
                Text("还没有历史版本")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { index, task in
                            row(task: task, number: task.versionNumber(in: shot?.taskIDs ?? []))
                            if index < versions.count - 1 {
                                Divider().padding(.horizontal, 6)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.hidden)
            }

        }
    }

    /// 一行版本：缩略图 + 「第 N 版」+ 日期
    private func row(task: LocalTask, number: Int) -> some View {
        let viewing = isViewing(task)
        let current = isCurrent(task)

        return Button {
            // 设为当前版本（提示词和参数换回这一版），和工作台二级页面、大预览、右栏同一个动作（2026-10-16 用户：工作台和生视频侧对不上；
            // 原来这里只是「看一看」，不换当前版本也不换提示词）
            if !current, let shotID = shot?.id { app.applyVersion(shotID: shotID, taskID: task.id) }
            app.timelineDisplayTaskID = nil
        } label: {
            HStack(alignment: .center, spacing: 7) {
                // 缩略图（有本地视频才有内容，否则是占位）
                Group {
                    if let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) {
                        VideoThumbnailView(path: path)
                    } else {
                        Rectangle().fill(.secondary.opacity(0.15))
                    }
                }
                .frame(width: 48, height: 27)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text("第 \(number) 版")
                            .font(.caption.weight(.medium))
                        if task.phase == .failed {
                            Text("失败").font(.system(size: 9)).foregroundStyle(Theme.danger)
                        }
                        if current {
                            Text("当前")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accent.opacity(0.15)))
                                .foregroundStyle(Theme.accent)
                        } else if viewing {
                            Text("在看")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(Formatters.taskDate.string(from: task.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if task.phase == .failed {
                        Text(task.errorMessage.map(Formatters.errorSummary) ?? "没有返回失败原因")
                            .font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(viewing ? Theme.accent.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle(hover: .fill(radius: 6)))
    }
}

private struct InlineShotPlayer: View {    let path: String
    /// 下一段的视频路径：**预载到空闲播放器**，切段时直接换层。
    /// 每段现建 `AVPlayer` 的话，新播放器还没解出第一帧就上屏 —— 连播时黑闪一下
    ///（全屏连播层 `CinemaPlaybackLayer` 用同一套双播放器做法，见那边注释）
    let nextPath: String?
    @Binding var isPlaying: Bool
    /// 播放时钟（段内进度 + 拖动位置）
    let clock: TimelineClock
    /// **本段**在时间轴上的起始秒数（拖动播放头时换算"段内位置"用）
    let shotOffset: Double
    /// 本段的分镜 id（认领 seek 请求用）
    let shotID: UUID
    /// 点画面 → **播放 / 暂停**（2026-09-23 改；原来是打开预览弹窗）
    ///
    /// ⚠️ 由外层传进来（而不是直接 toggle `isPlaying`）：时间轴的播放键有一整套"从哪一段开始播"
    /// 的逻辑（见 `toggleTimelinePlayback`），直接翻绑定会绕过它。
    var onTogglePlay: () -> Void
    /// 点全屏按钮 → 全片全屏播放（`app.cinemaPlaying = true`）
    var onToggleFullscreen: () -> Void
    /// 点访达按钮 → 在访达里定位这个视频文件
    var onRevealInFinder: () -> Void

    /// **是否跟随时间轴时钟**（默认 true）。
    /// 看历史版本时传 false —— 那时播的是"那一版的视频"，跟着播放头对齐会把画面
    /// 拽到**当前版本**的位置上（两个不同的视频，时间轴并不认识这一版）。
    var followsTimeline: Bool = true

    // **双播放器 A/B 轮换**（2026-09-18）：跨段换源时往空闲的那个预载，切层时它已经有帧了。
    @State private var playerA = AVPlayer()
    @State private var playerB = AVPlayer()
    @State private var activeIsA = true
    /// 活动播放器载的是哪段（nil = 还没载任何段 → 显示加载圈）
    @State private var loadedPath: String?
    /// 当前播放器里**实际装着的那一段**的段起始秒数（和 `loadedPath` 同一次赋值）。
    /// ⚠️ 写播放头必须用它，不能用 view 的 `shotOffset`：连播换段的那几拍里，view 已经指向下一段、
    /// 活动播放器还是上一段（异步换层），用新段的 offset 配旧播放器的时间 → 播放头乱跳、
    /// 下一段的 seek 目标也跟着错（用户 2026-09-18 报"连播时播放头往后跳、视频对不上"）
    @State private var loadedOffset: Double = 0
    /// 换层代次：换层是异步的（等预载那层把第一帧画出来再切），旧任务回来时作废
    @State private var swapGeneration = 0
    @State private var hovered = false

    private var active: AVPlayer { activeIsA ? playerA : playerB }
    private var idle: AVPlayer { activeIsA ? playerB : playerA }

    var body: some View {
        ZStack {
            if loadedPath == nil {
                ProgressView().controlSize(.small)
            } else {
                // ⚠️ **两层都挂在图层树里**（预载那层 opacity 0）：只有挂着才会真的解码出第一帧，
                // 切层时才是现成画面；拿掉不可见的那层又会黑闪
                AVPlayerContainer(player: playerA).opacity(activeIsA ? 1 : 0)
                AVPlayerContainer(player: playerB).opacity(activeIsA ? 0 : 1)
            }
            // 悬停 → **画面底部浮出两个按钮**（2026-09-23 用户定）：
            // 左 = 在访达中显示，右 = 全屏播放。
            // ⚠️ 不能 `allowsHitTesting(false)` —— 这两个是要点的（原来那条只是提示文字）
            if hovered {
                HStack(spacing: 2) {
                    Button(action: onRevealInFinder) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverHighlightButtonStyle(expandX: 2, expandY: 2))
                    .help("在访达中显示")

                    Button(action: onToggleFullscreen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverHighlightButtonStyle(expandX: 2, expandY: 2))
                    .help("全屏播放（从这一段开始连播）")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                // 贴画面底部（用户："鼠标悬停播放器下边出现"）
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTogglePlay() }
        .onHover { hovered = $0 }
        .help("点击播放 / 暂停")
        .onAppear { syncToPath() }
        .onChange(of: path) { _, _ in syncToPath() }
        .onDisappear { playerA.pause(); playerB.pause() }
        // 外部改 isPlaying → 同步到播放器。
        // ⚠️ **播放/暂停永远生效** —— 卡片视图就靠这一条自己播自己的（那边 `followsTimeline == false`）；
        // 只有"预载下一段"是时间轴专属（卡片没有"下一段"这个概念）
        .onChange(of: isPlaying) { _, playing in
            if playing {
                if followsTimeline { preloadNext() }
                active.play()
            } else {
                active.pause()
            }
        }
        // 切到"看历史版本" → **立刻停掉**（否则当前版本继续出声，和画面里那一版对不上）
        .onChange(of: followsTimeline) { _, follows in
            if !follows { playerA.pause(); playerB.pause() }
        }
        // **播完**：时间轴那边由外层 `advanceTimeline` 推进（这里不插手）；
        // 卡片视图（不跟时间轴）没有"下一段"——**倒回开头并复位播放状态**，
        // 否则视频停在最后一帧、按钮还显示"暂停"，再点一下看着像没反应
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard !followsTimeline else { return }
            guard let item = note.object as? AVPlayerItem, item === active.currentItem else { return }
            active.seek(to: .zero)
            isPlaying = false
        }
        // 段内进度：1/30 秒一跳、写**普通 class**（不触发任何重算）；不播时不写。
        // ⚠️ **拖动播放头时在这里持续 seek**（预览跟着出画）——不走 @State 观察，天然每帧生效
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            // 看历史版本时不跟时钟（见 `followsTimeline` 的说明）
            guard followsTimeline else { return }
            let player = active
            // **登记"当前帧"**（全屏入口接着播用）：只认已经真正装载好的那层，
            // 这样拿到的一定是"画面上这一帧"，不是估算
            if loadedPath == path {
                let live = player.currentTime().seconds
                if live.isFinite { clock.livePath = path; clock.liveSeconds = max(0, live) }
            }
            // 一次性 seek 请求（单击/松手）——只认自己这一段
            if let req = clock.seekRequest, req.shotID == shotID {
                clock.seekRequest = nil
                player.seek(to: CMTime(seconds: req.seconds, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }
            if clock.scrubbing {
                // 拖动播放头：本段播放器跟着走（段内位置 = 全局 − 本段起始）；**不写回时钟**（全局才是真值）
                let within = max(0, clock.playhead - shotOffset)
                if abs(player.currentTime().seconds - within) > 0.04 {
                    player.seek(to: CMTime(seconds: within, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                }
                return
            }
            guard isPlaying else { return }
            let t = player.currentTime().seconds
            // 段内 → 全局（播放时唯一写入点）：offset 用**活动播放器那一段**的（见 loadedOffset 注释）
            // ⚠️ **时钟是真值、播放器是跟随者**：两者差得多 = 有一次 seek 还没生效
            //（点段后立刻播放 / 换段换层还在路上）。这时候**绝不能拿播放器位置去写时钟** ——
            // 那正是"播放时播放头往后跳、视频对不上"的根因（2026-09-18 日志实锤：
            // head=42.84 但播放器 t=0.00 → 播放头被拽回 30.0、视频从头播）。
            // 正确做法：反过来把播放器 seek 到时钟的位置。
            let target = clock.playhead - loadedOffset
            if abs(t - target) > 0.5 {
                player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                return
            }
            let newPlayhead = loadedOffset + max(0, t.isFinite ? t : 0)
            // ⚠️ **只允许往前走**（2026-09-18 用户报"播放头到两个分镜之间有轻微回跳"）：
            // 换段时新播放器还在 seek 路上，`currentTime()` 会短暂停在旧值/0（seek 完成前的抖动），
            // 直接写回就会把播放头拽回去一下。播放器时间本身就是有抖动的，绝不能让它往回带时钟。
            // 需要往回（拖动、点段）的场景走的是别的路径（scrub / seekRequest），不经过这里。
            if newPlayhead > clock.playhead {
                clock.playhead = newPlayhead
            } else if newPlayhead < clock.playhead - 0.4 {
                // 差得多 → 记一条（换段换层没跟上的诊断用；现在不会再写回，只留证据）
                AppLog.write("timeline", "播放头回跳被拦下 \(String(format: "%.2f", clock.playhead)) → \(String(format: "%.2f", newPlayhead)) | loadedOffset=\(String(format: "%.1f", loadedOffset)) t=\(String(format: "%.2f", t)) activeIsA=\(activeIsA) path=\(path.suffix(14)) loadedPath=\(loadedPath?.suffix(14) ?? "nil")")
            }
        }
    }

    /// 把活动播放器对齐到 `path`：空闲播放器里正好预载着这段 → **直接换层**（帧已就绪，不黑闪）；
    /// 否则现载（跳段等兜底路径，会黑一下，但不再是连播的常态）。
    private func syncToPath() {
        if loadedPath == path {
            // 同一段：只同步播放状态（比如连播推进后重新出现在树里）
            // ⚠️ 这里**绝不能 seek** —— "暂停 → 点播放"要从暂停位置续播（2026-09-29 用户定）
            if isPlaying { active.play() } else { active.pause() }
            preloadNext()
            return
        }
        // 🎯 2026-09-29 用户定（视频侧详情预览）：**切版本一律停住 + 回 0 帧** ——
        //   · 播放中切 → 不继续播；
        //   · 暂停位置不跨版本保留（切走再切回来也是 0 帧）。
        // 只在**不跟时间轴**的上下文这么做（详情面板；卡片视图没有播放器）。
        // ⚠️ 时间轴页已下线，但 `timelineClock` 仍被**全屏连播**写 —— 详情以前会把"全局 playhead"
        //    当成"这个视频里的秒数"（全屏看过 30s → 切版本被 seek 到 30s、超片长只剩末帧），一并修掉。
        if !followsTimeline {
            isPlaying = false
        }
        // 段内目标位置：跟时间轴的老路仍以时钟为准（有 seek 请求用它，否则对齐播放头）；
        // 不跟时间轴的详情路一律 0。
        // ⚠️ 跟时间轴时**必须真的 seek 过去**：不 seek 播放器停在段首，全屏接着播会从段首开始
        //（用户 2026-09-18 实测 0:37 → 全屏 0:30）。
        let targetElapsed: Double
        if !followsTimeline {
            targetElapsed = 0
        } else if let req = clock.seekRequest, req.shotID == shotID {
            targetElapsed = req.seconds
        } else {
            targetElapsed = max(0, clock.playhead - shotOffset)
        }
        if let url = (idle.currentItem?.asset as? AVURLAsset)?.url, url.path == path {
            // ⚠️ **等预载那层真的把第一帧画出来再换层**（seek 完成 + 一拍，和全屏连播层同一套）：
            // 直接 toggle 的话，隐藏层可能还没画过内容，切过去先闪一帧黑（实测 luma 17.8 的一帧）
            active.pause()
            swapGeneration += 1
            let gen = swapGeneration
            idle.seek(to: CMTime(seconds: targetElapsed, preferredTimescale: 600),
                      toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                // ⚠️ seek 被作废（比如这层被重新预载换掉了 item）→ 不能换层，重跑一次对齐
                guard finished else {
                    AppLog.write("timeline", "换层 seek 被作废 → 重试 path=\(path.suffix(12))")
                    syncToPath(); return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    guard gen == swapGeneration else { return }
                    // ⚠️ **换层前再确认一次这层装的就是目标视频**：预载/换段的竞态会把 item 换掉，
                    // 不查的话切上去的是"下一段"的视频 —— 表现为"当前分镜播的是下一个分镜的视频"
                    //（用户 2026-09-18 报的 off-by-one；预载已改成只在换层落定后做，这里是兜底）
                    guard (idle.currentItem?.asset as? AVURLAsset)?.url.path == path else {
                        AppLog.write("timeline", "换层前发现层里装错了 → 重试 path=\(path.suffix(12)) 实际=\((idle.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "nil")")
                        syncToPath()
                        return
                    }
                    activeIsA.toggle()
                    loadedPath = path
                    loadedOffset = shotOffset
                    if isPlaying { active.play() }
                    preloadNext()
                }
            }
            return
        }
        active.pause()
        active.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
        loadedPath = path
        loadedOffset = shotOffset
        if targetElapsed > 0 {
            active.seek(to: CMTime(seconds: targetElapsed, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying { active.play() }
        preloadNext()
    }

    /// 往空闲播放器预载下一段（自然连播不黑的关键）。
    /// ⚠️ 载完**立刻 seek 到 0**：让它在隐藏状态下就解出第一帧
    private func preloadNext() {
        guard let nextPath, nextPath != path else { return }
        if let url = (idle.currentItem?.asset as? AVURLAsset)?.url, url.path == nextPath { return }
        idle.pause()
        idle.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: nextPath)))
        idle.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

/// **分镜详情卡**：三栏（预览 / 脚本 / 资产库）+ 参数与操作 —— **两个视图共用**。
///
/// 原来只给时间轴视图用（叫 `TimelineDetailCard`）；2026-09-23 用户要求
/// "缩略图上边的卡片就算是一个组件，直接搬过去" → 卡片视图的 `ShotCardView` 也改成它。
///
/// 时间轴视图使用固定可用区域和资产栏；卡片列表使用提示词自适应的整宽布局。
private struct ShotDetailCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Binding var shot: ShotDraft
    /// 播放状态（时间轴：与时间轴共用；卡片：卡片自己的 `@State`）
    @Binding var isPlaying: Bool
    /// 播放时钟（段内进度 + 拖动位置）。
    /// 卡片视图也传一个 —— 但它 `followsTimeline == false`，那个时钟从头到尾不会被读写
    let clock: TimelineClock
    /// 本段在时间轴上的起始秒数（卡片视图传 0，用不到）
    let shotOffset: Double
    /// 点预览画面 → 播/停**这一张卡的分镜**。
    /// 时间轴那边由 `TimelineStrip` 提供（不是直接翻 `isPlaying`）：它要先**把播放头对齐到本段**，
    /// 否则会出现"点这张卡、播的却是播放头所在的那一段"；卡片那边就是翻自己的 `isPlaying`。
    var onTogglePlay: () -> Void
    /// 点预览画面上的「全屏」→ 全片全屏连播（**起点是"当前分镜"**）。
    /// 时间轴那边就是 `cinemaPlaying = true`；卡片那边要先把自己设成"当前分镜"
    var onToggleFullscreen: () -> Void
    /// 是否跟随时间轴时钟。卡片视图传 `false`：不跟播放头、播完自己倒回开头
    var followsTimeline = true
    /// 是否显示「删除」。卡片视图要；时间轴那边的删除挂在**时间轴的段**上（悬停浮出），不重复给
    var showsDelete = false
    /// 是否显示**播放器那一栏**。
    /// 卡片视图传 `false`（2026-09-23 用户："把视频侧卡片区的播放器删了"）——
    /// 一页 5 张卡就是 5 个播放器，太重；**播放统一在缩略图视图里做**。
    /// ⚠️ 关掉之后 `isPlaying` / `clock` / `shotOffset` / `onTogglePlay` / `onToggleFullscreen`
    /// 全都不再被读到（卡片视图那边传的是占位值）
    var showsPreview = true

    @State private var showDurationPopover = false
    @State private var showSubmitHint = false
    /// 参数条实测高度（基准高度要用：提示词高 + 间距 + 参数条高）
    @State private var paramsHeight: CGFloat = 36

    var body: some View {
        if usesInspectorLayout {
            // 缩略图页右侧的详情面板（2026-09-26）：**不加**卡片材质底 / 14pt 内边距 ——
            // 面板自己就是一列平的内容，布局与配色对齐生图侧缩略图页的 Inspector
            inspectorContent()
        } else {
            Group {
                if usesFlexibleCardLayout {
                    flexibleCardContent()
                } else {
                    // **时间轴视图**：撑满那块区域的高度（2026-09-17 用户定）——
                    // 预览正方形边长 = 内容高（等比放大）、中栏拉满、资产库拉满。
                    // ⚠️ 用 GeometryReader 是因为"可用高度"只有这里问得到；
                    // 卡片列表使用自然高度布局，不走这个几何尺寸分支。
                    GeometryReader { geo in
                        // 标题行（分镜名 + 状态徽章）占 ~32pt
                        let contentHeight = max(200, geo.size.height - 32)
                        content(side: contentHeight, contentHeight: contentHeight)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .padding(14)
            .materialCard()
        }
    }

    /// 卡片页使用一列自适应布局：提示词随内容自然增高，由外层列表统一滚动。
    var usesFlexibleCardLayout = false

    /// 缩略图页右侧的详情面板布局（2026-09-26；`ShotInspectorPanel` 用）。
    var usesInspectorLayout = false

    // MARK: 缩略图页的详情面板（生图侧同款结构，2026-09-26）

    /// 结构与配色对齐生图侧 Inspector（2026-09-26 用户定）：方形预览（**名称/第 N 版叠在方形顶部**）
    /// → 提示词块 → 生成设置。按钮行（全屏/访达）已按用户要求去掉——全屏仍在播放器悬停浮条里。
    private func inspectorContent() -> some View {
        // 结构对齐生图侧 Inspector（2026-09-26 用户定）：**VStack(spacing: 0) { 内容滚动；底部固定组件 }**
        // —— 生成设置 + 提交生成**都不跟内容滚动**。
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 🆕 2026-10-05（B 款视觉）：名称/状态标题行回归（纯视觉，行为不变；觉得多余可撤）
                    inspectorHeader
                        .padding(.bottom, 2)

                    // 当前这一版的预览（2026-10-10：右栏原来提示词下面整片空白）：有视频就是首帧 + 播放键，点一下大窗口播放
                    inspectorCover

                    // 历史版本（2026-10-16 和工作台、大预览统一：最新的在前、版本号按文件名、失败的也能点；0 版也在——占位在 `inlineHistoryVersions` 里）
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("历史版本（\(shot.taskIDs.count)）")
                        inlineHistoryVersions
                    }
                    // 这一版的参数 + 失败原因
                    InspectorChips(items: inspectorParamChips)
                    inspectorFailureNote
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("提示词")
                        inspectorPromptBlock
                    }
                    inspectorMaterials
                    // 生成设置已挪到**底部固定组件**：不参与滚动
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            // 底部留出工具条的高度：工具条整窗居中，会盖住右栏下半部分，长提示词要能滚到它上面
            .contentMargins(.bottom, ToolbarRowLayout.clearance, for: .scrollContent)
            // （生成参数 + 提交生成原来钉在这里的底部；2026-10-08 用户定：搬进页面底部的工具条，见 `ToolbarGenerationParams`）
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 右栏：预览 / 参数 / 失败原因 / 用到的素材（2026-10-10）

    /// 预览：有本地视频 = 首帧（缩略图缓存）+ 播放键，点一下大窗口播放；没有 = 按任务状态给一句话
    private var inspectorCover: some View {
        let path = localVideoPath
        // 大窗口播的是这张卡「当前」那一版；正在看历史版本时只给首帧，不给播放键（点了播的会是另一版）
        let playable = path != nil && displayTask == nil
        return ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.insetFill)
            if let path {
                VideoThumbnailView(path: path, fitsAspect: true)
                if playable {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.35), radius: 3)
                }
            } else {
                VStack(spacing: 6) {
                    switch shownTask?.phase {
                    case .queued?, .inProgress?:
                        ProgressView().controlSize(.small)
                        Text("生成中…").font(.caption).foregroundStyle(.secondary)
                    case .failed?:
                        Image(systemName: "xmark.circle").font(.title2).foregroundStyle(Theme.danger)
                        Text("生成失败").font(.caption).foregroundStyle(.secondary)
                    case .paused?:
                        Image(systemName: "pause.circle").font(.title2).foregroundStyle(.secondary)
                        Text("已暂停").font(.caption).foregroundStyle(.secondary)
                    default:
                        Image(systemName: "film").font(.title2).foregroundStyle(.tertiary)
                        Text("还没有视频").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(InspectorPreview.ratio(shownTask?.aspectRatio ?? shot.aspectRatio), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .hoverHighlight(radius: 14, clickable: playable)
        .onTapGesture {
            guard playable else { return }
            _ = app.openShotPreview(shot.id)
        }
        .help(playable ? "点一下大窗口播放" : "")
    }

    /// 这一版的参数标签（看别的版本时是那一版提交时的，否则是这张卡现在的）
    private var inspectorParamChips: [String] {
        let t = shownTask
        var chips: [String] = []
        if let model = (t?.model).flatMap({ $0.isEmpty ? nil : $0 }) ?? (shot.model.isEmpty ? nil : shot.model) { chips.append(model) }
        chips.append((t?.resolution ?? shot.resolution).displayName)
        chips.append((t?.aspectRatio ?? shot.aspectRatio).plainLabel)
        chips.append("\(t?.duration ?? shot.duration) 秒")
        return chips
    }

    /// 这一版失败了：原因就写在这里（悬停看全文）
    @ViewBuilder
    private var inspectorFailureNote: some View {
        if let t = shownTask, t.phase == .failed, let raw = t.errorMessage, !raw.isEmpty {
            Label(Formatters.errorSummary(raw), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.08)))
                .help(raw)
        }
    }

    /// 这一段挂着的参考图：缩略图 + 名字（和提示词里的「图N」是同一批）
    @ViewBuilder
    private var inspectorMaterials: some View {
        let items = shot.imageRefs.compactMap { app.libraryItem($0.libraryItemID) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("参考素材（\(items.count)）")
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, lib in
                        HStack(spacing: 6) {
                            Group {
                                if let url = lib.existingLocalImageURL { AsyncThumbImage(path: url.path) } else { Color.primary.opacity(0.06) }
                            }
                            .frame(width: 32, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(AssetVersionName.baseName(lib.matchKeyword)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
                    }
                }
            }
        }
    }

    /// Inspector 的提示词块：按实际内容自然增高，长提示词由详情面板统一滚动。

    private var inspectorPromptBlock: some View {
        let viewing = displayTask
        let text = viewing?.prompt ?? shot.prompt
        let isEmpty = text.isEmpty
        return ReadonlyPromptText(
            text: isEmpty ? "（无提示词，点此编辑）" : text,
            slots: viewing == nil ? slotItems : [],
            isPlaceholder: isEmpty
        )
        // ⚠️ 空着时也要有**最小高度**（2026-09-29 用户："空的时候提示词框高度太少"，生图/视频两侧一致）
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.insetFill))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .hoverHighlight(radius: 10, clickable: viewing == nil)
        .onTapGesture {
            guard viewing == nil else { return }
            app.activeModal = .editVideoPrompt(shotID: shot.id)
        }
    }

    /// B 款视觉：分节小标题（轻量、次要色；纯视觉）
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// 方形预览顶部的标题（分镜号 + 状态 + 第 N 版）——与生图侧 Inspector 同款。
    /// ⚠️ 整体不可点（`allowsHitTesting(false)`），别挡点画面播放/暂停
    private var inspectorHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(app.numbering(of: shot).title)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if let t = shownTask {
                StatusBadge(phase: t.phase).equatable()
            }
            Spacer(minLength: 4)
            if let t = shownTask, let n = versionNumber(of: t) {
                Text(displayTask == nil ? "第 \(n) 版" : "正在看 第\(n)版")
                    .font(.caption)
                    .foregroundStyle(displayTask == nil ? Color.secondary : Theme.accent)
            }
        }
        .allowsHitTesting(false)
    }

    /// 详情面板的预览：**方形**、`.insetFill` 底（2026-09-26 用户定：与生图侧一样是方形；
    /// 视频 16:9 会在方形里上下留边——播放器是 `resizeAspect`、留边透出 `.insetFill` 底）。
    /// 名称 / 状态 / 第 N 版叠在方形顶部（见 `inspectorHeader`）。
    private var inspectorPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.insetFill)
            if let path = localVideoPath {
                InlineShotPlayer(
                    path: path,
                    nextPath: nil,
                    isPlaying: $isPlaying,
                    clock: clock,
                    shotOffset: 0,
                    shotID: shot.id,
                    // 看别的版本时不响应播放（同卡片页规则）
                    onTogglePlay: {
                        guard displayTask == nil else { return }
                        onTogglePlay()
                    },
                    onToggleFullscreen: {
                        guard displayTask == nil else { return }
                        onToggleFullscreen()
                    },
                    onRevealInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    },
                    followsTimeline: false
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                previewPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // ⚠️ 生成中的呼吸光晕**已去掉**（2026-09-27 用户："太卡了"）——连续动画挂在常驻面板上开销大。
        //    状态反馈继续走转圈 / 状态徽章；想再加请用**非连续**效果。
        .overlay(alignment: .topLeading) { inspectorHeader }
    }

    private func flexibleCardContent() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            expandedPromptColumn
            // 参数条 + 提交 + 垃圾桶**整行已去掉**（2026-09-26 用户定）——右栏详情面板常驻之后，
            // 这些都在面板里；卡片只管名字/状态/提示词。
            //（`paramsRow` 定义留着——时间轴那套 `content(...)` 还在用，别一起删。）
        }
        // 历史抽屉仍从窗口右侧滑出；卡片模式给它一个稳定的 280×204 锚点。
        .overlay(alignment: .topTrailing) {
            Color.clear
                .frame(width: 280, height: 204)
                .anchorPreference(key: HistoryAssetBoundsKey.self, value: .bounds) { anchor in
                    [shot.id: anchor]
                }
        }
    }

    private var expandedPromptColumn: some View {
        let viewing = displayTask
        let text = viewing?.prompt ?? shot.prompt
        let isEmpty = text.isEmpty
        return ReadonlyPromptText(
            text: isEmpty ? "（无提示词，点此编辑）" : text,
            slots: viewing == nil ? slotItems : [],
            isPlaceholder: isEmpty
        )
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        // 点卡片 = 选中到右栏（单击，2026-09-26 用户定）
        // ⚠️ 双击走 **NSEvent 监听**（`onTapGesture(count: 2)` 会让单击等双击超时 → "切卡片慢一拍"）
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
    }

    /// 卡片内容（两种形态共用）：标题行 + 三栏
    ///
    /// 三栏顺序：**资产库 | 播放器 | 脚本+参数条**（2026-09-23 用户定：
    /// 先把播放器和资产库对调，再把**播放器放中间**）。
    /// ⚠️ 换位置只改**摆放顺序**，三栏的宽度/高度规则都没变
    ///（资产库仍 200 宽、播放器仍是边长 = 内容高的正方形、脚本栏吃掉剩余宽度）
    ///
    /// **播放器那一栏可以被整栏关掉**（`showsPreview == false`，卡片视图就是这种）——
    /// 那时只剩「资产库 | 脚本+参数条」两栏。
    private func content(side: CGFloat, contentHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            HStack(alignment: .top, spacing: 12) {
                assetColumn(width: assetWidth, height: contentHeight)
                    .anchorPreference(key: HistoryAssetBoundsKey.self, value: .bounds) { anchor in
                        // 两棵视图树常驻，只上报当前可见视图的资产库位置。
                        let visible = followsTimeline
                            ? app.videoViewStyle == .thumbnails
                            : app.videoViewStyle == .cards
                        return visible ? [shot.id: anchor] : [:]
                    }
                if showsPreview {
                    previewColumn(side: side)            // 中栏：播放器（正方形，边长 = side）
                }
                VStack(alignment: .leading, spacing: 8) {
                    // 右栏：脚本拉满（扣掉参数条），高度也是占满
                    promptColumn(height: max(120, contentHeight - 8 - paramsHeight))
                    paramsRow
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: contentHeight)
        }
    }

    /// 资产库宽度（**固定**：用户 2026-09-18 定"不跟窗口放大缩小；宽度变化给中间栏"）
    private var assetWidth: CGFloat { 200 }

    /// 标题行：历史版本统一从缩略图视图选择并直接应用；卡片只展示当前已应用版本。
    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(app.numbering(of: shot).title)
                .font(.headline)
            // 看别的版本时，徽章跟着显示**那一版**的状态
            if let t = shownTask {
                StatusBadge(phase: t.phase).equatable()
            }
            // 看别的版本时明确标出来（否则会以为这就是当前版本）
            if !followsTimeline, let d = displayTask, let n = versionNumber(of: d) {
                Text("正在看 第\(n)版")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
            Spacer()

            // 「应用此版本」：**只有看了别的版本才出现**（两段式的第二段）——
            // 点它才真正换播放源：写回 `shot.taskID`，并退出"查看"态
            if !followsTimeline, let d = displayTask {
                Button("应用此版本") {
                    // ⚠️ 用 `applyVersion` 而不是 `setCurrentVersion`：
                    // 前者把那一版的**提示词 + 参数**一起写回草稿，后者只挪"当前版本"指针
                    app.applyVersion(shotID: shot.id, taskID: d.id)
                    app.timelineDisplayTaskID = nil
                }
                .buttonStyle(HistoryActionButtonStyle(prominent: true))
                .help("把这一版设为当前版本 —— 时间轴上这一段会换成它（时长和视频都跟着换）")
            }

        }
        // 保留标题行占位，30pt 按钮上下各扩展 3pt，不移动下方内容。
        .frame(height: 24)
    }

    // MARK: 中栏：播放器（**固定方形** + 悬停浮出的访达/全屏）

    /// **当前版本**的任务（`shot.taskID`）—— 也就是时间轴上那一段的播放源
    private var task: LocalTask? {
        guard let taskID = shot.taskID else { return nil }
        return app.store.task(id: taskID)
    }

    /// 卡片模式历史抽屉里临时查看的版本。缩略图模式直接应用所点版本，不使用这个临时查看态。
    private var displayTask: LocalTask? {
        // timelineDisplayTaskID 是全局状态；只有这张分镜的历史版本才能驱动本卡按钮和内容。
        guard !followsTimeline,
              let id = app.timelineDisplayTaskID,
              shot.taskIDs.contains(id),
              id != shot.taskID,
              let t = app.store.task(id: id) else { return nil }
        return t
    }

    /// 这张卡**实际显示**的那一版（在看别的版本就是它，否则是当前版本）
    private var shownTask: LocalTask? { displayTask ?? task }

    /// 版本号（「第 N 版」）：按文件名，和工作台、大预览同一个口径（见 `LocalTask.versionNumber(in:)`）
    private func versionNumber(of t: LocalTask) -> Int? {
        shot.taskIDs.contains(t.id) ? t.versionNumber(in: shot.taskIDs) : nil
    }

    /// 预览里播 / 显示的路径 —— 跟"看的那一版"走
    private var localVideoPath: String? {
        guard let shownTask, let path = shownTask.localVideoPath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// 下一段可播视频（口径同 `advanceTimeline`：往后找第一个有本地视频的段）——
    /// 给就地播放器预载用，连播切段不黑闪
    private var nextVideoPath: String? {
        let shots = app.currentShots
        guard let idx = shots.firstIndex(where: { $0.id == shot.id }) else { return nil }
        for s in shots[(idx + 1)...] {
            guard let taskID = s.taskID, let t = app.store.task(id: taskID),
                  let path = t.localVideoPath,
                  FileManager.default.fileExists(atPath: path) else { continue }
            return path
        }
        return nil
    }

    /// 播放器那一栏（**三栏里居中** —— 2026-09-23 用户定）
    private func previewColumn(side: CGFloat) -> some View {
        let showsInlineHistory = followsTimeline && !shot.taskIDs.isEmpty
        let historyHeight: CGFloat = showsInlineHistory ? 58 : 0
        let playerSide = max(160, side - historyHeight - (showsInlineHistory ? 8 : 0))
        return VStack(alignment: .leading, spacing: 8) {
            previewSquare(side: playerSide)
            if showsInlineHistory {
                inlineHistoryVersions
                    .frame(height: historyHeight)
            }
            Spacer(minLength: 0)
        }
        // 历史条加入后播放器已经缩小；中栏也同步收窄，避免残留原 square 宽度形成空带。
        .frame(width: showsInlineHistory ? playerSide : side, height: side, alignment: .top)
    }

    /// 历史版本条（缩略图页 Inspector 里紧跟预览；时间轴页的播放器栏也用它）。
    /// 点版本即应用该版的提示词、参数和视频。标题带总数（与生图侧 Inspector 一致）。
    /// 2026-09-26：**0 版也显示占位**；小图尺寸/配色对齐生图侧（72×44、圆角 6；卡片圆角 9）。
    private var inlineHistoryVersions: some View {
        VStack(alignment: .leading, spacing: 7) {
            // （"历史版本 · 共 N 版"字样已按用户要求去掉，2026-09-29）
            if shot.taskIDs.isEmpty {
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
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        // 重新推理出来、还没生成的那一版：排最前面（2026-10-16 和工作台、大预览统一：最新的在前）
                        if shot.hasPendingVersion {
                            let current = shot.showsPendingVersion
                            Button {
                                app.applyPendingVersion(shotID: shot.id)
                                app.timelineDisplayTaskID = nil
                            } label: {
                                VStack(spacing: 4) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(.insetFill)
                                        .frame(width: 72, height: 44)
                                        .overlay { Text("还没生成").font(.caption2).foregroundStyle(.secondary) }
                                    Text("待生成")
                                        .font(.caption2)
                                }
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 8).fill(
                                    current ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.06)
                                ))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(current ? Theme.accent : Color.clear, lineWidth: 1.5)
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .help(current ? "当前版本（重新推理出来的提示词，还没生成视频）" : "换回重新推理出来、还没生成的提示词")
                        }
                        ForEach(Array(shot.taskIDs.enumerated()).reversed(), id: \.element) { entry in
                            let taskID = entry.element
                            if let version = app.store.task(id: taskID) {
                                let current = shot.taskID == taskID
                                Button {
                                    app.applyVersion(shotID: shot.id, taskID: taskID)
                                    app.timelineDisplayTaskID = nil
                                } label: {
                                    VStack(spacing: 4) {
                                        Group {
                                            if let path = version.localVideoPath,
                                               FileManager.default.fileExists(atPath: path) {
                                                VideoThumbnailView(path: path)
                                            } else {
                                                RoundedRectangle(cornerRadius: 6).fill(.insetFill)
                                            }
                                        }
                                        .frame(width: 72, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        HStack(spacing: 3) {
                                            Text("第 \(version.versionNumber(in: shot.taskIDs)) 版")
                                            if version.phase == .failed {
                                                Text("失败").foregroundStyle(Theme.danger)
                                            }
                                        }
                                        .font(.caption2)
                                    }
                                    .padding(5)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(
                                        current ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.06)
                                    ))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(current ? Theme.accent : Color.clear, lineWidth: 1.5)
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())
                                .help(version.phase == .failed ? "失败：\(version.errorMessage ?? "没有返回失败原因")（点一下换回这一版的提示词和参数，改好再交）"
                                      : current ? "当前版本" : "应用第 \(version.versionNumber(in: shot.taskIDs)) 版")
                            }
                        }

                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    /// 预览：**正方形**（边长 = 基准高度 = 提示词+参数条）——高度自然对齐，形状还是方的
    private func previewSquare(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.55))
            if let path = localVideoPath {
                InlineShotPlayer(
                    path: path,
                    nextPath: nextVideoPath,
                    isPlaying: $isPlaying,
                    clock: clock,
                    shotOffset: shotOffset,
                    shotID: shot.id,
                    // 点画面 = 播放/暂停（2026-09-23；原来是打开预览弹窗）。
                    // ⚠️ **看别的版本时不响应**：播的是时间轴上的**当前版本**，
                    // 和画面里显示的那一版不是同一个 —— 播出去只会让人困惑。
                    onTogglePlay: {
                        guard displayTask == nil else { return }
                        onTogglePlay()
                    },
                    onToggleFullscreen: {
                        guard displayTask == nil else { return }
                        onToggleFullscreen()
                    },
                    // 访达：打开**正在看的那一版**的文件（看了别的版本也对得上）
                    onRevealInFinder: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    },
                    // 看历史版本时**不跟时间轴时钟**（播的是别的视频，跟过去就对不上了）；
                    // 卡片视图本来就不跟（`followsTimeline == false` 一路传下来）
                    followsTimeline: followsTimeline && displayTask == nil
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                // 没有本地视频（生成中 / 失败 / 下载中）：占位内容自己就显示进度和失败原因，
                // 不需要再开什么（2026-09-23：本视图不再走预览弹窗）
                previewPlaceholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            if shot.taskIDs.count > 1 {
                Text("共 \(shot.taskIDs.count) 版")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.85)))
                    .foregroundStyle(Theme.onAccent)
                    .padding(6)
            }
        }
        // ⚠️ 这里原来有个**常驻的全屏按钮**（右下角圆形），2026-09-23 已删 ——
        // 全屏入口统一挪到 `InlineShotPlayer` 的**悬停浮条**里（和"在访达中显示"并排），
        // 常驻按钮和浮条同时存在会出现两个全屏入口
    }

    @ViewBuilder
    private var previewPlaceholder: some View {
        if let task {
            switch task.phase {
            case .failed:
                VStack(spacing: 6) {
                    Image(systemName: "xmark.circle").font(.title2).foregroundStyle(Theme.danger)
                    Text("生成失败").font(.caption).foregroundStyle(.secondary)
                    // 失败原因摘要（完整原文去任务列表点开看；这里悬停也能看全）
                    if let raw = task.errorMessage, !raw.isEmpty {
                        Text(Formatters.errorSummary(raw))
                            .font(.caption2)
                            .foregroundStyle(Theme.danger.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .help(raw)
                    }
                }
            case .completed:
                if task.errorMessage != nil {
                    Text("视频下载失败").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在下载视频").font(.caption).foregroundStyle(.secondary)
                    }
                }
            default:
                TaskInProgressView(task: task)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "film").font(.title3).foregroundStyle(.tertiary)
                Text("暂无内容").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: 中栏：脚本（限高、超出滑动；点一下进编辑弹窗）

    private func promptColumn(height: CGFloat) -> some View {
        // **看别的版本** → 显示那一版**提交时的原文**（`LocalTask.prompt` 是提交那一刻的快照）；
        // 且**不给编辑**（那是历史，改它没意义 —— 要改就点「应用此版本」把它变成草稿）。
        // ⚠️ slots 传空：`LocalTask` 只存了素材的 URL、没存 libraryItemID，
        // 重建不出缩略图；拿**当前**的 slots 顶上又会张冠李戴（2026-09-23）
        let viewing = displayTask
        let text = viewing?.prompt ?? shot.prompt
        let isEmpty = text.isEmpty

        return ScrollView {
            ReadonlyPromptText(
                text: isEmpty ? "（无提示词，点此编辑）" : text,
                slots: viewing == nil ? slotItems : [],
                isPlaceholder: isEmpty
            )
            .padding(10)
            // **minHeight = 面板高度**（2026-09-18 用户报）：原来只有文字那么高，
            // 空提示词时只有"（无提示词，点此编辑）"那一行能点 → 现在整块面板都能点开编辑。
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .hoverHighlight(radius: 8, clickable: viewing == nil)
            .onTapGesture {
                guard viewing == nil else { return }   // 看历史版本时不进编辑
                app.activeModal = .editVideoPrompt(shotID: shot.id)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .frame(height: height)      // 和中间播放器的正方形等高（2026-09-17 用户要求）
        .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
    }

    private var slotItems: [SlotItem] {
        // 和编辑弹窗同一套（绑了音色的角色图带小喇叭，2026-10-26）
        SlotItem.list(for: shot, in: app)
    }

    // MARK: 左栏：资产库（点条目开预览；＋ 打开素材库抽屉并锁定到这张卡）

    private func assetColumn(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 「＋」已去掉（2026-09-17 用户要求）；素材仍走左侧素材库抽屉/提示词里的引用
            HStack(spacing: 6) {
                Text("资产库").font(.headline)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    assetGroup("角色", items: assetItems(of: .character))
                    assetGroup("场景", items: assetItems(of: .scene))
                    assetGroup("道具", items: assetItems(of: .prop))
                    // ⚠️ **「素材」是兜底组（没类型的条目）——空着就整组不显示**：
                    // 上面已经有素材了、下面还挂个"暂无素材"，看着像坏了（用户 2026-09-17 实测）
                    assetGroup("素材", items: assetItems(of: nil), hidesWhenEmpty: true)
                }
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: width, height: height, alignment: .top)
        // **鼠标停在资产库上 → 禁掉外层列表的滚动**（2026-09-18 用户报"滚资产库整页跟着动"）：
        // macOS 嵌套 ScrollView 有"滚动链"，内层滚到头会带着外层一起滚 ✗
        // 消费方在 `cardList` 那层（`.scrollDisabled(app.assetLibraryHovering)`）。
        //
        // ⚠️ **这一行 2026-09-23 重构时丢过一次**：旧卡片视图里它是写在 `cardAssetSection` 上的，
        // 我把旧布局整体删掉、换成这个共用组件时忘了搬过来 → 卡片视图又开始"滚资产库整页跟着动"。
        // 搬进共用组件后：卡片视图 ✓、缩略图视图（那边本来就没有外层纵向滚动，设了也无害）✓
        .onHover { app.assetLibraryHovering = $0 }
    }

    /// 这张卡引用到的素材（去重）按类型过滤；`nil` = 没类型的（用户手动拖进来的，只出现在「素材」）
    private func assetItems(of type: ImageSubjectType?) -> [LibraryItem] {
        var seen = Set<UUID>()
        var result: [LibraryItem] = []
        for ref in shot.imageRefs + shot.videoRefs + shot.audioRefs {
            guard seen.insert(ref.libraryItemID).inserted else { continue }
            guard let item = app.libraryItem(ref.libraryItemID) else { continue }
            // 两级回退：来源生图条目的 type（权威）→ 名字前缀（见 LibraryItem.subjectType 的说明）
            let sourceType = item.imageGenItemID.flatMap { id in
                app.imageItems.first(where: { $0.id == id })?.type
            }
            if item.subjectType(sourceType: sourceType) == type {
                result.append(item)
            }
        }
        return result
    }

    @ViewBuilder
    private func assetGroup(_ title: String, items: [LibraryItem], hidesWhenEmpty: Bool = false) -> some View {
        if !(hidesWhenEmpty && items.isEmpty) {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if items.isEmpty {
                Text("暂无\(title)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(items) { item in
                        assetThumb(item)
                    }
                }
            }
        }
        }
    }

    private func assetThumb(_ item: LibraryItem) -> some View {
        Button {
            // 点开预览（复用素材库那套预览浮层）
            app.previewingLibraryItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                // **方形格子 + 图按比例 fit**（2026-09-17 用户要求：不要裁掉铺满）
                // 底下垫一层淡灰：图按比例缩放后留出来的边看着是有意的，不是破图
                RoundedRectangle(cornerRadius: 6)
                    .fill(.insetFill)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if item.kind == .image, let url = item.existingLocalImageURL {
                            AsyncThumbImage(path: url.path, contentMode: .fit)
                        } else {
                            Image(systemName: item.kind == .video ? "film" : "waveform")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(item.matchName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(QuietButtonStyle())
        .help(item.matchName)
    }

    // MARK: 参数条（脚本底下；2026-09-17 从卡片底行搬来）

    /// 参数 + 提交生成。**「编辑提示词」按钮已去掉** —— 点脚本区就能进编辑弹窗。
    private var paramsRow: some View {
        Group {
            if let d = displayTask {
                // ⚠️ **看历史版本时必须换成只读文本**：下面的 `IconDropdown` 绑的是 `$shot.*`（草稿），
                // 直接显示会让人以为"那一版的参数可以改"、一改就污染草稿（2026-09-23）。
                // 要改就点「应用此版本」把那一版变成草稿，参数条自然恢复可编辑。
                HStack(spacing: 12) {
                    Label(d.model.isEmpty ? "未选模型" : d.model, systemImage: "cube")
                    Label(d.resolution?.displayName ?? "—", systemImage: "rectangle.on.rectangle")
                    Label(d.aspectRatio.plainLabel, systemImage: "aspectratio")
                    Label("\(d.duration) 秒", systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                editableParamsRow
            }
        }
        // 量参数条实际高度（基准高度 = 提示词高 + 8 + 这里量到的）
        .background(
            GeometryReader { g in
                Color.clear.onChange(of: g.size.height, initial: true) { _, h in paramsHeight = h }
            }
        )
    }

    /// 可编辑的参数条（只在"看的是当前版本"时出现）
    private var editableParamsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            FlowLayout(spacing: 10, lineSpacing: 10) {
                IconDropdown(
                    icon: "cube",
                    labelWidth: 130,
                    options: modelOptions,
                    selection: $shot.model,
                    hasModels: !app.videoModelNames.isEmpty,
                    emptyHint: "还没有可用的视频模型。请到「设置 → 模型渠道」添加渠道与视频模型。"
                )
                IconDropdown(
                    icon: "rectangle.on.rectangle",
                    labelWidth: 48,
                    options: resolutionOptions,
                    selection: $shot.resolution
                )
                IconDropdown(
                    icon: "aspectratio",
                    labelWidth: 44,
                    options: videoAspectOptions,
                    selection: $shot.aspectRatio
                )
                durationButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            submitButton
            // 「删除」只在**卡片视图**显示 —— 时间轴那边的删除挂在时间轴的段上（悬停浮出的垃圾桶），
            // 两边都给会重复（2026-09-23）
            if showsDelete {
                Button {
                    app.activeModal = .confirmDeleteShot(shotID: shot.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                }
                // ⚠️ 与生图卡片**完全同款**（2026-09-19 用户要求：样式和位置都要一致）：
                // 无边框 + 悬停高亮 + secondary 灰
                .buttonStyle(HoverHighlightButtonStyle())
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 时长草稿：拖动期间只改它（**时间轴段宽不跟着抖**），松手才写回 `shot.duration`（2026-09-17）
    @State private var draftDuration: Int?

    /// 时长（2026-09-26 用户："时长按钮怎么就这么点" —— 撑满半行，与同行三个 `fillsRow` 的下拉
    /// 完全同款：图标 + `.callout` 文字、无底色、内边距 6 → 高 29、悬停高亮）。
    private var durationButton: some View {
        Button {
            draftDuration = shot.duration
            showDurationPopover = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Text("\(draftDuration ?? shot.duration)")
                        .monospacedDigit().frame(width: 20, alignment: .trailing)
                    Text("秒")
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            // 同 IconDropdown 的 fillsRow：撑满所在行的剩余宽度（可点/悬停范围一起变大）
            .frame(maxWidth: .infinity, alignment: .leading)
            // ⚠️ 垂直内边距必须在 .contentShape 之前，否则撑大的部分接不到悬停
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .dropdownPopover(isPresented: $showDurationPopover, onClose: { commitDraftDuration() }) {
            // ⚠️ 草稿由**弹窗内容自己**持有（见 `DurationPopoverContent` 的说明）——
            // 不能再把 `draftDuration` 直接绑给它：浮层内容渲染在 RootView 的 overlay 里，
            // 拿不到卡片 @State 的变化通知，滑块会拖不动。
            DurationPopoverContent(
                initial: draftDuration ?? shot.duration,
                onLiveChange: { draftDuration = $0 },   // 只更新卡片按钮文字
                onCommit: { _ in commitDraftDuration() }
            )
        }
    }

    private func commitDraftDuration() {
        if let d = draftDuration, d != shot.duration {
            shot.duration = d
        }
        draftDuration = nil
    }

    /// 提交：**和生图卡片同款的文字按钮**（2026-09-19 用户要求）。
    /// 原来是为了窄窗口不挤参数条才做成圆形箭头；现在统一成 `.borderedProminent`「提交生成」，
    /// 不满足条件时**不做灰化**，点一下弹「缺什么」的 popover（同生图卡片）。
    private var submitButton: some View {
        Button {
            if issues.isEmpty { app.submitShot(shot.id) } else { showSubmitHint = true }
        } label: {
            // ⚠️ 加高必须加在**标签**的垂直内边距上：macOS 按钮样式**不跟外层 frame 拉伸**
            //（2026-09-26 实测）。5.5×2 = +11 → 36pt，与生图侧底部按钮同高（用户定）
            Text("提交生成").padding(.vertical, 5.5)
        }
        .buttonStyle(AccentButtonStyle())
        .help(issues.isEmpty ? "提交生成" : "还不满足提交条件（点看原因）")
        .dropdownPopover(isPresented: $showSubmitHint) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.caption)
                }
            }
            .padding(12)
        }
    }

    private var issues: [String] { ShotSubmitRules.issues(shot, app: app) }

    private var modelOptions: [DropdownOption<String>] {
        app.videoModelNames.map { DropdownOption(label: $0, value: $0) }
    }

    private var resolutionOptions: [DropdownOption<Resolution>] {
        Resolution.allCases.map { DropdownOption(label: $0.displayName, value: $0) }
    }

    private var videoAspectOptions: [DropdownOption<AspectRatio>] {
        // **只列真正的比例档**（2026-09-17 用户要求）：去掉「自适应」；
        // 去掉 `horizontal`/`vertical` 两个旧兼容档——它们的 plainLabel 就是 16:9 / 9:16，
        // 和正牌档重名（弹窗里会出现两个 16:9、两个 9:16）。
        // 旧数据的值（adaptive / horizontal / vertical）补进列表，别显示成空白。
        var values: [AspectRatio] = [.ratio16x9, .ratio9x16, .ratio1x1, .ratio4x3, .ratio3x4]
        if !values.contains(shot.aspectRatio) { values.append(shot.aspectRatio) }
        return values.map { DropdownOption(label: $0.plainLabel, value: $0) }
    }
}

/// 时间轴专用横向滚动容器：**自己拿 NSScrollView**（不用 SwiftUI 的 `ScrollView`）。
///
/// 为什么（2026-09-18 定案）：SwiftUI 的 ScrollView 在"内容宽度变化"那一帧只排新布局，
/// 滚动偏移要**下一帧**才应用 —— 缩放时播放头会先错一帧再跳回来（用户实测"蓝线左右抖/漂"）。
/// 自己拿 NSScrollView 就能在 `updateNSView` 里用**同一个 CATransaction** 原子地改文档宽度 +
/// clip 偏移，中间帧从根上不存在（Final Cut / Logic 这类轨道视图的标准做法）。
///
/// 用法：`forcedOffset` 非 nil 时（缩放手势期间）把偏移强制到该值；nil 时完全交给用户滚动。
/// 只在**内容宽度或强制值变化**时才写偏移 —— 平时绝不碰，免得跟用户的手抢。
private struct TimelineScrollContainer<Content: View>: NSViewRepresentable {
    /// 内容总宽（时间轴总宽；缩放时会变）
    let contentWidth: CGFloat
    /// 非 nil = 把滚动偏移强制到这个值（同一帧生效）；nil = 不管偏移
    let forcedOffset: CGFloat?
    /// 实际滚动偏移回调（用户滚动 / 我们强制写都会报）
    var onOffsetChange: (CGFloat) -> Void
    /// 返回 true = 吞掉滚轮/惯性事件（拖播放头期间：别让内容在拖动中自己漂 —— 用户 2026-09-18 报
    /// "滑动之后再拖动会漂移"，惯性还没停就开始拖是最可能来源）。
    /// 用闭包而不是 Bool：大表达式里加 Bool 参数会让编译器类型检查超时
    var suppressScroll: () -> Bool = { false }
    /// 用户手动滚动（滚轮/触控板）时回调 —— 用来**立刻解除缩放锚点**：
    /// 不解除的话，缩放保护期（0.45s）内滚动会被锚点拽回去（"放大后偶尔飘一下"的根因）
    var onUserScroll: () -> Void = {}
    @ViewBuilder var content: () -> Content

    /// 时间轴专用 NSScrollView：**在 `layout()` 里校准文档尺寸/偏移**。
    /// ⚠️ 不能只靠 `updateNSView` + 通知：实测文档高度/`origin.y` 从没被校准过，
    /// 内容被当成"文档高于视口"摆，可视窗口落在下半截（只剩段的下半截角标）。
    /// `layout()` 在每次尺寸变化后都会跑，是唯一可靠的时机。
    final class ScrollView: NSScrollView {
        var onLayout: (() -> Void)?
        var suppressScroll: () -> Bool = { false }
        var onUserScroll: () -> Void = {}
        override func scrollWheel(with event: NSEvent) {
            if suppressScroll() { return }   // 拖动播放头中：滚轮/惯性事件一律丢掉
            onUserScroll()                   // 用户自己滚了：解除缩放锚点，别把他拽回去
            super.scrollWheel(with: event)
        }
        override func layout() {
            super.layout()
            onLayout?()
        }
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: ScrollView?
        var hostingView: NSHostingView<Content>?
        var onOffsetChange: ((CGFloat) -> Void)?
        var contentWidth: CGFloat = 0
        var forcedOffset: CGFloat?
        var suppressScroll: () -> Bool = { false }
        var onUserScroll: () -> Void = {}
        private var lastWidth: CGFloat = -1
        private var lastForced: CGFloat?
        var observer: NSObjectProtocol?

        /// 把文档视图尺寸 + clip 偏移校准到最新状态。
        /// **必须在同一个 CATransaction 里**改文档宽度 + 偏移，并关掉隐式动画 ——
        /// 否则 AppKit 会给这次改动补一段动画，又变成"慢一拍"（用户实测的抖就是这个来源）。
        func syncDocument() {
            guard let scroll = scrollView, let hosting = hostingView else { return }
            let clip = scroll.contentView
            let viewport = clip.bounds.width
            let height = clip.bounds.height
            guard viewport > 0, height > 0 else { return }
            let docWidth = max(contentWidth, viewport)
            let widthChanged = abs(docWidth - lastWidth) > 0.01
            let forcedChanged = lastForced != forcedOffset
            lastWidth = docWidth
            lastForced = forcedOffset

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            // 文档尺寸 = 视口高（时间轴不纵向滚）、内容总宽
            if abs(hosting.frame.width - docWidth) > 0.01 || abs(hosting.frame.height - height) > 0.01 {
                hosting.setFrameSize(NSSize(width: docWidth, height: height))
            }
            // ⚠️ **纵向钉死 0**：documentView 初始高度/坐标系会让 AppKit 把窗口落在下半截
            //（实测：刻度尺和段的上半截全被裁掉，只剩段的下半截角标），每次都校回来
            let targetX: CGFloat
            if let forced = forcedOffset, widthChanged || forcedChanged {
                targetX = min(max(0, forced), max(0, docWidth - viewport))
            } else {
                // ⚠️ **用户滚动/惯性时不要动 x**：滑动会留下 1~3pt 的微小过冲（`-1`、超过末尾 1pt），
                // 原来这里把它夹回合法范围，而拖动播放头开始那次重渲染正好触发校准 →
                // 刻度/分镜"啪"地挪 1~3pt（用户 2026-09-18 实测：日志里 origin=-1→0、5129→5128）。
                // 越界交给 AppKit 自己约束；这里只钉 y（纵向不滚）
                targetX = clip.bounds.origin.x
            }
            // 阈值 0.5pt：亚像素漂移不动（原来 0.01 会把一点点小数误差也"啪"地校正一下）
            if abs(clip.bounds.origin.x - targetX) > 0.5 || abs(clip.bounds.origin.y) > 0.5 {
                AppLog.write("timeline", "syncDocument scroll: origin=\(String(format: "%.2f", clip.bounds.origin.x)),\(String(format: "%.2f", clip.bounds.origin.y)) → \(String(format: "%.2f", targetX)),0 docW=\(String(format: "%.1f", docWidth)) vp=\(String(format: "%.1f", viewport)) forced=\(forcedOffset.map { String(format: "%.1f", $0) } ?? "nil") widthChanged=\(widthChanged) forcedChanged=\(forcedChanged)")
                clip.scroll(to: NSPoint(x: targetX, y: 0))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    /// 视图销毁时摘掉通知观察者（deinit 是 nonisolated，碰不了 @MainActor 的状态）
    static func dismantleNSView(_ nsView: ScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
            coordinator.observer = nil
        }
        nsView.onLayout = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollView {
        let scroll = ScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.verticalScrollElasticity = .none
        // ⚠️ **横向橡皮筋也要关**：只关纵向的话，横向滑动会过冲，而 `syncDocument` 的
        // "夹回合法范围"在拖动开始那次重渲染里跑 → 刻度/分镜整体挪一点（用户 2026-09-18 实测）
        scroll.horizontalScrollElasticity = .none
        scroll.contentView.postsBoundsChangedNotifications = true

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.sizingOptions = []          // 尺寸以 frame 为准（别被 intrinsic size 抢）
        scroll.documentView = hosting

        let coord = context.coordinator
        coord.scrollView = scroll
        coord.hostingView = hosting
        coord.onOffsetChange = onOffsetChange
        coord.contentWidth = contentWidth
        coord.forcedOffset = forcedOffset
        coord.suppressScroll = suppressScroll
        coord.onUserScroll = onUserScroll
        scroll.suppressScroll = suppressScroll
        scroll.onUserScroll = onUserScroll
        scroll.onLayout = { [weak coord] in
            MainActor.assumeIsolated { coord?.syncDocument() }
        }
        coord.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak coord] _ in
            MainActor.assumeIsolated {
                guard let coord, let clip = coord.scrollView?.contentView else { return }
                coord.onOffsetChange?(clip.bounds.origin.x)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: ScrollView, context: Context) {
        let coord = context.coordinator
        coord.onOffsetChange = onOffsetChange
        coord.contentWidth = contentWidth
        coord.forcedOffset = forcedOffset
        coord.suppressScroll = suppressScroll
        coord.onUserScroll = onUserScroll
        scroll.suppressScroll = suppressScroll
        scroll.onUserScroll = onUserScroll
        // 更新 SwiftUI 内容（rootView 赋值走正常 diff，内容里的 @State 会保留）
        coord.hostingView?.rootView = content()
        coord.syncDocument()
    }
}

/// 一格分镜缩略图（缩略图页网格用）：视频首帧（`VideoThumbnailView`，带缓存）+ 编号/时长角标 +
/// 生成中/失败状态；选中时描主题色边框。视觉沿用原时间轴段的角标样式，一眼能对上。
/// 🧪 **实验 11（视频侧）**：卡片标题的唯一口径（格子 / 预载 / 搜索共用）。
/// 2026-09-26 用户定：名字前统一加「分镜」前缀，不然搜的时候不好搜（任务文件名原来是裸的「1-4-7」这种）。
@MainActor
private func shotThumbCellTitle(for shot: ShotDraft, task: LocalTask?, app: AppModel) -> String {
    if let name = task?.fileName, !name.isEmpty { return "分镜\(name)" }
    return app.numbering(of: shot).title   // 本身就是「分镜a-b」
}

/// 🧪 **实验 11（视频侧）**：文字烤图的唯一口径 —— 格子和预载共用，保证缓存键一致。
@MainActor
private func shotThumbCellTextState(shot: ShotDraft, task: LocalTask?, title: String, width: CGFloat) -> ThumbTextState {
    let statusTitle: String = {
        switch task?.phase {
        case .queued?: "排队中"
        case .inProgress?: "生成中"
        case .completed?: "已完成"
        case .failed?: "失败"
        case .paused?: "已暂停"
        case nil: "待生成"
        }
    }()
    let statusColorTag: Int = {
        switch task?.phase {
        case .inProgress?: 1
        case .completed?: 2
        case .failed?: 3
        default: 0
        }
    }()
    var parts: [String] = []
    if !shot.model.isEmpty { parts.append(shot.model) }
    parts.append(shot.resolution.displayName)
    parts.append(shot.aspectRatio.plainLabel)
    parts.append("\(shot.duration) 秒")
    let paramLabel = parts.joined(separator: " · ")
    let draftParamsDiffer: Bool = {
        guard let t = task else { return shot.paramsDirty }
        return shot.model != t.model
            || shot.resolution != t.resolution
            || shot.aspectRatio != t.aspectRatio
            || shot.duration != t.duration
    }()
    return ThumbTextState(
        title: title,
        countText: "\(shot.taskIDs.count) 版",
        statusTitle: statusTitle,
        statusColorTag: statusColorTag,
        paramsText: paramLabel,
        showsParams: task != nil || shot.paramsDirty,
        paramsDirty: draftParamsDiffer,
        width: width
    )
}

struct ShotThumbCell: View, Equatable {
    @Environment(AppModel.self) private var app
    let shot: ShotDraft
    let selected: Bool
    /// 多选（2026-09-26 与生图侧统一）：勾选框常驻视图树，悬停 / 选择模式时显示
    var selectionMode: Bool = false
    var isSelected: Bool = false
    /// 这一格正在悬停播放吗（由网格层从 ThumbVideoPlayback 传入；2026-10-08 起由悬停触发，原来是双击）
    var clickPlaying: Bool = false
    /// 🆕 2026-10-03：播放器出首帧了吗（没出首帧前继续盖着静态图，防"闪黑"）
    var playReady: Bool = false
    /// 🧪 实验 6b：网格层算好的固定格子宽（0 = 还没量到，退回老行为）
    var cellWidth: CGFloat = 0
    var onToggleSelect: () -> Void = {}

    /// ⚠️ `nonisolated`：SwiftUI 的 View 类型是 main-actor 隔离的，`Equatable.==` 是非隔离协议要求
    ///（Swift 6 会报"conformance crosses into main actor"）。只比较 Sendable 的字段即可（同 `CardRowView`）。
    /// 门控的意义（2026-09-27 日志实测）：切样式/切模式时**可见格子不再重算**。
    nonisolated static func == (a: ShotThumbCell, b: ShotThumbCell) -> Bool {
        a.shot == b.shot && a.selected == b.selected
            && a.selectionMode == b.selectionMode && a.isSelected == b.isSelected
            && a.cellWidth == b.cellWidth && a.clickPlaying == b.clickPlaying && a.playReady == b.playReady
    }

    @State private var hovered = false

    /// 🧪 **诊断开关（2026-09-27）**：文字行下线/上线（留作排查用）。
    /// 历史：关掉文字确实更顺 → 一度走"烤图"；后来格子环境改成"固定尺寸 + drawingGroup"后
    /// 实时 Text（`ThumbTextRows`）手感已够，**烤图路线已作废**（详见交接文件）。
    private static let showsTextRows = true
    /// 🧪 **实验 17（2026-09-27，诊断）**：格子内容逐项加回，定位吃时间的那一项。
    /// `0` = 全内容（正常）· `1` = 只缩略图 · `2` = **只文字**（本次）· `3` = 空壳（秃格子）。
    /// 网格 / 滚动 / 尺寸链全不动。验完改回 `0`。
    private static let cellContentMode = 0  // 🧪 本次：全内容（烤图文字）

    private var task: LocalTask? { shot.taskID.flatMap { app.store.task(id: $0) } }
    private var videoPath: String? {
        guard let p = task?.localVideoPath, FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }
    /// 卡片标题（口径见 `shotThumbCellTitle`；🧪 实验 11 起与预载共用）
    private var title: String {
        shotThumbCellTitle(for: shot, task: task, app: app)
    }
    /// 卡片上的生成参数（= 分镜**当前草稿**的：模型 · 分辨率 · 比例 · 时长；空项自动跳过）
    private var paramLabel: String {
        var parts: [String] = []
        if !shot.model.isEmpty { parts.append(shot.model) }
        parts.append(shot.resolution.displayName)
        parts.append(shot.aspectRatio.plainLabel)
        parts.append("\(shot.duration) 秒")
        return parts.joined(separator: " · ")
    }

    /// 草稿参数 ≠ 已提交任务的参数（= 改了还没提交）；0 版看脏标记
    private var draftParamsDiffer: Bool {
        guard let t = task else { return shot.paramsDirty }
        return shot.model != t.model
            || shot.resolution != t.resolution
            || shot.aspectRatio != t.aspectRatio
            || shot.duration != t.duration
    }

    /// 显示参数行的条件：提交过（有任务）或 改过参数
    private var showsParams: Bool { task != nil || shot.paramsDirty }

    /// 🧪 实验 8c：文字烤图的颜色标签（0 = secondary / 1 = orange / 2 = green / 3 = red）
    private var statusColorTag: Int {
        switch task?.phase {
        case .inProgress?: 1
        case .completed?: 2
        case .failed?: 3
        default: 0
        }
    }

    /// 🧪 实验 11：文字行烤图的状态键（**与预载共用同一口径** `shotThumbCellTextState`）
    private var textState: ThumbTextState {
        shotThumbCellTextState(shot: shot, task: task, title: title,
                               width: cellWidth > 0 ? cellWidth : 264)
    }

    var body: some View {
        // 文字在方形内部（见 `thumbnail` 里贴底的 `ThumbTextRows`）——格子只剩一个方形。
        thumbnail
        // 🧪 实验 6b：整格宽度给死（同上）
        .frame(width: cellWidth > 0 ? cellWidth : nil, alignment: .leading)
        .contentShape(Rectangle())
        // 🧪 2026-10-03 性能实验：每卡勾选框已删（每卡控件是滚动卡顿的大头，
        //   选择入口 = 拖框选 / 标题栏「全选」；有选中后单击卡片 = 选中/取消；选中态走卡片描边）
        .onHover { hovering in
            // 滚动中冻结悬停（同生图侧：卡片划过光标反复写状态会让滚动卡）
            guard !app.showLibraryDrawer, !app.showTaskDrawer else {
                if hovered { hovered = false }
                ThumbVideoPlayback.shared.hoverEnded(shotID: shot.id)
                return
            }
            // 滑动中照常响应悬停（2026-10-15 用户：恢复。10-14 为分镜页滑动卡关过，真凶是视频进度重算和滑动换集，见 `WorkbenchBoardProvider` /
            // `ScrolledEpisode`）。悬停播放自己会等滑动停了才起播（见 `ThumbVideoPlayback`）
            if !hovering {
                if hovered { hovered = false }
                ThumbVideoPlayback.shared.hoverEnded(shotID: shot.id)
                return
            }
            hovered = true
            // 🆕 2026-10-08（用户定）：悬停播放（有声、循环；停够一小会儿才起播、滚动中不播、有弹窗 / 预览 / 选择模式时不播）
            if let path = videoPath, !selectionMode, app.activeModal == nil, app.previewingShotID == nil {
                ThumbVideoPlayback.shared.hoverBegan(shotID: shot.id, url: URL(fileURLWithPath: path))
            }
        }
        // 弹窗 / 大窗口预览打开时：悬停播放让位
        .onChange(of: app.activeModal == nil) { _, none in
            if !none { ThumbVideoPlayback.shared.hoverEnded(shotID: shot.id) }
        }
        .onChange(of: app.previewingShotID) { _, id in
            if id != nil { ThumbVideoPlayback.shared.hoverEnded(shotID: shot.id) }
        }
        // 池子里格子会被回收给别的分镜：这一格换了分镜，旧分镜的悬停播放要收掉
        .onChange(of: shot.id) { old, _ in ThumbVideoPlayback.shared.hoverEnded(shotID: old) }
        .onChange(of: app.showLibraryDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        .onChange(of: app.showTaskDrawer) { _, isOpen in
            if isOpen { hovered = false }
        }
        // 🆕 2026-10-03：格子滚出屏幕/被删 → 停播（只停自己）
        .onDisappear { ThumbVideoPlayback.shared.hoverEnded(shotID: shot.id) }
        // 🆕 2026-10-03：播放中**切换版本**（shot.taskID 变了）→ 自动停播；
        //   缩略图立刻回到"新版本"的静态图（不然播放层还顶着旧版本的文件，看着像"没切"）
        .onChange(of: shot.taskID) { _, _ in
            if ThumbVideoPlayback.shared.playingShotID == shot.id { ThumbVideoPlayback.shared.stop() }
        }
    }

    /// 方形缩略图（1:1，与生图卡片一致）：视频**等比内缩**（留边透出 `.insetFill` 底），
    /// 原来的编号/时长角标已挪到下方文字行（2026-09-26 用户定：卡片样式尺寸跟生图侧统一）。
    /// ⚠️ **实验 3（2026-09-27 深夜）验证过：结构归一反而更卡** ✗（同上，已还原）。
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(.insetFill)
            // 🧪 实验 17（诊断）：按 mode 决定格子内容 —— 0 全 / 1 只图 / 2 只文字 / 3 空壳
            if Self.cellContentMode == 3 {
                Color.gray.opacity(0.25)
            } else {
                if Self.cellContentMode != 2 {
                    if clickPlaying {
                        // 🆕 2026-10-08（用户定）：悬停原地播放（有声循环；覆盖静态图，不吃点击）
                        //   🆕 出首帧前**继续盖着静态图**（防"图→黑→视频"的闪）
                        ZStack {
                            ThumbPlayerLayer(player: ThumbVideoPlayback.shared.player)
                                .padding(4)
                                .allowsHitTesting(false)
                            if !playReady, let path = videoPath {
                                VideoThumbnailView(path: path, fitsAspect: true)
                                    .padding(4)
                                    .allowsHitTesting(false)
                            }
                        }
                    } else if let path = videoPath {
                        VideoThumbnailView(path: path, fitsAspect: true)
                            .padding(4)
                    } else if task?.phase == .queued {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                    } else if task?.phase == .inProgress {
                        // 转圈不在这里（见 `.drawingGroup()` 之后的 overlay）：
                        // AppKit 进度指示器被 Metal 光栅化时会被系统「黄方块 + 禁止符」占位图顶替
                        EmptyView()
                    } else if task?.phase == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                    } else {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
                }
                if Self.cellContentMode != 1 {
                    // 文字**放进方形里**（贴底；颜色跟随界面深 / 浅，没有渐变底衬也没有阴影）——默认走"后台烤图"（`BakedThumbText`）；
                    // 诊断模式 2 用实时 Text 对照。都放在 `drawingGroup()` 之前，方形与文字拍成同一张纹理。
                    if Self.showsTextRows {
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
        }
        // 🧪 **实验 6b（2026-09-27）**：尺寸**给死**（网格层已算好固定列宽）——不再每格靠
        // maxWidth/aspectRatio 协商。没量到宽度时退回老行为。
        .frame(width: cellWidth > 0 ? cellWidth : nil,
               height: cellWidth > 0 ? cellWidth : nil)
        .frame(maxWidth: cellWidth > 0 ? nil : .infinity)
        .aspectRatio(1, contentMode: .fit)
        // 🧪 **实验 2（2026-09-27 深夜）**：图块一次栅格化成纹理（同上）。
        // 🎯 2026-09-29 撤掉（用户实测"手感好一点"；原因见生图侧那处注释）。
        // .drawingGroup()
        // 🎨 2026-09-27 用户定（"视频侧也换"）：和生图侧、详情面板统一 ——
        // 进行中不再转圈，改用**环形进度**：有百分比就用真实进度，没有就写 0。
        // ⚠️ 指示器不能放回拍平层（`ProgressView` 被 `drawingGroup()` 光栅化会被系统
        //「黄方块 + 禁止符」占位图顶替；`GenerationProgressView` 是 SwiftUI 自绘的，overlay 安全）。
        .overlay {
            if videoPath == nil, task?.phase == .inProgress {
                GenerationProgressView(progress: task?.progressPercent ?? 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // 勾选高亮（2026-09-26 用户定："选中后高亮"）：蓝色淡底
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.18))
            }
        }
        .overlay {
            // 选中 = 蓝框（右栏正在看的 / 或勾选的高亮）；悬停 = 淡灰框（同生图卡片）
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected || isSelected ? Theme.accent
                              : (hovered ? Color.secondary.opacity(0.45) : Color.clear),
                              lineWidth: selected || isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 旧版：文字在方形**外**（8c 前的样子）——已不在用，仅留对照。
    private var textRowsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 名称 + N 版（同生图卡片：名字在左、版数在右）
            HStack(spacing: 6) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    // 🧪 8a：`.truncationMode(.middle)` 已摘（中间省略每次布局都要测量；默认尾部省略）
                Spacer(minLength: 4)
                Text("\(shot.taskIDs.count) 版")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // 状态行（圆点 + 文案）+ 时长（对应生图侧那一行第三个信息位）
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // 生成参数（模型 · 分辨率 · 比例 · 时长）——与生图侧同一套规则（2026-09-26）：
                // **改过参数还没提交生成 → 蓝色；已按这套提交过 → 灰色；没提交也没改过 → 不显示**
                if showsParams {
                    Text(paramLabel)
                        .font(.caption2)
                        .foregroundStyle(draftParamsDiffer ? Theme.accent : Color.secondary)
                        .lineLimit(1)
                        // 🧪 8a：`.minimumScaleFactor(0.75)` 已摘（装不下要试排缩小，每次布局都算）
                }
            }
        }
        .drawingGroup()
    }

    /// 状态文案（与生图卡片同款口径；0 版 = 待生成）
    private var statusTitle: String {
        switch task?.phase {
        case .queued?: "排队中"
        case .inProgress?: "生成中"
        case .completed?: "已完成"
        case .failed?: "失败"
        case .paused?: "已暂停"
        case nil: "待生成"
        }
    }

    private var statusColor: Color {
        switch task?.phase {
        case .inProgress?: Theme.accent
        case .completed?: Theme.success
        case .failed?: Theme.danger
        default: .secondary
        }
    }
}

/// 视频分镜详情面板（缩略图页右侧，400pt 宽）：直接就是 `ShotDetailCard(usesInspectorLayout: true)`
/// —— 滚动内容 + **钉底提交栏**都在卡片自己的 `inspectorContent()` 里（对齐生图侧 Inspector）。
/// ⚠️ 播放器**不跟时间轴**（`followsTimeline: false`）——播完自动倒回开头并复位；时间轴已下线。
/// ⚠️ 2026-09-27：它挂在 **RootView 的共享右侧栏**里（四页共用、切换不拆建），所以不再是 private。

// 🆕 2026-10-08（用户定）：缩略图**悬停播放**（有声、循环、单实例）；双击改成弹出大窗口播放（见 `AppModel.openShotPreview`）。
// 原来（2026-10-03）是双击原地播放（播完浮出重播 / 访达）。
@MainActor
@Observable
final class ThumbVideoPlayback {
    static let shared = ThumbVideoPlayback()
    /// 悬停停够这么久才起播（划过去不播，停下来才播；同悬停放大预览的口径）
    static let hoverDelay: Duration = .milliseconds(350)

    private(set) var playingShotID: UUID?
    /// 播放器**出首帧了吗**——没出首帧前，格子里继续盖着静态图（防"闪黑"）
    private(set) var isReady = false
    let player = AVPlayer()

    /// 鼠标现在停在哪一格（起播的那一刻要还在这一格才播）
    @ObservationIgnored private var hoveredShotID: UUID?
    /// 等待起播的任务（鼠标离开 / 滚动 / 弹窗出现都会取消它）
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// 网格登记的「光标现在压着哪一格（要有本地视频）」。
    /// **为什么需要它**：悬停是靠 `onHover` 的进入事件触发的，而滚动停下时光标没动 —— 卡片是被滚到光标底下的，
    /// 系统不会再补一个「进入」事件；滚动开始又会清掉悬停状态。所以滚动停下后要自己问一次光标下是哪一格，才能接着播。
    @ObservationIgnored var cursorTarget: (@MainActor () -> (shotID: UUID, url: URL)?)? {
        didSet { if cursorTarget != nil { installScrollMonitorIfNeeded() } }
    }
    /// 等滚动停下、再按光标位置重新起播的任务
    @ObservationIgnored private var rehover: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var scrollMonitor: Any?

    private init() {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // ⚠️ 不把 Notification 带进隔离闭包（Swift 6：发送 note 有数据竞争）
            MainActor.assumeIsolated {
                guard let self, self.playingShotID != nil else { return }
                self.player.seek(to: .zero)       // 循环播放
                self.player.play()
            }
        }
    }

    /// 鼠标进了这一格：停够 `hoverDelay`、且不在滚动，才起播。
    func hoverBegan(shotID: UUID, url: URL) {
        hoveredShotID = shotID
        guard playingShotID != shotID else { return }
        pending?.cancel()
        installScrollMonitorIfNeeded()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            // 滚动中不播（卡片在光标下一格一格划过；滚完还停在这一格才播）
            while !Task.isCancelled, ScrollActivity.shared.isScrolling {
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard let self, !Task.isCancelled, self.hoveredShotID == shotID else { return }
            self.pending = nil
            self.start(shotID: shotID, url: url)
        }
    }

    /// 鼠标离开 / 这一格被回收或滚出屏幕：取消等待，正在播的就是它的话停掉
    func hoverEnded(shotID: UUID) {
        if hoveredShotID == shotID {
            hoveredShotID = nil
            pending?.cancel()
            pending = nil
        }
        if playingShotID == shotID { stop() }
    }

    private func start(shotID: UUID, url: URL) {
        isReady = false
        playingShotID = shotID
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: .zero)
        player.play()
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard playingShotID != nil || player.currentItem != nil else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        playingShotID = nil
        isReady = false
    }

    /// 一开始滚动就停（播放和等待起播都收掉）：光标下的卡片在换，继续播没意义，还抢滚动的资源。
    /// 滚动停下后，如果光标压着一格有视频的卡，就从它重新起播（见 `cursorTarget`）。
    func scrollBegan() {
        hoveredShotID = nil
        stop()
        scheduleRehover()
    }

    private func scheduleRehover() {
        guard cursorTarget != nil, rehover == nil else { return }      // 已经在等了：滚动事件一秒几十个，别重复排
        rehover = Task { @MainActor [weak self] in
            // 等滚动真正停下（含触控板惯性）
            repeat { try? await Task.sleep(for: .milliseconds(120)) } while !Task.isCancelled && ScrollActivity.shared.isScrolling
            guard let self, !Task.isCancelled else { return }
            self.rehover = nil
            if let target = self.cursorTarget?() { self.hoverBegan(shotID: target.shotID, url: target.url) }
        }
    }

    private func installScrollMonitorIfNeeded() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { ThumbVideoPlayback.shared.scrollBegan() }
            return event
        }
    }

    /// 播放层报告"能出画面了"（`AVPlayerLayer.isReadyForDisplay`）→ 撤掉静态图
    func markReady() {
        guard playingShotID != nil, !isReady else { return }
        isReady = true
    }
}

extension AppModel {
    /// 双击视频缩略图：弹出大窗口播放（和生图双击看大图同款）。这一张没有本地视频文件就什么都不做，返回 false。
    @discardableResult
    func openShotPreview(_ shotID: UUID) -> Bool {
        guard let shot = shots.first(where: { $0.id == shotID }),
              let taskID = shot.taskID, let task = store.task(id: taskID),
              let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) else { return false }
        ThumbVideoPlayback.shared.stop()
        previewingShotID = shotID
        return true
    }
}

final class ThumbPlayerNSView: NSView {
    override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
    /// 🆕 2026-10-03：**永远不吃点击**——不然播放中再点同一张卡（想停/切换）会被这层吞掉，
    /// 表现为"点了没反应"（SwiftUI 的 allowsHitTesting(false) 对 representable 的 NSView 不总是生效）
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    /// 🆕 2026-10-03：监听"播放层能出画面了吗"——出画面才让上层撤掉静态图（防闪黑）
    private var readyObs: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        readyObs = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in ThumbVideoPlayback.shared.markReady() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func attach(_ player: AVPlayer) { playerLayer.player = player }
}

struct ThumbPlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> ThumbPlayerNSView {
        let v = ThumbPlayerNSView()
        v.attach(player)
        return v
    }
    func updateNSView(_ v: ThumbPlayerNSView, context: Context) { v.attach(player) }
}

/// 时间轴（2026-09-17）：播放键 + 刻度尺 + 分镜段 + 播放头 + 缩放。
/// 段宽**按时长比例**（空白分镜按 10s）；有视频的段显示首帧 + 时长角标，空白段显示「点此编辑」；
/// 点段 = 选中（详情卡换成它）。播放键由外面驱动（按分镜顺序连播），**播放头可拖动**（scrub）。
private struct ShotTimelineStrip: View {
    @Environment(AppModel.self) private var app

    /// 缩放（1 = 基准；时间轴右侧滑杆调）
    @Binding var zoom: CGFloat
    /// 播放时钟（普通 class：段内进度 + 拖动位置，每帧读、不触发整条重算）
    let clock: TimelineClock
    let isPlaying: Bool
    /// 某分镜在时间轴上的起始秒数（外面算，避免两处口径不一致）
    var shotOffset: (ShotDraft) -> Double
    var onTogglePlay: () -> Void
    /// 拖动播放头（拖动中 / 松手）
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void

    /// 基准比例：每秒多少 pt（乘 `zoom` 才是实际段宽）
    private let baseScale: CGFloat = 6
    /// 时间轴可见宽度（量出来的）——用来算缩放上限
    @State private var availableWidth: CGFloat = 900
    /// 悬停的分镜 / "悬停在其右缘（要在这后面新增）"的分镜
    @State private var hoveredShotID: UUID?
    @State private var lastOffsetLogAt = Date.distantPast
    @State private var hoveredInsertAfterID: UUID?
    /// 横向滚动偏移（**非观察**普通 class：每帧写 @State 会触发重算，项目老教训）
    final class ScrollBox { var x: CGFloat = 0 }
    @State private var scrollBox = ScrollBox()

    /// **段的渲染窗口（2026-09-26）**：只画可视范围 ± 一屏的段。
    /// 全量渲染时，缩放一次要重排 300 段（实测 400-500ms 卡，sample 实锤）。
    /// ⚠️ 窗口不是每帧算的：滚动 x 每帧写 `scrollBox`（非观察），只有"走过半屏"才更新这两个 State。
    /// ⚠️ **刻度尺没有窗口化**（试过，出过"一段没刻度"的 bug，见 `ruler` 的注释）。
    @State private var renderSegmentRange: Range<Int> = 0..<0
    @State private var renderWindowAnchorX: CGFloat = -1
    /// 缩放锚点比例：**播放头在视口里的相对位置**。
    /// - 非 nil（缩放手势中 / 刚缩放完）= **冻结值**：`TimelineScrollContainer.forcedOffset`
    ///   由它和 zoom 算出来，容器在**同一帧**里把偏移设好；
    /// - nil = 不冻结（滚动偏移完全交给用户）。
    @State private var zoomAnchorFraction: CGFloat?
    /// 最后一次"取锚点"的时刻 —— 用于 0.45s 后自动解冻（判断一次连续手势结束）
    final class ZoomTickBox { var last: Date = .distantPast }
    @State private var zoomTick = ZoomTickBox()
    /// 锚点时间：**播放头不在视口里时**改锚"视口中心那条时间线"（见 `captureZoomAnchor`），
    /// 否则为 nil（锚点就是播放头）。存在的原因：forcedOffset 只认一个时间点，
    /// 而"把播放头钳到视口边缘"会让它在缩放时被硬拽进画面（用户 2026-09-18 报）
    @State private var zoomAnchorSeconds: Double?
    /// 滑杆是否还按着（按着期间**不解冻**锚点，哪怕手停了一会儿）
    @State private var isSliderEditing = false

    /// **是否正在拖播放头**（可观察 @State）——`TimelineView.paused` 要读它：
    /// 拖动开始/结束必须触发重渲染，否则 TimelineView 一直 paused → 播放头卡住（用户 2026-09-17 实测）
    @State private var isScrubbing = false


    /// **每段的（起始秒、时长）预计算**（2026-09-17）：原来播放头/刻度每帧都遍历全部分镜、
    /// 每段还查一次任务存储（sample 实锤是卡顿根因）——预计算后每帧只查表。
    @State private var layout: [(id: UUID, offset: Double, duration: Int)] = []
    /// id → 时长（和 `layout` 同一次构建）。段宽/时长角标/胶片条帧分布都走它 ——
    /// **时间轴只有一个时长口径**（预计算缓存）。段用实时查询、播放头用缓存的话，
    /// 两者一旦不同步，段排一套位置、播放头画另一套（2026-09-18 定案）
    @State private var durationByID: [UUID: Int] = [:]

    private func rebuildLayout() {
        var acc = 0
        var out: [(id: UUID, offset: Double, duration: Int)] = []
        var byID: [UUID: Int] = [:]
        for shot in app.currentShots {
            let d = displayDuration(of: shot)
            out.append((shot.id, Double(acc), d))
            byID[shot.id] = d
            acc += d
        }
        layout = out
        durationByID = byID
        updateRenderWindow(x: scrollBox.x, force: true)
    }

    /// 算"段 / 刻度块"的渲染窗口（可视 ± 一屏缓冲）。
    /// 节流：滚动 x 相对上次算窗口的位置没走过**半屏**就直接返回（滚动是每帧回调，不能每帧算/每帧重渲染）。
    private func updateRenderWindow(x: CGFloat, force: Bool = false) {
        let vp = max(240, availableWidth)
        if !force, renderWindowAnchorX >= 0, abs(x - renderWindowAnchorX) < vp / 2 { return }
        renderWindowAnchorX = x
        let lo = max(0, x - vp)
        let hi = x + vp * 2

        // 段：逐段累计宽度找 [lo, hi] 覆盖的下标范围（与 `seconds(atX:)` 同一口径）
        if layout.isEmpty {
            if renderSegmentRange != 0..<0 { renderSegmentRange = 0..<0 }
        } else {
            var first = -1, last = -1
            var start: CGFloat = 0
            for (i, entry) in layout.enumerated() {
                let w = segmentWidth(duration: entry.duration)
                let end = start + w
                if end >= lo, first < 0 { first = i }
                if start <= hi { last = i } else { break }
                start = end + gapWidth
            }
            let range = (first < 0 || last < first) ? 0..<0 : first..<(last + 1)
            if renderSegmentRange != range { renderSegmentRange = range }
        }
    }
    /// 段间距：**只留视觉分隔**（用户 2026-09-17：为了放「＋」留的宽间隙不需要了）
    private let gapWidth: CGFloat = 2
    /// 空白分镜（还没生成出视频）的默认时长（秒）——用户 2026-09-17 定
    private let blankDuration = 10
    /// 段高（2026-09-17）：**跟着时间轴条的实际高度伸缩**（方案 C：条高 = 窗口的 1/3），
    /// 初始 130 只是占位，量到真实高度后由 `onChange` 更新
    @State private var segmentHeight: CGFloat = 130
    /// 刻度尺高度占段高的比例（刻度:分镜条）。⚠️ 改这个值必须同步 `segmentHeight` 的除数
    /// （`1 + rulerRatio`），否则总高超出时间轴区、分镜条底部被裁（2026-09-18 用户实测）。
    private let rulerRatio: CGFloat = 0.22
    // 段宽**不再钳"最小宽度 = 段高"**（旧方案：最小缩放下短分镜是正方形，2026-09-17 定）。
    // ⚠️ 2026-09-18 改：方形钳制会让不同时长的段在缩放时**不同步**（短的被钳住不变、
    // 长的正常缩放），而且刻度尺用的是同一映射 → 刻度也被挤歪。
    // 现在宽度 = 时长 × baseScale × zoom，纯按比例（真时间轴），所有段同比例缩放。

    /// 缩放上限：**15 秒刚好铺满可见宽度**（用户 2026-09-17 定）
    /// 最小缩放：**15 秒的分镜正好露出一整格 16:9 画面**（不裁切）—— 用户 2026-09-18 定。
    /// 段高现在是固定值（时间轴区域高度固定），所以这里直接用实时段高算，窗口大小不影响。
    /// 胶片条一格宽 = 段高 × 16/9（`SegmentFilmstrip.tileWidth`），所以 pps = 格宽 ÷ 15。
    private var minZoom: CGFloat {
        (segmentHeight * 16 / 9) / (15 * baseScale)
    }

    /// 最大缩放：**刻度 1 秒一格**（pps 取 60 留余量），且"最长的那段"的段内画布不超 15600px。
    /// ⚠️ 画布超系统纹理上限（16384px）后系统不再按新尺寸重画 —— 表现为"刻度整体偏移、
    /// 和分镜对不上"（用户 2026-09-18 报的 bug 根因）。
    /// **2026-09-18 改**：刻度尺从"整条一条 Canvas"改成按 7800pt 切多条（见 `ruler`），
    /// 于是总时长不再限制缩放；只剩段内胶片条（每段一条 Canvas）需要看**最长段**。
    /// 旧行为：长项目先撞画布上限，`maxZoom` 被压到 ≤ `minZoom` → 完全缩不进去 ✗。
    private var maxZoom: CGFloat {
        let byStep = 60 / baseScale                                        // pps 60 → 1 秒一格
        let longestSegment = app.currentShots
            .map { Double(max(1, segmentDuration(of: $0))) }.max() ?? 15
        let bySegmentCanvas = 7800 / (CGFloat(longestSegment) * baseScale) // 7800pt = 15600px
        return max(minZoom, min(byStep, bySegmentCanvas))
    }

    var body: some View {
        GeometryReader { geo in
            // 读一下刷新计数：点**已选中**的段时没有别的可观察变化，靠它让整条重算一次
            let _ = app.timelinePlayheadRevision
            VStack(alignment: .leading, spacing: 6) {
                header
                // 自己拿 NSScrollView 的横向容器（为什么不用 SwiftUI 的 ScrollView 见它头上的注释）。
                // `forcedOffset`：缩放期间（锚点比例冻结）把偏移在同一帧里强制到位；
                // 锚点解冻后传 nil，容器就不碰偏移，完全交给用户滚动
                timelineScrollBody
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            // 段高跟着条高伸缩：扣掉 header 24 + 间距 6 + 间距 6，剩下的按 **刻度 : 分镜条 = 15 : 100** 分
            //（刻度尺也跟着等比缩，不再写死 26；用户 2026-09-18）
            .onAppear { segmentHeight = max(60, geo.size.height - 42) / (1 + rulerRatio); rebuildLayout() }
            // 分镜/任务变化时重建预计算（时长来自任务，任务建立/换段才变）
            .onChange(of: app.currentShots) { _, _ in rebuildLayout(); clampZoom() }   // 总长变了 → 最大缩放可能变小
            .onChange(of: totalSeconds) { _, _ in clampZoom() }
            // 任务时长也会变（视频生成完成时写入真实时长）→ 不同步重建的话，
            // 时间轴按旧时长排段、全屏按新时长算位置 —— 播放头/全屏对不上（用户 2026-09-18 报）
            .onChange(of: app.store.tasks) { _, _ in rebuildLayout() }
            .onChange(of: geo.size.height) { _, h in segmentHeight = max(60, h - 42) / (1 + rulerRatio) }
            .onChange(of: geo.frame(in: .global).origin) { old, new in
                AppLog.write("timeline", "时间轴区域位移 \(old.x),\(old.y) → \(new.x),\(new.y)")
            }
            .onAppear {
                segmentHeight = max(60, geo.size.height - 42) / (1 + rulerRatio)
                availableWidth = geo.size.width
                updateRenderWindow(x: scrollBox.x, force: true)
                clampZoom()   // 初始 zoom=1.0 比最小缩放小：开面板就落在"最小档"（15 秒=一整格）
            }
            // 窗口宽度变化 → 更新视口宽（`contentWidth` 靠它把短项目的时间轴铺满整条；
            // 不更新的话改窗口大小后刻度尺会停在旧宽度上）——同时重算渲染窗口
            .onChange(of: geo.size.width) { _, w in
                availableWidth = w
                updateRenderWindow(x: scrollBox.x, force: true)
            }
        }
    }


    /// 缩放锚点要强制到的偏移；**超出可滚范围时返回 nil（本次不强制）**。
    /// 日志实测：播放头在内容末尾附近时，锚点想要 1438.9 但最大只能滚 1388.7 →
    /// 强制的话内容被推到最右，用户看到"刻度和分镜漂一下"（2026-09-18）。
    /// 宁可让播放头位置变一点，也别动内容。
    private func anchorOffsetValue() -> CGFloat? {
        guard let fraction = zoomAnchorFraction else { return nil }
        let viewport = max(1, availableWidth)
        let maxOffset = max(0, contentWidth - viewport)
        let anchorTime = zoomAnchorSeconds ?? playheadSeconds
        let desired = max(0, xPosition(atTime: anchorTime) - fraction * viewport)
        if desired <= maxOffset { return desired }
        AppLog.write("timeline", "锚点超出可滚范围，本次不强制 desired=\(desired) max=\(maxOffset)")
        return nil
    }

    /// 时间轴滚动容器 + 内容（从 `body` 里拆出来：不拆编译器类型检查会超时）
    @ViewBuilder
    private var timelineScrollBody: some View {
        // 拆成局部变量：表达式太长编译器会超时
        let contentWidthValue = contentWidth
        let anchorOffset = anchorOffsetValue()
        TimelineScrollContainer(
            contentWidth: contentWidthValue,
            forcedOffset: anchorOffset,
            onOffsetChange: { x in
                scrollBox.x = x
                updateRenderWindow(x: x)   // 窗口只在"走过半屏"时才挪（内部节流）
            },
            suppressScroll: { clock.scrubbing },
            onUserScroll: { releaseZoomAnchor() }
        ) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ruler
                    // **段窗口化（2026-09-26）**：只渲染可视 ± 一屏（缓冲）的段。
                    // 背景：以前是全量 HStack（用户 2026-09-17 要求"同时渲染"，但 300 段时
                    // 缩放/宽度变化一次要重排全部 → 实测 400-500ms 卡，sample 实锤）。
                    // 现在窗口内仍是"一次渲染到位"（带一屏缓冲，滚动看不到补画），
                    // 远处不预渲染 —— 与生图侧 LazyVStack 同一个思路。
                    windowedSegments
                }

                // 播放头：**每帧重算位置**（TimelineView + 普通 class 时钟 —— 不触发整条时间轴重算）
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: !isPlaying && !isScrubbing)) { _ in
                    playhead
                        // ⚠️ **必须减半个命中框（11）**：播放头内容在 22pt 框里居中，
                        // 只减 5 的话线会画在真实位置右边 6pt —— 表现为"点击后往右跳一点、
                        // 拖到末尾看着靠右"（用户 2026-09-17 实测）
                        .offset(x: xPosition(atTime: playheadSeconds) - 11)
                }
                // ⚠️ **zoom 进 identity**：暂停的 TimelineView 只在"时间线出帧"时重算内容，
                // 缩放变了它不重画 —— 刻度和分镜都缩放了、播放头还钉在旧位置（用户 2026-09-18 报
                // "播放头位置不对/刻度偏移"）。换 identity 强制按新 zoom 重画一次。
                .id(zoom)
            }
            .coordinateSpace(name: "timeline")
            // **整条时间轴任意位置：按住就能拖播放头；单击（distance 0）也走同一条路** ——
            // 只挂播放头太细、还容易被横向滚动抢事件（用户 2026-09-17 实测"拖不动"）
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true   // 触发重渲染 → TimelineView 解除 paused
                            releaseZoomAnchor()  // 用户开始拖播放头：立即解冻，别钉在旧屏幕位置
                        }
                        onScrub(seconds(atX: value.location.x))
                    }
                    .onEnded { value in
                        onScrubEnd(seconds(atX: value.location.x))
                        isScrubbing = false
                        app.timelinePlayheadRevision &+= 1   // 保证松手后播放头按最终位置重画
                    }
            )
            // 内容里的 SwiftUI 视图要拿到 AppModel —— NSHostingView 是新的环境根，
            // 不会自动继承外层 `.environment(app)`（不注入的话段/资产库全空）
            .environment(app)
            // ⚠️ **内容窄于视口时靠左**（缩到最小时总宽只有视口一半，不靠左就被居中，
            // 时间轴跑到屏幕中间去了 —— 用户 2026-09-18 实测）。
            // NSHostingView 的根会按容器尺寸居中，这里显式撑满 + 前导对齐
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // ⚠️ **必须显式撑满**：NSViewRepresentable 没有 intrinsic size，VStack 会给它
        // 一个几乎为 0 的高度（实测：时间轴被裁得只剩几条时长角标）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 缩放锚点（用户 2026-09-17）：**播放头在屏幕上的位置不变**。
        // 比例在改 zoom 之前冻结（`captureZoomAnchor`），偏移由容器在同一帧强制到位；
        // 这里只管兜底取锚点 + 0.45s 后解冻（解冻后偏移交给用户滚动）
        .onChange(of: zoom) { _, _ in
            if zoomAnchorFraction == nil { captureZoomAnchor() }   // 兜底：手势开始时没取到
            scheduleAnchorRelease()
            updateRenderWindow(x: scrollBox.x, force: true)        // 缩放改了段宽 → 渲染窗口要重算
        }
    }

    /// 偏移变化诊断（节流 0.2s；临时）：排查"滑动后拖动偶尔漂移"
    private func noteOffsetChange(_ x: CGFloat) {
        let now = Date()
        guard now.timeIntervalSince(lastOffsetLogAt) > 0.2 else { return }
        lastOffsetLogAt = now
        AppLog.write("timeline", "偏移变化 \(scrollBox.x) → \(x) scrubbing=\(clock.scrubbing)")
    }

    /// 缩放前调一次：把**播放头在视口里的相对位置**冻结下来（容器会用它
    /// 和新的 zoom 算出该滚到哪里）。必须在改 zoom **之前**调 —— 那时布局和 `scrollBox.x`
    /// 还是同一口径的静止状态，取到的比例才是真的。
    /// 播放头在视口外时夹到 0/1（缩放后贴住对应边缘）。
    private func captureZoomAnchor() {
        // 锚播放头：缩放时**它在屏幕上不动**（内容会跟着滑 —— 用户 2026-09-17 验证过的手感）。
        // ⚠️ 用户手动滚动（滚轮/触控板）会立刻解除锚点（见容器 `onUserScroll`）：
        // 不解除的话，滚动会被锚点拽回它算的位置 —— 那就是"放大后偶尔飘一下"（用户 2026-09-18）
        let viewport = max(1, availableWidth)
        let playheadX = xPosition(atTime: playheadSeconds)
        let raw = (playheadX - scrollBox.x) / viewport
        if raw < 0 || raw > 1 {
            // 播放头在视口外：锚视口中心那条时间线，别为了"钉住播放头"把它拽进画面
            zoomAnchorSeconds = seconds(atX: scrollBox.x + viewport / 2)
            zoomAnchorFraction = 0.5
        } else {
            zoomAnchorSeconds = nil
            zoomAnchorFraction = raw
        }
        scheduleAnchorRelease()
    }

    /// 一次连续缩放结束后 0.45s **自动解冻**锚点比例，把滚动位置交还给用户滚动
    /// （用时间戳比较而不是取消定时器：期间每次取锚点/每次 zoom 变化都会续期，最后那次生效）
    private func scheduleAnchorRelease() {
        guard !isSliderEditing else { return }   // 滑杆还按着：这次手势没结束
        let stamp = Date()
        zoomTick.last = stamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if zoomTick.last == stamp { zoomAnchorFraction = nil }
        }
    }

    private func clampZoom() {
        let target = min(max(minZoom, zoom), maxZoom)
        guard target != zoom else { return }
        captureZoomAnchor()   // 窗口变宽也会改 zoom：先冻结锚点，别让它从左边缩
        zoom = target
    }

    // MARK: 头部：播放键（居中）+ 缩放（右）

    private var header: some View {
        ZStack {
            // 左侧：**当前播放头时间 | 总时长**（实时跟播放头走；用户 2026-09-17 要求）
            HStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                        paused: !isPlaying && !isScrubbing)) { _ in
                    Text("\(timeLabel(Int(playheadSeconds.rounded()))) | \(timeLabel(totalSeconds))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button {
                onTogglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 40, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverHighlightButtonStyle())
            .help(isPlaying ? "暂停" : "按分镜顺序播放")

            HStack {
                Spacer()
                HStack(spacing: 4) {
                    // − / ＋ 是**能点的按钮**（原来只是两个图标，用户实测点不动）
                    Button {
                        // 离散一步：改 zoom 前先冻结锚点（此刻滚动是静止的，取的是真实值）
                        captureZoomAnchor()
                        zoom = max(minZoom, zoom / 1.25)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverHighlightButtonStyle(expandX: 0, expandY: 0))
                    .help("缩小时间轴")

                    // 缩放**实时**生效（用户 2026-09-17：放大缩小要实时，帧跟着加/减）
                    // ⚠️ 锚点必须在**按下（还没改 zoom）时**冻结：改完再取的话，那一帧布局已经是
                    // 新宽度、`scrollBox.x` 还是旧位置，两者不同口径 —— 播放头会先错一帧（用户实测抖）。
                    Slider(value: $zoom, in: minZoom...maxZoom, onEditingChanged: { editing in
                        isSliderEditing = editing
                        if editing { captureZoomAnchor() } else { scheduleAnchorRelease() }
                    })
                    .frame(width: 140)
                    .controlSize(.small)

                    Button {
                        captureZoomAnchor()
                        zoom = min(maxZoom, zoom * 1.25)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverHighlightButtonStyle(expandX: 0, expandY: 0))
                    .help("放大时间轴（最大 = 15 秒铺满）")
                }
            }
        }
        .frame(height: 24)
    }

    // MARK: 播放头（可拖动）

    private var playhead: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.accent)
                // 头加长（用户 2026-09-18："头的有点小，做长一点"）：12 → 18（26 试过太长，回退）
                .frame(width: 10, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1)
                )
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 1.5, height: segmentHeight + 20)
        }
        // 不吃事件：拖动统一由外层时间轴的手势处理（这样任意位置按住都能拖）
        .frame(width: 22)
        .allowsHitTesting(false)
    }

    /// 立即解冻缩放锚点（用户开始**点/拖播放头**时用）。
    /// ⚠️ 不做的话：0.45s 解冻窗口内播放头被 overlay 钉在旧屏幕位置 —— 用户点分镜
    /// "播放头过一会才过去"（2026-09-18 实测）。把 `zoomTick.last` 刷新一下，
    /// 让已经排队的解冻定时器失效（它按时间戳判断"是不是最后一次"）。
    private func releaseZoomAnchor() {
        guard zoomAnchorFraction != nil else { return }
        zoomTick.last = Date()
        zoomAnchorFraction = nil
    }

    /// 播放头当前秒数：拖动中 → 拖动位置；否则 → 段首 + **段内进度（不播时也保留）** ——
    /// 用户 2026-09-17 实测："松手后被吸回段首"就是因为不播时没算段内进度
    private var playheadSeconds: Double {
        // 唯一真值就是 clock.playhead（全片秒数）；夹一下是防"删段后全局秒数还落在旧范围外"
        min(max(0, clock.playhead), Double(totalSeconds))
    }

    // MARK: 尺寸/位置（唯一来源：逐段累计）

    /// 段时长（2026-09-17 用户定）：**用任务里提交时的时长**——改时长草稿不会带着时间轴变，
    /// 提交生成之后才变；还没提交（没有任务）的空白段固定 10s（正方形）
    private func displayDuration(of shot: ShotDraft) -> Int {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID) else { return blankDuration }
        return max(1, task.duration)
    }

    private func localVideoPath(of shot: ShotDraft) -> String? {
        guard let taskID = shot.taskID, let task = app.store.task(id: taskID),
              let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// 段时长：**只认预计算缓存**（和播放头/刻度同一口径）；缓存还没建好（首帧）时实时查一次
    private func segmentDuration(of shot: ShotDraft) -> Int {
        durationByID[shot.id] ?? displayDuration(of: shot)
    }

    private func segmentWidth(of shot: ShotDraft) -> CGFloat {
        segmentWidth(duration: segmentDuration(of: shot))
    }

    /// 按**预计算的时长**算宽度（每帧调用路径上不能再去查任务存储）
    private func segmentWidth(duration: Int) -> CGFloat {
        CGFloat(duration) * baseScale * zoom
    }

    private var totalWidth: CGFloat {
        guard !layout.isEmpty else {   // 首帧兜底（onAppear 还没跑）
            let count = app.currentShots.count
            let segments = app.currentShots.reduce(CGFloat(0)) { $0 + segmentWidth(of: $1) }
            return segments + CGFloat(max(0, count - 1)) * gapWidth
        }
        let segments = layout.reduce(CGFloat(0)) { $0 + segmentWidth(duration: $1.duration) }
        return segments + CGFloat(max(0, layout.count - 1)) * gapWidth
    }

    private var totalSeconds: Int {
        guard let last = layout.last else {   // 首帧兜底
            return app.currentShots.reduce(0) { $0 + displayDuration(of: $1) }
        }
        return Int(last.offset) + last.duration
    }

    /// 时间轴**内容宽度**：总时长宽与**视口宽**取大（下限 240）——
    /// 短项目也要铺满整条时间轴，否则"只有分镜那截有刻度、右边全空"
    /// （2026-09-19 用户实测："只有一个分镜的时候……只有这个分镜的地方有刻度"）。
    private var contentWidth: CGFloat {
        max(totalWidth, 240, availableWidth)
    }

    /// 时刻 `t`（秒）对应的 x —— 逐段累计（含段间距；宽度纯按比例后其实就是 `t × scale`，
    /// 保留逐段实现是为了和 `rebuildLayout`/`seconds(atX:)` 共用同一口径）
    ///
    /// `t` 超出总时长（刻度尺会画到视口右缘之外的部分）→ 按 pps **继续外推**：
    /// 不这么做的话所有超出的刻度都会落在终点同一个 x 上，挤成一根竖线。
    private func xPosition(atTime t: Double, zoom zoomOverride: CGFloat? = nil) -> CGFloat {
        let z = zoomOverride ?? zoom
        var x: CGFloat = 0
        for entry in layout {
            let d = Double(entry.duration)
            let w = CGFloat(entry.duration) * baseScale * z
            if t <= entry.offset + d {
                let frac = d > 0 ? CGFloat((t - entry.offset) / d) : 0
                return x + w * frac
            }
            x += w + gapWidth
        }
        let overshoot = t - Double(totalSeconds)
        return x + CGFloat(max(0, overshoot)) * baseScale * z
    }

    /// x → 秒（`xPosition` 的反函数，拖动播放头用）
    private func seconds(atX x: CGFloat) -> Double {
        var cursor: CGFloat = 0
        for entry in layout {
            let d = Double(entry.duration)
            let w = segmentWidth(duration: entry.duration)
            if x <= cursor + w {
                let frac = w > 0 ? Double((x - cursor) / w) : 0
                return max(0, entry.offset + frac * d)   // 往左拖过头 → 夹到 0
            }
            cursor += w + gapWidth
        }
        return layout.last.map { $0.offset + Double($0.duration) } ?? 0
    }

    /// 刻度间隔（秒）：**随缩放自适应**——标签之间至少 80pt，选最小档
    /// （放大后按 1s/2s 显示，用户 2026-09-17 要求"拖动滑块要按秒显示"）
    private var tickStep: Int {
        let pxPerSecond = baseScale * zoom
        // 从最小档往上找：**标签放得下就停**（密度优先）。
        // ⚠️ 2026-09-19 去掉原来的"至少 4 个刻度"上限（`totalSeconds / 4`）：
        // 短项目 + 小缩放时它会把档位压得比密度允许的更小 → 标签互相叠着"挤在一块"（用户实测）。
        // 现在刻度尺铺满整条（见 `contentWidth`），短项目也不会显得空，不需要再靠小档位凑数量。
        //
        // ⚠️ **阈值 56 → 80**（2026-09-19 二次修）：56pt 是按"标签宽度"估的，但 `01:35` 这种
        // 5 字符标签实际就 40+pt，只剩十几 pt 空隙 —— 用户实测"01:35 和 01:40 贴在一起"。
        // 80pt = 标签 + 一个明显空位，读起来才不挤。
        var chosen = 1
        for s in [1, 2, 5, 10, 15, 30, 60, 120, 300] {
            chosen = s
            if CGFloat(s) * pxPerSecond >= 80 { break }
        }
        return chosen
    }

    /// 刻度尺：大刻度（`tickStep` 秒，带时间标签）+ **大刻度之间的小刻度**（10 等分）。
    /// 例：最小缩放时 00:00–00:10 之间 9 根短的（每 1 秒一根）；最大缩放 00:00–00:02 同理（2026-09-17 用户要求）。
    /// 小刻度太密（间距 < 4pt）时自动不画。
    /// 刻度尺的**单块 Canvas**（按 7800pt 切块，防止超纹理上限——原文见下）。
    /// 块由 `ruler` 按 7800pt 步进全量摆放；刻度位置统一用全局 `xPosition` 再减去本块原点，跨块对得上。
    private func rulerChunk(_ ci: Int, chunkW: CGFloat, total: CGFloat) -> some View {
        let originX = CGFloat(ci) * chunkW
        // ⚠️ **同步绘制**（2026-09-26 改）：原来是 `rendersAsynchronously: true`，实测出
        // "有一段没刻度、放大才出现"——每次渲染更新（滚动/缩放都会走 NSHostingView 换 rootView）
        // 画布的重绘被丢到后台，后台那次被推迟时画布就是**空白**，直到下一次缩放才补上。
        // 刻度的绘制本身很轻（只有线和少量文字），同步画不会拖慢滚动。
        return Canvas { ctx, size in
            let major = Double(tickStep)
            let minor = major / 10
            let pxPerSecond = baseScale * zoom
            let drawMinors = CGFloat(minor) * pxPerSecond >= 4
            let startT = Double(originX) / Double(pxPerSecond)
            let endT = Double(originX + size.width) / Double(pxPerSecond)
            // 从"本段起点所在的小格"开始，保证刻度和全局网格对齐（大刻度落在整倍数上）
            var t = (startT / minor).rounded(.down) * minor
            while t <= endT + 0.0001 {
                defer { t += drawMinors ? minor : major }
                // 只按**本段画布范围**裁剪（不再卡在总时长上）：短项目时刻度也要铺满整条
                //（超出总时长的位置由 `xPosition` 外推）——2026-09-19 用户实测要求
                guard t >= startT - 0.0001, t <= endT + 0.0001 else { continue }
                let x = xPosition(atTime: t) - originX
                let rem = t.truncatingRemainder(dividingBy: major)
                let isMajor = rem < 0.0001 || major - rem < 0.0001
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - (isMajor ? size.height * 0.38 : size.height * 0.19)))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.45 : 0.28)), lineWidth: 1)
                if isMajor {
                    // 标签默认画在刻度右侧；**右边放不下就画到左侧**（否则被 Canvas 边界裁掉，只剩个"0"）
                    // 边界判断用**整条总宽**（不是本条宽度），避免条与条交界处标签跳到左边
                    let label = ctx.resolve(Text(timeLabel(Int(t.rounded())))
                        .font(.system(size: max(7, size.height * 0.45))).foregroundStyle(.secondary))
                    let labelSize = label.measure(in: CGSize(width: 400, height: 20))
                    let overflowRight = xPosition(atTime: t) + 3 + labelSize.width > total
                    ctx.draw(label,
                             at: CGPoint(x: overflowRight ? x - 3 : x + 3, y: 0),
                             anchor: overflowRight ? .topTrailing : .topLeading)
                }
            }
        }
        .frame(width: min(chunkW, total - originX), height: segmentHeight * rulerRatio)  // 刻度尺高度跟段高等比（用户 2026-09-18 逐步调：15 → 20 → 25 → 22）
    }

    /// 刻度尺：**全量渲染**（2026-09-26 晚改回来）。
    ///
    /// ⚠️ 昨天试过"只渲染可视范围的块"，出了 bug（用户实测："有一段没刻度，放大才出现"）：
    /// 刻度 x 是按「段累计宽度 + 每段 2pt 间隙」算的，而块的裁剪边界用的是 `originX/pps`（没算间隙）
    /// → 每块左边缘 ~累计间隙 那一段的刻度被裁掉；再加上画布是异步栅格化、块被移进移出会留白。
    /// **刻度本身不是性能大头**（zoom 采样里只占 ~3%，大头是段的布局），所以退回全量渲染保稳。
    /// 要再窗口化的话：① 裁剪边界把间隙算进去（`originX - 累计间隙`）② 别让块跟着滚动增删。
    private var ruler: some View {
        let chunkW: CGFloat = 7800
        let total = contentWidth
        let chunkCount = max(1, Int(ceil(total / chunkW)))
        return ZStack(alignment: .topLeading) {
            // 占位：保证内容宽度 = 文档宽度（容器按 `contentWidth` 设 frame；刻度/段的 x 都以它为基准）
            Color.clear.frame(width: total, height: segmentHeight * rulerRatio)
            ForEach(0..<chunkCount, id: \.self) { ci in
                rulerChunk(ci, chunkW: chunkW, total: total)
                    .offset(x: CGFloat(ci) * chunkW)
            }
        }
    }

    /// 段（**窗口化**）：只渲染窗口内的段，按精确 x 摆放；等宽占位撑住文档宽度。
    /// 与刻度尺同理——全量渲染时缩放/重建一次要重排 300 段（400-500ms 卡）。
    /// ⚠️ 窗口带一屏缓冲：可视范围内永远是"全部已渲染"，不会出现当年 LazyHStack 的逐个补画。
    private var windowedSegments: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: contentWidth, height: segmentHeight)
            ForEach(Array(renderSegmentRange), id: \.self) { i in
                if i < app.currentShots.count {
                    segment(app.currentShots[i])
                        .offset(x: segmentX(at: i))
                }
            }
        }
    }

    /// 第 i 段的左缘 x（含段间距）——与 `seconds(atX:)` / `xPosition` 同一口径（逐段累计）
    private func segmentX(at index: Int) -> CGFloat {
        var x: CGFloat = 0
        for j in 0..<index where j < layout.count {
            x += segmentWidth(duration: layout[j].duration) + gapWidth
        }
        return x
    }

    private func timeLabel(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// 段标题 = **这一段实际挂着的视频自己的编号**（文件名「1-1-9」）——用户 2026-09-18 要求：
    /// 标签跟着视频走、不跟分镜编号走。这样某段要是挂错了别的视频，标签会直接把那个视频的编号显示出来
    /// （比如分镜1-1 上显示 1-3-2 = 挂错了），一眼能看出来。
    private func videoLabel(of shot: ShotDraft) -> String {
        guard let id = shot.taskID, let task = app.store.task(id: id) else {
            return app.numbering(of: shot).filePrefix   // 空白段（还没视频）：显示分镜编号
        }
        if let name = task.fileName, !name.isEmpty { return name }
        return app.numbering(of: shot).filePrefix + "-\((shot.taskIDs.firstIndex(of: id) ?? 0) + 1)"
    }

    /// 一段分镜：点 = 选中（播放头位置由外层手势统一给）；
    /// **悬停右上角出垃圾桶** → 删这一镜（用户 2026-09-17 要求）
    private func segment(_ shot: ShotDraft) -> some View {
        let selected = (app.timelineShotID ?? app.currentShots.first?.id) == shot.id
        let width = segmentWidth(of: shot)
        let hovered = hoveredShotID == shot.id
        return ZStack(alignment: .topLeading) {
            Group {
                if let path = localVideoPath(of: shot) {
                    // **胶片条**：按宽度铺 N 格、每格一帧（缩放越大格越多）——用户 2026-09-17 要求。
                    // 时长用**缓存口径**（= 视频实际时长），别用 `shot.duration`：那是可编辑的草稿时长，
                    // 改过草稿后帧分布会和段宽对不上
                    SegmentFilmstrip(path: path, duration: Double(max(1, segmentDuration(of: shot))),
                                     width: width, height: segmentHeight)
                        // 换历史版本会改视频路径；重建胶片条以清空旧首/尾帧 @State，避免新首帧混旧尾帧。
                        .id(path)
                } else if let task = shot.taskID.flatMap({ app.store.task(id: $0) }),
                          task.phase == .queued || task.phase == .inProgress {
                    // **生成中/排队中**（2026-09-18 用户要求）：新增分镜提交后，段内要显示进度，
                    // 而不是"点此编辑"（那是空段的样式，会让人以为没提交上）。
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.insetFill)
                        .overlay {
                            VStack(spacing: 4) {
                                if task.phase == .queued {
                                    Image(systemName: "clock.badge.questionmark")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                    Text(task.queuePosition.map { "排队 · 第\($0)位" } ?? "排队中")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                } else if let p = task.progressPercent {
                                    Text("\(Int(p))%")
                                        .font(.system(size: 12, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("生成中")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .lineLimit(1)              // 窄段（最小缩放）别折成竖排
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 2)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.insetFill)
                        .overlay {
                            // 2026-09-19 用户要求：空段的占位文案从「点此编辑」改成「暂无内容」
                            //（与卡片里预览区的空状态文案一致）
                            Text("暂无内容")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)              // 窄段（最小缩放）别折成竖排
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 2)
                        }
                }
            }
            .frame(width: width, height: segmentHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // **拍平成一张纹理**（2026-09-17）：段里是 N 格胶片，滚动时逐格重画很贵；
            // 拍平后滚动只搬纹理（同"提示词块 drawingGroup"那条先例）。
            // ⚠️ 只拍平内容（角标/选中描边在外面，保持实时）；段内没有材质，安全。
            .drawingGroup()
            .overlay(alignment: .bottomLeading) {
                Text(timeLabel(segmentDuration(of: shot)))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)              // 最小缩放时 10 秒段只有 30pt 宽：不缩就竖排换行
                    .minimumScaleFactor(0.45)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            // 点击：**选中 + 播放头按点击位置定位**（外层手势不再覆盖这里，见它改成 `.gesture` 的说明）
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("timeline"))
                    .onEnded { value in
                        AppLog.write("timeline", "点段选中 \(app.numbering(of: shot).title)")
                        releaseZoomAnchor()   // 点段要播放头**立刻**跟过去，别等 0.45s 解冻
                        app.timelineShotID = shot.id
                        let t = seconds(atX: value.location.x)
                        onScrub(t)
                        onScrubEnd(t)
                        // ⚠️ 必须 +1：`clock` 不是观察对象，点已选中的段时没有任何可观察变化，
                        // 不加的话播放头/头部时间不会重算（2026-09-18 实测"点完播放头没动"）
                        app.timelinePlayheadRevision &+= 1
                    }
            )

            // 段标题 = 视频自己的编号（见 `videoLabel`）
            Text(videoLabel(of: shot))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)   // 段窄了标题会折成两行，很丑
                .minimumScaleFactor(0.55)
                .padding(.horizontal, width < 76 ? 3 : 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.5)))
                .padding(4)
        }
        .frame(width: width, height: segmentHeight, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button {
                    AppLog.write("timeline", "删除分镜（弹确认） \(app.numbering(of: shot).title)")
                    app.activeModal = .confirmDeleteShot(shotID: shot.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(QuietButtonStyle(hover: .none))
                .help("删除这个分镜")
                .padding(4)
            }
        }
        // 「＋」新增分镜：贴在**右缘交界处**（半跨在下一段上，不占间隙）
        .overlay(alignment: .trailing) {
            if hoveredInsertAfterID == shot.id {
                Button {
                    AppLog.write("timeline", "右缘插入 → after \(app.numbering(of: shot).title)")
                    app.insertShot(after: shot.id)
                    if let idx = app.currentShots.firstIndex(where: { $0.id == shot.id }),
                       idx + 1 < app.currentShots.count {
                        let newShot = app.currentShots[idx + 1]
                        app.timelineShotID = newShot.id
                        clock.playhead = shotOffset(newShot)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Theme.accent))
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(QuietButtonStyle(hover: .none))
                .help("在这后面新增分镜")
                .offset(x: 9)
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            // 滚动中不更新悬停（同卡片列表的 ScrollActivity 解法）：滑动时鼠标一直压在段上，
            // 每帧写 @State 会让整条时间轴反复重算 —— 放大后段多、更明显（用户 2026-09-18）
            guard !ScrollActivity.shared.isScrolling else { return }
            switch phase {
            case .active(let p):
                // **变了才写**（悬停回调很频繁，重复写状态会白白重算——项目老经验）
                if hoveredShotID != shot.id { hoveredShotID = shot.id }
                let insert = (p.x > width - 16 && app.canInsertShot(after: shot)) ? shot.id : nil
                if hoveredInsertAfterID != insert { hoveredInsertAfterID = insert }
            case .ended:
                if hoveredShotID == shot.id { hoveredShotID = nil }
                if hoveredInsertAfterID == shot.id { hoveredInsertAfterID = nil }
            }
        }
    }
}


/// 分镜列表中的单卡：提示词按内容展开，参数与操作排在下方。
struct ShotCardView: View {
    @Environment(AppModel.self) private var app
    @Binding var shot: ShotDraft
    /// ⚠️ 当前没用到（渲染走 `app.numbering(of:)`）。留着是为了不动 `cardList` 那边的调用签名
    let index: Int

    /// 占位播放时钟。**卡片区没有播放器了**（2026-09-23 用户："把视频侧卡片区的播放器删了"），
    /// 但 `ShotDetailCard` 的接口里有这个参数 —— 统一给一个**从不被读写**的静态实例，
    /// 免得每张卡的 body 重算都新建一个对象。
    /// ⚠️ 绝不能拿全局 `app.timelineClock` 顶上 —— 那是时间轴的播放头
    private static let placeholderClock = TimelineClock()

    init(shot: Binding<ShotDraft>, index: Int) {
        _shot = shot
        self.index = index
    }

    var body: some View {
        // 🧪 **诊断探针（临时）**：统计 body 重算次数，由看门狗每秒汇总一条日志。
        // （不用 `_printChanges()`：它在 release 构建里不输出。详见 BodyEvalCounter 的注释。）
        let _ = BodyEvalCounter.bump("ShotCardView")
        ShotDetailCard(
            shot: $shot,
            // ⚠️ 下面这组播放相关的参数**是占位值**：`showsPreview: false` 意味着
            // 播放器那一栏整栏不渲染，这些一次都不会被读到（写也只写进 `.constant`，落地即丢）
            isPlaying: .constant(false),
            clock: Self.placeholderClock,
            shotOffset: 0,
            onTogglePlay: {},
            onToggleFullscreen: {},
            followsTimeline: false,
            showsDelete: true,
            // **卡片区不显示播放器**（用户 2026-09-23）—— 一页 5 张卡就是 5 个播放器，太重；
            // 播放统一在缩略图视图里做。因此卡片上也没有「悬停浮出的访达 / 全屏」入口
            showsPreview: false,
            usesFlexibleCardLayout: true
        )
    }
}

/// 素材区（分镜「编辑提示词」弹窗 与 图片「编辑提示词」弹窗 共用）：
/// 添加 / [自动匹配] / 清空素材 + 素材 chips（删除、图片角色循环）+ 拖入素材库条目。
///
/// **与宿主解耦**：不再认 `shotID`，只收「已解析的 refs + 一组动作闭包」。
/// 分镜（`ShotDraft`）和图片条目（`ImageGenItem`）的数据结构不同，增删改各写各的数据层，
/// 由调用方负责取数据与写回。
/// **⚠️ refs 必须传「实时」数据**，不能传打开弹窗时的快照——否则增删素材后 chip 缩略图不刷新
/// （`EditPromptSheet` 踩过这个坑，见它 `slotItems` 的注释）。
/// 🆕 2026-10-03（用户定）：编辑弹窗素材条的**一格**（32pt 固定高，防空/满状态跳动）
/// 缩略图 + 名称；**点击 = 看大图**（复用素材库预览浮层）、**悬停出叉号 = 删除**（保留原 token 清理口径）。
/// 设计参照 8894d5a「素材 Chip 精简：缩略图+名称、32pt 固定高」。
struct MaterialStripCell: View {
    @Environment(AppModel.self) private var app
    let item: LibraryItem
    var fallbackName: String = "素材"
    let onDelete: () -> Void
    var role: ReferenceImageRole? = nil
    var onCycleRole: (() -> Void)? = nil

    @State private var hovered = false

    private var name: String { item.matchName ?? item.fileName ?? fallbackName }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                app.previewingLibraryItemID = item.id   // 点击看大图
            } label: {
                HStack(spacing: 6) {
                    miniThumb
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary.opacity(0.9))
                        .frame(maxWidth: 110, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle(hover: .none))
            .help("点击看大图")

            // 🆕 2026-10-03（用户定）：徽章 = **类型**（图片/视频/音频）——沿用我们素材条老口径；
            // 不是 8894d5a 那个「参考/首帧/尾帧」角色徽章（角色循环入口早已按约定去掉）
            Text(kindLabel)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(hovered ? Color.secondary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(QuietButtonStyle(hover: .none))
            .help("从条目中移除此素材")
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
        .onHover { hovered = $0 }
    }

    private var kindLabel: String {
        switch item.kind {
        case .image: "图片"
        case .video: "视频"
        case .audio: "音频"
        }
    }

    @ViewBuilder
    private var miniThumb: some View {
        if let url = item.existingLocalImageURL {
            AsyncThumbImage(path: url.path)
        } else {
            switch item.kind {
            case .image: Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(.tertiary)
            case .video: Image(systemName: "video").font(.system(size: 11)).foregroundStyle(.tertiary)
            case .audio: Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct MaterialSection: View {
    @Environment(AppModel.self) private var app

    var imageRefs: [MaterialRef] = []
    var videoRefs: [MaterialRef] = []
    var audioRefs: [MaterialRef] = []

    /// 「自动匹配」按钮是否显示。分镜有（按素材名扫提示词）；**图片没有**——
    /// 生图提示词是短句手写的，按素材名匹配命中率低，用户明确要求去掉。
    var showsAutoMatch: Bool = true

    /// 标题换成分类标签「全部 (N) / 图片 / 视频 / 音频」，点哪类只看哪类（2026-10-30 用户：数素材得一个个数）。
    /// 只有分镜开：生图条目一般就两三张图，用不上
    var showsTypeTabs: Bool = false

    /// 空态提示文案（图片条目只接受图片，文案与分镜不同）
    var emptyHint: String = "从素材库添加图片 / 视频 / 音频，提示词用 @ 引用"

    /// 打开素材选择弹窗
    var onAdd: () -> Void
    /// 删素材：(refID, token 前缀, 序号 1-based)。调用方负责删数据层 + 清理自己那边的 token
    var onRemove: ((_ refID: UUID, _ tokenPrefix: String, _ index: Int) -> Void)? = nil
    var onAutoMatch: (() -> Void)? = nil
    var onClear: (() -> Void)? = nil
    /// 传 nil 则不显示图片角色徽章（图片条目就是这样——首尾帧是视频模型的语义，生图用不上）
    var onCycleRole: ((_ refID: UUID) -> Void)? = nil
    /// 拖入素材库条目
    var onDrop: (UUID) -> Void

    enum TypeFilter: Hashable { case all, image, video, audio }
    @State private var typeFilter: TypeFilter = .all

    private var isEmpty: Bool { imageRefs.isEmpty && videoRefs.isEmpty && audioRefs.isEmpty }

    /// 标签上的个数：0 个不写括号（和参考图一样）
    static func tabLabel(_ name: String, count: Int) -> String { count > 0 ? "\(name) (\(count))" : name }

    private var typeTabs: [(label: String, value: TypeFilter)] {
        [(Self.tabLabel("全部", count: imageRefs.count + videoRefs.count + audioRefs.count), .all),
         (Self.tabLabel("图片", count: imageRefs.count), .image),
         (Self.tabLabel("视频", count: videoRefs.count), .video),
         (Self.tabLabel("音频", count: audioRefs.count), .audio)]
    }

    private func shows(_ kind: TypeFilter) -> Bool { !showsTypeTabs || typeFilter == .all || typeFilter == kind }

    /// 选中的那类一个都没有（比如切到「视频」）
    private var filteredEmpty: Bool {
        switch showsTypeTabs ? typeFilter : .all {
        case .all: isEmpty
        case .image: imageRefs.isEmpty
        case .video: videoRefs.isEmpty
        case .audio: audioRefs.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsTypeTabs {
                    SegmentedBar(options: typeTabs, selection: $typeFilter)
                        .frame(width: 280)
                        .accessibilityIdentifier("material-type-tabs")
                } else {
                    Text("素材").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Button(action: onAdd) {
                    Label("添加", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(OutlineButtonStyle())
                .controlSize(.small)
                if showsAutoMatch {
                    Button { onAutoMatch?() } label: {
                        Label("自动匹配", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .controlSize(.small)
                    .help("按头行里的名字把这一段该用的素材图挂上")
                    .accessibilityIdentifier("material-auto-match")
                }
                Spacer()
                Button { onClear?() } label: {
                    Label("清空素材", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(OutlineButtonStyle())
                .controlSize(.small)
                .disabled(isEmpty)
            }
            // 两种状态统一 36 高，保证卡片尺寸一致
            if isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
            } else if filteredEmpty {
                Text("这一类没有素材")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if shows(.image) {
                            ForEach(Array(imageRefs.enumerated()), id: \.element.id) { i, ref in
                                if let item = app.libraryItem(ref.libraryItemID) {
                                    MaterialStripCell(
                                        item: item,
                                        fallbackName: "图\(i + 1)",
                                        onDelete: { onRemove?(ref.id, "图", i + 1) },
                                        role: ref.role,
                                        onCycleRole: onCycleRole == nil ? nil : { onCycleRole?(ref.id) }
                                    )
                                }
                            }
                        }
                        if shows(.video) {
                            ForEach(Array(videoRefs.enumerated()), id: \.element.id) { i, ref in
                                if let item = app.libraryItem(ref.libraryItemID) {
                                    MaterialStripCell(
                                        item: item,
                                        fallbackName: "视频\(i + 1)",
                                        onDelete: { onRemove?(ref.id, "视频", i + 1) }
                                    )
                                }
                            }
                        }
                        if shows(.audio) {
                            ForEach(Array(audioRefs.enumerated()), id: \.element.id) { i, ref in
                                if let item = app.libraryItem(ref.libraryItemID) {
                                    MaterialStripCell(
                                        item: item,
                                        fallbackName: "音频\(i + 1)",
                                        onDelete: { onRemove?(ref.id, "音频", i + 1) }
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(height: 36)
            }
        }
        // 收自定义的 `MaterialTransfer`（不是 String）：字符串会被提示词编辑器抢走，
        // 详见 `MaterialTransfer` 的注释。
        .dropDestination(for: MaterialTransfer.self) { items, _ in
            // 快速返回让拖拽预览消失动画立即开始，实际处理异步执行
            let ids = items.map(\.id)
            Task { @MainActor in
                for id in ids {
                    onDrop(id)
                }
            }
            return true
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
        // 「添加」按钮打开的是**左侧素材库抽屉**（浮在弹窗之上，可拖可双击），由 RootView 的 LibraryDrawerLayer 呈现
    }
}

struct MaterialChip: View {
    let item: LibraryItem
    let onDelete: () -> Void
    var role: ReferenceImageRole? = nil
    var onCycleRole: (() -> Void)? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            thumbnail
                .frame(width: 56, height: 36)
                // ⚠️ **直角，不圆角**（用户 2026-09-13 明确要求"把圆角去掉"）。
                // 这里**不能直接删掉裁剪** ✗ —— `thumbnail` 里的图是 `.fill` 的，
                // 不裁就会溢出 56×36 的格子 ✓ 所以保留裁剪、只是把圆角设成 0 ✓
                .clipShape(RoundedRectangle(cornerRadius: 0))
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(Color.appBackground))
            }
            // ⚠️ **外扩设 0**：默认的 `HoverHighlightButtonStyle()` 会往外扩 8×4 ✓ 图标被推往内 ✗
            // 表现为"叉号不够贴角"（用户 2026-09-13 反馈）✓ 设 0 后图标正好落在角上 ✓
            // 代价：悬停高亮区变小（就是图标本身那么大）✓
            .buttonStyle(HoverHighlightButtonStyle(expandX: 0, expandY: 0))
            // 底部一行：左类型徽章（图片/视频/音频），右角色徽章（仅图片，点击循环切换）
            // 底部只留**一个**徽章：类型徽章（图片/视频/音频），且**靠右下角**放 ✓
            //
            // ⚠️ **2026-09-13 用户要求的两处改动**：
            //   ① **去掉角色徽章**（原来右下角那个「参考/首帧/尾帧」蓝胶囊 ✓）——
            //      理由是"自动匹配默认素材是参考"✓ 那个徽章基本恒显示「参考」、没信息量 ✓
            //   ② **类型徽章从左下挪到右下**（占了角色徽章原来的位置 ✓）—— 所以下面用
            //      `Spacer` 把它顶到右边 ✓ 方块尺寸 56×36 不变 ✓
            //
            // ⚠️ **副作用**：角色徽章那个按钮**同时也是"点按循环 参考→首帧→尾帧"的入口** ✗
            // 去掉之后**界面上就没有改角色的地方了** ✓（`onCycleRole` 参数保留着没删，
            // 调用方仍在传 ✓ 哪天要换个入口（比如右键菜单）可以直接接上 ✓）
            HStack(spacing: 2) {
                // `lineLimit(1)` + `fixedSize()`：宽度紧张时**不许压缩换行** ✗
                //（缺了这两句、文字被挤窄时会变成两行 —— 用户报过"徽章怎么改成竖向的了" ✓）
                Spacer(minLength: 0)   // 把徽章顶到右下
                Text(kindLabel)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .foregroundStyle(.white)
            }
            .padding(2)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // ⚠️ **把整块钉死在缩略图的尺寸上**（用户 2026-09-13 反馈"图片/参考/叉号的位置不对"）：
        // 不加这一句时，`ZStack` 的尺寸由**最大的子视图**决定 ✗ —— 而删除按钮的
        // `HoverHighlightButtonStyle()` 会往外扩（默认 8×4 ✓）、底部那行徽章还带着
        // `Spacer()` + `maxHeight: .infinity` ✗ → 整块**长出去** ✓
        // 于是三个元素全落在"放大后的框"的角上：叉号偏右、徽章偏下偏外、图片也没贴住左下 ✗
        // 钉住之后：叉号在图区域内右上角、类型徽章左下、角色徽章右下 ✓（正是用户要的）
        .frame(width: 56, height: 36)
    }

    private var kindLabel: String {
        switch item.kind {
        case .image: "图片"
        case .video: "视频"
        case .audio: "音频"
        }
    }

    private var roleLabel: String {
        switch role {
        case .firstFrame: "首帧"
        case .lastFrame: "尾帧"
        case .referenceImage, .none: "参考"
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch item.kind {
        case .image:
            // 文件真的还在才用本地图：`localPath` 只是个字段，文件可能早被移走
            //（实测库里 131 张图有 48 张这样）——不判存在就会拿到死路径、缩略图空白且不回落。
            if let localURL = item.existingLocalImageURL {
                AsyncThumbImage(path: localURL.path)
            } else if let urlString = item.remoteURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        icon
                    }
                }
            } else {
                icon
            }
        case .video:
            if let path = item.localPath, FileManager.default.fileExists(atPath: path) {
                VideoThumbnailView(path: path)
            } else {
                icon
            }
        case .audio:
            icon
        }
    }

    private var icon: some View {
        Image(systemName: item.kind == .audio ? "waveform" : item.kind == .video ? "film" : "photo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.secondary.opacity(0.1))
    }
}


// MARK: - 复用的参数组件

/// 常亮滑块：轨道与滑块始终显示高亮色。
/// macOS 系统 Slider（含 .tint）在非悬停/非拖动时固定渲染为灰色，无法常亮，故自绘。
struct AlwaysBrightSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// 拖动状态回调（true = 按下开始拖；false = 松手）。
    /// **时长弹窗靠它做"松手才提交"**（2026-09-17：拖动时实时改时长会把时间轴段宽带着一起抖）
    var onEditingChanged: ((Bool) -> Void)? = nil
    @State private var dragging = false

    /// 滑块直径。**DurationPickerView 里的刻度也用它算行程，改这里必须同步那边**
    /// （两边都引用这个常量，就不会再各写各的 7.5 / 15）。
    static let knobSize: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob = Self.knobSize
            /// **行程 = 宽度 − 一个滑块**：圆心只能走 [knob/2, width − knob/2]，
            /// 这样滑块**边缘**正好贴住轨道两端，同时和刻度用同一套坐标。
            let travel = max(width - knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let clamped = min(max(fraction, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: knob / 2 + clamped * travel, height: 4)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    // 圆心 x = knob/2 + clamped * travel
                    .offset(x: clamped * travel)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            onEditingChanged?(true)
                        }
                        // ⚠️ **这里必须是上面显示公式的反函数**：圆心 = knob/2 + u*travel
                        //     ⇒ u = (x − knob/2) / travel
                        // 原来写的是 `x / width` —— 和显示公式**不是互逆的**，所以
                        //「拖到哪」和「显示到哪」有系统性偏差（只改视觉会变成"看着对齐、拖不准"）。
                        let f = min(max((gesture.location.x - knob / 2) / travel, 0), 1)
                        value = range.lowerBound + f * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: Self.knobSize)
    }
}

/// 时长选择：横向拖动条（**按整秒吸附**）+ 精确秒数输入（限整数）。
/// 范围**通用**（默认 2~30 秒），不再跟模型系列绑定。
struct DurationPickerView: View {
    @Binding var duration: Int
    var range: ClosedRange<Int> = 2...30
    /// **松手时回调一次** —— 配合"草稿值 + 松手提交"用（拖动期间别实时写回，见 `AlwaysBrightSlider.onEditingChanged`）
    var onCommit: (() -> Void)? = nil

    /// 滑块视觉范围固定从 0 开始（最低时长 2 秒是吸附与钳制规则，不是视觉起点）
    private var visualRange: ClosedRange<Double> {
        0...Double(range.upperBound)
    }

    /// 滑块绑定：吸附到**最近的整秒**，并钳制在允许范围
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(duration) },
            set: { newValue in
                duration = snapToSecond(newValue)
            }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { String(duration) },
            set: { newValue in
                if let v = Int(newValue.trimmingCharacters(in: .whitespaces)), range.contains(v) {
                    duration = v
                }
            }
        )
    }

    /// 按**整秒**吸附：四舍五入到最近的整数秒，再钳制到允许范围。
    /// （旧版是按 2/5/10/… 这种稀疏刻度吸附，拖不到 3、4 这种秒数。）
    private func snapToSecond(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("时长").font(.headline)
            HStack(alignment: .center, spacing: 8) {
                VStack(spacing: 4) {
                    AlwaysBrightSlider(value: sliderBinding, range: visualRange,
                                        onEditingChanged: { editing in if !editing { onCommit?() } })
                    // 刻度按秒数比例定位（与滑块同一套坐标，严格对齐）
                    GeometryReader { geo in
                        let width = geo.size.width
                        // **和 AlwaysBrightSlider 共用同一套坐标**：行程 = 宽度 − 一个滑块，
                        // 半宽也引用它的常量。原来这里硬编码 15 / 7.5、滑块那边也各写各的，
                        // 且两个公式不相等（只在 u = 0 / 0.5 / 1 重合）——
                        // 于是"中点前刻度偏右、中点后偏左"，表现为用户反馈的"忽左忽右"。
                        let knob = AlwaysBrightSlider.knobSize
                        let usableWidth = max(width - knob, 1)
                        ForEach(tickMarks, id: \.self) { tick in
                            Text("\(tick)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .position(
                                    x: knob / 2 + Double(tick) / Double(range.upperBound) * usableWidth,
                                    y: geo.size.height / 2
                                )
                        }
                    }
                    .frame(height: 14)
                }
                .frame(width: 210)

                TextField("", text: textBinding)
                    .frame(width: 44)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Text("秒").foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    /// 刻度**标签**（仅视觉参考：吸附已改成整秒，标签太密会糊，所以仍 5 秒一档）：
    /// 0 起 + 最低时长刻度（如 2 秒）+ 5 秒整档
    private var tickMarks: [Int] {
        var marks: [Int] = [0]
        if range.lowerBound > 0 { marks.append(range.lowerBound) }
        marks += stride(from: 5, through: range.upperBound, by: 5)
            .filter { $0 > range.lowerBound }
        return marks
    }
}

/// 时长弹窗的**内容**（不是按钮）—— 草稿值由**它自己**持有。
///
/// ⚠️ **为什么草稿不能放在卡片里**（2026-09-23 修）：
/// 浮层内容经 `DropdownPopoverModifier` 构建成 `AnyView` 存进 `DropdownPanel.shared`，
/// 渲染在 **`RootView` 的最外层 overlay** 里 —— 它**不在卡片的视图树中**。
/// 所以卡片 `@State` 变了（草稿值），这个快照**收不到通知、不会重绘**：
///
/// - 卡片上的「N 秒」按钮 ✅ 会变（它在卡片树里）
/// - 弹窗里的滑块圆点 ❌ 纹丝不动（它在单例的 AnyView 快照里）
///
/// 用户实测原话："时间变了但是按钮没动"。把草稿放进**弹窗内容自己的 `@State`** 之后，
/// SwiftUI 会正常重绘它，滑块就跟手了。
///
/// `onLiveChange` 只用于**同步卡片上那个按钮的文字**（拖动期间实时显示）——
/// 不写回 `shot.duration`，所以时间轴段宽不会跟着抖（见卡片里 `draftDuration` 的注释）。
struct DurationPopoverContent: View {
    @State private var draft: Int
    /// 拖动中实时回调（→ 卡片按钮文字）
    let onLiveChange: (Int) -> Void
    /// 松手 / 弹窗关闭时回调（→ 写回 shot.duration）
    let onCommit: (Int) -> Void

    init(initial: Int,
         onLiveChange: @escaping (Int) -> Void,
         onCommit: @escaping (Int) -> Void) {
        _draft = State(initialValue: initial)
        self.onLiveChange = onLiveChange
        self.onCommit = onCommit
    }

    var body: some View {
        DurationPickerView(
            duration: Binding(
                get: { draft },
                set: { newValue in
                    draft = newValue
                    onLiveChange(newValue)      // 卡片按钮文字跟着走
                }
            ),
            range: 2...30,
            onCommit: { onCommit(draft) }       // 只有它写回 shot.duration
        )
    }
}

/// 下拉选项
struct DropdownOption<Value: Hashable>: Identifiable {
    let label: String
    let value: Value
    var id: Value { value }
}

/// 下拉浮层（**窗口内实现**，2026-09-16 从独立 NSPanel 换过来）。
///
/// **为什么换**：
/// - NSPanel 是独立窗口 + `.popUpMenu` 层级 → 切到别的 App 时会一直浮在别人窗口上面；
///   锚点还要做「窗口坐标 → 屏幕坐标」换算（缓存为空 / 多显示器 / 窗口缩放都有坑）。
/// - 窗口内浮层：锚点直接用**窗口坐标**（SwiftUI `.global` 同一空间，零换算）；
///   跟着窗口走、随窗口最小化；不会跑到别的 App 上面；点外关闭用现成的 `OverlayEventShield`。
///
/// 渲染位置：`RootView` 最外层 `.overlay`（保证盖住卡片 / 抽屉 / 批量弹窗）；
/// 定位 + 边界翻转 + 捕获层见 `DropdownOverlay`。
///
/// 关闭路径（对齐旧实现）：点外面 / 滚轮 / 选完自动收 / 浮层开合时统一清 ——
/// 「滚轮压在锚点按钮上时网开一面」（2026-09-13 用户要求）在 `DropdownOverlay` 里保留。
@MainActor
@Observable
final class DropdownPanel {
    static let shared = DropdownPanel()

    struct Item {
        let owner: AnyHashable
        /// 锚点矩形：**窗口坐标**（与 SwiftUI `.global` 同一空间，y 向下）
        let anchor: CGRect
        let content: AnyView
    }

    private(set) var current: Item?

    func show<Content: View>(owner: AnyHashable, anchorWindowRect: CGRect, @ViewBuilder content: () -> Content) {
        current = Item(owner: owner, anchor: anchorWindowRect, content: AnyView(content()))
        AppLog.write("dropdownPanel", "弹出 owner=\(owner) anchor=\(anchorWindowRect)")
    }

    func dismiss() {
        guard let current else { return }
        AppLog.write("dropdownPanel", "收起 owner=\(String(describing: current.owner))")
        self.current = nil
    }
}

/// 窗口内下拉浮层：锚点定位 + 边界翻转 + 捕获层（点外关 / 滚轮关）。
struct DropdownOverlay: View {
    let item: DropdownPanel.Item

    @State private var panelSize: CGSize = .zero
    @State private var appeared = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 捕获层：点外面 → 关；滚轮 → 关（吞掉，不再穿透到后面的卡片列表）
                OverlayEventShield(
                    onTap: { DropdownPanel.shared.dismiss() },
                    onScroll: {
                        // ⚠️ 滚轮压在**锚点按钮**上时网开一面（2026-09-13 用户要求）：
                        // 刚点完按钮手还没移开就滚一下，不该把面板"滑没"
                        if !item.anchor.insetBy(dx: -4, dy: -4).contains(mousePointInWindow()) {
                            DropdownPanel.shared.dismiss()
                        }
                    }
                )
                .frame(width: geo.size.width, height: geo.size.height)

                item.content
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { panelSize = g.size }
                                .onChange(of: g.size) { _, new in panelSize = new }
                        }
                    )
                    // 点在下拉面板里（空白处）不算点外面（2026-10-28）；⚠️ 要在 offset 之前量，之后量是挪动前的位置
                    .shieldExempt()
                    // 定位：面板左上角 = 锚点上方 6pt（放不下翻到下方）；入场时从下方 8pt 滑上来
                    .offset(x: origin(in: geo.size).x,
                            y: origin(in: geo.size).y + (appeared ? 0 : 8))
                    .opacity(appeared && panelSize != .zero ? 1 : 0)
            }
            .collectsShieldExemptions()
        }
        .onChange(of: panelSize) { _, size in
            // 量到尺寸之后才揭幕（否则第一帧会出现在错误位置闪一下）
            guard size != .zero, !appeared else { return }
            withAnimation(.easeOut(duration: 0.14)) { appeared = true }
        }
    }

    /// 面板左上角：默认贴在锚点上方 6pt；上方放不下翻到下方；再整体夹进窗口内。
    private func origin(in container: CGSize) -> CGPoint {
        let a = item.anchor
        var x = a.minX
        var y = a.minY - 6 - panelSize.height
        if y < 8 { y = a.maxY + 6 }
        x = min(max(8, x), max(8, container.width - panelSize.width - 8))
        y = min(max(8, y), max(8, container.height - panelSize.height - 8))
        return CGPoint(x: x, y: y)
    }
}

/// **自绘弹出层修饰器**（2026-09-19 用户要求统一弹出层）：
/// 把系统 `.popover` 换成 app 自绘的 `DropdownPanel` —— 无箭头、跟着「玻璃效果」开关走、观感统一。
///
/// 用法和 `.popover(isPresented:)` 基本一样：
/// ```swift
/// .dropdownPopover(isPresented: $show, onClose: { commit() }) { 内容 }
/// ```
/// - `isPresented` 只当"请求打开"：一旦为 true，本修饰器**立刻复位它**并交给 `DropdownPanel`；
///   真正的开合由面板管（点外面 / 滚轮 / 选完自动收）。
/// - 面板关掉时回调 `onClose`（替代原来 `onChange(of: isPresented) { if !$0 { … } }` 的收尾）。
private struct DropdownPopoverModifier<PopContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var onClose: (() -> Void)?
    @ViewBuilder var popContent: () -> PopContent

    @State private var ownerID = UUID()
    /// 锚点矩形（窗口坐标）：用普通 class 持有，写入不触发重算（同 `IconDropdown`）
    @State private var anchorFrame = AnchorBox()
    @State private var showing = false

    final class AnchorBox { var rect: CGRect = .zero }

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { anchorFrame.rect = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, r in anchorFrame.rect = r }
                }
            )
            .onChange(of: isPresented) { _, open in
                guard open else { return }
                // ⚠️ **先取内容、再复位绑定**（顺序不能反，2026-09-19 修）：
                // 有些提示内容是从绑定里读数据的（生图那条读 `submitHint`）——
                // 先复位的话内容会被清成空字符串，面板看着"空的一样"（用户实测）。
                let built = popContent()
                isPresented = false          // 复位：真正的开合交给面板
                showing = true
                let rect = anchorFrame.rect.isEmpty
                    ? CGRect(origin: mousePointInWindow(), size: .zero)
                    : anchorFrame.rect
                DropdownPanel.shared.show(owner: ownerID, anchorWindowRect: rect) {
                    // ⚠️ **自绘面板没有底**（系统 popover 才有），这里统一补上 ——
                    // 和 `IconDropdown` 的弹出面板同款：材质/纯色 + 圆角 14 + 无阴影（面板自己有系统阴影）。
                    // 漏了这层的话内容会直接透到卡片上（用户实测："时长弹窗变透明了"）。
                    built
                        .glassPanel(cornerRadius: 14, shadow: false)
                }
            }
            // 面板被关掉（点外面 / 滚轮 / 选完）→ 复位内部状态 + 收尾回调
            .onChange(of: DropdownPanel.shared.current?.owner) { _, owner in
                guard showing, owner == nil else { return }
                showing = false
                onClose?()
            }
    }
}

extension View {
    /// 见 `DropdownPopoverModifier` 的说明
    func dropdownPopover<PopContent: View>(isPresented: Binding<Bool>,
                                           onClose: (() -> Void)? = nil,
                                           @ViewBuilder content: @escaping () -> PopContent) -> some View {
        modifier(DropdownPopoverModifier(isPresented: isPresented, onClose: onClose, popContent: content))
    }
}

/// 带图标的统一下拉选择器（圆角无箭头、向上弹出、点外收起）
struct IconDropdown<Value: Hashable>: View {
    let icon: String
    let labelWidth: CGFloat
    /// 图标固定宽度（默认 nil = 按图标自己的宽度）。工具条里的几个下拉要摆得**一样宽**，不同图标本来宽窄不一，所以固定住
    var iconWidth: CGFloat? = nil
    /// 标签字体（2026-09-18）：外部 `.font()` 传不进来（被 Button/ButtonStyle 吞掉），
    /// 所以做成参数。默认 14pt；主页排序那两个传 16。
    var labelFont: Font = .callout
    let options: [DropdownOption<Value>]
    @Binding var selection: Value
    /// true = 按钮**撑满所在行的剩余宽度**（批量设置参数弹窗用）。
    ///
    /// 原来是 `expandedWidth: CGFloat?`（固定 150）。问题是：整行只有 56+12+150=218 宽，
    /// 而弹窗内容区有 388 —— HStack 只占 218 就被 VStack **水平居中**了，
    /// 于是左侧标签看着不在最左边、右侧还空一截（用户："模式/模型等字样放左边，选项按钮放到区域最大"）。
    /// 改成撑满之后**两件事一起解决**：HStack 占满整行 → 标签自然贴左、按钮铺满剩余宽度。
    /// ⚠️ 本项目只有那两个批量设置弹窗传 true，别处**全部**用默认值（按内容自适应）。
    var fillsRow: Bool = false

    /// 按钮的垂直内边距。**默认 6**：内容高 16 → 28，悬停高亮 28+8 = **36**。
    ///
    /// 这个数是**全 App 统一的"标准按钮高度"**（2026-09-12 用户定标）：
    /// 他说"下拉菜单那个按钮的高度刚刚好，参数行、工具条的都有些小" —— 于是把
    /// 参数区（卡片）和工具条都提到这一档。同时它**和弹出的列表条目一样高**
    /// （条目本来就是 `.padding(.vertical, 6)`），按钮的高亮和它弹出的东西对齐。
    /// **要整体调高/调矮就改这一个数**（工具条那边也要跟着改 `ToolbarRow.rowHeight`）。
    var verticalPadding: CGFloat = 6

    /// 配置里**有没有该能力的模型**（卡片按各自能力传 `!app.videoModelNames.isEmpty`
    /// / `!app.imageModelNames.isEmpty`）。
    ///
    /// false → 按钮显示 `emptyPlaceholder`（「请选择模型」），点击**不弹下拉**，
    /// 而是弹一条轻提示（`emptyHint`）引导去设置里加渠道 / 模型。
    /// ⚠️ **默认 true**：所有其它调用点（批量设置弹窗等）行为完全不变。
    var hasModels: Bool = true
    var emptyPlaceholder: String = "请选择模型"
    var emptyHint: String = "还没有可用的模型。请到「设置 → 模型渠道」添加渠道与模型。"

    /// 非观察缓存：按钮屏幕坐标只在面板定位时读，body 不用。
    /// 用普通 class 持有 → 写入不触发 SwiftUI 重算。**别换回 @State**：每张卡有多个下拉，
    /// 滚动时每个下拉每帧都会写一次坐标 → 反复标脏重算 → 掉帧（2026-09-11 sample 实锤）。
    @State private var buttonFrame = FrameBox()
    /// 每个下拉实例唯一标识（防抖 owner 不能用 icon 字符串——同类型下拉跨卡片共享会互相吞点击）
    @State private var ownerID = UUID()
    /// 「没有可用模型」时点开的那条提示（popover）；有模型时永远为 false，不打扰
    @State private var showEmptyHint = false

    final class FrameBox {
        var rect: CGRect = .zero
    }

    /// 当前选择**不在候选里**（旧模型已从配置删除 / 从未选择 / 配置里一个模型都没有）→ 占位。
    /// 注意：候选非空（配置里还有别的模型）时，点开仍会弹下拉，让用户重新选 ✓
    private var isPlaceholder: Bool {
        if !hasModels { return true }
        return !options.contains(where: { $0.value == selection })
    }

    private var currentLabel: String {
        // 占位而不是空字符串（否则按钮看着像坏了）
        if isPlaceholder { return emptyPlaceholder }
        return options.first(where: { $0.value == selection })?.label ?? ""
    }

    var body: some View {
        Button {
            if hasModels {
                AppLog.write("dropdownTap", "icon=\(icon) rect=\(anchorWindowRect())")
                DropdownPanel.shared.show(owner: ownerID, anchorWindowRect: anchorWindowRect()) {
                    panelContent
                }
            } else {
                showEmptyHint = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: iconWidth)
                Text(currentLabel)
                    // ⚠️ 直接 `.font()` / 参数传 Font 都试过，实测这个组件里**不生效**
                    //（被 Button/ButtonStyle 内部某处固定住了，截图对比 12/14/16/17 全一个样）。
                    // 改用**环境字体**注入（见下方 `.environment(\.font, labelFont)`），能穿透。
                    .font(labelFont)
                    // 固定宽度的槽里**居中**（原来是 .leading）：短标签右端会空出一截，看着像偏左
                    // ⚠️ 长模型名**缩字不截断**（原来会 tail 截断成「模型名…」）——
                    // 「不截断」是参数行这轮明确要求之一。
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: fillsRow ? nil : labelWidth, alignment: .center)
                    .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                if fillsRow { Spacer(minLength: 0) }
                // 下箭头已按用户要求移除（所有 IconDropdown 一起去掉）。
                // 想恢复就在 Spacer 后面加回：
                //   Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            // **环境字体**：这个组件的字体只能从这里注入（见 Text 处的说明）
            .environment(\.font, labelFont)
            // fillsRow：撑满整行剩余宽度 —— 按钮的实际可点/悬停范围也跟着变大
            .frame(maxWidth: fillsRow ? .infinity : nil, alignment: .leading)
            // 垂直内边距：**必须在 .contentShape 之前**，否则撑大的部分接不到悬停
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        // 「没有可用模型」时点开的轻提示：一条短文案，点外面即收（比 alert 安静）
        .dropdownPopover(isPresented: $showEmptyHint) {
            Text(emptyHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                // 同生图侧：贴内容走（最长 260），别写死宽度
                .frame(maxWidth: 260, alignment: .leading)
                .padding(12)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { buttonFrame.rect = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, newValue in buttonFrame.rect = newValue }
            }
        )
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options) { option in
                Button {
                    selection = option.value
                    DropdownPanel.shared.dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text(option.label)
                            // 与按钮标签同档（2026-09-18 用户：面板条目和按钮字看着不一样大）
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .opacity(option.value == selection ? 1 : 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle())
            }
        }
        .padding(.vertical, 4)
        .frame(width: 200)
        // shadow: false —— 这块内容是装在 NSPanel 里的，面板自己有系统阴影；
        // SwiftUI 的阴影画到面板边界外会被裁掉，在圆角处留一道"印子"。
        .glassPanel(cornerRadius: 14, shadow: false)
    }

    /// 锚点矩形（**窗口坐标**）：缓存的按钮 frame 就是窗口坐标（`.global` 同一空间），直接用；
    /// 缓存为空（窗口缩放后卡片重建、`onChange` 还没填上）时用**鼠标位置**兜底 ——
    /// 用户刚点完按钮，光标就在按钮上。
    private func anchorWindowRect() -> CGRect {
        let f = buttonFrame.rect
        if f.isEmpty {
            AppLog.write("dropdownTap", "锚点缓存为空（窗口刚缩放？）→ 用鼠标位置兜底")
            return CGRect(origin: mousePointInWindow(), size: .zero)
        }
        return f
    }
}

/// 编辑提示词弹窗：从卡片提示词区点开，独立编辑 → 保存回写分镜（卡片只读区随之更新）。
/// 带素材区（点 chip 插入「图N是」，悬停放大缩略图）+ 支持 @ 触发素材选择。
struct EditPromptSheet: View {
    @State private var promptFocused = false
    @Environment(AppModel.self) private var app
    let shot: ShotDraft
    /// 关闭回调（原来是 `@Environment(\.dismiss)`，改成应用内浮层后没有 presentation 上下文）
    var onClose: () -> Void
    var onSave: ((String) -> Bool)?
    var showsMaterialSection: Bool
    /// 嵌在工作台二级页面中间那一栏（2026-10-15 用户：编辑弹窗整个搬进二级页面，不用再点开）：
    /// 没有标题、跟着栏宽高伸缩；没有「取消」——点外面就存（和剧情栏一样），不回滚；提交生成后不关
    var inline = false
    /// 嵌着时这一栏能给多宽（二级页面按栏宽算好传进来）：窄了参数那一行换成两行
    var availableWidth: CGFloat? = nil
    /// 参数 +「提交生成」排成一行要多宽（含左右边距；模型名用完整宽度，不截断）
    static let inlineRowMinWidth: CGFloat = 550   // 实测整栏最窄 546
    @State private var editPrompt: String
    /// 打开时的分镜备份：素材区、参数的操作是实时写数据层的，没提交就关掉时用它回滚（只回滚这几样，见 `rollbackShotEdits`）
    @State private var backup: ShotDraft?
    /// 已经提交 / 保存了：关闭时不再回滚
    @State private var finished = false
    @State private var showSubmitHint = false
    @State private var submitIssues: [String] = []
    /// 「自动匹配」前还没入库的张数（等确认；0 = 没有在等）
    @State private var autoMatchPendingLibrary = 0
    /// 「自动匹配」有没挂上的：说一句为什么（nil = 全部顺利，不打扰）
    @State private var autoMatchNote: String?

    // ⚠️ 自定义 init 必须显式接收并赋值 `onClose`（成员初始化器被它取代了）
    init(shot: ShotDraft, onClose: @escaping () -> Void,
         onSave: ((String) -> Bool)? = nil, showsMaterialSection: Bool = true, inline: Bool = false, availableWidth: CGFloat? = nil) {
        self.availableWidth = availableWidth
        self.shot = shot
        self.onClose = onClose
        self.onSave = onSave
        self.showsMaterialSection = showsMaterialSection
        self.inline = inline
        _editPrompt = State(initialValue: shot.prompt)
    }

    /// 数据层里的**实时**分镜。弹窗持有的 `shot` 是打开时的快照，
    /// 素材增删改后快照不更新 → chip 缩略图/槽位都会显示旧内容（关掉重开才对）。
    private var liveShot: ShotDraft { app.shots.first(where: { $0.id == shot.id }) ?? shot }

    // 素材和提示词的关系（2026-10-16 用户定，统一规则）：**提示词里删素材，素材区的素材不删；只有素材区删了，提示词里的才跟着删**。
    // 所以这里没有「按提示词对账删素材」：删素材只走素材区（chip 上的叉、清空素材、右栏移除），那边会同步清掉提示词里的「图N / 视频N / 音频N」并重新编号。
    // 原来的对账（提示词里没了就删素材）会把音频这种在提示词里只是一串字的素材悄悄删掉，用户以为只是改了句话。

    /// 该分镜的素材槽位（编辑器 @ 弹窗、缩略图显示、素材区 chip 共用）。
    /// 必须用 app.shots 里的**实时**数据：弹窗持有的 shot 是打开时的快照，
    /// 自动匹配/删素材后素材会变，用快照会导致缩略图不刷新（关掉重开才更新）。
    private var slotItems: [SlotItem] {
        // 同 `SlotItem.list`（绑了音色的角色图带小喇叭，2026-10-26）
        SlotItem.list(for: liveShot, in: app)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !inline {
            HStack {
                Text("编辑提示词")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 12`：分割线拿走后面向内容那侧收掉
            .padding(.top, 12)
            .padding(.bottom, 4)
            }
            editorColumn
        }
        // **只固定宽度**：里面的 `PromptEditor` 已经写死高度、内容高度是固定的，外层再钉高度只会多出一片空白
        .frame(width: inline ? nil : 620)
        .frame(maxWidth: inline ? .infinity : nil, maxHeight: inline ? .infinity : nil)
        .onAppear {
            // 打开时备份分镜（素材、提示词、参数），没提交就关掉时回滚（嵌在二级页面里的不回滚：改了就存）
            if !inline { backup = app.shots.first { $0.id == shot.id } }
        }
        // 没提交 / 没保存就关掉（点外面、Esc、旧页面的取消）：撤销弹窗期间改的；嵌着的：离开前把没存的存上
        .onDisappear {
            if inline { saveInline() }
            else if !finished, let backup { app.rollbackShotEdits(to: backup) }
        }
        // 嵌着的：别处改了这张卡的提示词（重新推理、换回别的版本、右边改素材）且没在打字 → 跟上
        .onChange(of: liveShot.prompt) { _, updated in
            if inline, !promptFocused, updated != editPrompt { editPrompt = updated }
        }
        // 嵌着的：没在打字时提示词变了（素材区删了素材、清空、自动匹配）→ 马上存
        .onChange(of: editPrompt) { _, _ in
            if inline, !promptFocused { saveInline() }
        }
        // 自动匹配：有还没入库的图 → 先问一句（和工作台「匹配」「应用素材」一样，视频生成要用素材库里的图）
        .alert("有 \(autoMatchPendingLibrary) 张图还没入库", isPresented: Binding(get: { autoMatchPendingLibrary > 0 }, set: { if !$0 { autoMatchPendingLibrary = 0 } })) {
            Button("入库并匹配") { runEpisodeAutoMatch() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("匹配时会先存进素材库（后台上传，进度在素材库底部），视频生成才拿得到这些参考图。")
        }
        .alert("自动匹配", isPresented: Binding(get: { autoMatchNote != nil }, set: { if !$0 { autoMatchNote = nil } })) {
            Button("好") {}
        } message: {
            Text(autoMatchNote ?? "")
        }
    }

    /// 编辑区（素材 + 提示词 + 参数 / 提交）
    private var editorColumn: some View {
        VStack(spacing: 0) {

            // 素材区：与分镜卡片同款（添加 / 自动匹配 / 清空 + 素材 chips）；点 chip 把「图N是」插入编辑器，
            // 删素材时同步清理编辑器里对应的 token（否则会残留「图N是」）
            if showsMaterialSection {
            MaterialSection(
                // 实时数据：弹窗持有的 `shot` 是打开时的快照
                imageRefs: liveShot.imageRefs,
                videoRefs: liveShot.videoRefs,
                audioRefs: liveShot.audioRefs,
                showsTypeTabs: true,
                // 「添加」打开左侧素材库抽屉（浮在本弹窗之上，可拖可双击），并把"加到哪儿"带过去
                onAdd: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        app.toggleLibraryDrawer(target: .shot(shot.id))
                    }
                },
                onRemove: { refID, prefix, index in
                    app.removeShotMaterial(shotID: shot.id, refID: refID)
                    editPrompt = AppModel.removeTokenAndRenumber(editPrompt, prefix: prefix, removedIndex: index)
                },
                onAutoMatch: autoMatch,
                onClear: {
                    app.clearShotMaterials(shot.id)
                    editPrompt = AppModel.strippingMaterials(editPrompt)
                },
                onCycleRole: { refID in app.cycleImageRole(shotID: shot.id, refID: refID) },
                onDrop: { app.addShotMaterial(shotID: shot.id, libraryItemID: $0) }
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
                onFocusChange: { focused in
                    promptFocused = focused
                    if inline, !focused { saveInline() }     // 嵌在二级页面里：点外面就存
                }
                // 在提示词里删掉内嵌缩略图：只删字，素材区不动（2026-10-16 用户定，见上面 `liveShot` 下的说明）
            )
            // 2026-09-29 用户：提示词框**顶上去**（260 → 340）+ 去掉上面那条横线；嵌在二级页面里跟着栏高伸缩
            .frame(height: inline ? nil : 340)
            .frame(maxHeight: inline ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 14).fill(.insetFill))
            .inputChrome(focused: promptFocused, radius: 14)
            .padding(.horizontal, inline ? 12 : 16)
            .padding(.top, inline ? 10 : 16)
            // 原 `.padding(16)`：下侧朝向被删的那条线，收掉
            .padding(.bottom, 6)

            if let onSave {
                // 旧页面（剧本里的分镜编辑）自己管保存：保留原来的「取消 / 保存」
                HStack {
                    Spacer()
                    Button("取消") {
                        finished = true
                        if let backup { app.rollbackShotEdits(to: backup) }
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
                // 生视频页的编辑提示词（2026-10-10 用户定）：下面一行就是生成参数 + 提交生成。
                // 点外面 / Esc 关掉 = 取消（提示词、素材、参数都回到打开时的样子）；提交生成 = 保存 + 提交。
                // 嵌在二级页面里、栏太窄（最小窗口）时「提交生成」换到参数下面一行，不把这一栏撑出去
                let stacked = inline && (availableWidth ?? .infinity) < Self.inlineRowMinWidth
                (stacked ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))) {
                    VideoParamControls(shot: app.shotBinding(shot.id), compact: false)
                        .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
                    if !stacked { Spacer(minLength: 8) }
                    Button { submit() } label: { Text("提交生成").lineLimit(1).fixedSize() }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(ShotSubmitRules.isSubmitting(liveShot, app: app))
                        .help("保存提示词和参数，并提交生成（⌘↩）")
                        .dropdownPopover(isPresented: $showSubmitHint) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(submitIssues, id: \.self) { issue in
                                    Label(issue, systemImage: "exclamationmark.triangle.fill").font(.caption)
                                }
                            }
                            .padding(12)
                        }
                }
                .padding(.horizontal, inline ? 12 : 16).padding(.vertical, 12)
                // ⌘S：只保存、不生成（生成要花钱，批量改完提示词再统一提交很常见）。没有按钮，只有快捷键
                .background {
                    Button("") { saveWithoutSubmitting() }
                        .keyboardShortcut("s", modifiers: .command)
                        .frame(width: 0, height: 0).opacity(0).allowsHitTesting(false)
                }
            }
        }
    }

    /// 素材区「自动匹配」。段落详情里也在左边这一行（2026-10-27 用户：审完提示词就匹配，原来在右栏「本段预览」里、每段都要切页）
    private func autoMatch() {
        // 弹窗编辑的是本地副本：先把编辑器内容写回数据层，再匹配，最后把结果读回编辑器
        //（否则匹配改的是数据层旧内容，编辑器看不到、保存时又被覆盖回去）
        app.updateShotPrompt(shot.id, prompt: editPrompt)
        // 属于某一集的分镜：和工作台工具条「匹配」、分段弹窗「应用素材」同一套（2026-10-14 用户）——
        // 按头行里的名字挂它该用的那一版生图卡，没入库的先问一句再入库，不改时长；
        // 不属于任何一集的（生视频页自己新建的）照旧按素材库名字匹配
        if let item = WorkbenchBatch.matchItem(shotID: shot.id, app: app) {
            let pending = WorkbenchBatch.matchNeedsLibrary([item], app: app)
            if pending > 0 { autoMatchPendingLibrary = pending } else { runEpisodeAutoMatch() }
        } else {
            app.autoMatchMaterials(shot.id)
            reloadPromptFromShot()
        }
    }

    /// 属于某一集的分镜做「自动匹配」：和工作台工具条「匹配」同一套（`WorkbenchBatch.match`）。全部顺利就不打扰，有没挂上的说一句
    private func runEpisodeAutoMatch() {
        autoMatchPendingLibrary = 0
        guard let item = WorkbenchBatch.matchItem(shotID: shot.id, app: app) else { return }
        let report = WorkbenchBatch.match([item], app: app)
        reloadPromptFromShot()
        var parts: [String] = []
        if report.withoutImage > 0 { parts.append("\(report.withoutImage) 个名字还没有图，没有挂（先提取、出图）") }
        if report.notInHeadLine > 0 { parts.append("\(report.notInHeadLine) 个在分镜头行里找不到名字") }
        if let skips = app.voiceSyncSkips[shot.id] { parts.append("音色没挂上（\(skips.joined(separator: "；"))）") }
        if !parts.isEmpty {
            autoMatchNote = "已挂上 \(report.applied) 个素材；" + parts.joined(separator: "；") + "。"
        } else if item.selections.isEmpty {
            autoMatchNote = "分镜头行里没有素材名字，没有可挂的。"
        }
    }

    /// 匹配改的是数据层里的分镜：把结果读回编辑器
    private func reloadPromptFromShot() {
        if let updated = app.shots.first(where: { $0.id == shot.id })?.prompt {
            editPrompt = updated
        }
    }

    /// 提交生成 = 保存 + 提交。先按「改完的提示词」检查提交条件，不满足就只提示、什么都不写、弹窗不关
    private func submit() {
        var candidate = liveShot
        candidate.prompt = editPrompt
        let issues = ShotSubmitRules.issues(candidate, app: app)
        guard issues.isEmpty else {
            submitIssues = issues
            showSubmitHint = true
            return
        }
        app.updateShotPrompt(shot.id, prompt: editPrompt)
        finished = true
        app.submitShot(shot.id)
        if !inline { onClose() }
    }

    private func saveWithoutSubmitting() {
        app.updateShotPrompt(shot.id, prompt: editPrompt)
        finished = true
        if !inline { onClose() }
    }

    /// 嵌在二级页面里：点外面 / 翻到别的段 / 关掉时存（没改就不写）
    private func saveInline() {
        guard liveShot.prompt != editPrompt else { return }
        app.updateShotPrompt(shot.id, prompt: editPrompt)
    }

}

/// 分镜预览弹窗：左视频（AVPlayer 控制条，可全屏）+ 右上提示词 + 右下历史版本列表（点击切换）
/// 分镜视频的大窗口预览（双击缩略图打开）。2026-10-08 用户定：**跟生图「双击看大图」一样**——
/// 视频占满整个窗口（窗口尺寸同 `PreviewLayout`），名称 / 版本做成左上浮层，「在访达中显示」在右下角（播放条最右）。
/// 原来右侧那一列（提示词 / 历史版本 / 显示当前）已删：版本在右栏里切，提示词在右栏里看。
struct ShotPreviewSheet: View {
    @Environment(AppModel.self) private var app
    let shot: ShotDraft

    @State private var player: AVPlayer?

    /// 实时的分镜（弹窗持有的是打开时的快照，之后换版本 / 下载完成要跟得上）
    private var live: ShotDraft { app.shots.first(where: { $0.id == shot.id }) ?? shot }

    /// 这张卡当前显示的那一版（缩略图显示的也是它）
    private var currentTask: LocalTask? {
        live.taskID.flatMap { app.store.task(id: $0) }
    }

    private var videoPath: String? {
        guard let path = currentTask?.localVideoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// 任务在文件名里的版本号（「1-2-8」→ 8），见 `LocalTask.versionNumber(in:)`
    private func versionNumber(of task: LocalTask) -> Int { task.versionNumber(in: live.taskIDs) }

    /// 当前版本的序号标注（如「第 2 版」）
    private var currentVersionLabel: String? {
        currentTask.map { "第 \(versionNumber(of: $0)) 版" }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            leftPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 左上浮层：名称 · 第 N 版（同生图大图预览）
            HStack(spacing: 6) {
                Text(app.numbering(of: live).title)
                    .lineLimit(1)
                if let label = currentVersionLabel {
                    Text(label)
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)
            // ⚠️ 别挡点视频暂停 / 播放
            .allowsHitTesting(false)
        }
        // 右上角「编辑分镜」：从工作台打开的大预览才有，点了打开这一段的二级页面（2026-10-14 用户）；
        // 大预览先收起、记下来，二级页面关掉时放回来（2026-10-15 用户，见 `AppModel.shotPreviewReturn`）
        .overlay(alignment: .topTrailing) {
            if let edit = app.shotPreviewEditSegment, !app.previewFullscreen {
                Button {
                    if let id = app.previewingShotID { app.shotPreviewReturn = (id, edit) }
                    if let close = app.previewCloseRequest { close() } else { app.previewingShotID = nil }
                    edit()
                } label: {
                    Label("编辑分镜", systemImage: "square.and.pencil")
                }
                .buttonStyle(OutlineButtonStyle())
                .padding(4)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
                .help("打开这一段的二级页面（点缩略图下面的文字那条也是）")
                .accessibilityIdentifier("shot-preview-edit-segment")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 叉号已按用户要求移除（统一"点弹窗外关闭"；这个浮层的遮罩本来就带 onTapGesture 关闭）。
        // ⚠️ **Esc 不能跟着丢**：原来 Esc 是靠那个按钮的 `.keyboardShortcut(.cancelAction)` 实现的，
        //    按钮一删 Esc 就失效，所以改用 `.onExitCommand` 顶上。
        .onExitCommand {
            if let close = app.previewCloseRequest {
                close()
            } else {
                app.previewingShotID = nil
            }
        }
        .onAppear { loadCurrent() }
        // 下载完成（本地视频路径出现）/ 换了当前版本时自动加载播放，避免弹窗停留在「正在下载视频」
        .onChange(of: currentTask?.localVideoPath) { _, _ in loadCurrent() }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var leftPane: some View {
        Group {
            if let player {
                AVPlayerContainer(player: player)
                    // 自绘控制条（系统那套随 AVPlayerView 一起换掉了，见 VideoControlBar）；鼠标移到画面上才出来（2026-10-15 用户）
                    .hoverRevealControls {
                        VideoControlBar(
                            player: player,
                            onToggleFullscreen: toggleFullscreen,
                            isFullscreen: app.previewFullscreen,
                            // 右下角「在访达中显示」（同生图大图预览右下角那个按钮）
                            onReveal: videoPath.map { path in
                                { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                            }
                        )
                    }
            } else if let task = currentTask {
                Color.clear
                    .overlay {
                        switch task.phase {
                        case .failed:
                            VStack(spacing: 8) {
                                Image(systemName: "xmark.circle")
                                    .font(.title)
                                    .foregroundStyle(Theme.danger)
                                Text("生成失败")
                                    .foregroundStyle(.secondary)
                                // 失败原因摘要（完整原文去任务列表点开看；这里悬停也能看全）
                                if let raw = task.errorMessage, !raw.isEmpty {
                                    Text(Formatters.errorSummary(raw))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.danger.opacity(0.9))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(3)
                                        .padding(.horizontal, 16)
                                        .help(raw)
                                }
                            }
                        case .completed:
                            // 已完成但无本地文件：有 errorMessage 才是真下载失败，否则是「正在下载」的中间态
                            if task.errorMessage != nil {
                                Text("视频下载失败")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在下载视频")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        default:
                            TaskInProgressView(task: task)
                        }
                    }
            } else {
                Color.clear
                    .overlay(
                        // 当前是重新推理出来的「待生成」版本（2026-10-15）
                        Text(live.showsPendingVersion ? "待生成" : "暂无视频")
                            .foregroundStyle(.secondary)
                    )
            }
        }
        // 左侧整块用**毛玻璃**打底（原来是纯黑 → 一度改成液态玻璃）：视频以外的区域——
        // 上下黑边、加载中、失败、无视频——都透出玻璃，而不是一块黑。
        // 配合 AVPlayerContainer 把播放器自身的背景清空（见那边注释）。
        //
        // ⚠️ **用 `FrostedPanel()`（`.withinWindow`），不用 `.glassPanel()`**：
        //    预览弹窗是**应用内浮层**，它后面就是主窗口被压暗的内容 —— `.withinWindow`
        //    糊的正好是这个；而液态玻璃的边缘反光会在这一块四边留一圈"边线"，
        //    这正是用户一直在去的那条线（`NSVisualEffectView` 不画描边）。
        .background { FrostedPanel() }
    }

    /// 全屏切换：**浮层铺满整个窗口 + 窗口进入全屏** —— 两者合起来才是"视频占满屏幕"。
    /// 只调 `toggleFullScreen` 的话就只是把软件窗口放大、浮层还是原来的比例。
    /// 自绘播放器后系统那套全屏没了，只能这样组合出来。
    private func toggleFullscreen() {
        app.previewFullscreen.toggle()
        (NSApp.mainWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
    }

    /// 载入当前版本并**自动播放**（有声；双击就是为了看它）
    private func loadCurrent() {
        guard let path = videoPath else {
            player?.pause()
            player = nil
            return
        }
        // 已经有播放器（切版本 / 下载完成）：同一个播放器换片源，不换播放器。
        // 2026-10-15 用户：在右边版本列里切版本后画面没了、进度条还在走——正在显示的视频图层换绑一个新播放器，有时只剩声音和进度、画面空白
        if let player {
            player.pause()
            player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: path)))
            player.seek(to: .zero)
            player.play()
            return
        }
        let next = AVPlayer(url: URL(fileURLWithPath: path))
        player = next
        next.play()
    }
}

/// 批量设置参数弹窗：把模型/分辨率/比例/时长统一应用到选中的分镜。
/// 2026-10-12 起是「批量提交」的第一步：点「应用」后接着弹提交确认；取消 = 这次不提交、参数也不改
struct BatchParamView: View {
    @Environment(AppModel.self) private var app
    /// 关闭回调（原来是 `@Environment(\.dismiss)`，改成浮层后失效，由外部传入）
    var onClose: () -> Void

    @State private var model: String = ""
    @State private var resolution: Resolution = .p720
    @State private var aspectRatio: AspectRatio = .ratio16x9
    @State private var duration: Int = 5
    @State private var showDurationPopover = false
    // 注：这里的「鼠标移出自动关闭」也已整条删除（与卡片上的时长弹窗同款，2026-09-13）。

    /// 批量设置的模型下拉：**只列配置里现有的视频模型**（旧模型名不再塞进列表）
    private var modelOptions: [DropdownOption<String>] {
        app.videoModelNames.map { DropdownOption(label: $0, value: $0) }
    }

    private var resolutionOptions: [DropdownOption<Resolution>] {
        Resolution.allCases.map { DropdownOption(label: $0.displayName, value: $0) }
    }

    private var aspectOptions: [DropdownOption<AspectRatio>] {
        [AspectRatio.ratio16x9, .ratio9x16, .ratio1x1, .ratio4x3, .ratio3x4]
            .map { DropdownOption(label: $0.rawValue, value: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("批量设置参数")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            // 原来是 `.padding(.vertical, 12)`：**分割线拿走之后，朝内容那一侧必须收掉**，
            // 否则头 12 + 内容 14 会叠成 26pt 死白（用户实测"上下有留空白"）。
            .padding(.top, 12)
            .padding(.bottom, 4)

            // 标题下**不加分割线**（同其余三个弹窗）

            // 与分镜卡片参数区同款的下拉样式
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Text("模型")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "cube",
                        labelWidth: 130,
                        options: modelOptions,
                        selection: $model,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
                HStack(spacing: 12) {
                    Text("分辨率")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "rectangle.on.rectangle",
                        labelWidth: 48,
                        options: resolutionOptions,
                        selection: $resolution,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
                HStack(spacing: 12) {
                    Text("比例")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    IconDropdown(
                        icon: "aspectratio",
                        labelWidth: 44,
                        options: aspectOptions,
                        selection: $aspectRatio,
                        fillsRow: true,
                        verticalPadding: 6
                    )
                }
                HStack(spacing: 12) {
                    Text("时长")
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    Button {
                        showDurationPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer").font(.caption).foregroundStyle(.secondary)
                            // 数字等宽 + 固定宽度右对齐，「秒」字固定，拖动滑块时文字不跳动
                            HStack(spacing: 2) {
                                Text("\(duration)")
                                    .monospacedDigit()
                                    .frame(width: 20, alignment: .trailing)
                                Text("秒")
                            }
                            Spacer(minLength: 0)
                        }
                        // ⚠️ **必须撑满，别再写死宽度**。这一行不是 `IconDropdown`，是自定义 Button+popover，
                        // 所以上一轮把下拉改成 `fillsRow` 撑满时**没带上它** —— 结果邻居铺满 388、它还是 150，
                        // 被 VStack 居中后与上面几行对不齐（用户反复反馈"时长一行没跟上边对齐"就是这个）。
                        // 历史：注释里原来写"① 宽度 150（原来是 110，窄 40pt → 右边缘对不齐）"，
                        // 那是"邻居也固定宽"时代的对齐思路，邻居改成撑满后这个数字就失效了。
                        // ② 不加 .padding(.horizontal)（加了图标会比其他行右缩，左边缘对不齐）
                        // ③ 下箭头一并去掉（其他下拉的箭头已全部移除）
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 与 `IconDropdown.verticalPadding`（6）一致 —— 否则这一行会比上下几行矮一截
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.insetFill))
                    }
                    .buttonStyle(HoverHighlightButtonStyle())
                    .dropdownPopover(isPresented: $showDurationPopover) {
                        DurationPickerView(duration: $duration, range: 2...30)
                    }
                }
            }
            .padding(.horizontal, 16)
            // 原 `.vertical, 14`：分割线拿走后面向被删线的那两侧要收掉，否则留成死白
            .padding(.top, 8)
            .padding(.bottom, 8)

            // 底部按钮上方也**不加分割线**（全 App 已无分割线，标题下那条同理）

            HStack {
                Text("应用到选中的 \(app.batchShotScopeIDs.count) 个分镜，再确认提交")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onClose() }
                Button("应用") {
                    // 只对**选中的**生效（2026-09-26 用户定）；先当草稿，提交确认里点「取消」会改回去（D08）
                    app.draftBatchParameters(BatchParamConfig(
                        model: model,
                        resolution: resolution,
                        aspectRatio: aspectRatio,
                        duration: duration
                    ), ids: app.batchShotScopeIDs)
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
        // **只固定宽度，不固定高度**（同 BatchImageParamView）：写死的高度会让 sheet
        // 多出一片空白。注意这个弹窗的参数行会随模型档位增减，去掉固定高度后
        // **高度会跟着档位变**；若觉得跳动碍眼，再回来给它钉一个"最大档位"的高度。
        .frame(width: 420)
        .onAppear { prefillFromShots() }
    }

    /// 打开时预填当前项目第一个分镜的实际参数
    private func prefillFromShots() {
        // 🆕 2026-10-03（用户定）：初值**优先跟随设置里的「默认参数（新建时套用）」**——
        // 保存默认参数后这里要同步（用户实测：以前只从第一条分镜预填，弹窗不同步）。
        // 某项是"不指定"（nil）时才退回第一条分镜的现值（保留原"不改/模型对账"语义）。
        let shot = app.currentShots.first

        if let m = app.defaultVideoModel, !m.isEmpty, app.videoModelNames.contains(m) {
            model = m
        } else {
            // 模型对账：旧模型已从配置删除时不要预填（否则「不改」语义失效、还会把旧名批量写回去）
            model = shot.map { app.videoModelNames.contains($0.model) ? $0.model : "" } ?? ""
        }

        if let d = app.defaultVideoDuration {
            duration = d
        } else if let shot {
            duration = shot.duration
        }

        if let a = app.defaultVideoAspect, let v = AspectRatio(rawValue: a) {
            aspectRatio = v
        } else if let shot {
            aspectRatio = shot.aspectRatio
        }

        if let r = app.defaultVideoResolution, let v = Resolution(rawValue: r) {
            resolution = v
        } else if let shot {
            resolution = shot.resolution
        }
    }
}

/// 生视频的「导入分镜」弹窗：粘贴或拖入 txt 剧本 → 切成多张分镜卡片。
///
/// 与生图侧 `BatchImageParseView` **同构**（都支持粘贴 + 拖入 txt、都是先填进输入框让用户
/// 确认再执行），区别只在解析器与产物：那边 `ImagePromptParser` → 生图条目，
/// 这边 `ShotScriptParser` → 分镜卡片。
///
/// 入口是底部工具条的 `doc.badge.plus`（原来点它直接弹系统文件选择器；现在换成这个弹窗，
/// 但里面保留了「选择文件…」，原来那条路没丢）。
/// ⚠️ **「直接把 txt 拖到分镜列表」那条入口仍然有效**（见 `GenerateView` 的 `dropDestination`），
/// 它走的是"导完弹确认"的老流程，两条入口并存。
struct BatchShotParseView: View {
    @FocusState private var pasteFocused: Bool
    @Environment(AppModel.self) private var app
    /// 关闭回调（浮层由 RootView 呈现，没有 presentation 上下文，不能靠 `dismiss`）
    var onClose: () -> Void
    var onParse: (([String]) -> Bool)? = nil
    var title: String = "导入分镜"

    /// 拖入的 txt 路径读不出来时的提示（正常情况下底部显示用法说明或识别结果）
    @State private var dropError: String?
    /// 当前文本切出来的分镜 —— **随内容实时更新**，让用户导入前就知道会建几张卡
    @State private var parsedShots: [String] = []
    /// 「选择文件…」的系统选择器
    @State private var showPicker = false

    var body: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            TextEditor(text: $app.shotScriptText)
                .focused($pasteFocused)
                .font(.system(size: 13))
                // ⚠️ 必须隐藏 TextEditor 自带的内容背景（同 `BatchImageParseView`）：
                // 它在 macOS 上是一块不透明方形，会盖住下面那个圆角底。
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.insetFill)
                )
                .inputChrome(focused: pasteFocused, radius: 14)
                // 拖入 .txt → 把「路径文本」还原成正文。
                // ⚠️ 不用 `.dropDestination`：`TextEditor` 底层是 `NSTextView`，它**自己**注册了
                // 文件拖放且优先级更高（生图侧 2026-09-22 实测：dropDestination 完全不触发，
                // `isTargeted` 也不亮），插入的是**路径**而不是内容。所以改成"接住路径再换掉"。
                .onChange(of: app.shotScriptText) { _, newValue in
                    if TextFileReader.looksLikeTextFilePath(newValue) {
                        if let content = TextFileReader.loadIfPath(newValue), !content.isEmpty {
                            // 换成正文 → 会再触发一次 onChange，那次走下面的重新解析
                            app.shotScriptText = content
                            dropError = nil
                        } else {
                            let name = (newValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent
                            dropError = "读取失败：\(name)"
                        }
                        return
                    }
                    dropError = nil
                    reparse(newValue)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                hintText
                Spacer(minLength: 8)
                Button("选择文件…") { showPicker = true }
                    .buttonStyle(QuietButtonStyle(hover: .fill(radius: 6)))
                    .foregroundStyle(.secondary)
                Button("取消") { closeAndReset() }
                Button(onParse == nil ? "导入" : "解析") {
                    if let onParse {
                        guard onParse(parsedShots) else { return }
                    } else {
                        app.importShots(parsedShots)
                    }
                    closeAndReset()
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(parsedShots.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .frame(width: 520, height: 340)
        // 打开时若输入框里还有上次没导入的残留文本，先解析一次让计数是对的
        .onAppear { reparse(app.shotScriptText) }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result,
                  let text = TextFileReader.read(url), !text.isEmpty else { return }
            app.shotScriptText = text
            dropError = nil
        }
    }

    /// 底部说明：出错 → 红字 ｜ 有结果 → 识别数量 + 首个分镜预览 ｜ 空 → 用法说明
    @ViewBuilder
    private var hintText: some View {
        if let dropError {
            Text(dropError)
                .font(.caption)
                .foregroundStyle(Theme.danger)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if !parsedShots.isEmpty {
            Text("识别到 \(parsedShots.count) 个分镜 · 首个：\(ShotScriptParser.previewLine(of: parsedShots[0]))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else if app.shotScriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()          // 还没粘贴内容：不放「粘贴或拖入 .txt…」这类说明（2026-10-10 用户：说明文字没必要）
        } else {
            Text("没识别到分镜：每个分镜要以「[场景][角色][道具]」这样三个标签的行开头")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func reparse(_ text: String) {
        parsedShots = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : ShotScriptParser.parse(text)
    }

    private func closeAndReset() {
        app.shotScriptText = ""
        onClose()
    }
}

/// 历史操作按钮统一尺寸；仅放大按钮，不改变详情卡的内容布局。
private struct HistoryActionButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(prominent ? Theme.onAccent : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? Theme.accent : Color.primary.opacity(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
