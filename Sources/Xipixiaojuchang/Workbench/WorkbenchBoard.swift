import SwiftUI

/// 工作台的数据接口（2026-10-09）：把 app 里的分镜卡 / 生图卡 / 素材库 / 视频任务交给 `WorkbenchStatus` 算。
extension AppModel {
    /// 一个分镜的视频现在是什么情况：有任务在排队 / 生成 = 生成中；有完成的 = 已完成；最近一次失败 = 失败；其余 = 还没有
    /// `phases`：任务 id → 状态，一次算好传进来（2026-10-27 提速：原来每段都在全部任务里一个个找、还要复制整条任务，
    /// 1150 条任务 × 489 段一次要 100ms，工作台每算一遍还要找两次）
    func workbenchVideoState(_ shot: ShotDraft, phases: [String: TaskPhase]? = nil) -> WorkbenchStatus.VideoState {
        if submittingShotIDs.contains(shot.id) { return .running }
        // 单独问一段时就地找（几条任务）；整份工作台一次算好的表传进来
        let states = shot.taskIDs.compactMap { id in phases.map { $0[id] } ?? store.task(id: id)?.phase }
        if states.contains(where: { $0 == .queued || $0 == .inProgress }) { return .running }
        if shot.showsPendingVersion { return .none }      // 当前是重新推理出来的「待生成」：这一版还没生成
        if states.contains(.completed) { return .completed }
        if states.last == .failed { return .failed }
        return .none
    }

    /// 全部视频任务的 id → 状态（同一个 id 有重复时取靠前的那条，和 `TaskStore.task(id:)` 一样）
    func taskPhases() -> [String: TaskPhase] {
        Dictionary(store.tasks.map { ($0.id, $0.phase) }, uniquingKeysWith: { first, _ in first })
    }

    func workbenchBoard(project key: String, archive: ProjectPipelineArchive) -> WorkbenchStatus.Board {
        let projectShots = Dictionary(shots.filter { $0.projectKey == key }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keywords = Dictionary(library.map { ($0.id, $0.matchKeyword) }, uniquingKeysWith: { first, _ in first })
        let sourceCards = Dictionary(library.compactMap { item in item.imageGenItemID.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let phases = taskPhases()
        return WorkbenchStatus.board(.init(
            episodes: archive.episodes, shots: projectShots,
            cards: imageItems.filter { $0.projectKey == key },
            libraryKeyword: { keywords[$0] },
            videoState: { self.workbenchVideoState($0, phases: phases) },
            libraryCardID: { sourceCards[$0] },
            shotOrder: shots.compactMap { $0.projectKey == key ? $0.id : nil }))
    }
}

/// 从工作台跳到生图页看同一个东西（2026-10-09 第 4 步；跳生视频页 2026-10-15 去掉，生视频页不再有入口）
extension AppModel {
    /// 打开生图页，右栏看这张卡（缩略图模式下滚到它）。`from`：是从工作台哪一段跳来的——给了，生图页头部就有「返回」
    func workbenchOpenImageCard(_ id: UUID, from: WorkbenchLocation? = nil) {
        switchWorkspaceMode(.image)
        workbenchJumpBack = from
        inspectorKind = .image
        inspectedImageItemID = id
        guard imageViewStyle == .thumbnails else { return }
        // 延后一拍再请求滚动：刚切页时立刻请求会被「页面出现后的重排」盖掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.scrollToImageItemID = id }
        }
    }

    /// 在当前页面上盖一层大图预览：看这张卡**现在显示的那一版**（没有图什么都不做）。和生图页点预览是同一个弹层
    func workbenchPreviewImageCard(_ id: UUID) {
        guard let card = imageItems.first(where: { $0.id == id }),
              let result = WorkbenchVersions.displayedResult(of: card), result.localPath != nil else { return }
        previewingImageResultID = result.id
        previewingImageItemID = card.id
    }
}

/// 工作台这一页的分镜状态，**整页只算一次**（2026-10-12）：原来集列表、底部胶囊、分镜网格、分段弹窗、失败提示
/// 各自一个 `WorkbenchBoardReader` 各算一遍——20 集 × 30 段的项目算一次约 64ms，分镜一变就是五遍、三百多毫秒，
/// 在工作台上关一下编辑提示词弹窗都看得出卡。现在由 `WorkbenchBoardProvider` 算好放进环境，各处直接拿。
struct WorkbenchBoardValue: Equatable {
    let board: WorkbenchStatus.Board?
    /// 每算一次 +1：环境比较只看它（不去逐项比整份状态）
    let version: Int
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }
}

private struct WorkbenchBoardEnvironmentKey: EnvironmentKey {
    static let defaultValue: WorkbenchBoardValue? = nil
}

extension EnvironmentValues {
    var workbenchBoard: WorkbenchBoardValue? {
        get { self[WorkbenchBoardEnvironmentKey.self] }
        set { self[WorkbenchBoardEnvironmentKey.self] = newValue }
    }
}

/// 包在整个工作台外面：**只有它自己**跟着分镜 / 生图卡 / 素材库 / 视频任务的变化重算，算好放进环境；
/// 页面其余部分（比如正在编辑的剧本文本框）不受牵连，只有读了 `workbenchBoard` 的那几块跟着换。
///
/// 工作台常驻之后，藏着的时候（在生图 / 生视频页）**不重算**：交出上一次算好的那份，也就不去读分镜 / 生图卡 / 视频任务——
/// 生视频页轮询进度时不会连带着算整个工作台；回到工作台那一拍再算最新的
struct WorkbenchBoardProvider<Content: View>: View {
    @Environment(AppModel.self) private var app
    @ViewBuilder let content: Content
    @State private var cache = Cache()

    /// 上一次算好的（引用类型：存进去不触发重画）
    private final class Cache {
        var key: String?
        var value: WorkbenchBoardValue?
        var version = 0
        var inputs: Inputs?
    }

    /// 算工作台状态用到的东西。视频任务只看「哪个任务、什么状态」：生成中的进度每 4 秒变一次，
    /// 原来每变一次整个工作台就重算一遍（真实 297 段的项目调试版 36ms，加上网格重画一帧 70～200ms），
    /// 有视频在生成时分镜网格滑着滑着就顿一下（2026-10-15 用户：滑动卡顿）。现在进度变了、状态没变就用上一次的。
    /// 数组相等先比存储是不是同一块，没改过的比较几乎不花时间
    private struct Inputs: Equatable {
        let key: String
        let archive: ProjectPipelineArchive
        let shots: [ShotDraft]
        let cards: [ImageGenItem]
        let library: [LibraryItem]
        let submitting: Set<UUID>
        let taskPhases: [TaskPhaseKey]
    }
    private struct TaskPhaseKey: Equatable {
        let id: String
        let phase: TaskPhase
    }

    var body: some View {
        content.environment(\.workbenchBoard, value)
    }

    private var value: WorkbenchBoardValue {
        // 没分集的项目也算（2026-10-14）：只有分镜、没导入剧本的老项目，工作台要显示「其他分镜」
        guard let key = app.currentProjectKey else { return remember(nil, key: nil) }
        let archive = app.currentPipelineArchive ?? ProjectPipelineArchive(wholeScript: "", episodes: [])
        if !app.isScriptPageVisible, cache.key == key, let frozen = cache.value { return frozen }
        let inputs = Inputs(key: key, archive: archive, shots: app.shots, cards: app.imageItems, library: app.library,
                            submitting: app.submittingShotIDs,
                            taskPhases: app.store.tasks.map { TaskPhaseKey(id: $0.id, phase: $0.phase) })
        let compareStart = Date()
        if let cached = cache.value, cache.inputs == inputs { return cached }
        cache.inputs = inputs
        let buildStart = Date()
        let board = app.workbenchBoard(project: key, archive: archive)
        // 批量回传卡顿排查（2026-10-21）：每回来一张图 / 一条视频都可能让工作台重算一次；超过 15 ms 才记
        let compareMs = Int(buildStart.timeIntervalSince(compareStart) * 1000), buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
        if compareMs + buildMs > 15 { AppLog.write("perf", "工作台状态重算 \(buildMs) ms（比对输入 \(compareMs) ms）") }
        return remember(board, key: key)
    }

    private func remember(_ board: WorkbenchStatus.Board?, key: String?) -> WorkbenchBoardValue {
        if key == nil { cache.inputs = nil }
        cache.version += 1
        let value = WorkbenchBoardValue(board: board, version: cache.version)
        cache.key = key
        cache.value = value
        return value
    }
}

/// 读工作台状态：在 `WorkbenchBoardProvider` 里面就直接拿它算好的（不再自己算）；外面没有（比如单独测某一块）才自己算一份。
/// 没有项目或还没分集时交出 nil。
struct WorkbenchBoardReader<Content: View>: View {
    @Environment(AppModel.self) private var app
    @Environment(\.workbenchBoard) private var provided
    @ViewBuilder let content: (WorkbenchStatus.Board?) -> Content

    var body: some View {
        if let provided {
            content(provided.board)
        } else {
            content(ownBoard)
        }
    }

    private var ownBoard: WorkbenchStatus.Board? {
        guard let key = app.currentProjectKey else { return nil }
        return app.workbenchBoard(project: key, archive: app.currentPipelineArchive ?? ProjectPipelineArchive(wholeScript: "", episodes: []))
    }
}
