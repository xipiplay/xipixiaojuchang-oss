import Foundation
import SwiftUI
import Observation
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// 项目元数据（名称 + 创建/修改时间）
struct ProjectMeta: Codable, Equatable {
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

/// 渠道配置持有盒（供 PollingManager 闭包读取，避免 init 期间捕获 self）
@MainActor
final class ChannelBox {
    var channels: [ModelChannel] = []

    func channel(named name: String) -> ModelChannel? {
        channels.first { $0.name == name }
    }
}

/// 项目名持有盒（供 PollingManager 闭包读取，避免 init 期间捕获 self）
@MainActor
final class ProjectNameBox {
    var names: [String: String] = [:]
}

/// 应用全局状态：项目（分镜草稿）、素材库、任务存储、轮询、上传、服务渠道
@MainActor
@Observable
final class AppModel {
    let store: TaskStore
    let poller: PollingManager

    private let channelBox = ChannelBox()
    private let nameBox = ProjectNameBox()

    /// 所有服务渠道（UserDefaults `"modelChannels"` 持久化；旧键不再读取、也不删除）
    private(set) var channels: [ModelChannel] = []

    /// 音色没挂上的分镜：分镜 ID → 「周承山：渠道不收参考音频」（`syncShotVoices` 写，段落详情底下显示；不存盘）
    var voiceSyncSkips: [UUID: [String]] = [:]

    /// 按模型名找渠道/模型（同名以先出现的为准）
    func channel(forModel name: String) -> (ModelChannel, ChannelModel)? {
        guard !name.isEmpty else { return nil }
        for channel in channels {
            if let model = channel.models.first(where: { $0.name == name }) {
                return (channel, model)
            }
        }
        return nil
    }

    /// 按渠道名查找（新提交任务的 providerID 存的就是渠道名）
    func channel(named name: String) -> ModelChannel? {
        channels.first { $0.name == name }
    }

    /// 配置里所有视频模型名（分镜卡片模型下拉用）
    var videoModelNames: [String] {
        channels.flatMap { $0.models.filter { $0.capability == .video }.map(\.name) }
    }

    /// 配置里所有图片模型名（生图卡片模型下拉用）
    var imageModelNames: [String] {
        channels.flatMap { $0.models.filter { $0.capability == .image }.map(\.name) }
    }

    /// 保存渠道（新增或整体替换），并持久化
    func saveChannel(_ channel: ModelChannel) {
        if let idx = channels.firstIndex(where: { $0.id == channel.id }) {
            channels[idx] = channel
        } else {
            channels.append(channel)
        }
        persistChannels()
        poller.resumeAllInProgress()
    }

    /// 删除渠道
    func removeChannel(id: UUID) {
        channels.removeAll { $0.id == id }
        persistChannels()
    }

    private func persistChannels() {
        channelBox.channels = channels
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: "modelChannels")
        }
    }

    /// 加载渠道（init 调用）
    private func loadChannels() {
        guard let data = UserDefaults.standard.data(forKey: "modelChannels"),
              let decoded = try? JSONDecoder().decode([ModelChannel].self, from: data) else { return }
        channels = decoded
        channelBox.channels = decoded
    }

    /// 全局生成默认：音频 / 水印（设置页维护，提交时生效；H3 系列请求体不传这两个字段）
    var generateAudioDefault: Bool {
        get { UserDefaults.standard.object(forKey: "generateAudioDefault") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "generateAudioDefault") }
    }

    var watermarkDefault: Bool {
        get { UserDefaults.standard.object(forKey: "watermarkDefault") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "watermarkDefault") }
    }

    // MARK: 🎯 生成默认参数（2026-10-01 用户定：**只作新建条目/分镜的初始值**，设置页点「保存」才写入）
    // 存 raw 字符串（空 = 不指定，新建时保持现有行为）

    var defaultImageModel: String? {
        get { UserDefaults.standard.string(forKey: "defaultImageModel") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultImageModel") }
    }
    var defaultImageType: String? {
        get { UserDefaults.standard.string(forKey: "defaultImageType") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultImageType") }
    }
    var defaultImageAspect: String? {
        get { UserDefaults.standard.string(forKey: "defaultImageAspect") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultImageAspect") }
    }
    var defaultImageQuality: String? {
        get { UserDefaults.standard.string(forKey: "defaultImageQuality") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultImageQuality") }
    }
    var defaultVideoModel: String? {
        get { UserDefaults.standard.string(forKey: "defaultVideoModel") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultVideoModel") }
    }
    var defaultVideoDuration: Int? {
        get { UserDefaults.standard.object(forKey: "defaultVideoDuration") as? Int }
        set { UserDefaults.standard.set(newValue, forKey: "defaultVideoDuration") }
    }
    var defaultVideoAspect: String? {
        get { UserDefaults.standard.string(forKey: "defaultVideoAspect") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultVideoAspect") }
    }
    var defaultVideoResolution: String? {
        get { UserDefaults.standard.string(forKey: "defaultVideoResolution") }
        set { UserDefaults.standard.set(newValue, forKey: "defaultVideoResolution") }
    }

    /// 所有分镜草稿（卡片），数组顺序即分镜顺序
    var shots: [ShotDraft] = []

    /// 全局素材库（拖入即预上传）
    var library: [LibraryItem] = [] {
        // 条数变了（加 / 删）才作废下标缓存；原地改某一条不影响下标，查的时候还会核对 id
        didSet { if library.count != oldValue.count { libraryIndex = nil } }
    }
    /// 素材 ID → 在 `library` 里的下标（2026-10-10）。`libraryItem(_:)` 原来是每次从头线性找，
    /// 工作台一页要问几百次（每个素材名每个参考图），库里有上千条时一次切换要几十毫秒。
    @ObservationIgnored private var libraryIndex: [UUID: Int]?

    /// 当前项目标识（projectKey）；nil 表示未进入项目
    var currentProjectKey: String?

    /// 项目元数据映射（projectKey → 名称 + 创建/修改时间），持久化在 UserDefaults
    var projectMetas: [String: ProjectMeta] = [:]
    /// 2.0 项目文件夹读写。数据升级失败时为 nil：不存盘，避免把空数据写进项目文件夹。
    @ObservationIgnored private(set) var projectStore: ProjectStore?
    /// 各项目的剧本存档（从 project.json 还原，旧剧本页按项目取）
    @ObservationIgnored private var pipelineArchives: [String: ProjectPipelineArchive] = [:]
    @ObservationIgnored private var projectSaveWork: Task<Void, Never>?
    /// 项目数据每变一次 +1（分镜 / 生图 / 素材库 / 剧本 / 任务 / 元数据任何一处改动都走 `scheduleProjectSave`）。
    /// 制作页靠它知道什么时候重新换算当前项目（2026-10-07 P3）。
    private(set) var dataRevision = 0

    /// 工作区模式（项目内切换生图/生视频）
    enum WorkspaceMode: String, Sendable {
        case video
        case image
    }

    /// 是否在工作区（false = 主页）
    var isInWorkspace = false {
        didSet { AppLog.write("nav", "isInWorkspace: \(oldValue) → \(isInWorkspace)") }
    }

    /// 当前工作区模式
    var workspaceMode: WorkspaceMode = .video
    /// 左栏「AI」「上传」两个测试图标的状态和最近一次结果（2026-10-07：点一下就测，不再跳设置页；仅本次运行有效，重启后变暗）。
    /// 悬浮底栏（那个胶囊）的窗口坐标范围：双击缩略图 / 卡片的监听要避开它（见 `DoubleClickRegion`）。非观察，量到就写
    @ObservationIgnored var workspaceToolbarFrame: CGRect = .zero
    var aiProbe: ProbeState = .unknown
    var aiProbeMessage = ""
    var uploadProbe: ProbeState = .unknown
    var uploadProbeMessage = ""
    /// 左栏上传图标测的是哪一条（测试时的「素材上传到哪里」设置）
    var uploadProbeHost: MaterialUploadHost = MaterialUploadHostStore.load()

    /// 左栏正在跑的那次 AI 测试（设置里测了在用的配置 / 保存了新配置时作废它，晚回来的结果不再盖掉新的）
    @ObservationIgnored private var aiProbeTask: Task<Void, Never>?

    /// 点左栏 AI 图标：用**已保存**的剧本流水线 AI 设置发一次最小请求。`probe` 给测试注入。
    func testAIConnection(using probe: (() async -> ProbeResult)? = nil) {
        guard aiProbe != .testing else { return }
        aiProbe = .testing
        aiProbeTask = Task { @MainActor in
            let result: ProbeResult
            if let probe { result = await probe() } else { result = await ConnectionProbe.savedAI() }
            guard !Task.isCancelled else { return }       // 中途被设置页的测试 / 保存作废了
            aiProbe = result.ok ? .ok : .failed
            aiProbeMessage = result.message
            aiProbeTask = nil
        }
    }

    /// 设置页测的就是当前在用的那份配置：左栏图标跟着它的结果走，左栏还在跑的那次作废（2026-10-12 用户：
    /// 左栏点了测试、模型慢一直转圈；去设置里换了模型测成功了，左栏还在转）
    func reportAIProbe(_ result: ProbeResult) {
        aiProbeTask?.cancel()
        aiProbeTask = nil
        aiProbe = result.ok ? .ok : .failed
        aiProbeMessage = result.message
    }

    /// 保存了不同的 AI 配置（换模型 / 换服务商 / 改地址……）：之前的测试结果不算数了，左栏回到「没测过」，还在跑的作废
    func resetAIProbe() {
        aiProbeTask?.cancel()
        aiProbeTask = nil
        aiProbe = .unknown
        aiProbeMessage = ""
    }

    /// 点左栏上传图标：测「素材上传到哪里」现在选的那一条。`probe` 给测试注入。
    func testUploadConnection(using probe: ((MaterialUploadHost) async -> ProbeResult)? = nil) {
        guard uploadProbe != .testing else { return }
        let host = MaterialUploadHostStore.load()
        uploadProbeHost = host
        uploadProbe = .testing
        Task { @MainActor in
            let result: ProbeResult
            if let probe { result = await probe(host) } else { result = await ConnectionProbe.upload(host: host) }
            uploadProbe = result.ok ? .ok : .failed
            uploadProbeMessage = result.message
        }
    }

    /// 剧本是独立页面，图片/视频生成模式仍沿用原有枚举。
    var projectPage: ProjectPage = .production
    /// 工作台（剧本页）现在看得见。2026-10-12 起它和生图 / 生视频一样常驻、切走只是藏起来：
    /// 藏着的时候分镜状态不跟着算（见 `WorkbenchBoardReader`），Esc 也不去关它的分段弹窗
    /// 工作台（剧本模式）看得见。自由创作的项目在工作台这一页显示的是生视频那一套（见 `isFreeCreation`），工作台本身藏着
    var isScriptPageVisible: Bool { isInWorkspace && projectPage == .script && !isFreeCreation }

    /// **自由创作模式**（2026-10-14 用户：软件分剧本模式和自由创作模式）：当前项目没导入剧本、但有分镜。
    /// 这种项目的工作台就是生视频那一整套（缩略图 / 卡片、右栏、底栏），不另做一套。有剧本时不读分镜（短路）
    var isFreeCreation: Bool {
        guard let key = currentProjectKey else { return false }
        if let archive = currentPipelineArchive, !archive.wholeScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return shots.contains { $0.projectKey == key }
    }

    /// 生视频 / 生图那一整套工作区现在看得见：在生视频 / 生图页，或者在自由创作项目的工作台
    var isProductionWorkspaceVisible: Bool {
        isInWorkspace && (projectPage == .production || (projectPage == .script && isFreeCreation))
    }

    /// 工作台里的一个位置：第几集（0 起）的第几段（1 起）
    struct WorkbenchLocation: Equatable, Sendable {
        var projectKey: String
        var episodeIndex: Int
        var segment: Int
    }
    /// 离开工作台时点开的是哪一段（每个项目一个，只在内存里）：从任何入口回来都接着回到那一段，不用再从第一层点进去（2026-10-10）
    var workbenchLocations: [String: WorkbenchLocation] = [:]
    /// 从分段详情跳去生图 / 生视频页时记下来：那两页的头部据此显示「返回第 N 段」。回到工作台（不管从哪个入口）就清掉
    var workbenchJumpBack: WorkbenchLocation?
    /// 分镜页点开某一段的居中弹窗开着时 = 关掉它（2026-10-12）；没开着是 nil。
    /// Esc 由 `RootView` 的统一路由调它，排在设置 / 编辑提示词这些上层浮层之后，一次 Esc 只关一层
    @ObservationIgnored var closeWorkbenchSegmentDetail: (() -> Void)?

    /// 当前项目的剧本流水线存档（若当前项目已导入剧本）
    var currentPipelineArchive: ProjectPipelineArchive?
    let pipelineFlow = PipelineFlow()
    /// 任务中心（2026-10-06 P2）：视频 / 生图按渠道排队，剧本 AI 留记录。见 JobCenter.swift。
    let jobCenter: JobCenter
    /// 制作页的一键推进（2026-10-07 P3-2 第 3 步）。运行状态在内存里，不随页面销毁，也不跨重启。
    let workbenchRunner = WorkbenchRunner()

    /// 工作区列表的**视图样式**（2026-09-16 新增）：卡片 / 缩略图。
    ///
    /// - `.cards`：提示词 + 预览 + 参数的完整卡片，每页 5 张、带翻页
    /// - `.thumbnails`：只读缩略图网格（16:9 + 序号/名称 + 状态），**不接翻页**（普通滚动）
    ///
    /// 交互：单击 = 打开预览浮层（与卡片预览一致）；双击 = 切回卡片模式并定位到该条目。
    /// **生视频 / 生图各记各的**（2026-09-17：两个工作区都能切，互不影响）。
    /// ⚠️ **必须是存储属性**（不要写成 UserDefaults 计算属性）：`@Observable` **不跟踪计算属性** ——
    /// 计算属性版会让「点按钮写进了 UserDefaults、但所有读它的视图都不刷新」（2026-09-16 实测踩坑：
    /// 点「缩略图」日志有记录、界面纹丝不动）。
    enum WorkspaceViewStyle: String, Sendable {
        case cards
        case thumbnails
    }

    /// 视图样式（卡片 / 缩略图）——**全局一份**（2026-09-27 用户定："把生图、生视频、卡片、缩略图
    /// 理解成四个独立的按钮"：生图/视频 与 卡片/缩略图 是**两个互不干扰的维度**）。
    /// 原来两个模式各记一份（`videoViewStyle` / `imageViewStyle`）→ 切模式时样式会跳到
    /// 另一个模式上次的样子（用户实测："切换生图和生视频的时候，有时候卡片和缩略图也会跟着变" ✗）。
    /// 键沿用旧的 "workspaceViewStyle"，第一次读不到再拿旧的 "imageViewStyle" 兜底。
    // 🔒 2026-10-03（用户定）：卡片视图**已下线**——两边恒为缩略图
    //    （不再读旧偏好：以前存过 cards 的老机器也不再进卡片视图；卡片代码暂留，稳定后再删）
    var viewStyle: WorkspaceViewStyle = .thumbnails

    /// 兼容别名：老代码里的 `imageViewStyle` / `videoViewStyle` 读点都落到全局样式上
    var imageViewStyle: WorkspaceViewStyle { viewStyle }
    var videoViewStyle: WorkspaceViewStyle { viewStyle }

    /// 切样式（卡片 ↔ 缩略图）：两个模式的按钮都走这里 —— **全局生效，不动模式**（反之模式也不动它）。
    func setViewStyle(_ style: WorkspaceViewStyle) {
        guard style != viewStyle else { return }
        // ⚠️ **切换前显式存下当前视图的滚动位置**（2026-09-17 用户实测：切回来跑到第一张）。
        // 别依赖视图自己的 `onDisappear` —— 视图被拆掉时 live 可能已经被刷成 0，
        // 或者那个回调根本不触发；在 setter 里存是**确定发生、且发生在视图拆除之前**的。
        snapshotScrollOffset(for: workspaceMode)
        viewStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "workspaceViewStyle")
        AppLog.write("viewStyle", "\(workspaceMode == .video ? "视频" : "生图")工作区 → \(style.rawValue)")
    }

    func setVideoViewStyle(_ style: WorkspaceViewStyle) { setViewStyle(style) }
    func setImageViewStyle(_ style: WorkspaceViewStyle) { setViewStyle(style) }

    /// **全片全屏播放**（时间轴视图的"全屏"入口；2026-09-17）——
    /// 由 `RootView` 的全屏播放层消费，独立于预览弹窗（那边是单镜详情）
    var cinemaPlaying = false

    /// 时间轴视图里**选中的分镜**（2026-09-17 新增）。
    /// nil / 失效时视图会兜底选第一个（见 `GenerateView.timelineView` 的 onAppear）。
    /// ⚠️ 换项目时归零（`startNewProject` / `openProject`）。
    var timelineShotID: UUID?

    /// 时间轴详情卡**正在看哪一版**（nil = 看当前版本）—— 2026-09-23 新增。
    ///
    /// ⚠️ **只影响详情卡的显示**（播放器 / 脚本 / 参数条），**绝不动 `shot.taskID`**：
    /// `shot.taskID` 是「当前版本」，它同时决定时间轴上那一段的**时长和播的视频** ——
    /// 动它会把整条导轨的布局搅乱。要真正换版本得走「应用此版本」（`setCurrentVersion`）。
    /// 这就是"看"和"用"两段式的实现基础。
    ///
    /// 换选中的分镜时归零（否则会拿着上个分镜的版本 id 去查这个分镜，查不到）
    var timelineDisplayTaskID: String?


    /// 历史版本抽屉（右侧；与任务抽屉互斥）—— 2026-09-23
    var showHistoryDrawer = false    /// 抽屉里显示的是**哪张卡**的版本（点「查看历史」时记下；关抽屉时清）
    var historyDrawerShotID: UUID?

    /// 时间轴播放时钟（**普通 class，非观察对象**：播放器每 1/30 秒写、播放头每帧读，
    /// 放这里是为了**全屏连播层也能读写它** —— 进出全屏时位置要对得上（2026-09-18）。
    /// 原来是 `GenerateView` 的 `@State`，那样全屏层拿不到、退出全屏播放头就停在旧位置）。
    let timelineClock = TimelineClock()

    /// 时间轴播放头**强制刷新**计数：`timelineClock` 不参与观察，点已选中的段 / 退出全屏
    /// 这类"只动了时钟、没动别的状态"的操作不会触发时间轴重算 → 播放头不动。
    /// 这些地方 +1，时间轴 body 读它 → 保证重算一次（2026-09-18 实测的"播放头卡住"）
    var timelinePlayheadRevision = 0

    /// 把"当前视图样式"对应的 live 滚动偏移抄进 saved 快照（切换视图前调用）。
    /// 四种组合各自独立（卡片/缩略图 × 生视频/生图），互不串位。
    private func snapshotScrollOffset(for mode: WorkspaceMode) {
        if mode == .video {
            if videoViewStyle == .cards {
                scrollAnchors.savedShotOffset = scrollAnchors.liveShotOffset
            } else {
                scrollAnchors.savedThumbOffset = scrollAnchors.liveThumbOffset
            }
        } else {
            if imageViewStyle == .cards {
                scrollAnchors.savedImageOffset = scrollAnchors.liveImageOffset
            } else {
                scrollAnchors.savedImageThumbOffset = scrollAnchors.liveImageThumbOffset
            }
        }
        AppLog.write("viewStyle", "存滚动位置 \(mode.rawValue)/\(mode == .video ? videoViewStyle.rawValue : imageViewStyle.rawValue)")
    }

    /// 底栏图标**悬停放大倍数**（程序坞式，设置页可调，2026-09-17 用户要求）。
    /// ⚠️ 同 `workspaceViewStyle`：**必须是存储属性**（@Observable 不跟踪 UserDefaults 计算属性），
    /// 否则设置页拖滑块时底栏不会实时跟着变。
    var dockHoverScale: Double = {
        let saved = UserDefaults.standard.double(forKey: "dockHoverScale")
        return saved == 0 ? 1.35 : min(max(saved, 1.0), 2.0)   // 0 = 没存过 → 默认 1.35
    }()

    func setDockHoverScale(_ scale: Double) {
        let clamped = min(max(scale, 1.0), 2.0)
        guard clamped != dockHoverScale else { return }
        dockHoverScale = clamped
        UserDefaults.standard.set(clamped, forKey: "dockHoverScale")
    }

    /// 任务抽屉是否展开（默认收起，点顶栏按钮滑出）
    var showTaskDrawer = false

    /// 素材库抽屉是否展开（默认收起，点「素材库」按钮或素材区的「添加」滑出）。
    ///
    /// **它和任务抽屉互斥**（用户 2026-09-12 定）：一左一右同时开会把中间挤得只剩一小块。
    /// 互斥在 `toggleLibraryDrawer` / `toggleTaskDrawer` 里各管一次。
    ///
    /// ⚠️ **这一层必须挂在 `RootModals` 之后**（见 `LibraryDrawerLayer`）——
    /// 任务抽屉那套放在工作区的 ZStack 里，位于提示词弹窗**之下**；
    /// 而素材库的核心用途就是"从抽屉里把素材拖进提示词弹窗"，必须在弹窗之上才拖得起来。
    var showLibraryDrawer = false

    /// 打开素材库抽屉时的**宿主**：分镜 / 图片条目的素材区。
    /// `nil` = 纯浏览（双击走预览）。非 nil 时双击素材 = 直接加进那个素材区。
    var libraryDrawerTarget: MaterialOwner?

    /// 当前打开的**应用内浮层**（nil = 没有）。
    ///
    /// **所有弹窗的状态都集中在这里**，取代原来分散在各视图里的 `.sheet` 开关：
    /// ① `.sheet` 是独立窗口 + 模态会话，打开时主线程会被滑入动画的嵌套 run loop 堵住
    ///    （实测 ≈0.9s，表现为转圈 + 按钮失效）；
    /// ② 改成应用内浮层后必须挂在**根视图**（`RootView`）才能盖住整窗 ——
    ///    挂在工作区里只盖得住中栏。所以开关不能再放在各视图的 `@State` 里。
    ///
    /// 内容按 case 取（需要的数据用 ID 带过来，根视图再从 `shots` / `imageItems` 查）。
    /// 「素材选择」弹窗挂在谁身上——分镜和图片条目都有素材区，两边的增删改各写各的数据结构。
    enum MaterialOwner: Equatable {
        case shot(UUID)
        case imageItem(UUID)
    }

    enum AppModalKind: Equatable {
        case settings
        case batchParam                                  // 内容按 workspaceMode 选生视频/生图两套
        case editVideoPrompt(shotID: UUID)
        case batchParse                                  // 生图：批量解析提示词 → 生图条目
        case batchParseShots                             // 生视频：导入分镜（粘贴/拖入 txt 剧本）
        case editImagePrompt(itemID: UUID)
        case confirmDeleteShot(shotID: UUID)   // 分镜垃圾桶的删除确认（2026-09-17）
        case confirmDeleteImage(itemID: UUID)  // 图片卡片垃圾桶的删除确认
        /// 生视频页单击分镜：打开和工作台同一个段落详情（2026-10-26 用户：生视频弹窗要和段落详情一样）
        case segmentDetail(shotID: UUID)
    }

    var activeModal: AppModalKind?
    /// 叠在段落详情上面的生图编辑弹窗（2026-10-26：生视频页打开的段落详情占着 `activeModal`，
    /// 里面点「编辑这张卡」不能把它顶掉——叠一层，关掉就看到后面的详情，和工作台里一样）
    var stackedImageEditorID: UUID?

    /// 生图侧「正在右栏查看的条目」——2026-09-27 从 `ImageGenPanel` 提上来：右栏改成
    /// **共享右侧栏**（挂在 RootView 层，切换生图/生视频不拆建），选中态就得放在页面之外。
    var inspectedImageItemID: UUID?

    /// 共享右栏显示哪一边（生图 / 视频）——**只跟"点击条目"走，不跟页面切换走**
    ///（2026-09-27 用户："切换生图和生视频，右边详情还是跟着变" ✗ → 点谁才显示谁）。
    /// 打开项目 / 首次进入时按当前模式给初值（见 RootView 的页壳）。
    enum InspectorKind { case image, video }
    var inspectorKind: InspectorKind = .image

    /// 多选：生图条目 / 视频分镜的选中集合——2026-09-27 提到这里：
    /// **共享底栏要随选中态换内容**（没选中 = 现在那些按钮；选中 = 删除/设置/提交/取消），
    /// 选中态必须放在页面之外（四个页面 + 共享底栏都读它）。
    var selectedImageItemIDs: Set<UUID> = []
    var selectedShotIDs: Set<UUID> = []

    /// 批量工具条操作的是分镜还是生图卡（2026-10-14：工作台分镜网格也能拖选，批量操作和生视频页同一套；在工作台上一律是分镜）
    var batchTargetsShots: Bool { projectPage == .script || workspaceMode == .video }

    /// 工作台批量条点了哪个按钮：删除 / 批量匹配 / 批量提交。按钮在工作台底部胶囊里，确认框和后续流程在 RootView（和生视频页共用），
    /// RootView 看到它变了就接着做。`token` 每次都换：连点同一个也会再触发
    enum ShotBatchAction: Equatable { case delete, match, submit }
    struct ShotBatchRequest: Equatable {
        let action: ShotBatchAction
        let token = UUID()
    }
    var shotBatchRequest: ShotBatchRequest?

    /// 批量设置参数的**作用范围**（当前多选）——打开批量弹窗前由面板写入。
    /// 2026-09-26 用户定："批量设置参数和批量提交的逻辑，只对选中的生效"。
    var batchImageScopeIDs: [UUID] = []
    var batchShotScopeIDs: [UUID] = []
    /// 批量设置参数是批量提交的第一步（2026-10-12 用户定：拖选 → 批量提交 → 设参数 → 应用 → 确认提交）。
    /// 弹窗里点「应用」就 +1，底部工具条看到变化接着弹提交确认
    var batchParamsAppliedForSubmit = 0
    /// 批量设置参数的草稿（D08，2026-10-23 用户定「点取消就不写回」）：点「应用」时先写进卡片（检查和提交都读卡片），
    /// 这里记下改之前的那几张；提交确认点「提交」/「只保存参数」才算数（`keepBatchParamDraft`），
    /// 点「取消」或检查没过就按原值改回去（`revertBatchParamDraft`）
    @ObservationIgnored private(set) var batchParamDraftOriginals: (shots: [ShotDraft], images: [ImageGenItem])?

    /// 「批量解析」粘贴框里的文本。
    /// 原来在 `ImageWorkspaceView` 的 `@State` 里、靠 `@Binding` 层层传下去；
    /// 浮层改由 RootView 呈现之后那个 Binding 跨不过去，所以提到这里。
    var imagePasteText = ""

    /// 「导入分镜」粘贴框里的文本（生视频侧）。与 `imagePasteText` 同理提到这里。
    var shotScriptText = ""

    /// 两个工作区的**分页页码**（生图 / 生视频各一个）。
    ///
    /// 原来各自是 `ImageWorkspaceView` / `GenerateView` 里的 `@State`，问题在于：
    /// 切换生图/生视频时 RootView 是用 `if/else` 换视图的，而 **SwiftUI 会把离开视图树的
    /// `@State` 整个丢掉** —— 你翻到第 3 页、切走再切回来，就回到第 1 页了（用户 2026-09-12 反馈）。
    /// 提到这里（环境对象不随视图销毁）之后，来回切换能停在原来那一页 ✓
    ///
    /// ⚠️ **换项目时必须归零**：`startNewProject` / `openProject` 里都写了。
    /// 不归零的话会带着上个项目的页码进新项目（条目少时还要靠视图里的越界校正兜底，很别扭）。
    /// ⚠️ 视图里**不要**再把这个状态写回 `@State` —— 那等于把这条修复撤销掉。
    var imagePage = 0
    var videoPage = 0

    /// **非观察缓存**：两个工作区"上次滚到哪一条目"，用来在视图被摘掉重建后把滚动位置接回去。
    ///
    /// ⚠️ **必须是普通 class，不能是 `@Observable` 里的普通属性**（`@State` 同理）：
    /// 记录滚动位置的那个回调**每帧都在写**，写可观察状态 → 视图标脏 →
    /// 整个面板（几十张卡片）重算 —— 正是 `Components.swift` 里 `FrameCache` 那条注释
    /// sample 实锤过的掉帧根因。写成普通 class 之后，写它**不触发任何重算** ✓
    ///
    /// 又为什么放这儿而不是视图里的 `@State`：**它得活得比视图久** —— 切换生图/生视频时
    /// 工作区整个被摘掉，`@State` 跟着一起没；放这儿才留得住（和上面的 `imagePage` 同一个理由）。
    let scrollAnchors = ScrollAnchors()

    final class ScrollAnchors {
        /// 持续记录的**滚动偏移**（`contentOffset.y`），由 `.onScrollGeometryChange` 每帧写。
        ///
        /// ⚠️ **存偏移，不存"最上面是哪一条"** —— 2026-09-12 实测：`.scrollPosition(id:)`
        /// 在这两个列表上**报不出条目**。它会触发，但写进绑定里的**永远是 nil**（app.log 里
        /// 连续两条 `live ← nil`，而同一时刻 `.onScrollGeometryChange` 报的偏移已经走到 641）。
        /// 原因没继续深究（`.id()` 显式标识 vs ForEach 标识、或 LazyVStack 的惰性都在嫌疑内），
        /// 换成 `.onScrollGeometryChange` + 按偏移恢复之后整条链路都稳 ✓
        ///
        /// 按偏移恢复还有个额外好处：**比按条目精确** —— 不会出现"从这张卡开始"的偏差。
        var liveImageOffset: CGFloat = 0
        var liveShotOffset: CGFloat = 0

        /// **离开时的快照**，由 `.onDisappear` 从 live 抄一次。**恢复只认这个**。
        /// `nil` = 从没存过 → 首次进项目/刚换项目时不滚，停在顶部 ✓
        var savedImageOffset: CGFloat?
        var savedShotOffset: CGFloat?

        /// 缩略图模式的滚动偏移 —— **与卡片模式各存各的**：
        /// 两种布局的条目高度完全不同，共用一个值会在切换视图时串位（2026-09-16）
        var liveThumbOffset: CGFloat = 0
        var savedThumbOffset: CGFloat?

        /// 生图工作区缩略图模式的滚动偏移（同上，生图侧 2026-09-17 加）
        var liveImageThumbOffset: CGFloat = 0
        var savedImageThumbOffset: CGFloat?
    }

    /// 请求图片工作区滚动到某条目（点任务抽屉行时设置）
    var scrollToImageItemID: UUID?

    /// 打开预览的生图条目 ID（nil = 未打开；RootView 按窗口比例渲染预览弹窗）
    var previewingImageItemID: UUID?

    /// 生图预览选中的版本 ID
    var previewingImageResultID: UUID?

    /// 从生图缩略图详情的大图打开的素材库样式单图预览。
    var previewingStandaloneImagePath: String?
    var previewingStandaloneImageFileName: String?

    /// 任务抽屉开关。与素材库抽屉**互斥且可互切**。
    ///
    /// ⚠️ 2026-09-19 用户要求改的：素材库开着时点「任务」→ **直接切过去**
    ///（关素材库 + 开任务抽屉）。原来是"只关不开"，用户看着像"点一下缩回去了"。
    /// 注意：要真正切得动，底栏那条不能被捕获层盖住（见 RootView 捕获层的"底部让位"）。
    /// 这里**不带动画**，动画一律由调用点的 `withAnimation` 提供（既有约定，别改）。
    func toggleTaskDrawer() {
        if showLibraryDrawer {
            closeLibraryDrawer()
            showTaskDrawer = true
            return
        }
        showTaskDrawer.toggle()
    }

    /// 历史版本抽屉：打开（**与另外两个抽屉互斥**）—— 2026-09-23
    ///
    /// 由时间轴详情卡的「查看历史」调用；`shotID` 记下是**哪张卡**，抽屉据此列出它的所有版本。
    func openHistoryDrawer(shotID: UUID) {
        historyDrawerShotID = shotID
        showHistoryDrawer = true
        // 互斥：一次只开一个抽屉（同 2026-09-19 定的规矩）。这里不带动画，动画在调用点。
        showLibraryDrawer = false
        showTaskDrawer = false
        libraryDrawerTarget = nil
    }

    /// 关历史版本抽屉。
    /// ⚠️ **不清 `timelineDisplayTaskID`** —— 关掉抽屉后那张卡还停在"正在看第 N 版"，
    /// 用户可以在卡上点「应用此版本」再决定。清掉的话抽屉一关就白选了（2026-09-23）
    func closeHistoryDrawer() {
        showHistoryDrawer = false
    }

    /// 素材库抽屉开关。同样与任务抽屉互斥**且可互切**（同 `toggleTaskDrawer`）。
    ///
    /// `target`：本次打开是"要往哪个素材区里加东西"。素材区的「添加」按钮会传进来；
    /// 顶栏的「素材库」按钮传 nil（纯浏览，双击走预览）。
    func toggleLibraryDrawer(target: MaterialOwner? = nil) {
        // 已经是开着、且这次带了新目标 → 只换目标、不关抽屉
        // （否则"在弹窗里点添加"会先把已经开着的抽屉关掉，看着像没反应）
        if showLibraryDrawer, target != nil {
            libraryDrawerTarget = target
            return
        }
        // 任务抽屉开着 → **直接切过去**（关任务 + 开素材库）。
        // **但"素材区点添加"这种明确意图除外**（target 非 nil）—— 那是用户明确要开素材库，
        // 不该被"顺手关掉任务抽屉"吃掉。
        if showTaskDrawer, target == nil {
            showTaskDrawer = false
            showLibraryDrawer = true
            libraryDrawerTarget = nil
            return
        }
        showLibraryDrawer.toggle()
        if showLibraryDrawer {
            libraryDrawerTarget = target
            showTaskDrawer = false          // 互斥
        } else {
            libraryDrawerTarget = nil
        }
    }

    /// 收起素材库抽屉（点外面 / Esc 用）。**只关抽屉，不动 `activeModal`** ——
    /// 用户定的规则是"点抽屉外面只关抽屉，提示词弹窗留着"。
    func closeLibraryDrawer() {
        showLibraryDrawer = false
        libraryDrawerTarget = nil
    }

    /// 关掉最上面那层浮层 —— 顶栏控件在"有浮层开着"时统一走这个。
    ///
    /// 对应全 App 的规则「**弹层开着时，点外面只是关掉它，不再同时触发别的**」
    /// （用户早前明确定过："点按钮出现弹窗，再点另一个按钮是关闭"）。
    ///
    /// ⚠️ **不带动画** —— 和本文件其他开关一样，动画由调用点包 `withAnimation` 提供（既有约定）。
    /// 调用点共两处：`RootView.closeTopmostOverlay()`（模式切换的罩子）和
    /// `TopBarButton.handleTap()`（顶栏按钮）。**两处都必须是动画版** ——
    /// 漏一处就表现为"抽屉瞬间收回、滑出动画没了"（用户实测 2026-09-13）。
    ///
    /// ⚠️ 这段状态逻辑**曾经在两处各写一份**，结果就是一边补了 `withAnimation`、
    /// 另一边没有，动画在两个入口表现不一致。**别再把它复制回去。**
    func dismissTopmostOverlay() {
        if showLibraryDrawer {
            closeLibraryDrawer()
        } else if showHistoryDrawer {
            closeHistoryDrawer()
        } else if showTaskDrawer {
            showTaskDrawer = false
        } else {
            activeModal = nil
        }
    }

    /// 把素材加进"抽屉当前的宿主"（双击素材时调）。
    /// 返回 `false` = 这次打开抽屉没有宿主（纯浏览）→ 调用方按原来的语义走预览。
    @discardableResult
    func addToDrawerTarget(_ libraryItemID: UUID) -> Bool {
        switch libraryDrawerTarget {
        case .shot(let shotID):
            addShotMaterial(shotID: shotID, libraryItemID: libraryItemID)
        case .imageItem(let itemID):
            addImageItemMaterial(itemID: itemID, libraryItemID: libraryItemID)
        case nil:
            return false
        }
        return true
    }

    /// 当前项目进行中的任务数（左栏任务图标角标）：视频 + 生图 + 剧本 AI（2026-10-06 P2 合并）。
    /// ⚠️ 必须按当前项目数（2026-09-19 修过：数全局的话别的项目会让角标虚高）。
    var activeTaskCount: Int {
        guard let key = currentProjectKey else { return 0 }
        let videos = store.tasks.filter { $0.groupKey == key && ($0.phase == .queued || $0.phase == .inProgress) }.count
        let images = imageItems.filter { $0.projectKey == key && $0.status.isBusy }.count
        let records = jobCenter.records
        // 推理分镜整批那一行不单独算（抽屉里也不显示）：一批 = 正在做的那一集
        let ai = records.filter { $0.kind == .ai && $0.projectKey == key && $0.state.isActive
            && !JobCenter.hidesBatchDriver($0, among: records) }.count
        return videos + images + ai
    }

    // MARK: 素材链接检查（2026-09-18 用户要求：「检查链接 + 一键重传」）

    /// 链接检查结果：id → 是否可用（nil = 还没查过）
    var libraryLinkStatus: [UUID: Bool] = [:]
    /// 正在批量检查
    var checkingLibraryLinks = false
    /// 检查进度（已完成 / 总数）
    var libraryLinkProgress: (done: Int, total: Int) = (0, 0)
    /// 正在批量重传
    var reuploadingLibrary = false

    /// 失效（查过且不可用）的素材数
    var deadLibraryLinkCount: Int {
        currentProjectLibrary.filter { libraryLinkStatus[$0.id] == false }.count
    }

    /// 最近一次「检查链接」的结果说明（素材库底部显示；下次检查前保留）
    var libraryLinkCheckNote: String?

    /// 批量检查当前项目素材的远程链接是否还能用。
    ///
    /// 2026-10-09 用户：「批量入库后点检查链接，出现很多失效，但素材其实已经上传成功了」。原来：
    /// ① 还在上传（没有直链）的也算失效——批量入库是 167 张同时在传；② 失效标记存下来后，素材传完了也不消；
    /// ③ 网络抖动 / 429 / 5xx 一律当失效。现在：
    /// - **还在上传的不检查**（还没有直链），并清掉它们身上的旧失效标记；
    /// - **上传失败的算失效**（2026-10-09 用户：「批量入库有几个失败的，检查链接只报成功的，失败的直接不查了」）：它们没有可用的链接，
    ///   标成失效、计入「失效 N 个」，「重传失效」会把它们一起重传；
    /// - 单个链接按 `LibraryLinkProbe` 判定：临时性问题自动重试，多次仍没答复的算「没能确认」，**不标失效**；
    /// - 结果说明（检查了几个、失效几个、没能确认几个、跳过几个）写在素材库底部，失效 / 没能确认的原因记进日志。
    func checkLibraryLinks(session: URLSession? = nil, retryDelays: [Duration] = LibraryLinkProbe.defaultRetryDelays) async {
        guard !checkingLibraryLinks else { return }
        checkingLibraryLinks = true
        libraryLinkCheckNote = nil
        let all = currentProjectLibrary
        let items = all.filter { $0.uploadState == .uploaded }
        let uploadFailed = all.filter { $0.uploadState == .failed }
        let stillUploading = all.count - items.count - uploadFailed.count
        for item in all where item.uploadState == .pending || item.uploadState == .uploading { libraryLinkStatus[item.id] = nil }
        libraryLinkProgress = (0, items.count)
        var status: [UUID: Bool] = [:]
        var unsure = 0
        var problems: [String] = []
        for item in uploadFailed {
            status[item.id] = false
            problems.append("失效 \(item.fileName ?? item.matchName)：上传失败，没有可用的链接")
        }
        var done = 0
        await withTaskGroup(of: (UUID, String, LinkVerdict).self) { group in
            var iterator = items.makeIterator()
            func start(_ item: LibraryItem) {
                group.addTask { (item.id, item.fileName ?? item.matchName, await LibraryLinkProbe.verdict(for: item.remoteURL, session: session, retryDelays: retryDelays)) }
            }
            // 并发 8 路：既快又不至于把对端打急
            for _ in 0..<8 {
                guard let item = iterator.next() else { break }
                start(item)
            }
            for await (id, name, verdict) in group {
                switch verdict {
                case .alive: status[id] = true
                case .dead(let reason): status[id] = false; problems.append("失效 \(name)：\(reason)")
                case .unsure(let reason): unsure += 1; problems.append("没能确认 \(name)：\(reason)")
                }
                done += 1
                await MainActor.run { self.libraryLinkProgress = (done, items.count) }
                if let next = iterator.next() { start(next) }
            }
        }
        for (id, ok) in status { libraryLinkStatus[id] = ok }
        // 检查过但「没能确认」的：不留旧标记（旧的失效 / 可用都不作数了）
        let confirmed = Set(status.keys)
        for item in items where !confirmed.contains(item.id) { libraryLinkStatus[item.id] = nil }
        checkingLibraryLinks = false
        let dead = status.values.filter { !$0 }.count
        var parts = ["已检查 \(items.count + uploadFailed.count) 个",
                     "失效 \(dead) 个" + (uploadFailed.isEmpty ? "" : "（其中 \(uploadFailed.count) 个是上传失败的，可点「重传失效」）")]
        if unsure > 0 { parts.append("没能确认 \(unsure) 个（网络或对方限流，稍后再查）") }
        if stillUploading > 0 { parts.append("还在上传的 \(stillUploading) 个没查") }
        libraryLinkCheckNote = parts.joined(separator: " · ")
        AppLog.write("library", "链接检查完成：" + parts.joined(separator: "，"))
        for line in problems.prefix(30) { AppLog.write("library", "链接检查 " + line) }
    }

    /// 一键重传所有失效链接的素材（本地文件还在 → 重新上传拿新链接；批量入库时上传失败的也在里面）。
    /// 结果写在素材库底部那行说明里：成功几个、没成功几个（本地文件没了 / 又失败了），没成功的仍留着失效标记，可以再点。
    func reuploadFailedLinks() async {
        guard !reuploadingLibrary else { return }
        reuploadingLibrary = true
        let dead = currentProjectLibrary.filter { libraryLinkStatus[$0.id] == false }
        var succeeded = 0, noFile = 0, failed = 0
        for item in dead {
            guard let path = item.localPath, FileManager.default.fileExists(atPath: path) else { noFile += 1; continue }
            let service = uploadService
            let draft = ReferenceDraftItem.local(url: URL(fileURLWithPath: path))
            do {
                let remote = try await service.upload(draft)
                guard let idx = library.firstIndex(where: { $0.id == item.id }) else { continue }
                library[idx].remoteURL = remote.url
                library[idx].uploadState = .uploaded
                libraryLinkStatus[item.id] = true
                persistLibrary()
                succeeded += 1
            } catch {
                failed += 1
                AppLog.write("upload", "重传失败（\(item.fileName ?? item.matchName)）：\(error.localizedDescription)")
            }
        }
        reuploadingLibrary = false
        var parts = ["重传完成：成功 \(succeeded) 个"]
        if failed > 0 { parts.append("又失败 \(failed) 个（网络或上传服务的问题，稍后可再点）") }
        if noFile > 0 { parts.append("本地文件已不在 \(noFile) 个（没法重传）") }
        libraryLinkCheckNote = parts.joined(separator: " · ")
        AppLog.write("library", "批量重传完成：" + parts.joined(separator: "，"))
    }

    /// 素材库里**上传失败**的条数（当前项目）—— 底栏素材库图标显示三角叹号用
    var libraryUploadFailedCount: Int {
        currentProjectLibrary.filter { $0.uploadState == .failed }.count
    }

    /// 任务里**失败**的条数（当前工作区）—— 底栏任务图标显示三角叹号用
    var failedTaskCount: Int {
        switch workspaceMode {
        case .video:
            // ⚠️ **必须与任务列表同源**（`currentProjectTasks`）——2026-09-19 修：
            // 原来数的是**全局** `store.tasks` → 别的项目里有失败任务时，当前项目明明没任务
            // 也一直挂着三角叹号（用户实测："没有任务为什么还是有叹号"）。
            return currentProjectTasks.filter { $0.phase == .failed }.count
        case .image:
            return currentImageItems.filter { $0.status == .failed }.count
        }
    }

    /// 图片生成条目（批量解析产物，含生成状态与结果）
    var imageItems: [ImageGenItem] = [] {
        // 同 `library`：条数变了才作废下标缓存；原地改某一条、换了顺序都没关系（查的时候核对 id，对不上就重建）
        didSet { if imageItems.count != oldValue.count { imageItemIndex = nil } }
    }
    /// 生图卡 ID → 在 `imageItems` 里的下标（2026-10-15 用户：项目有了素材后打开 / 关闭很卡）。
    /// 工作台每张段卡、每个素材名、每张参考图都要按 id 找生图卡，原来每次在所有项目的 2000 多张卡里从头找
    @ObservationIgnored private var imageItemIndex: [UUID: Int]?

    /// 当前打开预览弹窗的分镜 ID（nil = 未打开）
    var previewingShotID: UUID?
    /// 视频大预览右上角的「编辑分镜」（2026-10-14 用户）：只有从工作台分镜网格打开的大预览才有，点了打开这一段的二级页面。
    /// 大预览关掉时清掉（见 RootView）；从生视频页打开的没有
    var shotPreviewEditSegment: (() -> Void)?
    /// 点「编辑分镜」时记下的大预览（2026-10-15 用户：二级页面在大图之上，关掉二级页面还是大图）。
    /// 两个弹窗不在一层，二级页面没法真的叠在大预览上：点按钮时大预览先收起、记在这里，二级页面关掉时 `reopenShotPreviewAfterSegmentDetail` 把它放回来
    @ObservationIgnored var shotPreviewReturn: (shotID: UUID, edit: () -> Void)?

    /// 二级页面关掉了：如果它是从大预览的「编辑分镜」打开的，把大预览放回来（分镜已经删了就不放）
    func reopenShotPreviewAfterSegmentDetail() {
        guard let back = shotPreviewReturn else { return }
        shotPreviewReturn = nil
        guard previewingShotID == nil, shots.contains(where: { $0.id == back.shotID }) else { return }
        shotPreviewEditSegment = back.edit
        previewingShotID = back.shotID
    }

    /// 分镜预览弹窗是否处于「视频全屏」：RootView 据此把浮层从 86%×82% 改成**铺满整个窗口**，
    /// 配合窗口全屏就得到"视频占满屏幕"的效果（自绘播放器后系统那套全屏没了，只能这么做）。
    var previewFullscreen = false

    /// RootView 注入的「淡出后关闭预览弹窗」处理器（打开预览弹窗时可用）
    var previewCloseRequest: (() -> Void)?

    /// 请求中间列滚动到某分镜（点击任务列表任务时设置）
    var scrollToShotID: UUID?

    /// 任务列表筛选状态
    var taskFilter: TaskFilter = .all

    // MARK: - 项目

    struct ProjectSummary: Identifiable {
        let key: String
        let createdAt: Date
        let updatedAt: Date
        let shotCount: Int
        let taskCount: Int
        var id: String { key }
    }

    /// 主页历史项目列表（合并分镜草稿 + 任务）
    /// `projects` 的缓存（2026-09-13）。
    /// ⚠️ 必须 `@ObservationIgnored` —— 否则"写缓存"本身会触发观察者刷新，形成自反馈循环（项目里踩过）。
    @ObservationIgnored private var projectsCache: (sig: Int, value: [ProjectSummary])?

    /// 缓存签名：**只用数字**（三个集合的规模 + 元数据更新时间之和）。
    /// ⚠️ **别把 String 塞进来做哈希**：Swift 的 String 哈希是 **NFC 感知**的，中文下极贵
    ///（2026-09-11 踩过 —— 签名里 combine 任务 id 直接把 Unicode 规范化顶到采样栈顶）。
    private var projectsSignature: Int {
        var s = shots.count &* 31 &+ store.tasks.count
        s = s &* 31 &+ projectMetas.count
        var t: Double = 0
        for (_, m) in projectMetas { t += m.updatedAt.timeIntervalSince1970 }
        return s &* 31 &+ Int(t)
    }

    var projects: [ProjectSummary] {
        // **必须缓存**：这个计算要遍历全部分镜（280+）+ 全部任务，还要建集合 / map / sort，
        // 而它在主页 body 里 —— body 每次重算都跑一遍（实测"点开项目"时 `WelcomeView.body` 重算 29 次、
        // `projects` 16 次，是那 283ms 等待的主要来源之一；主页明明不可见却照样在算）。
        // 作废有两道保险：① 签名变了就重算；② `touchProject` 里直接清空（项目数据变动的必经之路）。
        let sig = projectsSignature
        if let cached = projectsCache, cached.sig == sig { return cached.value }
        var shotCount: [String: Int] = [:]
        var taskCount: [String: Int] = [:]
        for shot in shots where !shot.projectKey.isEmpty {
            shotCount[shot.projectKey, default: 0] += 1
        }
        for task in store.tasks {
            taskCount[task.groupKey, default: 0] += 1
        }
        // 所有创建过的项目都显示（含空项目：新建后直接关闭也在历史列表里）
        // 2.0：项目 = 有项目文件的；只剩任务记录的 key（如不迁移的压测项目）不再列出
        let keys = Set(projectMetas.keys).union(shotCount.keys)
        let result = keys.map {
            let meta = projectMetas[$0]
            return ProjectSummary(
                key: $0,
                createdAt: meta?.createdAt ?? .distantPast,
                updatedAt: meta?.updatedAt ?? .distantPast,
                shotCount: shotCount[$0] ?? 0,
                taskCount: taskCount[$0] ?? 0
            )
        }
        // ⚠️ 必须给**并列**一个确定性的定序规则。
        // 上面的 `keys` 是 `Set`，遍历顺序是**哈希序**；而 `sorted` 只比 updatedAt，
        // 一旦两条的时间相同（`updatedAt` 有 `?? .distantPast` 的兜底，并列是真实存在的），
        // 相对顺序就由 Set 的哈希序决定 —— 任何一次重算都可能换个顺序，
        // 表现为"主页项目顺序会乱跳"（悬停「开始创作」写 @State、切到别的 App 都会触发重算）。
        .sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.key < $1.key   // 并列时按 key（稳定且唯一）
        }
        projectsCache = (sig, result)
        return result
    }

    /// 项目 key → 该项目「最新一个可播放视频」的本地路径（主页项目卡片缩略图用）。
    ///
    /// ⚠️ **必须缓存，不能写成"每张卡在 body 里现算"**：
    /// 原来 `ProjectCard.thumbnailTask` / `ProjectGridCell.thumbnailTask` 是计算属性，
    /// 每次 body 求值都 `filter` 全部任务（100+ 条）**并对候选逐个 `FileManager.fileExists`**
    /// —— 窗口缩放时 body 反复重算，一屏几十张卡 × 上百任务 × 每帧 = **每帧成千上万次文件系统调用**。
    /// `sample` 实测：缩放期间的热点就是 `ProjectCard.thumbnailTask.getter`。
    /// 这里用"任务 id + 路径"的哈希做签名，没变直接返回缓存；`@ObservationIgnored`
    /// 保证**写缓存不会触发视图刷新**（否则又变成自反馈循环）。
    @ObservationIgnored private var thumbnailPathCache: (signature: Int, map: [String: String]) = (0, [:])

    var projectThumbnailPaths: [String: String] {
        let tasks = store.tasks
        // ⚠️ 签名**只能用整数运算**。第一版我写成 `hasher.combine(t.id)` / `combine(t.localVideoPath)`，
        //    结果 `sample` 里 `_StringGutsSlice._fastNFCCheck`（Unicode 规范化）直接顶到栈顶 ——
        //    **Swift 的 String 哈希是 NFC 感知的**，130 条任务 × 每张卡 × 每帧 = 每帧几千次
        //    带规范化的字符串哈希，量级和原来的 fileExists 一样糟。
        //    这里改成：任务数 + 有视频的任务数 + 各任务 updatedAt 之和 —— 全是数字，且任何
        //    任务被增删改（updatedAt 变化）都会让签名变。
        var withPath = 0
        var stampSum = 0.0
        for t in tasks {
            if t.localVideoPath != nil { withPath += 1 }
            stampSum += t.updatedAt.timeIntervalSince1970
        }
        let signature = tasks.count &* 1_000_003 &+ withPath &* 31 &+ Int(stampSum)
        if thumbnailPathCache.signature == signature { return thumbnailPathCache.map }

        var map: [String: String] = [:]
        for t in tasks {
            guard let path = t.localVideoPath, FileManager.default.fileExists(atPath: path) else { continue }
            map[t.groupKey] = path   // 顺序遍历 → 后面的覆盖前面的，等于取"最后一个有视频的"
        }
        thumbnailPathCache = (signature, map)
        return map
    }

    /// 当前项目下的分镜：**一律按编号（a-b）数值排序**，不是数组顺序。
    /// 用户 2026-09-18 定：顺序以"分镜命名"为准 —— 数组顺序只是插入顺序，中间插段/删段后
    /// 它和编号可能不一致；而且字符串比较会把 1-10 排到 1-9 前面，必须按数值。
    /// 时间轴显示、连播的"下一段"、批量提交全走这里，保证同一套顺序。
    var currentShots: [ShotDraft] {
        guard let currentProjectKey else { return [] }
        let projectShots = shots.filter { $0.projectKey == currentProjectKey }
        // 编号**一遍算齐**再排序（2026-09-26 修）：原来排序比较器里每次比较都调 `numbering(of:)`，
        // 而它对"没有编号的旧分镜"要 filter 全表找下标 → O(n² log n)（压测 300 张时实锤的卡顿源）。
        var nums: [UUID: ShotNumbering] = [:]
        nums.reserveCapacity(projectShots.count)
        for (i, s) in projectShots.enumerated() {
            nums[s.id] = s.numbering ?? ShotNumbering(a: i + 1, b: 1)
        }
        return projectShots.sorted {
            let x = nums[$0.id] ?? ShotNumbering(a: 0, b: 0)
            let y = nums[$1.id] ?? ShotNumbering(a: 0, b: 0)
            return x.a != y.a ? x.a < y.a : x.b < y.b
        }
    }

    /// 当前项目下的任务
    var currentTasks: [LocalTask] {
        guard let currentProjectKey else { return [] }
        return store.tasks
            .filter { $0.groupKey == currentProjectKey }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// 当前项目下的所有任务（右栏平铺展示，按创建时间降序）
    var currentProjectTasks: [LocalTask] {
        guard let currentProjectKey else { return store.tasks }
        return store.tasks.filter { $0.groupKey == currentProjectKey }
    }

    // MARK: - 导航

    /// 主页点「新建项目」：生成新 projectKey、立即创建缓存文件夹、默认进入剧本页。
    /// 🆕 2026-10-03（用户定）：退出/切换项目时**自动收起所有抽屉与弹窗**——
    /// 之前开着任务列表去别的项目，抽屉还开着（用户实测）
    private func closeAllOverlays() {
        DropdownPanel.shared.dismiss()
        activeModal = nil
        showLibraryDrawer = false
        showTaskDrawer = false
        showHistoryDrawer = false
    }

    func startNewProject(named preferredName: String? = nil) {
        projectPage = .script
        let key = UUID().uuidString
        currentProjectKey = key
        currentPipelineArchive = nil
        self.closeAllOverlays()   // 🆕 退出/切换项目：自动收起抽屉与弹窗
        isInWorkspace = true
        workspaceMode = .image
        imagePage = 0            // 新项目的页码从第 1 页起（见 imagePage 的注释）
        videoPage = 0
        scrollAnchors.liveImageOffset = 0     // 滚动位置也一并清掉，别带着上个项目的偏移
        scrollAnchors.liveShotOffset = 0
        scrollAnchors.liveThumbOffset = 0
        scrollAnchors.liveImageThumbOffset = 0
        scrollAnchors.savedImageOffset = nil
        scrollAnchors.savedShotOffset = nil
        scrollAnchors.savedThumbOffset = nil
        scrollAnchors.savedImageThumbOffset = nil
        timelineShotID = nil                  // 时间轴视图的选中分镜也归零
        timelineDisplayTaskID = nil           // 「正在看哪一版」也归零（2026-09-23）
        showHistoryDrawer = false             // 历史版本面板跟着关
        historyDrawerShotID = nil
        // 多选也清（2026-09-27 修，同 `bindContent`）：别把上个项目的"已选 N"带进新项目
        selectedShotIDs.removeAll()
        selectedImageItemIDs.removeAll()
        let now = Date()
        let fallbackName = "项目 \(projectMetas.count + 1)"
        let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 2026-10-06 P0：缓存目录按项目名，重名会共用目录 → 新建时自动加序号避开
        let name = uniqueProjectName(preferred.isEmpty ? fallbackName : preferred)
        projectMetas[key] = ProjectMeta(name: name, createdAt: now, updatedAt: now)
        nameBox.names[key] = name
        persistProjectMetas()
        // 新建项目立即创建项目文件夹（图片/视频），空项目也能在访达里看到
        try? FileManager.default.createDirectory(at: FileLocations.projectImagesDirectory(key), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: FileLocations.projectVideosDirectory(key), withIntermediateDirectories: true)
    }

    /// 项目内切换工作区模式（生图/生视频）
    func switchWorkspaceMode(_ mode: WorkspaceMode) {
        // 新剧本入口此时还没有项目；不能切进媒体页造成隐式空项目。
        guard projectPage != .script || currentProjectKey != nil else { return }
        projectPage = .production
        workspaceMode = mode
        previewingShotID = nil
        previewingLibraryItemID = nil
        previewingImageItemID = nil
        previewingStandaloneImagePath = nil
        previewingStandaloneImageFileName = nil
    }

    /// P1.1 主页入口只打开页壳，不创建 ProjectMeta、缓存目录或制作条目。
    func beginScriptImport() {
        closeAllOverlays()
        stopPlayback()
        ThumbVideoPlayback.shared.stop()
        ImagePreviewOnTap.shared.cancelPending()
        intendedProjectKey = nil
        currentProjectKey = nil
        projectPage = .script
        isInWorkspace = true
    }

    func openScriptPage() {
        guard isInWorkspace, let key = currentProjectKey else { return }
        snapshotScrollOffset(for: workspaceMode)
        closeAllOverlays()
        stopPlayback()
        ThumbVideoPlayback.shared.stop()
        ImagePreviewOnTap.shared.cancelPending()
        previewingShotID = nil
        previewingLibraryItemID = nil
        previewingImageItemID = nil
        previewingStandaloneImagePath = nil
        previewingStandaloneImageFileName = nil
        projectPage = .script
        workbenchJumpBack = nil
        if currentPipelineArchive == nil {
            currentPipelineArchive = pipelineArchive(for: key)
        }
    }

    // MARK: - 剧本流水线存档持久化（按项目划分）

    func pipelineArchive(for projectKey: String) -> ProjectPipelineArchive? {
        guard !projectKey.isEmpty else { return nil }
        return pipelineArchives[projectKey]
    }

    func savePipelineArchive(_ archive: ProjectPipelineArchive, for projectKey: String) {
        guard !projectKey.isEmpty else { return }
        if let issue = archive.validationIssue {
            AppLog.write("pipeline", "项目 \(projectKey) 剧本存档校验未通过（照常保存）：\(issue)")
        }
        pipelineArchives[projectKey] = archive
        if currentProjectKey == projectKey {
            currentPipelineArchive = archive
        }
        touchProject(projectKey)
        AppLog.write("pipeline", "保存项目 \(projectKey) 剧本存档：\(archive.loadedFileName)（\(archive.wholeScript.count)字）")
    }

    /// 项目的时代背景（空 = 没填）。没有剧本存档的项目不存
    func setEraBackground(_ text: String, project projectKey: String) {
        guard var archive = pipelineArchive(for: projectKey) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard archive.eraBackground != value else { return }
        archive.eraBackground = value
        savePipelineArchive(archive, for: projectKey)
    }

    func removePipelineArchive(for projectKey: String) {
        guard !projectKey.isEmpty else { return }
        pipelineArchives[projectKey] = nil
        if currentProjectKey == projectKey {
            currentPipelineArchive = nil
        }
        touchProject(projectKey)
        AppLog.write("pipeline", "移除项目 \(projectKey) 剧本存档")
    }

    func clearAllPipelineArchives() {
        pipelineArchives.removeAll()
        currentPipelineArchive = nil
        scheduleProjectSave()
    }

    /// 项目名（未命名则返回默认）
    func projectName(for key: String) -> String {
        projectMetas[key]?.name ?? "未命名项目"
    }

    /// 避开已占用的项目名（2026-10-06 P0）：缓存目录按项目名命名，两个同名项目会共用一个目录，
    /// 删其中一个就会连带删掉另一个的图片和视频。名字被占用时依次尝试「名字 2」「名字 3」…，总长不超过 `limit`。
    nonisolated static func uniqueProjectName(_ base: String, taken: Set<String>, limit: Int = 30) -> String {
        let first = String(base.prefix(limit))
        guard taken.contains(first) else { return first }
        var n = 2
        while true {
            let suffix = " \(n)"
            let candidate = String(base.prefix(max(1, limit - suffix.count))) + suffix
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    private func uniqueProjectName(_ base: String) -> String {
        Self.uniqueProjectName(base, taken: Set(projectMetas.values.map(\.name)))
    }

    /// 重命名项目：只改名字（2.0 项目文件夹按 ID，不用搬目录）；与别的项目重名时拒绝
    func renameProject(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "未命名项目" : trimmed
        guard let oldMeta = projectMetas[key] else { return }
        if projectMetas.contains(where: { $0.key != key && $0.value.name == finalName }) {
            AppLog.write("renameProject", "重名拒绝 key=\(key) name=\(finalName)")
            return
        }
        projectMetas[key] = ProjectMeta(name: finalName, createdAt: oldMeta.createdAt, updatedAt: Date())
        nameBox.names[key] = finalName
        persistProjectMetas()
    }

    /// 更新项目的修改时间
    func touchProject(_ key: String) {
        // 主页项目列表缓存作废 —— `touchProject` 是"项目数据变动"的必经之路，见 `projects` 的说明。
        // ⚠️ 必须放在下面的 `guard` **之前**：项目还没有 meta 时它会提前返回，那样缓存就漏清了。
        projectsCache = nil
        guard var meta = projectMetas[key] else {
            // 兜底：元数据缺失时补一条，别让"打开项目"白打开（以前直接 return，时间不更新）
            let name = uniqueProjectName("项目")
            projectMetas[key] = ProjectMeta(name: name, createdAt: Date(), updatedAt: Date())
            nameBox.names[key] = name
            persistProjectMetas()
            return
        }
        meta.updatedAt = Date()
        projectMetas[key] = meta
        persistProjectMetas()
        AppLog.write("nav", "touchProject \(key.prefix(8)) → \(meta.updatedAt)")
    }

    /// 项目元数据随项目文件一起存（2.0 起不再写 UserDefaults）
    private func persistProjectMetas() {
        scheduleProjectSave()
    }

    /// 项目内容换绑：默认准备剧本页，制作工作区保留生图模式。
    /// 内容换绑（含各种归零）：**不带动画**（`withAnimation(nil)`）——
    /// 带动画的话旧项目的子树会"淡出"、看着闪一下空/旧页面（用户 2026-09-18 实测）。
    private func bindContent(_ key: String) {
        // 诊断（临时）：用户报"打开有图有视频的项目，图片页是空的" —— 记录换绑那一刻各数据源的数量
        AppLog.write("nav", "bindContent key=\(key.prefix(8)) imageItems=\(imageItems.count) 该项目图片=\(imageItems.filter { $0.projectKey == key }.count) shots=\(shots.filter { $0.projectKey == key }.count)")
        withAnimation(nil) {
            currentProjectKey = key
            projectPage = .script
            currentPipelineArchive = pipelineArchive(for: key)
            self.closeAllOverlays()   // 🆕 退出/切换项目：自动收起抽屉与弹窗
            workspaceMode = .image
            imagePage = 0            // 换项目回第 1 页（见 imagePage 的注释）
            videoPage = 0
            scrollAnchors.liveImageOffset = 0     // 滚动位置也一并清掉，别带着上个项目的偏移
            scrollAnchors.liveShotOffset = 0
            scrollAnchors.liveThumbOffset = 0
            scrollAnchors.liveImageThumbOffset = 0
            scrollAnchors.savedImageOffset = nil
            scrollAnchors.savedShotOffset = nil
            scrollAnchors.savedThumbOffset = nil
            scrollAnchors.savedImageThumbOffset = nil
            timelineShotID = nil                  // 时间轴视图的选中分镜也归零
            timelineDisplayTaskID = nil           // 「正在看哪一版」也归零（2026-09-23）
            showHistoryDrawer = false             // 历史版本面板跟着关
            historyDrawerShotID = nil
            // 多选也要清（2026-09-27 修）：不清的话会带着上个项目的"已选 N"幽灵选中 ——
            // 底栏停在批量模式；且批量删除是**按 ID 全局删**的，会把上个项目里选中的分镜/图片真删掉 ✗
            selectedShotIDs.removeAll()
            selectedImageItemIDs.removeAll()
            // 兜底：切换项目时清掉可能残留的预览弹窗状态，避免遮罩拦截点击
            previewingShotID = nil
            previewingLibraryItemID = nil
            previewingImageItemID = nil
            previewingStandaloneImagePath = nil
            previewingStandaloneImageFileName = nil
            // **素材库抽屉也要关**：它挂在 `RootModals` 之后（浮层之上），
            // 不像任务抽屉那样跟着工作区一起消失 —— 不主动关就会**留在主页上**。
            closeLibraryDrawer()
        }
    }

    /// 鼠标是否停在卡片的"资产库"上（2026-09-18）：停着的时候**临时禁掉外层列表的滚动** ——
    /// macOS 嵌套 ScrollView 有"滚动链"，内层滚到头会带着外层一起滚（用户实测"滚资产库整页跟着动"）✗
    var assetLibraryHovering = false

    /// 本次"想打开"的项目：`openProject` 设定。**预绑必须匹配它**，否则丢弃 ——
    /// 悬停预绑的计时器（0.25s）可能在"点击打开"之后才触发，那时它拿的是**上一个悬停项目**，
    /// 会把刚绑好的工作区改回那个项目 ✗（用户 2026-09-18 实测："打开有图有视频的项目，
    /// 结果打开的是某一个别的项目的页面"）。
    private var intendedProjectKey: String?

    /// **悬停预绑**（2026-09-18）：鼠标在项目卡片上停留时，先把内容换绑做掉（工作区还隐藏着）。
    /// 这样真正点击时内容已经是这个项目的 → 翻页立刻发生、且第一帧就是真实内容。
    func preBindProject(_ key: String) {
        // ⚠️ 不跳过"同一个项目"：同项目重开也要回到剧本页、归零制作区分页/滚动，
        // 那同样是一次换绑（用户 2026-09-18：同项目在视频页关闭再打开也会闪）。
        guard !isInWorkspace else { return }
        // 已经点过"打开某个项目"了 → 迟到的预绑一律作废（硬保险，别只看 isInWorkspace：
        // 它和翻页之间还有个窗口，那一瞬预绑仍能挤进来）
        if let intended = intendedProjectKey, intended != key { return }
        bindContent(key)
    }

    /// 主页点历史项目：默认进入剧本页；打开即更新项目「更新时间」。
    func openProject(_ key: String) {
        AppLog.write("nav", "openProject: 开始 key=\(key.prefix(8))")
        intendedProjectKey = key
        bindContent(key)
        // ⚠️ **换绑完（隐藏状态下渲染好）再翻页**：同一帧换绑+翻页的话，淡入的头几帧用的还是
        // 旧图层的画面 → 会闪一下"上个项目关闭时的页面"（用户 2026-09-18 实测，视频页最明显）。
        // 延后一帧（`Task.yield`）等换绑渲染落定，翻页动画的第一帧就已经是新项目。
        Task { @MainActor in
            await Task.yield()
            // ⚠️ **自愈**（2026-09-18 用户报"点几个空项目后再开有内容的项目变成空的"）：
            // 迟到的"悬停预绑"可能在换绑之后才触发，把 key 改回上一个悬停项目 ✗。
            // 翻页前核对一次，不对就按本次点击的项目重新换绑。
            if currentProjectKey != key { bindContent(key) }
            // ⚠️ **关键**：换绑（尤其"视频页→生图页"的模式切换）是一次重渲染，
            // 只让出一帧（yield）渲染还没落定 → 翻页淡入的头几帧露出**旧内容**
            //（2026-09-18 实测拍到：淡入时隐约叠着上个项目关闭时的视频页 ✗）。
            // `CATransaction.flush()` 把当前事务强制提交，保证翻页时新内容已经在屏上。
            CATransaction.flush()
            AppLog.write("nav", "openProject: bind 完成，准备翻页")
            withAnimation(.easeInOut(duration: 0.18)) {
                isInWorkspace = true
            } completion: {
                AppLog.write("nav", "openProject: 翻页动画完成")
            }
            // 翻页（0.18s）播完再更新「更新时间」，主页卡片重排不会露在动画里。
            // ⚠️ **不能挂在上面那个动画的 completion 上**（2026-10-12 用户：打开又关掉，卡片没排到前面）：
            // completion 有时根本不来——日志里 13 次打开有 4 次没有「翻页动画完成」，那几次更新时间都没写。
            // 同一次事务里混进了不结束的动画时它会一直等。所以按时间来，固定等 0.25s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.touchProject(key) }
            }
        }
    }

    /// 返回主页（立即持久化分镜、素材库和图片工作区状态，确保关闭后历史可恢复）
    func goHome() {
        saveProjectsNow()
        withAnimation(nil) {
            // 兜底：清掉可能残留的预览弹窗状态，避免遮罩拦截点击
            previewingShotID = nil
            previewingLibraryItemID = nil
            previewingImageItemID = nil
            previewingStandaloneImagePath = nil
            previewingStandaloneImageFileName = nil
            // 同上：素材库抽屉是**根级浮层**，回主页不会自动消失，必须显式关
            closeLibraryDrawer()
        }
        // **拆旧内容放在淡出播完之后**（2026-09-18，用户方案）：淡出期间工作区还可见，
        // 这时候清空会露出"点击此处新建卡片"的空状态 ✗；等它全透明了再拆，用户看不到。
        // 好处：下次进项目的换绑只剩"建新项目"这一半（拆旧的这半已经在这里付掉了）。
        AppLog.write("nav", "goHome: 开始淡出")
        withAnimation(.easeInOut(duration: 0.18)) {
            isInWorkspace = false
        } completion: {
            AppLog.write("nav", "goHome: 淡出完成")
        }
        // 淡出（0.18s）播完再拆。⚠️ **不挂在动画 completion 上**（2026-10-12，同 `openProject`）：completion 有时不来；
        // 而且回主页后马上又点开一个项目时，迟到的 completion 会把刚打开的项目解绑掉。按时间来，到点还在主页才拆
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isInWorkspace else { return }
                AppLog.write("nav", "goHome: 拆旧内容")
                withAnimation(nil) {
                    self.currentProjectKey = nil
                    self.currentPipelineArchive = nil
                }
                self.closeAllOverlays()   // 🆕 退出项目：自动收起抽屉与弹窗
            }
        }
        stopPlayback()
        intendedProjectKey = nil   // 回主页后悬停预绑重新自由
    }

    /// 删除整个项目（分镜草稿 + 任务 + 项目缓存目录）
    func deleteProject(key: String) {
        let shotCount = shots.filter { $0.projectKey == key }.count
        let taskCount = store.tasks.filter { $0.groupKey == key }.count
        let imageCount = imageItems.filter { $0.projectKey == key }.count
        // ① 先停掉这个项目所有任务的轮询：否则循环还在跑，删除后还会继续写状态/下载
        for task in store.tasks where task.groupKey == key {
            poller.cancelPolling(taskID: task.id)
        }
        // ② 清数据（分镜 + 任务 + **生图条目** + 缓存目录 + 元数据）
        // ⚠️ 生图条目原来没清 → 项目删了、图片记录还在（绑着一个没有 meta 的 key），
        //    是"删不干净"的一部分（2026-09-19 修）
        shots.removeAll { $0.projectKey == key }
        store.removeGroup(groupKey: key)
        imageItems.removeAll { $0.projectKey == key }
        // 素材库条目也清（2.0 起素材属于项目；留着会让存盘时把这个项目又建回来）
        library.removeAll { $0.projectKey == key }
        pipelineArchives[key] = nil
        if currentProjectKey == key { currentPipelineArchive = nil }
        jobCenter.removeRecords(projectKey: key)
        // 项目文件夹（按 ID，不会波及同名项目）整个移到废纸篓
        if let projectStore { projectStore.queue.sync { projectStore.trashProject(key) } }   // 排在之前的存盘后面，别被写回来
        projectMetas.removeValue(forKey: key)
        nameBox.names.removeValue(forKey: key)
        persistProjectMetas()
        if currentProjectKey == key { currentProjectKey = nil; closeAllOverlays() }
        projectsCache = nil
        // ③ **立刻落盘**（不能走 300ms 防抖）：
        //    用户删完可能马上关窗/重启，防抖还没跑到 → 数据从磁盘复活 →
        //    主页又冒出一条没有 meta 的「未命名项目」（2026-09-19 用户报的就是这个）。
        saveProjectsNow()
        store.flush()
        AppLog.write("deleteProject", "删除 key=\(key.prefix(8)) 分镜\(shotCount) 任务\(taskCount) 图片\(imageCount)")
    }

    /// 把某个历史版本设为分镜的**当前版本**（预览弹窗里的「显示当前」，2026-09-19 用户要求）。
    ///
    /// 规则（用户原话）：**版本号和列表顺序都不动** —— 只改 `shot.taskID`：
    /// 卡片/详情卡的缩略图、时间轴段长、下次打开预览弹窗都会跟着显示这一版。
    /// ⚠️ 不要顺手重排 `taskIDs` 或改文件名里的版本号（那是用户明确不要的）。
    func setCurrentVersion(shotID: UUID, taskID: String) {
        guard let i = shots.firstIndex(where: { $0.id == shotID }),
              shots[i].taskIDs.contains(taskID),
              shots[i].taskID != taskID || shots[i].pendingIsCurrent else { return }
        parkPendingVersion(i)
        shots[i].taskID = taskID
        persistShots()
        AppLog.write("version", "分镜 \(shots[i].id.uuidString.prefix(8)) 当前版本 → \(taskID)")
    }

    /// **应用某个历史版本** —— 时间轴详情卡的「应用此版本」（2026-09-23）
    ///
    /// ⚠️ **和 `setCurrentVersion` 是两回事，别合并**：
    /// - `setCurrentVersion`：只把"当前版本"**指**过去（缩略图/详情卡显示它），
    ///   **不动提示词和参数**。预览弹窗的「显示当前」用它 —— 用户明确要求"版本号和顺序都不动"。
    /// - `applyVersion`（本方法）：把那一版**整个搬回来** —— 提示词、模型、分辨率、比例、时长、
    ///   音频开关、渠道全按**那一版提交时的快照**写回草稿，用户可以直接改一改再提交。
    ///
    /// ⚠️ **会覆盖草稿**，所以只在用户点「应用此版本」时调 ——
    /// 不能在"看一看"的时候调（那正是两段式要防的事）。
    ///
    /// 不判"是不是已经是当前版本"：**重复应用同一版是有意义的** ——
    /// 用户改乱了草稿之后，可以拿它当"还原到那一版"用。
    func applyVersion(shotID: UUID, taskID: String) {
        guard let i = shots.firstIndex(where: { $0.id == shotID }),
              shots[i].taskIDs.contains(taskID),
              let task = store.task(id: taskID) else { return }

        parkPendingVersion(i)
        shots[i].taskID = taskID
        copyVersionDraft(from: task, into: i)
        persistShots()

        AppLog.write("version", "应用版本（含提示词/参数）→ \(taskID.prefix(14))")
    }

    private func copyVersionDraft(from task: LocalTask, into i: Int) {
        shots[i].prompt = task.prompt
        shots[i].model = task.model
        shots[i].aspectRatio = task.aspectRatio
        shots[i].duration = task.duration
        shots[i].generateAudio = task.generateAudio
        if let r = task.resolution { shots[i].resolution = r }
        if !task.providerID.isEmpty { shots[i].providerID = task.providerID }
    }

    /// 换到别的版本前：当前是「待生成」的话，把它的提示词收起来（点回「待生成」还能拿回来）
    private func parkPendingVersion(_ i: Int) {
        guard shots[i].pendingIsCurrent else { return }
        shots[i].pendingPrompt = shots[i].prompt
        shots[i].pendingIsCurrent = false
    }

    /// 点回「待生成」版本（大预览版本列 / 生视频页右栏历史版本）：收起来的提示词放回卡上，缩略图和大预览显示「待生成」
    func applyPendingVersion(shotID: UUID) {
        guard let i = shots.firstIndex(where: { $0.id == shotID }), !shots[i].pendingIsCurrent,
              let prompt = shots[i].pendingPrompt else { return }
        shots[i].prompt = prompt
        shots[i].pendingPrompt = nil
        shots[i].pendingIsCurrent = true
        shots[i].taskID = nil
        // 不按提示词摘素材（2026-10-16 用户定）：待生成那版是重新推理来的，推理时已经清过参考图
        persistShots()
        AppLog.write("version", "分镜 \(shotID.uuidString.prefix(8)) 当前版本 → 待生成")
    }

    /// 重新推理写进了新提示词：生成过视频的卡多一个「待生成」版本并设为当前（已有的就覆盖）；没生成过的卡用不着
    func markShotReinferred(_ shotID: UUID) {
        guard let i = shots.firstIndex(where: { $0.id == shotID }) else { return }
        shots[i].pendingPrompt = nil
        shots[i].pendingIsCurrent = !shots[i].taskIDs.isEmpty
        if shots[i].pendingIsCurrent { shots[i].taskID = nil }
    }

    /// 删除单条任务：停止轮询 + 同步清理分镜历史任务 ID
    func deleteTask(id: String) {
        poller.cancelPolling(taskID: id)
        if id.hasPrefix("pending-") {
            // 排队 / 提交失败的占位：连同任务中心的记录一起撤掉
            if let shotID = jobCenter.records.first(where: { $0.id == id })?.shotID,
               !jobCenter.videoSubmitting.contains(id) {
                submittingShotIDs.remove(shotID)
            }
            pendingVideoSnapshots[id] = nil
            jobCenter.removeRecord(id: id)
        }
        store.remove(id: id)
        for i in shots.indices {
            shots[i].taskIDs.removeAll { $0 == id }
            if shots[i].taskID == id { shots[i].taskID = shots[i].taskIDs.last }
        }
        persistShots()
    }

    /// 清除当前项目的所有分镜与任务（保留项目本身，用于重新开始）
    func clearAllShots() {
        guard let key = currentProjectKey else { return }
        shots.removeAll { $0.projectKey == key }
        store.removeGroup(groupKey: key)
        persistShots()
    }

    /// 清除所有项目（全部分镜 + 全部任务 + 项目元数据），回到初始状态
    func clearAllProjects() {
        if let projectStore { projectStore.queue.sync { for key in projectMetas.keys { projectStore.trashProject(key) } } }
        shots.removeAll()
        store.removeAll()
        imageItems.removeAll()
        library.removeAll()
        clearAllPipelineArchives()
        projectMetas.removeAll()
        currentProjectKey = nil
        currentPipelineArchive = nil
        self.closeAllOverlays()   // 🆕 退出/切换项目：自动收起抽屉与弹窗
        isInWorkspace = false
        persistShots()
        persistProjectMetas()
    }

    // MARK: - 分镜卡片

    /// 取分镜的**编号**；旧数据没有就现算兜底（a = 它在项目里的位置序号、b = 1）。
    ///
    /// 兜底只影响"加这个字段之前就存在"的分镜：那批本来就没有插入历史，按位置给编号是对的，
    /// 而且一旦被 `persistShots` 写回就固定下来了。**别在别处直接读 `shot.numbering`**。
    func numbering(of shot: ShotDraft) -> ShotNumbering {
        if let n = shot.numbering { return n }
        let projectShots = shots.filter { $0.projectKey == shot.projectKey }
        let index = (projectShots.firstIndex(where: { $0.id == shot.id }) ?? 0) + 1
        return ShotNumbering(a: index, b: 1)
    }

    /// 项目里 **a 段**已经用过的最大 b（这一段从没插过就是 0）
    private func maxB(projectKey: String, a: Int) -> Int {
        shots.filter { $0.projectKey == projectKey && numbering(of: $0).a == a }
            .map { numbering(of: $0).b }
            .max() ?? 0
    }

    /// 项目里用过的最大 a（末尾新建分镜时接着往下排）
    private func maxA(projectKey: String) -> Int {
        shots.filter { $0.projectKey == projectKey }
            .map { numbering(of: $0).a }
            .max() ?? 0
    }

    /// **能不能在这个分镜下面「增加分镜」**（用户 2026-09-13 定的规则）。
    ///
    /// 判据：它后面**紧跟着的**不是"同一段的下一个分镜"才放行 ——
    /// 例：在「分镜1-1」后面插出「分镜1-2」之后，1-1 的按钮就变灰，只能在 1-2 下面接着插。
    /// 这样每段的 b 严格递增、不跳号（否则在 1-1 下面连点会得到 1-3、1-4，
    /// 而它们的插入位置其实都在 1-1 后面，顺序就乱了）。
    ///
    /// 别段不受影响：分镜2-1 是段 2 的最后一个 → 一直可插。
    func canInsertShot(after shot: ShotDraft) -> Bool {
        let projectShots = shots.filter { $0.projectKey == shot.projectKey }
        guard let idx = projectShots.firstIndex(where: { $0.id == shot.id }) else { return false }
        let next = idx + 1
        guard next < projectShots.count else { return true }   // 它已经是最后一个 → 可以
        return numbering(of: projectShots[next]).a != numbering(of: shot).a
    }

    /// 新增分镜卡片（默认追加到项目末尾；给了 `index` 就是插到那个位置）
    @discardableResult
    func addShot(projectKey: String? = nil, at index: Int? = nil) -> UUID {
        let key = projectKey ?? currentProjectKey ?? UUID().uuidString
        // 编号：插在中间 → 挂到"前一个分镜"那一段（b 递增）；追加到末尾 → 新开一段（a = 最大 + 1）
        // （变量名别叫 `numbering` —— 会遮蔽上面的 `numbering(of:)` 方法）
        let newNumbering: ShotNumbering
        if let index, index > 0, index <= shots.count,
           let anchor = shots.prefix(index).last(where: { $0.projectKey == key }) {
            let a = numbering(of: anchor).a
            newNumbering = ShotNumbering(a: a, b: maxB(projectKey: key, a: a) + 1)
        } else {
            newNumbering = ShotNumbering(a: maxA(projectKey: key) + 1, b: 1)
        }
        var shot = ShotDraft(projectKey: key, providerID: "", generateAudio: generateAudioDefault, watermark: watermarkDefault, numbering: newNumbering)
        applyDefaultVideoParams(to: &shot)
        var newShots = shots
        if let index, index <= newShots.count {
            newShots.insert(shot, at: index)
        } else {
            newShots.append(shot)
        }
        shots = newShots
        touchProject(key)
        persistShots()
        return shot.id
    }

    /// 手动新增分镜：底栏和空项目入口共用；批量解析仍只调用 addShot()。
    /// 🎯 新建分镜时套用「默认参数」（设置页保存的那些；没设的保持构造函数里的现状）
    private func applyDefaultVideoParams(to shot: inout ShotDraft) {
        if let m = defaultVideoModel, !m.isEmpty { shot.model = m }
        if let d = defaultVideoDuration { shot.duration = d }
        if let a = defaultVideoAspect, let v = AspectRatio(rawValue: a) { shot.aspectRatio = v }
        if let r = defaultVideoResolution, let v = Resolution(rawValue: r) { shot.resolution = v }
    }

    /// 🎯 新建生图条目时套用「默认参数」（同上）
    private func applyDefaultImageParams(to item: inout ImageGenItem) {
        if let t = defaultImageType, let v = ImageSubjectType(rawValue: t) { item.type = v }
        if let m = defaultImageModel, !m.isEmpty { item.model = m }
        if let a = defaultImageAspect, let v = ImageAspect(rawValue: a) { item.aspectRatio = v }
        if let q = defaultImageQuality, let v = ImageQuality(rawValue: q) { item.quality = v }
    }

    /// 推理分镜（2026-10-07）：把一集推理出的各段提示词写成这一集的生视频卡，返回按段顺序的卡片 id。
    ///
    /// - 编号：第 `episodeNumber` 集的第 k 段 = 「分镜 集号-k」，文件名 `集号-k-版本`。
    /// - 这一集已经有卡（`existing`，上一次推理建的）：按位置覆盖提示词，卡片、编号、已生成的视频版本都不动；
    ///   段数变多就追加新卡；变少，多出来的老卡留在原地不删（不丢视频、不重排编号），只是不再算这一集的卡。
    /// - 新卡的编号如果被别的卡占了（比如手动新增的分镜正好是 4-1），不覆盖也不撞文件名，改用这一集下一个空的段号。
    /// - 新卡插在位置上：前面各集的卡（`before`）和这一集的卡之后；一张前面的都没有就插在后面各集的卡（`after`）之前；
    ///   都没有就放末尾。这样先推第 3 集再推第 2 集，卡片顺序也是对的。
    @discardableResult
    /// `firstNumber`：第一张新卡的段号（编号「集-段」的段）；单段补卡时传那一段的段号
    func writeStoryboardCards(project key: String, episodeNumber: Int, existing: [UUID],
                              before: [UUID], after: [UUID], prompts: [String], firstNumber: Int = 1) -> [UUID] {
        var result: [UUID] = []
        var all = shots
        let earlier = Set(before).union(existing)
        let later = Set(after)
        for (k, prompt) in prompts.enumerated() {
            if k < existing.count, let idx = all.firstIndex(where: { $0.id == existing[k] && $0.projectKey == key }) {
                if all[idx].prompt != prompt {
                    // 生成过视频的卡：新提示词是一个「待生成」版本（见 `markShotReinferred`）
                    all[idx].pendingPrompt = nil
                    all[idx].pendingIsCurrent = !all[idx].taskIDs.isEmpty
                    if all[idx].pendingIsCurrent { all[idx].taskID = nil }
                }
                all[idx].prompt = prompt
                result.append(existing[k])
                continue
            }
            func used(_ n: ShotNumbering) -> Bool {
                all.contains { $0.projectKey == key && ($0.numbering ?? numbering(of: $0)) == n }
            }
            var b = firstNumber + k
            if used(ShotNumbering(a: episodeNumber, b: b)) {
                b = (all.filter { $0.projectKey == key }.map { ($0.numbering ?? numbering(of: $0)) }
                    .filter { $0.a == episodeNumber }.map(\.b).max() ?? 0) + 1
            }
            var shot = ShotDraft(projectKey: key, providerID: "", generateAudio: generateAudioDefault, watermark: watermarkDefault,
                                 numbering: ShotNumbering(a: episodeNumber, b: b))
            shot.prompt = prompt
            applyDefaultVideoParams(to: &shot)
            let owned = earlier.union(result)
            let position = all.lastIndex(where: { owned.contains($0.id) }).map { $0 + 1 }
                ?? all.firstIndex(where: { later.contains($0.id) })
                ?? all.count
            all.insert(shot, at: position)
            result.append(shot.id)
        }
        shots = all
        touchProject(key)
        persistShots()
        return result
    }

    func addShotAndInspect() {
        let hadShots = !currentShots.isEmpty
        let id = addShot()
        inspectorKind = .video
        timelineShotID = id
        // 卡片页新增只选中右栏，保留列表当前位置；缩略图页仍跳到新条目。
        if hadShots, videoViewStyle == .thumbnails { scrollToShotID = id }
    }

    /// 删除分镜卡片
    func deleteShot(id: UUID) {
        // 已选中 → 从集合摘掉，别让「已选 N」虚高（2026-09-27；批量删除也会走这里）
        selectedShotIDs.remove(id)
        let key = shots.first(where: { $0.id == id })?.projectKey
        shots = shots.filter { $0.id != id }
        if let key { touchProject(key) }
        persistShots()
    }

    /// 在指定分镜卡片之后插入新卡片
    func insertShot(after shotID: UUID) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else {
            AppLog.write("insertShot", "guard 失败 shotID=\(shotID)")
            return
        }
        let key = shots[idx].projectKey
        // 规则兜底：只能在"自己那一段的最后一个"下面续插（UI 上按钮已禁用，这里防别的调用路径）
        guard canInsertShot(after: shots[idx]) else {
            AppLog.write("insertShot", "该分镜后面已有同段的下一个 → 不续插 shot=\(shotID)")
            return
        }
        // **编号：挂到前一个分镜那一段**（a 沿用它的、b 在该段内递增）——
        // 这样它不挤动后面分镜的编号，文件名永远撞不上旧的（见 `ShotNumbering` 的说明）
        let anchorA = numbering(of: shots[idx]).a
        let newNumbering = ShotNumbering(a: anchorA, b: maxB(projectKey: key, a: anchorA) + 1)
        var newShots = shots
        var inserted = ShotDraft(projectKey: key, providerID: "", generateAudio: generateAudioDefault, watermark: watermarkDefault, numbering: newNumbering)
        applyDefaultVideoParams(to: &inserted)
        newShots.insert(inserted, at: idx + 1)
        shots = newShots  // 整体赋值，确保 @Observable 触发视图刷新
        touchProject(key)
        persistShots()
    }

    /// 直接更新分镜提示词（绕过绑定，确保持久化）
    func updateShotPrompt(_ shotID: UUID, prompt: String) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return }
        guard shots[idx].prompt != prompt else { return }
        shots[idx].prompt = prompt
        persistShots()
    }

    /// 给分镜添加素材库引用（按素材类型归到对应 refs）
    func addShotMaterial(shotID: UUID, libraryItemID: UUID) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }),
              let item = libraryItem(libraryItemID) else { return }
        switch item.kind {
        case .image:
            // 新协议下线了能力矩阵：图片默认当参考图，首/尾帧由卡片上的角色徽章手动切换
            shots[idx].imageRefs.append(MaterialRef(libraryItemID: libraryItemID, role: .referenceImage))
        case .video:
            shots[idx].videoRefs.append(MaterialRef(libraryItemID: libraryItemID))
        case .audio:
            shots[idx].audioRefs.append(MaterialRef(libraryItemID: libraryItemID))
        }
        touchProject(shots[idx].projectKey)
        persistShots()
    }

    /// 循环切换图片素材角色：参考图 → 首帧 → 尾帧（首尾帧/图生需要指定首尾帧）
    func cycleImageRole(shotID: UUID, refID: UUID) {
        guard let shotIdx = shots.firstIndex(where: { $0.id == shotID }),
              let refIdx = shots[shotIdx].imageRefs.firstIndex(where: { $0.id == refID }) else { return }
        switch shots[shotIdx].imageRefs[refIdx].role {
        case .firstFrame: shots[shotIdx].imageRefs[refIdx].role = .lastFrame
        case .lastFrame: shots[shotIdx].imageRefs[refIdx].role = .referenceImage
        default: shots[shotIdx].imageRefs[refIdx].role = .firstFrame
        }
        persistShots()
    }

    /// 移除分镜里的素材引用
    func removeShotMaterial(shotID: UUID, refID: UUID) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let shot = shots[idx]
        // 被删素材在各自类型里的序号（1-based）：用于同步清理提示词里的 token 并重编号
        let imageIndex = shot.imageRefs.firstIndex(where: { $0.id == refID }).map { $0 + 1 }
        let videoIndex = shot.videoRefs.firstIndex(where: { $0.id == refID }).map { $0 + 1 }
        let audioIndex = shot.audioRefs.firstIndex(where: { $0.id == refID }).map { $0 + 1 }

        shots[idx].imageRefs.removeAll { $0.id == refID }
        shots[idx].videoRefs.removeAll { $0.id == refID }
        shots[idx].audioRefs.removeAll { $0.id == refID }

        // 同步删掉提示词里对应的「图N是/图N」，并把更大的编号前移（否则残留 token 会导致自动匹配错乱）
        var prompt = shots[idx].prompt
        if let i = imageIndex { prompt = Self.removeTokenAndRenumber(prompt, prefix: "图", removedIndex: i) }
        if let i = videoIndex { prompt = Self.removeTokenAndRenumber(prompt, prefix: "视频", removedIndex: i) }
        if let i = audioIndex { prompt = Self.removeTokenAndRenumber(prompt, prefix: "音频", removedIndex: i) }
        shots[idx].prompt = prompt

        touchProject(shots[idx].projectKey)
        persistShots()
        // 删的是图：它带的音色也跟着走（2026-10-26）。删的是音频本身不同步——不然刚摘掉的音色又被挂回去
        if imageIndex != nil { syncShotVoices(shotID) }
    }

    /// 从提示词里删除 `prefix+N` 的 token（含紧跟的「是」），并把更大的编号整体前移一位。
    /// 用正则从后往前替换：既避免「图1」误伤「图10」，也避免编号前移时连锁覆盖。
    /// static：编辑提示词弹窗里删素材时也要用同一套清理逻辑。
    static func removeTokenAndRenumber(_ text: String, prefix: String, removedIndex: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\(prefix)(\\d+)") else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let numRange = m.range(at: 1)
            guard let n = Int(ns.substring(with: numRange)) else { continue }
            if n == removedIndex {
                var full = m.range
                let after = m.range.location + m.range.length
                if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == "是" {
                    full = NSRange(location: m.range.location, length: m.range.length + 1)
                }
                ns.replaceCharacters(in: full, with: "")
            } else if n > removedIndex {
                ns.replaceCharacters(in: numRange, with: "\(n - 1)")
            }
        }
        return ns as String
    }

    /// 清理提示词里**超出引用数量的"野 token"**：`图N` 但 `imageRefs` 里根本没有第 N 个。
    ///
    /// 来源：① 从别的分镜**复制粘贴**提示词（带过来一串「图2是…」但当前分镜没引用它）；
    /// ② 历史上删素材时没清干净的残留。这类 token 渲染不出缩略图、提交时也是噪音
    ///（用户 2026-09-13 报的"删完素材还残留着『图2是』"）。
    ///
    /// 删除时连**紧跟的「是」**一起删（同 `removeTokenAndRenumber` 的规则）。
    static func stripDanglingTokens(_ text: String, prefix: String, maxCount: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\(prefix)(\\d+)") else { return text }
        let ns = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {   // 从后往前，改动才不串位
            guard let n = Int(ns.substring(with: m.range(at: 1))), n > maxCount else { continue }
            var full = m.range
            let after = m.range.location + m.range.length
            if after < ns.length, ns.substring(with: NSRange(location: after, length: 1)) == "是" {
                full = NSRange(location: m.range.location, length: m.range.length + 1)
            }
            ns.replaceCharacters(in: full, with: "")
        }
        return ns as String
    }

    /// 「编辑提示词」弹窗没提交就关掉（点外面 / Esc）：撤销弹窗期间改过的那几样——提示词、素材引用、生成参数。
    /// 弹窗里的素材和参数是实时写数据层的（便于即时看到效果），所以关掉时靠这个回滚。
    /// 只回滚这几样，**不整条替换**：任务 / 版本这些在弹窗开着的时候可能被后台改掉（视频刚好生成完），整条换回去会把新版本弄丢。
    func rollbackShotEdits(to backup: ShotDraft) {
        guard let idx = shots.firstIndex(where: { $0.id == backup.id }) else { return }
        // 没改过就什么都不写（2026-10-12）：原来每次关编辑提示词弹窗都整段写回 + 存盘，分镜一变工作台就整个重算，关一下也卡
        guard shots[idx] != backup else { return }
        shots[idx].prompt = backup.prompt
        shots[idx].imageRefs = backup.imageRefs
        shots[idx].videoRefs = backup.videoRefs
        shots[idx].audioRefs = backup.audioRefs
        shots[idx].model = backup.model
        shots[idx].resolution = backup.resolution
        shots[idx].aspectRatio = backup.aspectRatio
        shots[idx].duration = backup.duration
        shots[idx].generateAudio = backup.generateAudio
        shots[idx].watermark = backup.watermark
        shots[idx].paramsDirty = backup.paramsDirty
        touchProject(backup.projectKey)
        persistShots()
    }

    /// 清空分镜的所有素材引用，并从提示词里删除 @ 槽位 token
    func clearShotMaterials(_ shotID: UUID) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return }
        shots[idx].prompt = Self.stripAllTokens(shots[idx].prompt)
        shots[idx].imageRefs.removeAll()
        shots[idx].videoRefs.removeAll()
        shots[idx].audioRefs.removeAll()
        touchProject(shots[idx].projectKey)
        persistShots()
    }

    // MARK: - 图片条目的素材（参考图）

    /// 给图片条目添加参考图。
    /// **只接受图片类素材**——生图走 `/v1/images/edits`，该端点只吃图片，视频/音频挂了也没用。
    /// 角色恒为 `.referenceImage`：首帧/尾帧是视频模型的语义（图生视频要指定起止帧），生图没有这个概念。
    /// （对照 `addShotMaterial`：那边也默认参考图，首/尾帧由卡片角色徽章手动切换）
    func addImageItemMaterial(itemID: UUID, libraryItemID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }),
              let item = libraryItem(libraryItemID), item.kind == .image else { return }
        imageItems[idx].imageRefs.append(MaterialRef(libraryItemID: libraryItemID, role: .referenceImage))
        persistImageItems()
    }

    /// 移除图片条目的参考图，并同步清理提示词里对应的「图N是」token（后续编号前移）
    func removeImageItemMaterial(itemID: UUID, refID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }),
              let removedIndex = imageItems[idx].imageRefs.firstIndex(where: { $0.id == refID }).map({ $0 + 1 })
        else { return }
        // 删的就是基础版的图：用户不想要它当参考图，关联一并取消（不然下次生成又自动挂回来）
        if let baseID = imageItems[idx].referenceCardID,
           let removed = imageItems[idx].imageRefs.first(where: { $0.id == refID }),
           let resultID = libraryItem(removed.libraryItemID)?.imageGenResultID,
           imageItems.first(where: { $0.id == baseID })?.results.contains(where: { $0.id == resultID }) == true {
            imageItems[idx].referenceCardID = nil
        }
        imageItems[idx].imageRefs.removeAll { $0.id == refID }
        imageItems[idx].prompt = Self.removeTokenAndRenumber(imageItems[idx].prompt, prefix: "图", removedIndex: removedIndex)
        persistImageItems()
    }

    /// 清空图片条目的参考图，并从提示词里删除所有 @ 槽位 token
    func clearImageItemMaterials(itemID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }) else { return }
        imageItems[idx].prompt = Self.stripAllTokens(imageItems[idx].prompt)
        imageItems[idx].imageRefs.removeAll()
        imageItems[idx].referenceCardID = nil
        persistImageItems()
    }

    /// 图片的「编辑提示词」弹窗没提交就关掉：撤销提示词、参考图、生成参数（同 `rollbackShotEdits`，不碰结果 / 状态）。
    func rollbackImageItemEdits(to backup: ImageGenItem) {
        guard let idx = imageItems.firstIndex(where: { $0.id == backup.id }) else { return }
        // 没改过就什么都不写（2026-10-14 用户：工作台开关生图编辑提示词弹窗卡）：原来每次关弹窗都整段写回 + 存盘，
        // 生图卡一变，工作台整页状态、藏在后面的生图页都跟着重算（同 `rollbackShotEdits` 10-12 的修法）
        let current = imageItems[idx]
        guard current.prompt != backup.prompt || current.imageRefs != backup.imageRefs || current.model != backup.model
                || current.type != backup.type || current.aspectRatio != backup.aspectRatio || current.quality != backup.quality
                || current.paramsDirty != backup.paramsDirty else { return }
        imageItems[idx].prompt = backup.prompt
        imageItems[idx].imageRefs = backup.imageRefs
        imageItems[idx].model = backup.model
        imageItems[idx].type = backup.type
        imageItems[idx].aspectRatio = backup.aspectRatio
        imageItems[idx].quality = backup.quality
        imageItems[idx].paramsDirty = backup.paramsDirty
        persistImageItems()
    }

    /// 把参考图引用解析成**本地文件路径**——生图要 multipart 上传文件本体，光有直链不够。
    ///
    /// ⚠️ **本地文件缺失是常态，不是边缘情况**：2026-09-12 实测素材库 131 张图里有 **48 张**的
    /// `localPath` 指向的文件已被移走或删除（素材是从 `~/Downloads` 拖进来的，Downloads 被清过），
    /// 所以「本地不在 → 回落 remoteURL 下载」是**主路径之一**，不能当兜底随手写。
    /// 两条路都拿不到就跳过该张并记日志——**不静默假装成功**（否则用户以为参考图生效了）。
    private func referenceImageFilePaths(for refs: [MaterialRef]) async -> [String] {
        var paths: [String] = []
        for ref in refs {
            guard let item = libraryItem(ref.libraryItemID) else { continue }
            if let local = item.localPath, FileManager.default.fileExists(atPath: local) {
                paths.append(local)
                continue
            }
            if let remote = item.remoteURL, let url = URL(string: remote),
               let tmp = await downloadToTemporaryFile(url: url, fileName: item.fileName) {
                paths.append(tmp)
                continue
            }
            AppLog.write("imagegen", "参考图取不到，已跳过：\(item.matchName)（本地文件和直链都不可用）")
        }
        return paths
    }

    /// 下载到临时文件（参考图回落用）。临时目录由系统回收，调用方不用管清理。
    private func downloadToTemporaryFile(url: URL, fileName: String?) async -> String? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let ext: String
            if let fileName, !fileName.isEmpty {
                ext = (fileName as NSString).pathExtension
            } else {
                ext = url.pathExtension
            }
            let name = "ref-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try data.write(to: dest)
            return dest.path
        } catch {
            AppLog.write("imagegen", "参考图下载失败 \(url.absoluteString.prefix(60))：\(error.localizedDescription)")
            return nil
        }
    }

    /// 删除文本里所有 @ 槽位 token（图N/视频N/音频N，含紧跟的「是」）。
    /// static：编辑提示词弹窗里「清空素材」时也要同步清理编辑器内容。
    static func stripAllTokens(_ text: String) -> String {
        var prompt = text
        // 从大到小删除，避免「图1」误匹配「图10」
        for i in stride(from: 20, through: 1, by: -1) {
            for token in ["图", "视频", "音频"] {
                prompt = prompt.replacingOccurrences(of: "\(token)\(i)是", with: "")
                prompt = prompt.replacingOccurrences(of: "\(token)\(i)", with: "")
            }
        }
        return prompt
    }

    /// 把某条任务的素材直链转成素材库条目并引用回分镜（旧任务「编辑此分镜」兼容）
    @discardableResult
    func refShot(from task: LocalTask) -> UUID? {
        // 找到或创建该任务对应的分镜卡片
        if let existing = shots.first(where: { $0.taskID == task.id }) {
            return existing.id
        }
        var shot = ShotDraft(projectKey: task.groupKey, model: task.model, providerID: task.providerID,
                             prompt: task.prompt,
                             duration: task.duration, aspectRatio: task.aspectRatio,
                             generateAudio: task.generateAudio, taskID: task.id,
                             // 旧任务转卡片：当新的一段（它没有插入历史）
                             numbering: ShotNumbering(a: maxA(projectKey: task.groupKey) + 1, b: 1))
        // 旧任务参考素材直链 → 素材库（按 remoteURL 去重复用）
        var imageRefs: [MaterialRef] = []
        for url in (task.referenceImageURLs ?? []) {
            let itemID = ensureLibraryItem(remoteURL: url, kind: .image, projectKey: task.groupKey)
            imageRefs.append(MaterialRef(libraryItemID: itemID, role: .referenceImage))
        }
        var videoRefs: [MaterialRef] = []
        for url in (task.referenceVideoURLs ?? []) {
            let itemID = ensureLibraryItem(remoteURL: url, kind: .video, projectKey: task.groupKey)
            videoRefs.append(MaterialRef(libraryItemID: itemID))
        }
        var audioRefs: [MaterialRef] = []
        for url in (task.referenceAudioURLs ?? []) {
            let itemID = ensureLibraryItem(remoteURL: url, kind: .audio, projectKey: task.groupKey)
            audioRefs.append(MaterialRef(libraryItemID: itemID))
        }
        shot.imageRefs = imageRefs
        shot.videoRefs = videoRefs
        shot.audioRefs = audioRefs
        shots.append(shot)
        persistShots()
        persistLibrary()
        return shot.id
    }

    // MARK: - 素材库

    /// 素材库按 id 查找
    func libraryItem(_ id: UUID) -> LibraryItem? {
        if let index = libraryIndex?[id], library.indices.contains(index), library[index].id == id { return library[index] }
        // 没建过 / 下标过期了（整体换了顺序）：重建一次再查
        var rebuilt: [UUID: Int] = [:]
        rebuilt.reserveCapacity(library.count)
        for (offset, item) in library.enumerated() where rebuilt[item.id] == nil { rebuilt[item.id] = offset }
        libraryIndex = rebuilt
        return rebuilt[id].map { library[$0] }
    }

    /// 按 id 找生图卡（所有项目里找；同 `libraryItem(_:)`，用下标缓存，不再每次从头线性找）
    func imageItem(_ id: UUID) -> ImageGenItem? {
        if let index = imageItemIndex?[id], imageItems.indices.contains(index), imageItems[index].id == id { return imageItems[index] }
        // 没建过 / 下标过期了（换了顺序、或者这张卡不在了）：重建一次再查
        var rebuilt: [UUID: Int] = [:]
        rebuilt.reserveCapacity(imageItems.count)
        for (offset, item) in imageItems.enumerated() where rebuilt[item.id] == nil { rebuilt[item.id] = offset }
        imageItemIndex = rebuilt
        return rebuilt[id].map { imageItems[$0] }
    }

    /// 按 remoteURL 复用或创建素材库条目，返回条目 id（避免重复素材）
    func ensureLibraryItem(remoteURL: String, kind: LibraryItem.Kind, projectKey: String) -> UUID {
        if let existing = library.first(where: { $0.remoteURL == remoteURL && $0.kind == kind }) {
            return existing.id
        }
        // fileName 用 URL 最后一段（文件名），避免把整个 URL 当名称显示
        let urlName = (remoteURL as NSString).lastPathComponent
        var item = LibraryItem(kind: kind, localPath: nil, fileName: urlName, projectKey: projectKey)
        item.remoteURL = remoteURL
        item.uploadState = .uploaded
        library.append(item)
        return item.id
    }

    /// 当前项目的素材库（按项目隔离）
    var currentProjectLibrary: [LibraryItem] {
        guard let currentProjectKey else { return [] }
        return library.filter { $0.projectKey == currentProjectKey }
    }

    /// 当前项目的图片生成条目（图片工作区按项目隔离）
    var currentImageItems: [ImageGenItem] {
        guard let currentProjectKey else { return [] }
        return imageItems.filter { $0.projectKey == currentProjectKey }
    }

    // MARK: - 素材预览（图片大图 / 音频视频单次播放）

    /// 当前正在播放的素材库条目 ID
    var playingLibraryItemID: UUID?

    /// 正在预览的素材库条目 ID（弹窗展示）
    var previewingLibraryItemID: UUID?

    /// 当前播放器（供视频画面展示）
    private(set) var mediaPlayer: AVPlayer?

    private var playEndObserver: NSObjectProtocol?

    /// 正在预览的素材（弹窗内容据此展示）
    var previewingItem: LibraryItem? {
        guard let id = previewingLibraryItemID else { return nil }
        return libraryItem(id)
    }

    /// 点击素材：图片弹大图，视频/音频弹窗播放
    func previewLibraryItem(_ id: UUID) {
        guard let item = libraryItem(id) else { return }
        previewingLibraryItemID = id
        if item.kind != .image {
            startPlayback(id)
        }
    }

    /// 关闭预览弹窗
    func dismissPreview() {
        stopPlayback()
        previewingLibraryItemID = nil
    }

    private func startPlayback(_ id: UUID) {
        guard let item = libraryItem(id),
              let path = item.localPath, FileManager.default.fileExists(atPath: path) else { return }
        stopPlayback()
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        mediaPlayer = player
        playingLibraryItemID = id
        playEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopPlayback()
                self?.previewingLibraryItemID = nil
            }
        }
        player.play()
    }

    /// 停止播放并复位
    func stopPlayback() {
        if let playEndObserver {
            NotificationCenter.default.removeObserver(playEndObserver)
            self.playEndObserver = nil
        }
        mediaPlayer?.pause()
        mediaPlayer = nil
        playingLibraryItemID = nil
    }

    /// 拖入本地文件 → 素材库（自动归类 + 启动预上传）
    // MARK: - 图片生成

    /// 图片条目持久化（防抖异步写盘，退出/重启不丢）
    private var imagePersistWork: Task<Void, Never>?

    func persistImageItems() {
        scheduleProjectSave()
    }

    private func writeImageItems() {
        saveProjectsNow()
    }

    /// 读项目文件（init 调用）。第一次启动 2.0：先把 1.x 数据迁过来（先备份，旧文件不改不删）。
    private func loadProjects() {
        // 单元测试里构造 AppModel：用一次性的临时目录，绝不读写真实项目、也不跑迁移
        // （2026-10-06 踩过：测试进程跑了一次迁移，在真实数据目录里多出一份项目文件夹）
        if NSClassFromString("XCTestCase") != nil {
            let projectStore = ProjectStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("xipi-tests-\(UUID().uuidString)", isDirectory: true))
            _ = projectStore.loadAll()
            self.projectStore = projectStore
            return
        }
        if ProjectStore.recordedRoot == nil {
            do {
                let outcome = try ProjectStore.migrateLegacyData(cacheRoot: FileLocations.videosDirectory)
                if !outcome.report.projects.isEmpty { Self.announceMigration(outcome) }
            } catch {
                AppLog.write("project", "1.x → 2.0 迁移失败：\(error.localizedDescription)")
                Self.announceMigrationFailure(error)
                return
            }
        }
        let projectStore = ProjectStore(root: FileLocations.projectsRoot)
        let docs = projectStore.loadAll()
        let snapshot = LegacyProjection.snapshot(from: docs, projectsRoot: projectStore.root)
        projectMetas = snapshot.metas
        shots = snapshot.shots
        imageItems = snapshot.imageItems
        library = snapshot.library
        pipelineArchives = snapshot.pipelines
        self.projectStore = projectStore
        // 视频任务记录从各段的视频版本还原（P2 起不再读写 tasks.json；旧文件原样留着）
        store.replaceAll(LegacyProjection.tasks(from: docs, projectsRoot: projectStore.root))
        // 重启恢复：同步生图请求随进程消失，残留的「生成中/下载中」条目无法恢复，
        // 重置为失败并提示去中转后台确认（中转站可能已生成完成）
        for i in imageItems.indices where imageItems[i].status == .generating || imageItems[i].status == .downloading {
            recordImageFailure(at: i, "应用退出导致任务中断——中转站可能已生成，请到后台确认或重试")
        }
        if !projectStore.unreadable.isEmpty {
            let names = projectStore.unreadable.keys.sorted().joined(separator: "、")
            Self.announce(title: "有项目读不出来", text: "这些项目文件夹里的 project.json 读取失败，已跳过（不会覆盖）：\n\(names)\n\n详情见日志。")
        }
    }

    private static func announceMigration(_ outcome: ProjectStore.MigrationOutcome) {
        let r = outcome.report
        let review = r.projects.reduce(0) { $0 + $1.needsReview.count }
        let missing = r.projects.reduce(0) { $0 + $1.missingFiles.count }
        let text = "已把 \(r.projects.count) 个项目迁到新的数据格式，项目文件夹在：\n\(outcome.reportFile.deletingLastPathComponent().path)\n\n"
            + "待确认的设定 \(review) 个，找不到的旧文件 \(missing) 个，详见迁移报告。旧数据原样保留，并已另做备份。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = "数据已升级到 2.0"
            alert.informativeText = text
            alert.addButton(withTitle: "打开迁移报告")
            alert.addButton(withTitle: "好")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(outcome.reportFile)
            }
        }
    }

    private static func announceMigrationFailure(_ error: Error) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = "数据升级失败"
            alert.informativeText = "\(error.localizedDescription)\n\n原来的数据没有改动。应用将退出，可以装回上一版继续使用，并把这条信息发给开发者。"
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private static func announce(title: String, text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    // MARK: - 任务中心（P2）

    /// 用户点了「停止」的生图（生成中被取消），失败文案换成说明
    @ObservationIgnored private var stoppedImageIDs: Set<UUID> = []

    /// 接上任务中心：提交入口、生图入口；恢复上次没提交完的视频和排队中的生图
    private func connectJobCenter() {
        jobCenter.startVideo = { [weak self] placeholderID, shotID in
            self?.performVideoSubmit(placeholderID: placeholderID, shotID: shotID)
        }
        jobCenter.runImage = { [weak self] id in await self?.generateImageItem(id) }
        pipelineFlow.jobCenter = jobCenter
        AIStreamHub.jobCenter = jobCenter
        store.onChange = { [weak self] in self?.scheduleProjectSave() }
        jobCenter.load()
        restoreVideoTasksFromJobs()
        jobCenter.pumpVideos()
        // 上次还没发出去的生图：接着生成（生成中的已在 loadProjects 判失败，不自动重试）
        for item in imageItems where item.status == .queued {
            jobCenter.enqueueImage(item.id)
        }
    }

    /// 恢复上次没提交出去的视频任务（jobs.json → 任务列表）：
    /// - 排队中的：重建占位，接着提交；
    /// - 失败的：重建一条，抽屉里能看到原因；
    /// - **已经随项目文件载入过的（失败占位会存进 project.json 的视频版本里）就不要再建了**——
    ///   同一个 id 只留一条。否则重启一次任务抽屉多一行重复的失败记录，
    ///   而且查 id / 存盘都是「第一条优先」，后建的那条会顶掉原来那条（2026-10-18 修）。
    func restoreVideoTasksFromJobs() {
        for record in jobCenter.records where record.kind == .video {
            guard let shotID = record.shotID, let shot = shots.first(where: { $0.id == shotID }) else {
                jobCenter.removeRecord(id: record.id)
                continue
            }
            if let existing = store.task(id: record.id) {
                // 已随项目文件还原过：状态和记录不一致时以记录为准（比如之前是排队中被中断）
                if record.state == .failed, existing.phase != .failed {
                    store.update(id: record.id, phase: .failed, error: record.note)
                }
                if record.state == .waiting { submittingShotIDs.insert(shotID) }
                continue
            }
            var task = makeLocalTask(shot: shot, providerName: record.channel ?? shot.providerID, id: record.id,
                                     phase: record.state == .waiting ? .queued : .failed)
            task.errorMessage = record.state == .waiting ? nil : record.note
            store.add(task)
            if record.state == .waiting { submittingShotIDs.insert(shotID) }
        }
    }

    /// 生图：交给任务中心立刻开始。所有「生成 / 重新生成」入口都走这里。
    func requestImageGeneration(_ itemID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }) else { return }
        switch imageItems[idx].status {
        case .queued, .generating, .downloading: return
        default: break
        }
        imageItems[idx].status = .queued
        imageItems[idx].submittedAt = Date()
        imageItems[idx].errorMessage = nil
        persistImageItems()
        jobCenter.enqueueImage(itemID)
    }

    /// 停止生图：取消请求（中转站可能已在生成，仍可能扣费）
    func stopImageGeneration(_ itemID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }) else { return }
        if imageItems[idx].status.isBusy {
            stoppedImageIDs.insert(itemID)
            jobCenter.stopImage(itemID)
        }
    }

    /// 明确指定某张生图卡片「进用」的那一版（制作页「挑定妆图」）。
    /// 和 `applyImageResult` 不同：只改选中的版本，不动卡片上的提示词和参数。
    func selectImageResult(_ itemID: UUID, resultID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }),
              imageItems[idx].results.contains(where: { $0.id == resultID }),
              imageItems[idx].selectedResultID != resultID else { return }
        imageItems[idx].selectedResultID = resultID
        persistImageItems()
    }

    /// 视频「不再等待」：平台没有取消接口，只是本地不再查它的结果（服务端可能照样生成、照样扣费）。
    /// 排队中还没提交的占位直接撤掉。
    func stopWaitingVideo(taskID: String) {
        guard let task = store.task(id: taskID) else { return }
        if taskID.hasPrefix("pending-") {
            guard !jobCenter.videoSubmitting.contains(taskID) else { return }
            jobCenter.cancelWaitingVideo(placeholderID: taskID)
            pendingVideoSnapshots[taskID] = nil
            store.remove(id: taskID)
            if let shot = shots.first(where: { $0.id == shotForTask(task)?.id }) { submittingShotIDs.remove(shot.id) }
            return
        }
        poller.cancelPolling(taskID: taskID)
        store.update(id: taskID, phase: .paused)
    }

    /// 视频「继续等待」：重新开始查结果
    func resumeWaitingVideo(taskID: String) {
        guard let task = store.task(id: taskID), task.phase == .paused else { return }
        poller.resumePolling(task)
    }

    /// 任务对应的分镜（占位任务没进 taskIDs，按提示词和项目找最近的一张）
    func shotForTask(_ task: LocalTask) -> ShotDraft? {
        if let shot = shots.first(where: { $0.taskIDs.contains(task.id) || $0.taskID == task.id }) { return shot }
        if let record = jobCenter.records.first(where: { $0.id == task.id }), let id = record.shotID {
            return shots.first { $0.id == id }
        }
        return nil
    }

    /// 批量粘贴解析：按关键字识别类型与名字；只替换「从未提交过」的待生成条目，已提交/已生成的任务保留
    /// 手动新增一条空白图片生成条目，并让它成为右栏当前条目。
    /// 名字默认「图片N」（N = 已有的「图片N」里最大的 + 1，删过卡片也不撞号，见 `ImageCardNaming`）；
    /// 缩略图页新增时请求滚到新条目，卡片页只选中右栏。
    @discardableResult
    func addImageItem() -> UUID {
        let key = currentProjectKey ?? ""
        let projectItems = imageItems.filter { $0.projectKey == key }
        let name = ImageCardNaming.placeholder(ImageCardNaming.nextPlaceholderNumber(existing: projectItems.map(\.name)))
        var item = ImageGenItem(projectKey: key, type: nil, name: name, prompt: "")
        applyDefaultImageParams(to: &item)
        imageItems.append(item)
        persistImageItems()
        inspectorKind = .image
        inspectedImageItemID = item.id
        if !projectItems.isEmpty, imageViewStyle == .thumbnails { scrollToImageItemID = item.id }
        return item.id
    }

    /// 更新图片生成条目的类型（默认 nil = 不挂徽章 / 角色 / 场景 / 道具）
    @discardableResult
    func savePipelineAssetImage(_ asset: SimplePipelineAsset, model: String?, aspect: ImageAspect,
                                quality: ImageQuality, type: ImageSubjectType?) -> UUID? {
        guard let key = currentProjectKey else { return nil }
        let existing = PipelineAssetImageRules.item(for: asset, projectKey: key, items: imageItems)
        let id: UUID
        if let existing, let index = imageItems.firstIndex(where: { $0.id == existing.id }) {
            id = existing.id
            imageItems[index].name = asset.name
            imageItems[index].prompt = asset.description
            imageItems[index].model = model
            imageItems[index].type = type
            imageItems[index].aspectRatio = aspect
            imageItems[index].quality = quality
            imageItems[index].paramsDirty = existing.model != model || existing.type != type ||
                existing.aspectRatio != aspect || existing.quality != quality || existing.paramsDirty
        } else {
            var item = ImageGenItem(projectKey: key, type: type, name: asset.name, prompt: asset.description)
            applyDefaultImageParams(to: &item)
            item.model = model
            item.aspectRatio = aspect
            item.quality = quality
            id = item.id
            imageItems.append(item)
        }
        persistImageItems()
        return id
    }

    /// 改卡片的阶段 / 起始集（生图页右栏「版本」两格；2026-10-14 名字与形态分离）。没变就什么都不写
    func updateImageItemVersion(_ id: UUID, stage: String?, fromEpisode: Int?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        let stage = CardVersion.normalizedStage(stage)
        let fromEpisode = fromEpisode.flatMap { $0 > 0 ? $0 : nil }
        guard imageItems[idx].stage != stage || imageItems[idx].fromEpisode != fromEpisode else { return }
        imageItems[idx].stage = stage
        imageItems[idx].fromEpisode = fromEpisode
        persistImageItems()
    }

    /// 绑 / 解绑角色卡的音色音频（素材库里的一段音频；nil = 解绑）。编辑提示词弹窗右栏「音色」，改了马上存，不跟着弹窗回滚（2026-10-26）。
    /// 绑上就切到「音频音色」（刚绑的当然是要用的）
    func updateImageItemVoiceAudio(_ id: UUID, audioID: UUID?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        if let audioID, libraryItem(audioID)?.kind != .audio { return }
        let mode: VoiceMode? = audioID == nil ? imageItems[idx].voiceMode : .audio
        guard imageItems[idx].voiceAudioID != audioID || imageItems[idx].voiceMode != mode else { return }
        imageItems[idx].voiceAudioID = audioID
        imageItems[idx].voiceMode = mode
        persistImageItems()
        syncVoices(ofCard: id)
    }

    /// 选「文本音色 / 音频音色」（两边填的都留着）
    func updateImageItemVoiceMode(_ id: UUID, mode: VoiceMode) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }), imageItems[idx].voiceMode != mode else { return }
        imageItems[idx].voiceMode = mode
        persistImageItems()
        syncVoices(ofCard: id)
    }

    /// 卡上的音色改了：挂着这张卡的图的分镜跟着更新（音频素材 +「【音色】」那行）
    func syncVoices(ofCard cardID: UUID) {
        syncVoices(ofCards: [cardID])
    }

    /// 几张卡一起：查表整理一次、最后存一次盘（主角用到上百段，原来每段各整理一遍、各存一次；批量提取音色一次几十张卡）。
    /// 返回改了几段分镜
    @discardableResult
    func syncVoices(ofCards cardIDs: Set<UUID>) -> Int {
        let cards = imageItems.filter { cardIDs.contains($0.id) }
        var changedCount = 0
        for projectKey in Set(cards.map(\.projectKey)) {
            let images = Set(library.filter { $0.imageGenItemID.map(cardIDs.contains) == true }.map(\.id))
            guard !images.isEmpty else { continue }
            let context = VoiceSyncContext(app: self, projectKey: projectKey)
            var changed = 0
            for shot in shots where shot.projectKey == projectKey && shot.imageRefs.contains(where: { images.contains($0.libraryItemID) }) {
                if syncShotVoices(shot.id, context: context) { changed += 1 }
            }
            if changed > 0 {
                touchProject(projectKey)
                persistShots()
            }
            changedCount += changed
        }
        return changedCount
    }

    /// 批量提取音色的结果写回卡上的文本音色（不动音频、不改选的是文本还是音频），再统一同步一次分镜。
    /// 和原来一样的不算；返回实际写了几张卡、改了几段分镜
    func applyExtractedVoices(_ voices: [UUID: String]) -> (cards: Int, shots: Int) {
        var written = Set<UUID>()
        for (id, text) in voices {
            guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { continue }
            let text = CardVoice.normalizedText(text)
            guard text != nil, imageItems[idx].voiceText != text else { continue }
            imageItems[idx].voiceText = text
            written.insert(id)
        }
        guard !written.isEmpty else { return (0, 0) }
        persistImageItems()
        return (written.count, syncVoices(ofCards: written))
    }

    /// 改角色卡的音色文字描述（空 = 不要）。没变就什么都不写
    func updateImageItemVoiceText(_ id: UUID, text: String?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        let text = CardVoice.normalizedText(text)
        guard imageItems[idx].voiceText != text else { return }
        imageItems[idx].voiceText = text
        persistImageItems()
        syncVoices(ofCard: id)
    }

    func updateImageItemType(_ id: UUID, type: ImageSubjectType?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        imageItems[idx].type = type
        persistImageItems()
    }

    /// 应用生图历史版本：切换预览图，并将该次生成快照恢复到当前条目草稿。
    /// nil = 跟随最新结果。早期版本缺少的快照字段保持草稿现值，不猜测历史参数。
    /// 生图失败：卡片标失败，同时把这一次记成一个版本（2026-10-16 用户：失败的生图也留成一个版本）。
    /// `snapshot` 不给 = 按卡片现在的提示词和设置记（还没真正发出请求的失败：没配模型、基础版还没图、退出时中断）
    func recordImageFailure(at idx: Int, _ message: String, snapshot: ImageGenFailure? = nil) {
        guard imageItems.indices.contains(idx) else { return }
        let item = imageItems[idx]
        imageItems[idx].status = .failed
        imageItems[idx].errorMessage = message
        imageItems[idx].failures.append(snapshot ?? ImageGenFailure(
            error: message, prompt: item.prompt, model: item.model, type: item.type,
            aspectRatio: item.aspectRatio, quality: item.quality, imageRefs: item.imageRefs))
    }

    /// 点历史版本里失败的那一版：换回那一次的提示词和设置（改了再交），预览写失败原因。和 `applyImageResult` 对应
    func applyImageFailure(_ itemID: UUID, failureID: UUID) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }),
              let failure = imageItems[idx].failures.first(where: { $0.id == failureID }) else { return }
        imageItems[idx].viewingFailureID = failureID
        if let prompt = failure.prompt { imageItems[idx].prompt = prompt }
        if let model = failure.model { imageItems[idx].model = model }
        imageItems[idx].type = failure.type ?? imageItems[idx].type
        if let aspectRatio = failure.aspectRatio { imageItems[idx].aspectRatio = aspectRatio }
        if let quality = failure.quality { imageItems[idx].quality = quality }
        if let refs = failure.imageRefs { imageItems[idx].imageRefs = refs }
        persistImageItems()
    }

    func applyImageResult(_ itemID: UUID, resultID: UUID?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }) else { return }
        imageItems[idx].viewingFailureID = nil
        guard let resultID else {
            imageItems[idx].selectedResultID = nil
            persistImageItems()
            return
        }
        guard let result = imageItems[idx].results.first(where: { $0.id == resultID }) else { return }
        imageItems[idx].selectedResultID = resultID
        if let prompt = result.prompt { imageItems[idx].prompt = prompt }
        // model 非 nil 表示完整生成设置快照存在；允许 type 为 nil（默认类型）。
        if let model = result.model {
            imageItems[idx].model = model
            imageItems[idx].type = result.type
            if let aspectRatio = result.aspectRatio { imageItems[idx].aspectRatio = aspectRatio }
            if let quality = result.quality { imageItems[idx].quality = quality }
        }
        if let imageRefs = result.imageRefs { imageItems[idx].imageRefs = imageRefs }
        persistImageItems()
    }

    /// 把解析出来的提示词块追加成生图卡片（不动界面状态）。**名字直接用解析出来的**（张三、客厅、怀表）；
    /// 提不出名字才叫「图片N」，同名自动加序号（见 `ImageCardNaming`，2026-10-08 用户定；原来一律叫「图片N」）。
    /// 追加不清空：保留手动「新增图片」的卡片，只在末尾追加（重复解析会叠加，同名的加序号）。
    @discardableResult
    func appendParsedImageCards(_ parsed: [ImagePromptParser.Parsed], projectKey key: String) -> [ImageGenItem] {
        // 名字里的「第N集的」拆成起始集（2026-10-14 名字与形态分离）；重名只在同一个版本槽（起始集 + 阶段）里算：
        // 「第1集的周承山」「第3集的周承山」都叫「周承山」，是两个版本，不是重名
        let existing = imageItems.filter { $0.projectKey == key }
        var taken: [String: Set<String>] = [:]
        for card in existing { taken[CardVersion.slot(card), default: []].insert(card.name) }
        var allNames = Set(existing.map(\.name))
        var next = ImageCardNaming.nextPlaceholderNumber(existing: Array(allNames))
        var newItems: [ImageGenItem] = []
        for raw in parsed {
            // 「起始集：」「阶段：」两行和旧写法的「第N集的」「基于…修改」拿出来存成字段，不留在要发给生图模型的提示词里
            let p = CardVersion.takeVersionLines(raw)
            var item = ImageGenItem(projectKey: key, type: p.type, name: p.name, prompt: p.prompt)
            item.fromEpisode = p.fromEpisode
            item.stage = p.stage
            if p.name == ImagePromptParser.unnamed || p.name.isEmpty {
                item.name = ImageCardNaming.unique(ImageCardNaming.placeholder(next), taken: allNames)
                next += 1
            } else {
                CardVersion.splitLegacyPrefix(&item)
                item.name = ImageCardNaming.unique(item.name, taken: taken[CardVersion.slot(item)] ?? [])
            }
            taken[CardVersion.slot(item), default: []].insert(item.name)
            allNames.insert(item.name)
            // 设置里的「默认参数」（模型 / 比例 / 画质）要带上；类型以解析出来的为准，不被默认类型盖掉
            applyDefaultImageParams(to: &item)
            item.type = p.type
            newItems.append(item)
        }
        imageItems.append(contentsOf: newItems)
        persistImageItems()
        return newItems
    }

    /// 记下「卡 → 基础版」（变化版出图时拿基础版的图当参考图，见 `prepareBaseReference`）
    func linkReferenceCards(_ links: [UUID: UUID]) {
        guard !links.isEmpty else { return }
        for (cardID, baseID) in links {
            if let i = imageItems.firstIndex(where: { $0.id == cardID }) { imageItems[i].referenceCardID = baseID }
        }
        persistImageItems()
    }

    func parseImagePrompts(_ text: String) {
        let parsed = ImagePromptParser.parse(text)
        let key = currentProjectKey ?? ""
        let newItems = appendParsedImageCards(parsed, projectKey: key)
        // 🆕 2026-10-03（用户定）：解析后**跳到新增的第一条**（同「新增图片」的逻辑）
        if let first = newItems.first {
            inspectedImageItemID = first.id
            if imageViewStyle == .thumbnails {
                // 🆕 2026-10-03：同视频侧——延后一拍再请求滚动（躲开关弹窗后的重排）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { [weak self] in self?.scrollToImageItemID = first.id }
                }
            }
        }
    }

    /// 移除单条图片生成条目
    func removeImageItem(id: UUID) {
        // 已选中 → 从集合摘掉，别让「已选 N」虚高（2026-09-27）
        selectedImageItemIDs.remove(id)
        imageItems.removeAll { $0.id == id }
        persistImageItems()
    }

    /// 编辑图片生成条目的提示词（重提对账用：同一个版本槽重提 = 更新这张卡的描述；生成历史 / 图全保留）。
    /// **这里刻意不改名字**——改名只发生在「提交生成 / 重新生成」时（见 `generateImageItem`）。
    func applyReconciledUpdate(cardID: UUID, parsed: ImagePromptParser.Parsed) {
        guard let idx = imageItems.firstIndex(where: { $0.id == cardID }) else { return }
        imageItems[idx].prompt = parsed.prompt
        imageItems[idx].type = parsed.type
        persistImageItems()
    }

    /// 编辑图片生成条目的提示词。
    /// **这里刻意不改名字**——改名只发生在「提交生成 / 重新生成」时（见 `generateImageItem`），
    /// 编辑提示词、切换类型都不动名字。
    func updateImageItemPrompt(_ id: UUID, prompt: String) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        imageItems[idx].prompt = prompt
        persistImageItems()
    }

    /// 批量设置图片参数：**只应用到 `ids` 指定的条目**（2026-09-26 用户定："只对选中的生效"）。
    /// `model` 为 nil / 空 = 不改模型（弹窗里的「请选择模型」= 不改）。
    func batchSetImageParams(ids: [UUID], model: String?, aspect: ImageAspect, quality: ImageQuality) {
        let targets = Set(ids)
        var touched = false
        for i in imageItems.indices where targets.contains(imageItems[i].id) {
            if let model, !model.isEmpty { imageItems[i].model = model }
            imageItems[i].aspectRatio = aspect
            imageItems[i].quality = quality
            imageItems[i].paramsDirty = true   // 改过参数 → 卡片参数显示为蓝色（2026-09-26）
            touched = true
        }
        if touched { persistImageItems() }
    }

    /// 更新图片条目的画幅
    func updateImageItemAspect(_ id: UUID, aspect: ImageAspect) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        imageItems[idx].aspectRatio = aspect
        imageItems[idx].paramsDirty = true     // 改过参数 → 卡片参数显示为蓝色
        persistImageItems()
    }

    /// 更新图片条目的分辨率档位
    func updateImageItemQuality(_ id: UUID, quality: ImageQuality) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        imageItems[idx].quality = quality
        imageItems[idx].paramsDirty = true     // 改过参数 → 卡片参数显示为蓝色
        persistImageItems()
    }

    /// 更新图片条目的模型（nil / 空 = 用配置里第一个图片模型）
    func updateImageItemModel(_ id: UUID, model: String?) {
        guard let idx = imageItems.firstIndex(where: { $0.id == id }) else { return }
        imageItems[idx].model = (model?.isEmpty ?? true) ? nil : model
        imageItems[idx].paramsDirty = true     // 改过参数 → 卡片参数显示为蓝色
        persistImageItems()
    }

    /// 清空当前项目的图片生成条目
    func clearImageItems() {
        let key = currentProjectKey ?? ""
        // 清掉的条目如果正在多选里，一并摘掉（2026-09-27，别让「已选 N」虚高）
        let removedIDs = Set(imageItems.lazy.filter { $0.projectKey == key }.map(\.id))
        imageItems.removeAll { $0.projectKey == key }
        if !removedIDs.isEmpty { selectedImageItemIDs.subtract(removedIDs) }
        persistImageItems()
    }

    /// 生成单条图片（异步更新条目状态；结果下载/落盘转存，追加版本不覆盖）
    func generateImageItem(_ itemID: UUID) async {
        guard imageItems.contains(where: { $0.id == itemID }) else { return }
        // 变化版（第24集的周承山 / 周承山十岁时期）：先把基础版的图挂成参考图；基础版还没图就不发请求，卡片上写明白
        guard await prepareBaseReference(for: itemID) else { return }
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }) else { return }
        // 解析模型：卡片选中的优先；为空则用配置里第一个图片模型
        let selected = imageItems[idx].model
        let modelName = (selected?.isEmpty == false) ? selected! : imageModelNames.first
        guard let modelName, let (channel, _) = channel(forModel: modelName) else {
            recordImageFailure(at: idx, "未配置图片模型，请到设置里添加渠道与图片模型")
            persistImageItems()
            return
        }
        // **名字在「提交生成 / 重新生成」时同步**：
        // 从提示词里提取（「这个人是：小明」→「小明」）。提不出来（手动新增的「图片N」、
        // 提示词里没有「关键字：名字」结构）就保持原名不动；提出来的还是同一个名字（含「小明 2」这种序号）也不动；
        // 换了名字就用新的，和别的卡重名加序号（`ImageCardNaming.nameAfterSubmit`）。
        let others = imageItems             // 先拷一份：同一个数组不能边 inout 边读
        CardVersion.syncNameFromPrompt(&imageItems[idx], others: others)
        // 旧数据可能没有版本提示词快照。此时右侧详情暂以条目当前提示词展示；
        // 重新生成会让旧结果变成历史版，因此先把当前显示的提示词固化到旧最新版本，避免它“消失”。
        let submittedPrompt = imageItems[idx].prompt
        if let previousIndex = imageItems[idx].results.indices.last,
           imageItems[idx].results[previousIndex].prompt?.isEmpty != false {
            imageItems[idx].results[previousIndex].prompt = submittedPrompt
        }
        let referenceIDs = imageItems[idx].imageRefs
        let size = imageItems[idx].sizeString
        let quality = imageItems[idx].quality.apiValue
        let submittedType = imageItems[idx].type
        let submittedAspectRatio = imageItems[idx].aspectRatio
        let submittedQuality = imageItems[idx].quality
        /// 提交时的原始模型字段（nil = 用配置里第一个模型）——成功后用它判断"参数期间被改过没有"，
        /// 决定要不要**保留**参数脏标记（2026-09-26）
        let submittedModelRaw = imageItems[idx].model
        let itemUUID = imageItems[idx].id
        // 重新生成后新结果应成为当前显示版本；nil 表示跟随 results.last。
        imageItems[idx].selectedResultID = nil
        imageItems[idx].viewingFailureID = nil
        imageItems[idx].status = .generating
        imageItems[idx].submittedAt = Date()
        imageItems[idx].errorMessage = nil
        persistImageItems()
        // 每个生成版本绑定提交时的提示词与生成设置快照，之后的异步操作不再读取可变草稿。
        let refPaths = await referenceImageFilePaths(for: referenceIDs)
        do {
            let outputs = try await ImageGenService.generate(
                channel: channel,
                modelName: modelName,
                prompt: submittedPrompt,
                size: size,
                quality: quality,
                referenceImagePaths: refPaths
            )
            guard let output = outputs.first else { throw APIError.invalidContent }
            // 中转已返回：进入下载阶段（UI 显示「下载中」而非继续转圈）
            imageItems[idx].status = .downloading
            persistImageItems()
            let returnedAt = Date()          // 批量回传卡顿排查（2026-10-21）：下载 / 搬进项目、写回卡片各花多久
            let version = imageItems[idx].results.count
            let projectKey = imageItems[idx].projectKey
            let baseName = "img-\(itemUUID.uuidString)-\(version)"
            let local: URL
            let resultURL: String?
            switch output {
            case .url(let url):
                AppLog.write("imagegen", "下载开始 name=\(imageItems[idx].name) url=\(url.absoluteString.prefix(80))")
                local = try await DownloadService.downloadImage(from: url, name: baseName, projectKey: projectKey)
                resultURL = url.absoluteString
            case .localFile(let path):
                // b64 已落盘：直接搬进项目图片目录（同一套命名/去重规则）
                local = try DownloadService.saveImage(fromFile: path, name: baseName, projectKey: projectKey)
                resultURL = nil
            }
            AppLog.write("imagegen", "下载完成 name=\(imageItems[idx].name) path=\(local.path)")
            let savedAt = Date()
            imageItems[idx].results.append(ImageGenResult(
                localPath: local.path,
                resultURL: resultURL,
                prompt: submittedPrompt,
                model: modelName,
                type: submittedType,
                aspectRatio: submittedAspectRatio,
                quality: submittedQuality,
                imageRefs: referenceIDs
            ))
            // 参数脏标记：这套参数已经真的生成出来了 → 灰（期间用户又改过参数就保持蓝，2026-09-26）
            imageItems[idx].paramsDirty = imageItems[idx].model != submittedModelRaw
                || imageItems[idx].aspectRatio != submittedAspectRatio
                || imageItems[idx].quality != submittedQuality
            imageItems[idx].status = .success
            persistImageItems()
            AppLog.write("perf", "生图回传 name=\(imageItems[idx].name) 下载/搬进项目 \(Int(savedAt.timeIntervalSince(returnedAt) * 1000)) ms，写回卡片 \(Int(Date().timeIntervalSince(savedAt) * 1000)) ms")
        } catch {
            AppLog.write("imagegen", "失败 name=\(imageItems[idx].name) err=\(error.localizedDescription)")
            let message = stoppedImageIDs.remove(itemID) != nil
                ? "已停止。中转站可能已经在生成，仍可能扣费，可到后台确认"
                : error.localizedDescription
            // 记的是提交那一刻的提示词和设置（生成期间草稿可能又改了）
            recordImageFailure(at: idx, message, snapshot: ImageGenFailure(
                error: message, prompt: submittedPrompt, model: modelName, type: submittedType,
                aspectRatio: submittedAspectRatio, quality: submittedQuality, imageRefs: referenceIDs))
            persistImageItems()
        }
    }


    /// 同时在等基础版的两张变化版之间，轮询基础版状态的间隔（测试里调小）
    static var baseReferencePollInterval: Duration = .milliseconds(250)

    /// **出图前：变化版挂上基础版的图当参考图**（2026-10-09）。没有 `referenceCardID` 的卡什么都不做（返回 true）。
    /// 2026-10-11 用户定：**软件不再替用户把基础版入库**（批量提交生图时，基础版一生成好，变化版就接着把它刚生成的那一版自动入库、
    /// 挂成参考图——用户还没看过好不好、要不要重出）。入库是用户自己的动作：看过、选好一版、点「保存到素材库」，变化版才用它。
    /// - 基础版还在排队 / 生成（「全部生成」时基础版和变化版同时点的）：等它做完，**再等用户入库一版**，入库了自动接着往下生成
    ///   （变化版一直是「排队中」，卡片上写着在等什么；点「停止」随时退出）；
    /// - 基础版早就做完了、点变化版时还没入库：不挂着等，直接不生成，写明先去入库；
    /// - 基础版有入库过的版本：用**选中那一版**的入库条目；选中的那一版没入库就取入库过的**最新**一版。
    ///   挂成这张卡的参考图——已经挂着基础版的旧图（基础版换了入库的版本）就原位换成现在的，图号不变；没挂过就接在最后面；
    ///   再在提示词里补一句「根据图N参考生成。」；
    /// - 基础版没有图（没生成过 / 生成失败）：**不发请求**，卡片标失败并写明先给谁出图（出图要花钱，不替用户先出基础版）。
    /// - 基础版的卡被删了：关联作废，当普通卡生成。
    /// 返回 false = 这张卡这次不生成（原因已写在卡片上）。
    func prepareBaseReference(for itemID: UUID) async -> Bool {
        guard let first = imageItems.first(where: { $0.id == itemID }), let baseID = first.referenceCardID else { return true }
        guard let startBase = imageItems.first(where: { $0.id == baseID }) else {
            if let i = imageItems.firstIndex(where: { $0.id == itemID }) { imageItems[i].referenceCardID = nil; persistImageItems() }
            return true
        }
        // 点变化版时基础版正在做 = 同时提交的：做完以后还要等用户入库；基础版早就做完了，没入库就不挂着等
        let submittedTogether = startBase.status.isBusy
        var libraryID: UUID?
        while libraryID == nil {
            guard let base = imageItems.first(where: { $0.id == baseID }) else {
                // 等的时候基础版被删了：关联作废，当普通卡生成
                if let i = imageItems.firstIndex(where: { $0.id == itemID }) {
                    imageItems[i].referenceCardID = nil
                    imageItems[i].errorMessage = nil
                    persistImageItems()
                }
                return true
            }
            if base.status.isBusy {
                // 基础版还在做：等它
                if !(await waitBaseReference(itemID)) { return false }
                continue
            }
            let hint = "要先给「\(base.name)」出图：这一张要拿它当参考图。先生成它，再生成这一张。"
            guard !base.results.isEmpty else { return failBaseReference(itemID, hint) }
            libraryID = Self.savedBaseLibraryID(base, library: library)
            if libraryID != nil { break }
            guard submittedTogether else {
                return failBaseReference(itemID, "「\(base.name)」还没有入库的版本：先在它那里选好一版，点「保存到素材库」，再生成这一张。")
            }
            // 同时提交的：等用户看过基础版、入库一版（也可能重新出图，重出时上面会接着等）
            if let i = imageItems.firstIndex(where: { $0.id == itemID }), imageItems[i].errorMessage == nil {
                imageItems[i].errorMessage = "等「\(base.name)」入库一版定妆图后自动继续"
            }
            if !(await waitBaseReference(itemID)) { return false }
        }
        guard let libraryID, let base = imageItems.first(where: { $0.id == baseID }),
              let index = imageItems.firstIndex(where: { $0.id == itemID }) else { return false }
        imageItems[index].errorMessage = nil
        let baseResultIDs = Set(base.results.map(\.id))
        var refs = imageItems[index].imageRefs
        let number: Int
        if let old = refs.firstIndex(where: { ref in libraryItem(ref.libraryItemID)?.imageGenResultID.map(baseResultIDs.contains) ?? false }) {
            if refs[old].libraryItemID != libraryID {
                refs[old] = MaterialRef(id: refs[old].id, libraryItemID: libraryID, role: refs[old].role)
            }
            number = old + 1
        } else {
            refs.append(MaterialRef(libraryItemID: libraryID, role: .referenceImage))
            number = refs.count
        }
        imageItems[index].imageRefs = refs
        imageItems[index].prompt = ReferenceLinks.promptWithReferenceLine(imageItems[index].prompt, token: number)
        persistImageItems()
        return true
    }

    /// 基础版入库过的版本里，变化版该用哪一条素材库条目：选中（没选就最新）那一版入库了就用它，没有就取入库过的最新一版；一版都没入库 = nil
    static func savedBaseLibraryID(_ base: ImageGenItem, library: [LibraryItem]) -> UUID? {
        let shown = base.results.first(where: { $0.id == base.selectedResultID }) ?? base.latestResult
        if let shown, let entry = library.first(where: { $0.imageGenResultID == shown.id }) { return entry.id }
        for result in base.results.reversed() {
            if let entry = library.first(where: { $0.imageGenResultID == result.id }) { return entry.id }
        }
        return nil
    }

    /// 等一个轮询间隔；被取消（用户点停止）就把这张卡标成「已停止」，返回 false
    private func waitBaseReference(_ itemID: UUID) async -> Bool {
        do { try await Task.sleep(for: Self.baseReferencePollInterval) } catch {
            stoppedImageIDs.remove(itemID)
            return failBaseReference(itemID, "已停止") && false
        }
        return true
    }

    private func failBaseReference(_ itemID: UUID, _ message: String) -> Bool {
        if let i = imageItems.firstIndex(where: { $0.id == itemID }) {
            recordImageFailure(at: i, message)
            persistImageItems()
        }
        return false
    }

    /// 把生成成功的图片（指定版本）存入素材库（命名「类型-名字[-序号]」，入库后走 OSS 预上传供分镜引用）；返回素材库条目 ID
    @discardableResult
    func saveImageItemToLibrary(_ itemID: UUID, resultID: UUID? = nil) -> UUID? {
        // 诊断（2026-09-18 用户报"保存到素材库失败"）：每个静默失败点都记一条，方便定位
        AppLog.write("library", "入库开始 item=\(itemID.uuidString.prefix(8)) result=\(resultID?.uuidString.prefix(8) ?? "nil")")
        // 必须有项目上下文（旧版曾产生 projectKey=nil 的孤儿素材）
        guard let projectKey = currentProjectKey else {
            AppLog.write("library", "入库失败：没有当前项目（currentProjectKey=nil）")
            return nil
        }
        guard let idx = imageItems.firstIndex(where: { $0.id == itemID }),
              imageItems[idx].status == .success else {
            AppLog.write("library", "入库失败：找不到条目或状态不是成功")
            return nil
        }
        // 默认类型（无类型徽章）纯生图，不入库成素材
        guard imageItems[idx].type != nil else {
            AppLog.write("library", "入库失败：该条目没有类型（纯生图，按设计不入库）")
            return nil
        }
        let result: ImageGenResult?
        if let resultID, let r = imageItems[idx].results.first(where: { $0.id == resultID }) {
            result = r
        } else {
            result = imageItems[idx].latestResult
        }
        // 去重：同一结果版本只能入库一次（按结果 ID，不按文件名）
        if let result, library.contains(where: { $0.imageGenResultID == result.id }) {
            AppLog.write("library", "入库失败：这个结果版本已经入库过（去重）")
            return nil
        }
        guard let localPath = result?.localPath else {
            AppLog.write("library", "入库失败：结果没有本地文件路径")
            return nil
        }
        let item = imageItems[idx]
        // 默认类型已在上面拦截；此处类型非空，直接用前缀命名
        let prefix = "\(item.type!.namePrefix)-\(item.name)"
        // 序号 = 本项目里已有同名前缀的**最大序号 + 1**，**不是"条数"**。
        // ⚠️ 用条数会在删掉中间一个之后撞名：入库 3 张得到「角色-雪娘 / -1 / -2」，
        // 删掉「-1」再入库一张，条数又变成 2 → 又叫「-2」，和还在的那条重名
        //（2026-09-13 查命名逻辑时发现；视频文件那边是同一天修掉的同一个病 —— 位置/数量派生）。
        // 无后缀的那条记作序号 0；跨项目同名素材不影响本项目编号。
        let usedNumbers: [Int] = library.compactMap { lib in
            guard lib.projectKey == projectKey, let name = lib.name else { return nil }
            if name == prefix { return 0 }
            guard name.hasPrefix(prefix + "-") else { return nil }
            return Int(name.dropFirst(prefix.count + 1))
        }
        let rawName = usedNumbers.isEmpty ? prefix : "\(prefix)-\((usedNumbers.max() ?? 0) + 1)"
        let finalName = Self.sanitizedMaterialName(rawName)
        // 缓存文件重命名为素材名（角色-雪娘.png），访达里与素材库显示一致
        var finalLocalPath = localPath
        do {
            let path = localPath
            let ext = (path as NSString).pathExtension
            let directory = FileLocations.projectImagesDirectory(projectKey)
            // 目标名被占就**加后缀**（`-2`、`-3`…）另存，**绝不覆盖**已有文件。
            // （原来撞名时是"整个不重命名" → 素材库显示名和磁盘上的文件名对不上）
            var target = directory.appendingPathComponent("\(finalName).\(ext)").path
            var suffix = 2
            while target != path, FileManager.default.fileExists(atPath: target) {
                target = directory.appendingPathComponent("\(finalName)-\(suffix).\(ext)").path
                suffix += 1
            }
            if path != target, FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.moveItem(atPath: path, toPath: target)
                finalLocalPath = target
            }
        }
        // 缓存文件重命名后，同步结果版本的 localPath（否则预览/引用读到旧路径失效）
        if finalLocalPath != localPath, let r = result,
           let ri = imageItems[idx].results.firstIndex(where: { $0.id == r.id }) {
            imageItems[idx].results[ri].localPath = finalLocalPath
            persistImageItems()
        }
        var libItem = LibraryItem(
            kind: .image,
            localPath: finalLocalPath,
            fileName: (finalLocalPath as NSString).lastPathComponent,
            name: finalName,
            projectKey: projectKey
        )
        libItem.source = .imageGenerated
        libItem.imageGenItemID = item.id
        libItem.imageGenResultID = result?.id
        library.append(libItem)
        persistLibrary()
        AppLog.write("library", "入库成功：\(finalName) → \(finalLocalPath)")
        // 与素材库拖入一致：预上传 OSS 拿直链，供字字动画分镜引用
        uploadLibraryItem(libItem.id)
        return libItem.id
    }

    /// 「批量入库」预检结果：**全有全无**（2026-09-28 用户定）——
    /// 有任何一条不能入库就**整批不执行、只弹提示**，不做"能入的先入"。各字段是分类计数。
    struct BatchSaveLibraryIssues {
        var noType = 0        // 无类型的纯生图（按设计不进素材库）
        var noResult = 0      // 还没有生成结果（生成中/失败/空卡）
        var alreadySaved = 0  // "当前显示的那一版"已经入库过（按结果 ID 去重）
        var missingFile = 0   // 结果本地文件缺失（极少见）

        var isEmpty: Bool { noType + noResult + alreadySaved + missingFile == 0 }

        /// 给用户看的原因汇总（"；"分隔）
        var summary: String {
            var parts: [String] = []
            if noType > 0 { parts.append("\(noType) 张没有类型（纯生图），不能入库 —— 请先给它们选类型") }
            if noResult > 0 { parts.append("\(noResult) 张还没有生成结果") }
            if alreadySaved > 0 { parts.append("\(alreadySaved) 张当前显示的那一版已经入库过") }
            if missingFile > 0 { parts.append("\(missingFile) 张的本地文件缺失") }
            return parts.joined(separator: "；")
        }
    }

    /// 一张卡在「批量入库」预检里的结论（同一套口径，预检和「跳过已入库」共用，免得两边判得不一样）
    enum BatchSaveVerdict: Equatable { case ok, noType, noResult, alreadySaved, missingFile }

    func batchSaveVerdict(_ item: ImageGenItem) -> BatchSaveVerdict {
        if item.type == nil { return .noType }
        guard item.status == .success,
              let result = item.results.first(where: { $0.id == item.selectedResultID }) ?? item.latestResult else { return .noResult }
        if library.contains(where: { $0.imageGenResultID == result.id }) { return .alreadySaved }
        guard let path = result.localPath, FileManager.default.fileExists(atPath: path) else { return .missingFile }
        return .ok
    }

    /// 「批量入库」预检（全有全无）：逐条按**当前显示的那一版**检查。
    ///
    /// 显示版口径与卡片/右栏一致：`results.first { $0.id == selectedResultID } ?? latestResult`
    ///（用户 2026-09-28 明确："存的是当前显示的，并不一定是最新版"）。
    /// 返回空 = 全部可入；否则整批不执行（调用方只弹提示）。
    func batchSaveLibraryIssues(for itemIDs: [UUID]) -> BatchSaveLibraryIssues {
        var issues = BatchSaveLibraryIssues()
        for id in itemIDs {
            guard let item = imageItems.first(where: { $0.id == id }) else { continue }
            switch batchSaveVerdict(item) {
            case .ok: break
            case .noType: issues.noType += 1
            case .noResult: issues.noResult += 1
            case .alreadySaved: issues.alreadySaved += 1
            case .missingFile: issues.missingFile += 1
            }
        }
        return issues
    }

    /// 预检没过时的「跳过已入库」（2026-10-09 用户要求，失败弹窗里加按钮）：把「当前显示的那一版已经入库过」的去掉，
    /// 剩下的**再预检一遍**。剩下的全部能入库 → 返回它们（按原顺序）；否则返回 nil：
    /// 没有已入库的（跳过也没用）、全都已入库（没有要存的）、或者还有别的问题（无类型 / 没结果 / 文件缺失——
    /// 全有全无的规矩对这些不变，得先处理）。
    func batchSaveIDsSkippingSaved(_ itemIDs: [UUID]) -> [UUID]? {
        let verdicts = itemIDs.compactMap { id in imageItems.first(where: { $0.id == id }).map { (id, batchSaveVerdict($0)) } }
        guard verdicts.contains(where: { $0.1 == .alreadySaved }) else { return nil }
        let rest = verdicts.filter { $0.1 != .alreadySaved }
        guard !rest.isEmpty, rest.allSatisfy({ $0.1 == .ok }) else { return nil }
        return rest.map(\.0)
    }

    /// 「批量入库」执行：逐条存**当前显示的那一版**（`selectedResultID` 命中版，没命中才 latest），
    /// 返回成功条数。⚠️ 调用前必须先过 `batchSaveLibraryIssues`（全有全无），否则会有静默失败。
    /// OSS 预上传**不限并发**（用户 2026-09-28 定：一次全发，失败各自标"上传失败"）。
    @discardableResult
    func batchSaveImageItemsToLibrary(_ itemIDs: [UUID]) -> Int {
        var saved = 0
        for id in itemIDs {
            guard let item = imageItems.first(where: { $0.id == id }) else { continue }
            if saveImageItemToLibrary(item.id, resultID: item.selectedResultID) != nil { saved += 1 }
        }
        return saved
    }


    /// 返回加进库的条目 ID（扩展名不认的文件跳过）
    @discardableResult
    func addLibraryFiles(_ urls: [URL]) -> [UUID] {
        var added: [UUID] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: LibraryItem.Kind
            if ["png", "jpg", "jpeg", "webp", "gif"].contains(ext) {
                kind = .image
            } else if ["mp4", "mov", "m4v"].contains(ext) {
                kind = .video
            } else if ["mp3", "wav", "aac", "m4a"].contains(ext) {
                kind = .audio
            } else {
                continue
            }
            let item = LibraryItem(kind: kind, localPath: url.path, fileName: url.lastPathComponent, projectKey: currentProjectKey)
            library.append(item)
            let itemID = item.id
            added.append(itemID)
            if kind != .image {
                // 异步探测音视频时长
                Task {
                    if let d = try? await MediaInspector.mediaDuration(at: url) {
                        if let idx = self.library.firstIndex(where: { $0.id == itemID }) {
                            self.library[idx].duration = d
                            self.persistLibrary()
                        }
                    }
                }
            }
        }
        persistLibrary()
        if let key = currentProjectKey { touchProject(key) }
        // 逐个预上传
        for item in library where item.uploadState == .pending {
            uploadLibraryItem(item.id)
        }
        return added
    }

    /// 删除素材库条目：**只从库里移除 + 清理分镜内引用，磁盘上的文件一律不动**
    func removeLibraryItem(id: UUID) {
        // ⚠️ **只从库里移除，绝不动磁盘上的文件**（用户 2026-09-13 定的规则，别再加回来）。
        //
        // 原来这里有一句 `removeItem(atPath: localPath)` —— 而**拖进来的素材** `localPath` 直接指向
        // 用户自己的文件（`~/Downloads/…`，见 `addLibraryFiles`），删素材等于**未经同意删掉他的原文件**。
        // 当年需要"删文件"是为了避免"删掉再入库时撞上残留文件"，那个问题现在已经被
        // 「序号取最大 + 1」+「重命名撞名加后缀」解决了（见 `saveImageItemToLibrary`），
        // 所以整条规则可以去掉了。
        library.removeAll { $0.id == id }

        // **摘引用时必须连提示词一起改**：素材引用是**按位置编号**的（`imageRefs[0]` = 「图1」…），
        // 删掉「图1」之后原来的「图2」会顺位变成「图1」，而提示词文字里还写着「图1是…」「图2是…」
        // → 渲染时**张冠李戴**（用户 2026-09-13 实测：删掉场景图后，"角色图的缩略图跑到了
        // 「图1是蕴古斋前柜 日 内」那里"）。
        // 复用编辑弹窗那套 `removeTokenAndRenumber`：删掉被删的 token（含紧跟的「是」），
        // 并把更大的编号整体前移一位 —— 两边走同一条规则，才不会各修各的。
        var cleanedShots = 0
        for i in shots.indices {
            var prompt = shots[i].prompt
            var changed = false
            // 倒序遍历 + 删除：删多个时下标不会乱
            for idx in shots[i].imageRefs.indices.reversed() where shots[i].imageRefs[idx].libraryItemID == id {
                prompt = Self.removeTokenAndRenumber(prompt, prefix: "图", removedIndex: idx + 1)
                shots[i].imageRefs.remove(at: idx)
                changed = true
            }
            for idx in shots[i].videoRefs.indices.reversed() where shots[i].videoRefs[idx].libraryItemID == id {
                prompt = Self.removeTokenAndRenumber(prompt, prefix: "视频", removedIndex: idx + 1)
                shots[i].videoRefs.remove(at: idx)
                changed = true
            }
            for idx in shots[i].audioRefs.indices.reversed() where shots[i].audioRefs[idx].libraryItemID == id {
                prompt = Self.removeTokenAndRenumber(prompt, prefix: "音频", removedIndex: idx + 1)
                shots[i].audioRefs.remove(at: idx)
                changed = true
            }
            guard changed else { continue }
            // 兜底：把"超出引用数量"的野 token 也清掉（复制粘贴带过来的、或历史残留）
            prompt = Self.stripDanglingTokens(prompt, prefix: "图", maxCount: shots[i].imageRefs.count)
            prompt = Self.stripDanglingTokens(prompt, prefix: "视频", maxCount: shots[i].videoRefs.count)
            prompt = Self.stripDanglingTokens(prompt, prefix: "音频", maxCount: shots[i].audioRefs.count)
            shots[i].prompt = prompt
            touchProject(shots[i].projectKey)
            cleanedShots += 1
        }

        // 生图条目同理（它的提示词里也有「图N」）
        var cleanedItems = 0
        for i in imageItems.indices {
            var prompt = imageItems[i].prompt
            var changed = false
            for idx in imageItems[i].imageRefs.indices.reversed() where imageItems[i].imageRefs[idx].libraryItemID == id {
                prompt = Self.removeTokenAndRenumber(prompt, prefix: "图", removedIndex: idx + 1)
                imageItems[i].imageRefs.remove(at: idx)
                changed = true
            }
            guard changed else { continue }
            prompt = Self.stripDanglingTokens(prompt, prefix: "图", maxCount: imageItems[i].imageRefs.count)
            imageItems[i].prompt = prompt
            cleanedItems += 1
        }
        // 角色卡绑的音色就是这段音频：解绑（文字描述留着）
        for i in imageItems.indices where imageItems[i].voiceAudioID == id {
            imageItems[i].voiceAudioID = nil
        }

        // 只留一条汇总日志：这是个"会改用户提示词"的操作，真出问题时能对上时间
        if cleanedShots + cleanedItems > 0 {
            AppLog.write("library", "删素材：同步清理了 \(cleanedShots) 个分镜 / \(cleanedItems) 个生图条目的提示词 token")
        }

        persistLibrary()
        persistShots()
        persistImageItems()
    }

    /// 某图片结果版本是否已入库（预览弹窗「已入库」状态用）
    func isImageResultSaved(_ resultID: UUID?) -> Bool {
        guard let resultID else { return false }
        return library.contains { $0.imageGenResultID == resultID }
    }

    /// 重命名素材（匹配名）：同步重命名缓存文件
    /// 把用户可见的素材名净化为**能当文件名用**的形态（2026-09-18）：
    /// `/`（路径分隔符）、`:` 等替换成 `-`。素材名里带这些字符时，
    /// 重命名会静默失败、上传时按"斜杠后的部分"找不到文件 ✗（用户实测："上传失败"）。
    nonisolated static func sanitizedMaterialName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return String(String.UnicodeScalarView(
            name.unicodeScalars.map { illegal.contains($0) ? Unicode.Scalar(45) : $0 }   // 45 = "-"
        ))
    }

    func renameLibraryItem(_ id: UUID, to name: String) {
        guard let idx = library.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = Self.sanitizedMaterialName(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let oldName = library[idx].matchName
        library[idx].name = trimmed.isEmpty ? nil : trimmed
        let newName = library[idx].matchName
        // 缓存文件重命名为新素材名
        if oldName != newName, let path = library[idx].localPath,
           FileManager.default.fileExists(atPath: path) {
            let ext = (path as NSString).pathExtension
            let target = ((path as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("\(newName).\(ext)")
            if !FileManager.default.fileExists(atPath: target) {
                try? FileManager.default.moveItem(atPath: path, toPath: target)
                library[idx].localPath = target
            }
        }
        persistLibrary()
    }

    /// 提示词被**整段换掉**之后（重新推理、整集重新出分镜）：新提示词里没有「图N」的参考图摘掉。
    /// 只在重新推理时用——那是用户点了确认的「会覆盖提示词并清掉挂着的参考图」。
    /// ⚠️ 只管参考图：手动挂的视频 / 音频不动；平时在提示词里删字也不走这里（2026-10-16 用户定：提示词里删素材，素材区的不删）。
    /// 从最大序号倒着来：删掉一个之后，后面的序号会整体前移
    func clearImageRefsMissingFromPrompt(_ shotID: UUID) {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let prompt = shots[idx].prompt
        guard let regex = try? NSRegularExpression(pattern: "图(\\d+)") else { return }
        let ns = prompt as NSString
        let kept = Set(regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) })
        let refs = shots[idx].imageRefs
        for index in stride(from: refs.count - 1, through: 0, by: -1) where !kept.contains(index + 1) {
            removeShotMaterial(shotID: shotID, refID: refs[index].id)
        }
    }

    /// 自动匹配素材：扫描提示词，按素材名匹配，命中则加入分镜素材区并在词前插入「图N是」；同时识别时长
    /// 返回匹配到的素材数量（未命中或分镜不存在返回 0）
    ///
    /// `candidates`：只在这些素材里匹配（制作页用它指定「每个设定选中的那一张图」；nil = 本项目整个素材库，旧页面的行为）。
    /// `detectsDuration`：false = 不按 `[X-Y 秒]` 改分镜时长（制作页的时长由参数栏管）。
    @discardableResult
    func autoMatchMaterials(_ shotID: UUID, candidates pool: [LibraryItem]? = nil, detectsDuration: Bool = true) -> Int {
        let matched = matchMaterialsByName(shotID, candidates: pool, detectsDuration: detectsDuration)
        // 挂着的角色图带上它们的音色（2026-10-26，见 `ShotVoiceSync`）：没挂上新图也要跑（卡上刚绑了音色、换了版本）
        syncShotVoices(shotID)
        return matched
    }

    private func matchMaterialsByName(_ shotID: UUID, candidates pool: [LibraryItem]?, detectsDuration: Bool) -> Int {
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return 0 }
        let shot = shots[idx]
        let prompt = shot.prompt

        // 识别时长（取所有 [X-Y 秒] 时间段的最大结束秒数）
        if detectsDuration, let duration = detectDuration(from: prompt) {
            shots[idx].duration = duration
        }

        struct Match {
            let item: LibraryItem
            let range: Range<String.Index>
        }

        // 收集匹配：只在「[场景][角色][道具]」这类方括号段落内找素材名，正文里同名当普通词时绝不插入。
        // 已添加的素材跳过，避免重复叠加。
        //
        // **长关键词优先 + 占用区间**（修「子串抢位」）：素材名互相包含时（如「沈吟卧房」/「沈吟」），
        // 若逐个按库顺序取「第一次出现」，短名「沈吟」会先匹配到 [沈吟卧房] 里，把角色图插进场景段。
        // 改为：关键词长的先占位，并记录已占用的 Range；短名只在**未被占用**的出现位置匹配，
        // 找不到空闲位置就不匹配（宁可漏，不错位）。
        let existingIDs = Set(shot.imageRefs.map(\.libraryItemID) + shot.videoRefs.map(\.libraryItemID) + shot.audioRefs.map(\.libraryItemID))
        // 同一角色可能有「角色-沈砚」和「角色-沈砚-1」等多个版本。
        // 它们的 matchKeyword 都是「沈砚」，不能在同一提示词里被当成两个独立素材反复插入。
        // 已有引用也按语义键占位，让重复点击保持幂等。
        // 2026-10-09：用**基础名**（去掉「第N集的」前缀）做语义键 —— 同一个人的「第1集的沈惊澜」「第8集的沈惊澜」是同一个素材的两个版本，
        // 一条提示词里只挂一张（挂哪张见下面按分镜集号选版本）。
        // 头行里的名字（分镜是推理出来的时才有）。素材名和头行里的某个名字「只差重名序号」（素材叫「周承山 2」、头行写「周承山」）时，
        // 它顶的是头行那个名字的位置：按头行的名字去找、和同名的其他版本算同一个素材、已经挂着它就不再挂别的版本。
        // 头行里另有一行正好叫它自己的名字时，各管各的。头行读不出来（手动建的分镜）就按素材自己的名字，和原来一样。
        let headNames: [String] = {
            guard let head = StoryboardNames.head(of: prompt) else { return [] }
            return (head.scenes + head.roles + head.props).sorted()
        }()
        func slotName(_ name: String) -> String {
            if headNames.isEmpty || headNames.contains(name) { return name }
            let family = AssetVersionName.withoutDuplicateNumber(name)
            return headNames.first { AssetVersionName.withoutDuplicateNumber($0) == family } ?? name
        }
        func semanticKey(_ item: LibraryItem) -> String {
            let name = item.matchName
            let category = ["场景-", "角色-", "道具-"].first(where: { name.hasPrefix($0) }) ?? ""
            let base = slotName(AssetVersionName.baseName(item.matchKeyword))
            return "\(item.kind.rawValue)|\(category)|\(base.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))"
        }
        let existingSemanticKeys = Set(existingIDs.compactMap { id in
            currentProjectLibrary.first(where: { $0.id == id }).map(semanticKey)
        })
        let segments = bracketSegments(in: prompt)   // [(content 范围内的 matches 时用，这里直接给全局 Range)]

        struct Candidate { let item: LibraryItem; let name: String; let order: Int }
        struct Eligible { let candidate: Candidate; let version: Int }
        var groups: [String: [Eligible]] = [:]
        var groupOrder: [String] = []
        // 生图入库的素材：起始集 / 阶段看来源卡（2026-10-14 起卡名不带「第N集的」，入库名里也就没有了）
        let cardsByID = Dictionary(imageItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (order, item) in (pool ?? currentProjectLibrary).enumerated() {
            let sourceCard = item.imageGenItemID.flatMap { cardsByID[$0] }
            // 整个素材库里找时（没指定候选）：别的阶段的卡（四十岁 / 少年）不顶主时间线的名字；指定了候选的是调用方选好的那一版
            if pool == nil, let sourceCard, !sourceCard.hasStage(nil) { continue }
            // 图片生成素材用剥离前缀/序号的匹配关键词（角色-丫鬟-1 → 丫鬟），其他素材用显示名；
            // 带「第N集的」版本前缀的再去掉前缀，用基础名去提示词里找（分割 / 分镜里写的是不带前缀的名字）
            let parsed = AssetVersionName.parse(item.matchKeyword)
            let name = slotName(parsed?.base ?? item.matchKeyword)
            guard !name.isEmpty, name != "未命名" else { continue }
            // 纯数字文件名（如「1.png」「2.png」）不能作为匹配词：提示词里的时间段
            // `[0.8-8.8 秒]` 也在方括号中，数字素材会误命中时间码并把图标插进数字中间。
            guard name.rangeOfCharacter(from: .letters) != nil else { continue }
            guard !existingIDs.contains(item.id) else { continue }
            let key = semanticKey(item)
            guard !existingSemanticKeys.contains(key) else { continue }
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(Eligible(candidate: Candidate(item: item, name: name, order: order),
                                                    version: sourceCard?.versionEpisode ?? parsed?.episode ?? 0))
        }
        // 同一个基础名有多个版本：按这条分镜是第几集选一个（推理分镜建的卡 a = 集号；手动建的分镜没有集号 → 取最早的基础形象）。
        // 没有版本前缀的素材全是 0，选的就是库里靠前的那张，和原来的行为一样。
        let shotEpisode = shot.numbering?.a
        var candidates: [Candidate] = groupOrder.compactMap { key in
            guard let group = groups[key], let chosen = AssetVersionName.pick(versions: group.map(\.version), episode: shotEpisode) else { return nil }
            return group[chosen].candidate
        }
        // 关键词长的先处理（同长度按素材库原顺序），保证长名先占住自己的区间
        candidates.sort {
            if $0.name.count != $1.name.count { return $0.name.count > $1.name.count }
            return $0.order < $1.order
        }

        // 已经挂着图的名字（前面带「图N」的那一项）它那一段文字也算占着：不然更短的素材名会在它里面再匹配上
        //（2026-10-10 用户项目：场景「年度赛车颁奖礼后台」已经挂好，再匹配一次，道具「赛车」就在场景名中间插了个「图6」、多挂了一张赛车图）
        var occupied: [Range<String.Index>] = attachedNameRanges(in: prompt, segments: segments)
        func overlapsOccupied(_ range: Range<String.Index>) -> Bool {
            occupied.contains { $0.lowerBound < range.upperBound && range.lowerBound < $0.upperBound }
        }
        // 挂着、但提示词里没有它的「图N」的参考图（2026-10-16 用户定：提示词里删素材，素材区的不删——删了字图还挂着）：
        // 在方括号里找到它的名字，前面补回它原来的「图N」（编号就是它在素材区的位置，不新挂、不重排）。先于新素材占位
        var restores: [(range: Range<String.Index>, token: String)] = []
        do {
            let present: Set<Int> = {
                guard let regex = try? NSRegularExpression(pattern: "图(\\d+)") else { return [] }
                let ns = prompt as NSString
                return Set(regex.matches(in: prompt, range: NSRange(location: 0, length: ns.length))
                    .compactMap { Int(ns.substring(with: $0.range(at: 1))) })
            }()
            let missing: [(name: String, token: String)] = shot.imageRefs.enumerated().compactMap { k, ref in
                guard !present.contains(k + 1), let item = libraryItem(ref.libraryItemID) else { return nil }
                let name = slotName(AssetVersionName.parse(item.matchKeyword)?.base ?? item.matchKeyword)
                guard !name.isEmpty, name.rangeOfCharacter(from: .letters) != nil else { return nil }
                return (name, "图\(k + 1)")
            }.sorted { $0.name.count > $1.name.count }
            for entry in missing {
                search: for seg in segments {
                    var searchStart = seg.lowerBound
                    while let r = prompt.range(of: entry.name, options: .caseInsensitive, range: searchStart..<seg.upperBound) {
                        if !overlapsOccupied(r) {
                            restores.append((r, entry.token))
                            occupied.append(r)
                            break search
                        }
                        searchStart = r.upperBound
                    }
                }
            }
        }
        var matches: [Match] = []
        for candidate in candidates {
            // 只在这排方括号段内找：跳过已占用区间，取第一个空闲出现位置
            search: for seg in segments {
                var searchStart = seg.lowerBound
                while let r = prompt.range(of: candidate.name, options: .caseInsensitive, range: searchStart..<seg.upperBound) {
                    if !overlapsOccupied(r) {
                        matches.append(Match(item: candidate.item, range: r))
                        occupied.append(r)
                        break search
                    }
                    searchStart = r.upperBound
                }
            }
        }
        guard !matches.isEmpty || !restores.isEmpty else { return 0 }
        // 排序：场景图优先（图1 是场景），角色次之，道具最后；同类型按提示词出现位置
        func typePriority(_ item: LibraryItem) -> Int {
            let n = item.matchName
            if n.hasPrefix("场景-") { return 0 }
            if n.hasPrefix("角色-") { return 1 }
            if n.hasPrefix("道具-") { return 2 }
            return 3
        }
        matches.sort {
            let p0 = typePriority($0.item), p1 = typePriority($1.item)
            if p0 != p1 { return p0 < p1 }
            return $0.range.lowerBound < $1.range.lowerBound
        }

        // 按类型分组编号（图片→图N、视频→视频N、音频→音频N）。
        // 编号必须接续「已有素材数量」：新匹配的素材是 append 到末尾的，
        // 若从 0 重新编号会与已有素材撞号，导致提示词里的「图N是」指向错误的图。
        var imageCounter = shot.imageRefs.count
        var videoCounter = shot.videoRefs.count
        var audioCounter = shot.audioRefs.count
        var tokenByID: [UUID: String] = [:]
        for match in matches {
            switch match.item.kind {
            case .image: imageCounter += 1; tokenByID[match.item.id] = "图\(imageCounter)"
            case .video: videoCounter += 1; tokenByID[match.item.id] = "视频\(videoCounter)"
            case .audio: audioCounter += 1; tokenByID[match.item.id] = "音频\(audioCounter)"
            }
        }

        // 用 NSString 整数偏移按文本位置从后往前插入「token」（如「图1」）：Swift String.Index
        // 在插入后会失效，直接 insert 会落在多字节字符中间导致乱码；UTF-16 整数偏移稳定。
        // ⚠️ 2026-09-18 用户要求去掉原来拼在后面的「是」（"匹配素材时默认有个'是'"）——
        // 现在插入的就是纯「图1」，和 `@` 选择器保持一致。
        let ns = NSMutableString(string: prompt)
        // `matches` 当前按素材类型优先级排序（用于稳定素材编号）；不能直接 reversed，
        // 因为那不保证文本偏移从大到小，较早插入会移动后续位置，让标记错位到下文。
        let insertions = (matches.compactMap { match -> (offset: Int, token: String)? in
            guard let token = tokenByID[match.item.id] else { return nil }
            return (match.range.lowerBound.utf16Offset(in: prompt), token)
        } + restores.map { ($0.range.lowerBound.utf16Offset(in: prompt), $0.token) })
            .sorted { $0.offset > $1.offset }
        for insertion in insertions {
            // 名字前面留着一个「@」（在提示词框里打了 @ 没选就关掉，2026-10-26 用户实测）：补「图N」时把它换掉，不留「@图2周承山」
            if insertion.offset > 0, ["@", "＠"].contains(ns.substring(with: NSRange(location: insertion.offset - 1, length: 1))) {
                ns.replaceCharacters(in: NSRange(location: insertion.offset - 1, length: 1), with: insertion.token)
            } else {
                ns.insert(insertion.token, at: insertion.offset)
            }
        }
        let newPrompt = ns as String

        // 添加素材引用
        var imageRefs = shot.imageRefs
        var videoRefs = shot.videoRefs
        var audioRefs = shot.audioRefs
        for match in matches {
            switch match.item.kind {
            case .image: imageRefs.append(MaterialRef(libraryItemID: match.item.id, role: .referenceImage))
            case .video: videoRefs.append(MaterialRef(libraryItemID: match.item.id))
            case .audio: audioRefs.append(MaterialRef(libraryItemID: match.item.id))
            }
        }

        shots[idx].prompt = newPrompt
        shots[idx].imageRefs = imageRefs
        shots[idx].videoRefs = videoRefs
        shots[idx].audioRefs = audioRefs
        touchProject(shots[idx].projectKey)
        persistShots()
        return matches.count        // 只算新挂上的（补回「图N」的不算：调用方按它判断有没有挂上新图）
    }

    /// 提取提示词里所有「[...]」方括号段的 Range（用于把素材名匹配限定在这排引用段内）。
    /// 用 for-in 扫描开/闭括号，处理嵌套与逗号分隔的多名字段落。
    private func bracketSegments(in prompt: String) -> [Range<String.Index>] {
        var segments: [Range<String.Index>] = []
        var i = prompt.startIndex
        while i < prompt.endIndex {
            guard let open = prompt[i...].firstIndex(of: "["),
                  let nextClose = prompt[open...].firstIndex(of: "]") else { break }
            let afterOpen = prompt.index(after: open)
            if afterOpen < nextClose {
                segments.append(afterOpen..<nextClose)
            }
            i = prompt.index(after: nextClose)
        }
        return segments
    }

    /// 头行里已经挂着素材的名字所在的文字区间：方括号段里按「、，,；;」切成一项一项，开头是「图N / 视频N / 音频N」的那一项（整项，含名字）
    private func attachedNameRanges(in prompt: String, segments: [Range<String.Index>]) -> [Range<String.Index>] {
        let separators: Set<Character> = ["、", "，", ",", "；", ";", "\n"]
        func startsWithToken(_ element: Substring) -> Bool {
            let trimmed = element.drop(while: { $0 == " " || $0 == "\t" || $0 == "　" })
            for prefix in ["图", "视频", "音频"] where trimmed.hasPrefix(prefix) {
                let rest = trimmed.dropFirst(prefix.count).drop(while: { $0 == " " })
                if let first = rest.first, first.isASCII, first.isNumber { return true }
            }
            return false
        }
        var ranges: [Range<String.Index>] = []
        for segment in segments {
            var start = segment.lowerBound
            var index = segment.lowerBound
            while index <= segment.upperBound {
                let atEnd = index == segment.upperBound
                if atEnd || separators.contains(prompt[index]) {
                    if start < index, startsWithToken(prompt[start..<index]) { ranges.append(start..<index) }
                    if atEnd { break }
                    start = prompt.index(after: index)
                }
                index = prompt.index(after: index)
            }
        }
        return ranges
    }

    /// 识别提示词里的时长：取所有 [X-Y 秒] 时间段的最大结束秒数
    private func detectDuration(from prompt: String) -> Int? {
        let pattern = #"\[(\d+(?:\.\d+)?)-(\d+(?:\.\d+)?)\s*秒\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(prompt.startIndex..., in: prompt)
        let matches = regex.matches(in: prompt, range: nsRange)
        var maxEnd = 0.0
        for match in matches {
            if let endRange = Range(match.range(at: 2), in: prompt),
               let end = Double(prompt[endRange]) {
                maxEnd = max(maxEnd, end)
            }
        }
        guard maxEnd > 0 else { return nil }
        let duration = Int(maxEnd.rounded())
        return (2...30).contains(duration) ? duration : nil
    }

    /// 素材上传进度（0~1，**非持久化**）——素材库列表里显示「上传中 42%」用。
    ///
    /// ⚠️ 只在**整数百分比变化**时写：上传回调很密（每几十 KB 一次），每 tick 都写会让素材库整列重算。
    /// 上传结束（成功/失败）时清掉对应 key。
    var libraryUploadProgress: [UUID: Double] = [:]

    /// **这一批上传的数量**（2026-10-09 用户：「上传时看不到数量」）：批量入库是一两百张同时在传，
    /// 每张只有自己的百分比，没有「一共多少、传完几个、失败几个」。一批 = 从没有上传在跑，到全部传完（成功 / 失败都算传完）；
    /// 一批传完之后再有新的上传就从 0 重新数。**非持久化**。
    struct LibraryUploadBatch: Equatable {
        var total = 0
        var finished = 0
        var failed = 0
        var isRunning: Bool { finished < total }
        var succeeded: Int { finished - failed }
        /// 素材库底部显示的那行：「上传中 45/167」，有失败再加「 · 失败 3」
        var label: String { "上传中 \(finished)/\(total)" + (failed > 0 ? " · 失败 \(failed)" : "") }
        /// 传完以后留在素材库底部的说明。一两张成功的不值得提；有失败的、或者一批不少的才留
        var summary: String? {
            guard !isRunning, total > 0, failed > 0 || total >= 5 else { return nil }
            return failed > 0
                ? "上传完成：成功 \(succeeded) 个 · 失败 \(failed) 个（点「检查链接」，再点「重传失效」可以重传）"
                : "上传完成：成功 \(succeeded) 个"
        }
        /// 开始传一张：上一批已经传完就从 0 开始数新的一批
        mutating func begin() {
            if !isRunning { self = LibraryUploadBatch() }
            total += 1
        }
        mutating func finish(failed didFail: Bool) {
            finished += 1
            if didFail { failed += 1 }
        }
    }
    var libraryUploadBatch = LibraryUploadBatch()

    /// 预上传素材库条目
    func uploadLibraryItem(_ id: UUID) {
        guard let idx = library.firstIndex(where: { $0.id == id }),
              let path = library[idx].localPath else { return }
        library[idx].uploadState = .uploading
        libraryUploadBatch.begin()
        let item = ReferenceDraftItem.local(url: URL(fileURLWithPath: path))
        let uploadService = self.uploadService
        Task {
            do {
                let remote = try await uploadService.upload(item) { fraction in
                    // 回调在 URLSession 的后台队列 → 切回主线程再写状态
                    Task { @MainActor in
                        let percent = (fraction * 100).rounded(.down) / 100   // 整数百分比
                        guard percent > 0, percent < 1 else { return }
                        if self.libraryUploadProgress[id] != percent {
                            self.libraryUploadProgress[id] = percent
                        }
                    }
                }
                self.libraryUploadProgress[id] = nil
                self.library[idx].remoteURL = remote.url
                self.library[idx].uploadState = .uploaded
                self.libraryLinkStatus[id] = nil      // 传完了：之前检查时记的「失效」（那时还没传完）作废
                if let d = remote.duration { self.library[idx].duration = d }
                self.libraryUploadBatch.finish(failed: false)
            } catch {
                self.libraryUploadProgress[id] = nil
                AppLog.write("upload", "素材上传失败（\(self.library[idx].fileName ?? "?")）：\(error.localizedDescription)")
                self.library[idx].uploadState = .failed
                self.libraryLinkStatus[id] = nil
                self.libraryUploadBatch.finish(failed: true)
            }
            // 这一批全部传完：留一句结果在素材库底部（有失败的要让人看见）
            if let summary = self.libraryUploadBatch.summary, !self.checkingLibraryLinks { self.libraryLinkCheckNote = summary }
            self.persistLibrary()
        }
    }

    // MARK: - 提交分镜

    /// 下载文件名「X-分镜-Y」（X=项目内分镜序号 1 起，Y=该分镜即将提交的版本号）；阿拉伯数字开头便于文件排序
    private func shotFileName(shotID: UUID) -> String {
        guard let shot = shots.first(where: { $0.id == shotID }) else { return "" }
        // 版本号 = 这个分镜**已用过的最大版本 + 1**（从旧任务的文件名里数）。
        // ⚠️ 不能用 `taskIDs.count + 1`：删过任务/重下过之后 count 和已用版本会错位 → 撞名，
        // 出现两个"1-1-9"（用户 2026-09-18 实测）；撞名现在不会丢视频了——下载遇同名是加 `-2` 后缀、
        // 不覆盖旧的（见 `DownloadService.uniqueDestination`），只是文件名对不上
        let used = shot.taskIDs.compactMap { id -> Int? in
            guard let name = store.task(id: id)?.fileName else { return nil }
            return name.split(separator: "-").last.flatMap { Int($0) }
        }
        let version = (used.max() ?? shot.taskIDs.count) + 1
        // 「A-B-版本」：A = 段号（分镜号）、B = 段内序号（插入分镜靠它不撞名）、版本号。
        // 例：分镜一第 1 版 = `1-1-1`；在分镜一后面插入的新分镜第 1 版 = `1-2-1`。
        // ⚠️ **别改回"位置派生"**（原来算的是 `projectShots.firstIndex + 1`）：删掉一个分镜，
        // 后面的全体前移一位 → 新文件名撞上已存在的旧文件，而下载遇同名是"删掉旧的再写"
        // → **静默丢视频**（用户 2026-09-11 提出这个风险、2026-09-13 修）。
        return "\(numbering(of: shot).filePrefix)-\(version)"
    }

    /// 通过 id 查找分镜的 Binding（比下标更稳定，避免中间插入后下标错乱）。
    /// 2026-09-27 从 GenerateView 提到这里：右栏搬到 RootView 之后，**面板和卡片页都要用它**。
    func shotBinding(_ id: UUID) -> Binding<ShotDraft> {
        Binding(
            get: {
                if let found = self.shots.first(where: { $0.id == id }) { return found }
                AppLog.write("shotBinding", "get 找不到 id=\(id)")
                return ShotDraft(projectKey: "")
            },
            set: { newValue in
                if let idx = self.shots.firstIndex(where: { $0.id == id }) {
                    var updated = newValue
                    // 参数被改过（模型/分辨率/比例/时长）→ 标记脏：卡片参数显示为蓝色（2026-09-26）
                    let old = self.shots[idx]
                    if old.model != updated.model
                        || old.resolution != updated.resolution
                        || old.aspectRatio != updated.aspectRatio
                        || old.duration != updated.duration {
                        updated.paramsDirty = true
                    }
                    // 整体赋值确保 @Observable 触发视图刷新
                    var newShots = self.shots
                    newShots[idx] = updated
                    self.shots = newShots
                } else {
                    AppLog.write("shotBinding", "set 找不到 id=\(id)")
                }
            }
        )
    }

    /// **正在提交中的分镜**（点「提交生成」→ 上游返回任务 ID 之间的窗口）。
    ///
    /// 为什么需要它：`submitShot` 是"先建占位任务（id = `pending-…`）、等上游返回真任务 ID
    /// 才写 `shot.taskID`"，而右栏底部按钮的置灰判据读的是 `shot.taskID`
    ///（`ShotDetailCard.isSubmitting`）——这段窗口里按钮看不到任何任务，会一直亮着、还能再点。
    /// 瞬态，不落盘；`submitShot` 进/出各维护一次（失败也移除，让用户能重试）。
    /// P2 起占位任务在排队期间也算「提交中」（排队记录存在 jobs.json，重启后接着排）。
    var submittingShotIDs: Set<UUID> = []

    /// 提交分镜：立即创建「排队中」占位任务进列表，后台提交；成功替换占位，失败标记失败
    func submitShot(_ shotID: UUID) {
        guard shots.contains(where: { $0.id == shotID }) else { return }
        // 防连点：提交窗口内重复调用直接吞掉（按钮禁用要等一次重绘，双击会抢在它前面）
        guard !submittingShotIDs.contains(shotID) else { return }
        // 每次提交都是新的一版，之前失败的版本照样留着（2026-10-16 用户：重新提交后失败的版本消失了）。
        // 原来这里会先删掉「还没拿到任务号就失败」的记录，删完版本号还会被下一次提交重新用掉
        guard let idx = shots.firstIndex(where: { $0.id == shotID }) else { return }
        let shot = shots[idx]
        // 参数脏标记：提交后这套参数已经进入任务 → 卡片参数转灰（之后再改会重新变蓝，2026-09-26）
        shots[idx].paramsDirty = false
        shots[idx].pendingIsCurrent = false     // 「待生成」这就生成了，成为正式的新版本（收起来的那份不动）

        // 按模型名解析渠道（新协议不再有服务商概念）
        guard let (channel, _) = channel(forModel: shot.model) else {
            addFailedTask(shot: shot, error: "未配置模型「\(shot.model.isEmpty ? "（未选择）" : shot.model)」，请到设置里添加渠道与模型")
            return
        }
        guard !channel.apiKey.isEmpty else {
            addFailedTask(shot: shot, error: "渠道「\(channel.name)」未填写 API Key，请到设置里保存")
            return
        }

        // 先创建占位任务，立即进列表
        let placeholderID = "pending-\(UUID().uuidString)"
        store.add(makeLocalTask(shot: shot, providerName: channel.name, id: placeholderID, phase: .queued))
        taskFilter = .all
        touchProject(shot.projectKey)
        // 新提交写渠道名
        shots[idx].providerID = channel.name
        persistShots()

        // 标记「提交中」→ 右栏底部按钮立刻置灰、并挡住重复点击。
        // 必须先于异步任务打上：`shot.taskID` 要等上游返回真任务 ID 才写（见 `submittingShotIDs` 注释）。
        submittingShotIDs.insert(shotID)

        // 进任务中心并立刻提交（2026-10-06 P2；渠道不限并发，不排队等空位）
        pendingVideoSnapshots[placeholderID] = shot
        jobCenter.enqueueVideo(placeholderID: placeholderID, shotID: shotID, projectKey: shot.projectKey,
                               channel: channel.name)
    }

    /// 点提交那一刻的分镜快照（提示词和参数）。瞬态：重启后接着提交时按分镜当前内容。
    @ObservationIgnored private var pendingVideoSnapshots: [String: ShotDraft] = [:]

    /// 真正提交（网络类错误重试 3 次；参考素材的直链在组装阶段补齐）
    private func performVideoSubmit(placeholderID: String, shotID: UUID) {
        guard let shot = pendingVideoSnapshots.removeValue(forKey: placeholderID)
                ?? shots.first(where: { $0.id == shotID }) else {
            store.update(id: placeholderID, phase: .failed, error: "分镜已删除")
            submittingShotIDs.remove(shotID)
            jobCenter.videoSubmitFinished(placeholderID: placeholderID, error: "分镜已删除")
            return
        }
        guard let (channel, _) = channel(forModel: shot.model), !channel.apiKey.isEmpty else {
            let message = "未配置模型「\(shot.model)」或渠道没有 API Key，请到设置里检查"
            store.update(id: placeholderID, phase: .failed, error: message)
            recordSubmitFailure(shotID: shotID, taskID: placeholderID)
            submittingShotIDs.remove(shotID)
            jobCenter.videoSubmitFinished(placeholderID: placeholderID, error: message)
            return
        }
        let client = APIClient(channel: channel)
        // New API：只有参考图需要公网直链；音视频素材两种规范都原样带上。
        // OpenAI 规范保持原逻辑（本地文件 multipart，远程直链原样带上）。
        let resolveImagesViaLink = channel.apiFormat != .openAI
        let resolveMediaViaLink = false
        Task {
            // 提交窗口结束（成功/失败都走）→ 撤掉「提交中」标记：
            // 失败时让用户能再点（成功时 `shot.taskID` 已写回，按钮由任务阶段继续置灰）
            defer { self.submittingShotIDs.remove(shotID) }
            let request: VideoGenerationRequest
            do {
                request = try await self.makeRequest(
                    for: shot,
                    resolveImagesViaLink: resolveImagesViaLink,
                    resolveMediaViaLink: resolveMediaViaLink
                )
            } catch {
                AppLog.write("submit", "组装请求失败：\(error.localizedDescription)")
                self.store.update(id: placeholderID, phase: .failed, error: error.localizedDescription)
                self.recordSubmitFailure(shotID: shotID, taskID: placeholderID)
                self.jobCenter.videoSubmitFinished(placeholderID: placeholderID, error: error.localizedDescription)
                return
            }
            var taskID: String?
            var lastError: Error = APIError.noTaskID
            for attempt in 0..<3 {
                do {
                    taskID = try await client.submit(request)
                    break
                } catch {
                    lastError = error
                    AppLog.write("submit-retry", "第\(attempt + 1)次失败: \(error.localizedDescription)")
                    if case APIError.config = error { break }      // 配置 / 前置条件不满足（比如模型收不了音频）：重试也一样
                    if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
                }
            }
            guard let taskID else {
                self.store.update(id: placeholderID, phase: .failed, error: lastError.localizedDescription)
                self.recordSubmitFailure(shotID: shotID, taskID: placeholderID)
                self.jobCenter.videoSubmitFinished(placeholderID: placeholderID, error: lastError.localizedDescription)
                return
            }
            self.store.remove(id: placeholderID)
            let task = self.makeLocalTask(shot: shot, providerName: channel.name, id: taskID, phase: .queued)
            self.store.add(task)
            self.poller.resumePolling(task)
            if let i = self.shots.firstIndex(where: { $0.id == shotID }) {
                self.shots[i].taskID = taskID
                if !self.shots[i].taskIDs.contains(taskID) {
                    self.shots[i].taskIDs.append(taskID)
                }
                self.persistShots()
            }
            self.jobCenter.videoSubmitFinished(placeholderID: placeholderID, error: nil)
        }
    }

    private func makeRequest(for shot: ShotDraft,
                             resolveImagesViaLink: Bool,
                             resolveMediaViaLink: Bool) async throws -> VideoGenerationRequest {
        func resolveOpenAIInput(_ ref: MaterialRef) -> (input: VideoFileInput, role: ReferenceImageRole?)? {
            guard let item = libraryItem(ref.libraryItemID) else { return nil }
            if let path = item.localPath, FileManager.default.fileExists(atPath: path) {
                return (VideoFileInput(localPath: path, remoteURL: item.remoteURL, fileName: item.fileName ?? ""), ref.role)
            }
            if let remote = item.remoteURL {
                return (VideoFileInput(localPath: nil, remoteURL: remote, fileName: item.fileName ?? ""), ref.role)
            }
            return nil
        }

        var imageInputs: [(input: VideoFileInput, role: ReferenceImageRole?)] = []
        for ref in shot.imageRefs {
            if resolveImagesViaLink {
                imageInputs.append((try await resolvedInput(for: ref, label: imageLabel(for: ref)), ref.role))
            } else if let resolved = resolveOpenAIInput(ref) {
                imageInputs.append(resolved)
            }
        }
        let classified = Self.classifyImageInputs(imageInputs)

        var referenceVideos: [String] = []
        for ref in shot.videoRefs {
            if resolveMediaViaLink {
                referenceVideos.append(try await resolvedInput(for: ref, label: "参考视频").remoteURL ?? "")
            } else {
                referenceVideos.append(libraryItem(ref.libraryItemID)?.remoteURL ?? "")
            }
        }
        var referenceAudios: [String] = []
        for ref in shot.audioRefs {
            if resolveMediaViaLink {
                referenceAudios.append(try await resolvedInput(for: ref, label: "参考音频").remoteURL ?? "")
            } else {
                referenceAudios.append(libraryItem(ref.libraryItemID)?.remoteURL ?? "")
            }
        }

        return VideoGenerationRequest(
            model: shot.model,
            prompt: shot.prompt.isEmpty ? nil : shot.prompt,
            duration: shot.duration,
            aspectRatio: shot.aspectRatio,
            size: shot.aspectRatio.videoSize,
            resolutionName: shot.resolution.apiValue,
            generateAudio: shot.generateAudio,
            watermark: shot.watermark,
            mode: classified.mode,
            firstFrame: classified.firstFrame,
            lastFrame: classified.lastFrame,
            referenceImages: classified.referenceImages,
            referenceVideos: referenceVideos,
            referenceAudios: referenceAudios
        )
    }

    /// 图片素材按角色分类成 `frames` / `reference` 两种提交形态（OpenAI 与 New API 共用）。
    private static func classifyImageInputs(
        _ inputs: [(input: VideoFileInput, role: ReferenceImageRole?)]
    ) -> (mode: String?, firstFrame: VideoFileInput?, lastFrame: VideoFileInput?, referenceImages: [VideoFileInput]) {
        let frameInputs = inputs.filter { $0.role == .firstFrame || $0.role == .lastFrame }
        if !frameInputs.isEmpty {
            return ("frames",
                    frameInputs.first(where: { $0.role == .firstFrame })?.input,
                    frameInputs.first(where: { $0.role == .lastFrame })?.input,
                    [])
        }
        if !inputs.isEmpty {
            return ("reference", nil, nil, inputs.map(\.input))
        }
        return (nil, nil, nil, [])
    }

    /// 把单个参考素材保证成**服务端能拉取的公网直链**，并回写素材库。
    ///
    /// 顺序：
    /// ① 素材库里已有免费图床直链（catbox / litterbox）→ 直接复用；
    /// ② 已有 OSS 直链 → HEAD 验证能匿名读就复用（2026-09-19 之前上传的对象是私有的，往下走重传）；
    /// ③ 本地文件 → 上传（catbox 链路）；
    /// ④ 仅远程直链（aitohumanize 这类可能过期/防盗链）→ 先下载再上传。
    ///
    /// 2026-09-19（用户要求）：**提交不再转存 OSS**。实测上游能直接拉 catbox
    /// （480p/5s 任务全程无下载错误、正常出片），转存 OSS 纯属多余（还撞上过"对象私有 → 上游 403"）。
    /// 素材取不到 / 上传失败 → 抛清晰错误（不让任务静默停在「排队中」）。
    private func resolvedInput(for ref: MaterialRef, label: String) async throws -> VideoFileInput {
        guard let item = libraryItem(ref.libraryItemID) else {
            throw APIError.config("\(label)已不在素材库中，请重新添加")
        }

        // ① 素材库里已有的免费图床直链 → 直接用（我们自己传的，最可靠）
        // ⚠️ **只在「素材上传位置 = 免费图床」时复用**（2026-09-19）：切到 OSS 后，旧的 catbox
        //    链接不再直接用（否则拉不到 catbox 的上游照样被拒）——
        //    用「检查链接 + 一键重传」重传一遍，素材就会传到 OSS 并回写。
        if MaterialUploadHostStore.load() == .freeHost,
           let remote = item.remoteURL, Self.isFreeHostDirectLink(remote) {
            return VideoFileInput(localPath: item.localPath, remoteURL: remote, fileName: item.fileName ?? "")
        }

        // ② 历史 OSS 直链：能匿名读就复用，私有（旧对象）就往下走重传
        if let remote = item.remoteURL, OSSUploadService.isOSSDirectLink(remote, config: OSSConfigStore.load()) {
            if await OSSUploader.isPubliclyReadable(remote) {
                return VideoFileInput(localPath: item.localPath, remoteURL: remote, fileName: item.fileName ?? "")
            }
            AppLog.write("upload", "\(label)已有 OSS 直链但匿名不可读（旧对象私有）→ 重新上传")
        }

        // ③ 取数据：本地文件优先，其次远程下载
        let data: Data
        let fileExtension: String
        if let path = item.localPath, FileManager.default.fileExists(atPath: path),
           let localData = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            data = localData
            fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        } else if let remote = item.remoteURL, let url = URL(string: remote) {
            do {
                let (remoteData, _) = try await URLSession.shared.data(from: url)
                data = remoteData
                fileExtension = url.pathExtension.lowercased()
            } catch {
                throw APIError.transport("\(label)下载失败，无法上传：\(remote)")
            }
        } else {
            throw APIError.config("\(label)取不到文件：素材库里既没有本地文件，也没有可下载的直链")
        }

        // ④ 上传（免费图床链路）并回写素材库（下次免传）
        let resolved: String
        do {
            if let path = item.localPath, FileManager.default.fileExists(atPath: path) {
                resolved = try await uploadService.upload(.local(url: URL(fileURLWithPath: path))).url
            } else {
                // 从远程下载来的数据：先落临时文件，再走同一条上传链路
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(fileExtension.isEmpty ? "bin" : fileExtension)")
                try data.write(to: tmp)
                defer { try? FileManager.default.removeItem(at: tmp) }
                resolved = try await uploadService.upload(.local(url: tmp)).url
            }
        } catch {
            throw APIError.transport("\(label)上传失败：\(error.localizedDescription)")
        }

        if let libraryIndex = library.firstIndex(where: { $0.id == ref.libraryItemID }) {
            library[libraryIndex].remoteURL = resolved
            library[libraryIndex].uploadState = .uploaded
            persistLibrary()
        }
        AppLog.write("upload", "\(label) → \(resolved)")
        return VideoFileInput(localPath: item.localPath, remoteURL: resolved, fileName: item.fileName ?? "")
    }

    /// 素材库直链是不是我们自己传的免费图床（catbox 永久 / litterbox 72 小时）。
    /// 这类链接上游能直接拉，提交时不用再转存（2026-09-19 实测上游能拉 catbox）。
    private static func isFreeHostDirectLink(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "files.catbox.moe" || host == "litter.catbox.moe"
    }

    /// 图片素材的错误提示名（按角色区分首帧/尾帧/参考图，带素材显示名）
    private func imageLabel(for ref: MaterialRef) -> String {
        let kind: String
        switch ref.role {
        case .firstFrame: kind = "首帧图"
        case .lastFrame: kind = "尾帧图"
        default: kind = "参考图"
        }
        if let name = libraryItem(ref.libraryItemID)?.matchName, !name.isEmpty {
            return "\(kind)「\(name)」"
        }
        return kind
    }

    /// 组装本地任务（提交占位与正式任务共用）
    private func makeLocalTask(shot: ShotDraft, providerName: String, id: String, phase: TaskPhase) -> LocalTask {
        let imageURLs = shot.imageRefs.compactMap { libraryItem($0.libraryItemID)?.remoteURL }
        let videoURLs = shot.videoRefs.compactMap { libraryItem($0.libraryItemID)?.remoteURL }
        let audioURLs = shot.audioRefs.compactMap { libraryItem($0.libraryItemID)?.remoteURL }
        return LocalTask(
            id: id,
            model: shot.model, providerID: providerName, prompt: shot.prompt, duration: shot.duration,
            aspectRatio: shot.aspectRatio, resolution: shot.resolution, generateAudio: shot.generateAudio,
            phase: phase, createdAt: Date(), updatedAt: Date(), costFen: shot.costFen,
            referenceImageURLs: imageURLs.isEmpty ? nil : imageURLs,
            referenceVideoURLs: videoURLs.isEmpty ? nil : videoURLs,
            referenceAudioURLs: audioURLs.isEmpty ? nil : audioURLs,
            groupID: shot.projectKey,
            fileName: shotFileName(shotID: shot.id)
        )
    }

    /// 创建一条失败任务进列表（同步校验失败用）
    /// 提交失败（还没拿到平台的任务号）：把这条失败的任务记到分镜上，卡片才会显示「失败」。
    /// 原来这样的失败只在任务抽屉里有一条，分镜自己不知道——卡片一直显示「待生成」，工作台也一直是「待生成视频」（2026-10-10 用户实测）。
    /// - 这张卡还没有可看的版本（没成功过 / 当前版本也是失败的）：它就是当前版本，卡片显示失败；
    /// - 已经有完成的视频：只记进历史，不盖掉那个视频。
    /// 这条记录是历史版本里的一版（占一个版本号），再次提交也不删：用了什么提示词、为什么失败都能回头看（2026-10-16 用户定）。
    func recordSubmitFailure(shotID: UUID, taskID: String) {
        guard let i = shots.firstIndex(where: { $0.id == shotID }) else { return }
        if !shots[i].taskIDs.contains(taskID) { shots[i].taskIDs.append(taskID) }
        let current = shots[i].taskID.flatMap { store.task(id: $0) }
        if current == nil || current?.phase == .failed { shots[i].taskID = taskID }
        persistShots()
    }

    private func addFailedTask(shot: ShotDraft, error: String) {
        var task = LocalTask(
            id: "failed-\(UUID().uuidString)",
            model: shot.model, providerID: shot.providerID, prompt: shot.prompt, duration: shot.duration,
            aspectRatio: shot.aspectRatio, resolution: shot.resolution, generateAudio: shot.generateAudio,
            phase: .failed, createdAt: Date(), updatedAt: Date(), costFen: shot.costFen,
            referenceImageURLs: nil, referenceVideoURLs: nil, referenceAudioURLs: nil,
            groupID: shot.projectKey,
            // 也占一个版本号（历史版本里显示「版本 N · 失败」；没文件名的话下一次提交会重复用这个号）
            fileName: shotFileName(shotID: shot.id)
        )
        task.errorMessage = error
        store.add(task)
        taskFilter = .all
        recordSubmitFailure(shotID: shot.id, taskID: task.id)
    }

    // MARK: - 批量操作

    /// 批量自动匹配：传入选中 ID 时只处理当前项目中选中的分镜；不传时处理整个项目。
    struct BatchMatchReport {
        let shotCount: Int
        let totalMatched: Int
    }

    func batchAutoMatch(shotIDs: Set<UUID>? = nil) -> BatchMatchReport {
        let shots = currentShots.filter { shotIDs?.contains($0.id) ?? true }
        var totalMatched = 0
        for shot in shots {
            totalMatched += autoMatchMaterials(shot.id)
        }
        return BatchMatchReport(shotCount: shots.count, totalMatched: totalMatched)
    }

    /// 批量提交计划：预检每个分镜，汇总可提交数与跳过原因、预计费用
    struct BatchSubmitPlan {
        struct SkippedShot {
            let title: String
            let reasons: [String]
        }
        let readyCount: Int
        let skipped: [SkippedShot]
        let totalCostFen: Int
    }

    func batchSubmitPlan() -> BatchSubmitPlan {
        let shots = currentShots
        var readyCount = 0
        var skipped: [BatchSubmitPlan.SkippedShot] = []
        var totalCostFen = 0
        for shot in shots {
            let issues = ShotValidator.validate(shot)
            if issues.isEmpty {
                readyCount += 1
                totalCostFen += shot.costFen
            } else {
                skipped.append(.init(title: numbering(of: shot).title, reasons: issues))
            }
        }
        return BatchSubmitPlan(readyCount: readyCount, skipped: skipped, totalCostFen: totalCostFen)
    }

    /// 批量提交：对给定分镜（默认当前项目全部）中可提交的逐个发起提交。
    func batchSubmitExecute(shots: [ShotDraft]? = nil) {
        let ready = (shots ?? currentShots).filter { ShotValidator.validate($0).isEmpty }
        for shot in ready { submitShot(shot.id) }
    }

    /// 导入分镜：按顺序为每个分镜新建卡片并填入提示词，返回导入数量
    @discardableResult
    func importShots(_ prompts: [String]) -> Int {
        guard !prompts.isEmpty else { return 0 }
        var firstNew: UUID?
        for prompt in prompts {
            addShot()
            if let idx = shots.indices.last {
                shots[idx].prompt = prompt
                if firstNew == nil { firstNew = shots[idx].id }
            }
        }
        persistShots()
        // 🆕 2026-10-03（用户定）：导入后**跳到新卡片**——同工具条「＋」新增的逻辑
        //（右栏定位 + 缩略图页滚动到它；用户实测"批量解析后没跳到新增的卡片"）
        if let id = firstNew {
            inspectorKind = .video
            timelineShotID = id
            if videoViewStyle == .thumbnails {
                // 🆕 2026-10-03：**延后一拍再请求滚动**——批量弹窗还开着时立刻请求，
                // 会被"关弹窗后的重排/滚动恢复"覆盖（用户实测"跳不过去"）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    MainActor.assumeIsolated { [weak self] in self?.scrollToShotID = id }
                }
            }
        }
        return prompts.count
    }

    /// 批量提交那一步的「应用」：先记原值再写（见 `batchParamDraftOriginals`）
    func draftBatchParameters(_ config: BatchParamConfig, ids: [UUID]) {
        let targets = Set(ids)
        batchParamDraftOriginals = (shots.filter { targets.contains($0.id) }, [])
        batchSetParameters(config, ids: ids)
    }

    func draftBatchImageParams(ids: [UUID], model: String?, aspect: ImageAspect, quality: ImageQuality) {
        let targets = Set(ids)
        batchParamDraftOriginals = ([], imageItems.filter { targets.contains($0.id) })
        batchSetImageParams(ids: ids, model: model, aspect: aspect, quality: quality)
    }

    /// 草稿算数：参数留在卡片上
    func keepBatchParamDraft() { batchParamDraftOriginals = nil }

    /// 草稿作废：只把参数几项（模型 / 分辨率 / 画幅 / 时长 / 参数改动标记）改回原值，卡片别的内容不动
    func revertBatchParamDraft() {
        guard let originals = batchParamDraftOriginals else { return }
        batchParamDraftOriginals = nil
        if !originals.shots.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: originals.shots.map { ($0.id, $0) })
            for i in shots.indices {
                guard let old = byID[shots[i].id] else { continue }
                shots[i].model = old.model
                shots[i].resolution = old.resolution
                shots[i].aspectRatio = old.aspectRatio
                shots[i].duration = old.duration
                shots[i].paramsDirty = old.paramsDirty
            }
            persistShots()
        }
        if !originals.images.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: originals.images.map { ($0.id, $0) })
            for i in imageItems.indices {
                guard let old = byID[imageItems[i].id] else { continue }
                imageItems[i].model = old.model
                imageItems[i].aspectRatio = old.aspectRatio
                imageItems[i].quality = old.quality
                imageItems[i].paramsDirty = old.paramsDirty
            }
            persistImageItems()
        }
    }

    /// 批量设置参数：**只应用到 `ids` 指定的分镜**（2026-09-26 用户定："只对选中的生效"）。
    /// `config.model` 为空 = 不改模型。
    func batchSetParameters(_ config: BatchParamConfig, ids: [UUID]) {
        let targets = Set(ids)
        for i in shots.indices where targets.contains(shots[i].id) {
            if !config.model.isEmpty { shots[i].model = config.model }
            shots[i].resolution = config.resolution
            shots[i].aspectRatio = config.aspectRatio
            shots[i].duration = config.duration
            shots[i].paramsDirty = true     // 改过参数 → 卡片参数显示为蓝色（2026-09-26）
        }
        persistShots()
    }

    /// 上传服务：**catbox 主站（永久）优先，litterbox（72h 临时）兜底**（2026-09-19 调整）。
    ///
    /// 为什么从"只用 litterbox"改回来：litterbox 的 API 被 Cloudflare 403 拦了
    ///（本机实测多次全 403）；catbox 主站带已存的 userhash 上传正常（2MB / 8MB 实测一致）。
    /// 没配 userhash 时只能走 litterbox。
    ///
    /// ⚠️ **不再自动切 OSS**（2026-09-18 用户要求："失败了不要自动切 OSS，直接显示失败就行"）：
    /// 两条免费链路都失败就标失败（素材库里能看到"上传失败"），想用 OSS 由用户自己决定。
    /// 测试用：指定了就用它，不走真实上传
    @ObservationIgnored var uploadServiceOverride: (any UploadService)?

    var uploadService: any UploadService {
        if let uploadServiceOverride { return uploadServiceOverride }
        // 素材上传位置（设置页「素材上传位置」开关，2026-09-19 用户要求）：
        // 开 OSS → 素材（含补传）都传到阿里云 OSS（对象 public-read，上游拉取不会 403）。
        if MaterialUploadHostStore.load() == .oss, let config = OSSConfigStore.load() {
            return OSSUploadService(config: config)
        }
        if CatboxConfigStore.load() != nil {
            return FallbackUploadService(primary: CatboxMainUploadService(),
                                         backup: LitterboxUploadService())
        }
        return LitterboxUploadService()
    }

    // MARK: - 持久化

    private let shotsEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let shotsDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var persistWork: Task<Void, Never>?

    func persistShots() {
        scheduleProjectSave()
    }

    private func writeShots() {
        saveProjectsNow()
    }

    private var libraryPersistWork: Task<Void, Never>?

    /// 防抖异步写盘（与 shots 一致）：避免拖入素材时主线程同步 IO 卡顿拖拽动画
    func persistLibrary() {
        scheduleProjectSave()
    }

    private func writeLibrary() {
        saveProjectsNow()
    }

    // MARK: - 2.0 项目文件（旧数组 → project.json）

    /// 防抖存盘：分镜 / 生图 / 素材库 / 剧本 / 元数据任何一处改动都走这里
    func scheduleProjectSave() {
        dataRevision &+= 1
        projectSaveWork?.cancel()
        projectSaveWork = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.saveProjectsInBackground()
        }
    }

    /// 当前内存数据换算出的某个项目的文档（制作页读它；不写盘）。设定 / 视频 ID 沿用上次存盘的，来回不漂。
    func workbenchDocument(for key: String) -> ProjectDocument? {
        guard !key.isEmpty, let projectStore else { return nil }
        let projectShots = shots.filter { $0.projectKey == key }
        let taskIDs = Set(projectShots.flatMap { $0.taskIDs + [$0.taskID].compactMap { $0 } })
        let snapshot = LegacySnapshot(
            metas: projectMetas[key].map { [key: $0] } ?? [:],
            shots: projectShots,
            imageItems: imageItems.filter { $0.projectKey == key },
            library: library.filter { $0.projectKey == key },
            tasks: store.tasks.filter { taskIDs.contains($0.id) },
            pipelines: pipelineArchives[key].map { [key: $0] } ?? [:])
        let options = MigrationOptions.live(root: projectStore.root,
                                            previous: projectStore.saved[key].map { [key: $0] } ?? [:])
        let plan = LegacyMigrationPlanner.plan(snapshot, options: options) { FileManager.default.fileExists(atPath: $0) }
        return plan.projects.first { $0.id == key }
    }

    /// 项目里确认过的名字规则（别名 → 设定名、忽略名单）。新分出来 / 新提取出来的素材名按它自动处理。
    func nameRules(for key: String) -> NameRules {
        NameRules(doc: projectStore?.saved[key])
    }

    /// 应用一批名字确认（制作页的「确认名字」）：
    /// 别名 / 忽略名单记进项目文件；所有集的段落里的名字改过去（对应 / 忽略）或加素材（新建）。
    func applyNameDecisions(_ decisions: [NameDecision], projectKey key: String) throws {
        guard !decisions.isEmpty else { return }
        guard var archive = pipelineArchive(for: key) else { throw WorkbenchActions.Failure("这个项目没有剧本") }
        // 先记别名 / 忽略名单：页面随后刷新时要用它们解析名字
        if let projectStore, projectStore.unreadable[key] == nil, var doc = workbenchDocument(for: key),
           NameConfirmation.record(decisions, in: &doc) {
            projectStore.queue.sync { projectStore.write(doc) }        // 和后台存盘排在一条队列上
        }
        var changed = false
        for e in archive.episodes.indices {
            var work = SimplePipeline.work(in: archive, index: e)
            if NameConfirmation.apply(decisions, to: &work) {
                SimplePipeline.save(work, to: &archive)
                changed = true
            }
        }
        if changed { savePipelineArchive(archive, for: key) } else { dataRevision &+= 1 }
    }

    // MARK: 菜单快捷键（2026-10-10）：⌘N 新建、⌘F 搜索

    /// ⌘N 现在能不能用：主页 = 新建项目；项目里的生视频 / 生图页 = 新增分镜 / 新增图片；其他页（剧本页）没有「新建」
    var canCreateNewItem: Bool {
        guard activeModal == nil else { return false }
        return !isInWorkspace || isProductionWorkspaceVisible
    }

    /// ⌘N：主页 → 新建项目；生视频页 → 新增分镜；生图页 → 新增图片
    func performNewItemShortcut() {
        guard canCreateNewItem else { return }
        if !isInWorkspace { startNewProject(); return }
        if workspaceMode == .video { addShotAndInspect() } else { addImageItem() }
    }

    /// ⌘F：让当前页的搜索框拿到焦点（各页自己接收，见 `Notification.Name.focusPageSearch`）
    func focusPageSearch() {
        NotificationCenter.default.post(name: .focusPageSearch, object: nil)
    }

    // MARK: 更换项目文件夹（设置 → 缓存，2026-10-10）

    /// 搬项目的进度（nil = 没在搬）。`ProjectsRootChangeOverlay` 据此盖住整个窗口
    struct ProjectsRootChange: Equatable {
        var done = 0
        var total = 0
    }
    var projectsRootChange: ProjectsRootChange?
    /// 更换项目文件夹进行中 / 即将重启：不再往旧位置写项目文件（退出时的落盘也不写，免得在旧位置又建出一堆空文件夹）
    var projectSavesSuspended = false

    /// 现在有没有还在跑的东西（视频 / 生图 / 剧本 AI / 素材上传）；有就写出来，没有 = nil。更换项目文件夹要等它们跑完
    func busyWorkSummary() -> String? {
        var parts: [String] = []
        let videos = store.tasks.filter { $0.phase == .queued || $0.phase == .inProgress }.count + submittingShotIDs.count
        if videos > 0 { parts.append("\(videos) 个视频") }
        let images = imageItems.filter { $0.status.isBusy }.count
        if images > 0 { parts.append("\(images) 张图") }
        if pipelineFlow.batches.values.contains(where: { !$0.finished }) { parts.append("剧本 AI 任务") }
        if reuploadingLibrary { parts.append("素材上传") }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }

    /// 把项目文件夹换到 `newRoot`：`moveExisting` = 现有项目一起搬过去；否则只是改用这个文件夹（它里面本来就有项目）。
    /// 搬完记下新路径并重启软件（整个软件要按新位置重新读一遍）。失败：原样不动、抛错。
    func changeProjectsRoot(to newRoot: URL, moveExisting: Bool) async throws {
        if let busy = busyWorkSummary() {
            throw ProjectsRootMover.Failure(message: "还有任务在跑（\(busy)），等它们结束再换。")
        }
        let old = projectStore?.root ?? FileLocations.projectsRoot
        try ProjectsRootMover.validate(old: old, new: newRoot)
        saveProjectsNow()                       // 先把内存里还没落盘的存下来，之后不再写
        projectSavesSuspended = true
        projectsRootChange = ProjectsRootChange()
        if moveExisting {
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    try ProjectsRootMover.move(from: old, to: newRoot, progress: { done, total in
                        Task { @MainActor in self?.projectsRootChange = ProjectsRootChange(done: done, total: total) }
                    })
                }.value
            } catch {
                projectSavesSuspended = false
                projectsRootChange = nil
                throw error
            }
        }
        UserDefaults.standard.set(newRoot.path, forKey: ProjectStore.rootDefaultsKey)
        AppLog.write("project", "项目文件夹换到 \(newRoot.path)（\(moveExisting ? "现有项目已一起搬过去" : "只改位置")），重启软件")
        AppRelaunch.now()
    }

    /// 项目文件夹（制作页把相对路径换成绝对路径用）
    func projectFolder(for key: String) -> URL {
        (projectStore?.root ?? FileLocations.projectsRoot).appendingPathComponent(key, isDirectory: true)
    }

    /// 立刻把内存里的旧数组换算成项目文档写盘（只写有变化的项目）。
    /// 外部文件（如从「下载」拖进来的素材）会被拷进项目文件夹，内存里的路径随之改成新位置。
    /// 当前要存的全部数据（数组都是值拷贝，拍一张几乎不花时间；组装、比较都在存盘队列上做）
    private func projectSaveSnapshot() -> LegacySnapshot {
        LegacySnapshot(metas: projectMetas, shots: shots, imageItems: imageItems, library: library,
                       tasks: store.tasks, pipelines: pipelineArchives)
    }

    /// 防抖之后的那次存盘：放到存盘队列的后台去做，主线程不等（2026-10-13 稳定性：原来在主线程上，项目大的时候一次卡零点几秒）。
    /// 有外部文件被拷进项目文件夹时，回到主线程把内存里的路径改过来
    func saveProjectsInBackground() {
        projectSaveWork?.cancel()
        projectSaveWork = nil
        guard let projectStore, !projectSavesSuspended else { return }
        let snapshot = projectSaveSnapshot()
        projectStore.queue.async { [weak self] in
            let moved = projectStore.saveChanged(snapshot)
            guard !moved.isEmpty else { return }
            Task { @MainActor in self?.applyMovedFiles(moved) }
        }
    }

    /// **立刻存、存完才返回**（回主页、删项目、退出、换项目目录、测试用）。和后台那些排在同一条队列上：
    /// 之前排着的先做完，所以返回时内存里的东西一定都落盘了
    func saveProjectsNow() {
        projectSaveWork?.cancel()
        projectSaveWork = nil
        guard let projectStore, !projectSavesSuspended else { return }
        let snapshot = projectSaveSnapshot()
        let moved = projectStore.queue.sync { projectStore.saveChanged(snapshot) }
        applyMovedFiles(moved)
    }

    private func applyMovedFiles(_ moved: [String: String]) {
        guard !moved.isEmpty else { return }
        for i in imageItems.indices {
            for j in imageItems[i].results.indices {
                if let path = imageItems[i].results[j].localPath, let new = moved[path] {
                    imageItems[i].results[j].localPath = new
                }
            }
        }
        for i in library.indices {
            if let path = library[i].localPath, let new = moved[path] { library[i].localPath = new }
        }
        store.relocateVideos(moved)
        AppLog.write("project", "\(moved.count) 个外部文件已拷进项目文件夹")
    }

    init() {
        // 诊断（临时，验完删）：量启动各阶段耗时 —— 用户报"启动有点慢"，但数据文件总共才 1.2MB、
        // 代码里也看不出同步重活，只能实测。
        let tStart = Date()
        var tMark = tStart
        func lap(_ name: String) {
            let now = Date()
            AppLog.write("startup", "\(name): \(Int(now.timeIntervalSince(tMark) * 1000))ms（累计 \(Int(now.timeIntervalSince(tStart) * 1000))ms）")
            tMark = now
        }
        // P2 起没有 tasks.json：任务记录在各项目的视频版本里，读项目文件时还原（见 loadProjects）
        let store = TaskStore()
        self.store = store
        self.jobCenter = JobCenter(fileURL: NSClassFromString("XCTestCase") != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("xipi-tests-jobs-\(UUID().uuidString).json")
            : FileLocations.jobsFile)
        self.poller = PollingManager(
            store: store,
            channelProvider: { [channelBox] name in
                channelBox.channel(named: name)
            },
            projectNameProvider: { [nameBox] key in
                nameBox.names[key] ?? key
            }
        )
        // 加载服务渠道（旧键 videoProviderConfigs / imageChannel / … 不再读取、也不删除）
        self.loadChannels()
        lap("渠道配置")
        self.loadProjects()
        lap("项目文件")
        self.connectJobCenter()
        lap("任务中心")

        // 同步项目名盒（PollingManager 下载视频时查项目名用）
        nameBox.names = projectMetas.mapValues(\.name)

        lap("素材库 + 项目元数据读取")
        // 给已有项目补元数据（创建/修改时间从任务推导，保证排序稳定）
        ensureProjectMetas()
        lap("ensureProjectMetas（补项目元数据）")

        // 一次性按分镜引用关系重新分配素材归属（修正早期错误迁移）
        if !UserDefaults.standard.bool(forKey: "libraryReassignedByRefs") {
            reassignLibraryByReferences()
            UserDefaults.standard.set(true, forKey: "libraryReassignedByRefs")
        }
        // 一次性数据修正（2026-09-18）：上面那条旧规则把"未被引用的素材"全塞给了第一个项目 ✗，
        // 这里按修正后的规则再跑一次 —— 把"被引用 / 生图来源能对上"的挑回原项目（其余保持现状）。
        if !UserDefaults.standard.bool(forKey: "libraryRefsFixed20260918") {
            reassignLibraryByReferences()
            UserDefaults.standard.set(true, forKey: "libraryRefsFixed20260918")
        }
        // 第二轮修正（2026-09-18 补）：上一轮只按"分镜引用"找，漏了**生图来源**这条线索 ——
        // 现在把"有 imageGenItemID 且生图条目在别的项目"的素材也挑回去。
        if !UserDefaults.standard.bool(forKey: "libraryRefsFixed2") {
            reassignLibraryByReferences()
            UserDefaults.standard.set(true, forKey: "libraryRefsFixed2")
        }

        // 分镜数据丢失的兜底：从任务恢复分镜卡片
        recoverShotsFromTasksIfNeeded()

        // 退出前强制落盘：防抖 Task 可能还没到 300ms，Cmd+Q 就把进程干掉了
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushAll()
        }
    }

    /// 取消所有防抖 Task，立刻同步写盘。
    /// 退出前由 `NSApplication.willTerminateNotification` 触发；也可在需要保证落盘的场景主动调用。
    func flushAll() {
        // 分镜 / 生图 / 素材库 / 剧本 / 元数据（都在项目文件里）
        saveProjectsNow()
        // 任务中心的排队与剧本 AI 记录
        jobCenter.flush()
    }

    /// 若分镜草稿为空但存在任务，从任务恢复分镜卡片（数据损坏兜底）
    private func recoverShotsFromTasksIfNeeded() {
        guard shots.isEmpty, !store.tasks.isEmpty else { return }
        for task in store.tasks {
            refShot(from: task)
        }
        persistShots()
        persistLibrary()
    }

    /// 锚定项目创建/修改时间：从分镜草稿 + 任务的时间推导（缺失的项目补元数据）
    private func ensureProjectMetas() {
        // 只给有分镜的 key 补元数据（只剩任务记录的 key 不算项目，见 `projects`）
        var keys = Set(shots.map(\.projectKey))
        keys.remove("")
        var changed = false
        for key in keys {
            let shotDates = shots.filter { $0.projectKey == key }.compactMap(\.createdAt)
            let taskDates = store.tasks.filter { $0.groupKey == key }.map(\.createdAt)
            let allDates = shotDates + taskDates
            let createdAt = allDates.min() ?? (projectMetas[key]?.createdAt ?? Date())

            if var meta = projectMetas[key] {
                // ⚠️ **绝不能用派生时间覆盖 `updatedAt`**（2026-09-18 用户实测：
                // "打开项目显示更新于刚刚，重启后又变回旧时间"）。`updatedAt` 是"最近使用/
                // 最近改动"的权威值（由 `touchProject` 维护），派生值（分镜/任务的最晚创建时间）
                // 只用来**补缺失的元数据**。以前这里每次都覆盖 → 主页排序在重启前后不一致 ✗
                // → 用户按肌肉记忆点同一张卡，点到的就是别的项目（用户实测的那个 bug）。
                if meta.createdAt != createdAt {
                    meta.createdAt = createdAt
                    projectMetas[key] = meta
                    changed = true
                }
            } else {
                let updatedAt = allDates.max() ?? Date()
                let name = uniqueProjectName("项目")
                projectMetas[key] = ProjectMeta(name: name, createdAt: createdAt, updatedAt: updatedAt)
                nameBox.names[key] = name
                changed = true
            }
        }
        if changed { persistProjectMetas() }
    }

    /// 按分镜引用关系重新分配素材归属：被引用的归到引用它的项目，未引用的归到第一个引用项目
    /// 按分镜引用关系修正素材归属：**被引用的**归到引用它的项目；**未被引用的保持原样**。
    ///
    /// ⚠️ **2026-09-18 修正**：原实现把"没被任何分镜引用的素材"统一塞给**第一个引用项目** ✗ ——
    /// 结果所有还没挂到分镜上的素材都堆进那一个项目（用户实测："这个项目的素材库里有别的项目的素材"）。
    /// 现在只修正"被引用但归属错了"的；没引用的原本属于谁无从判断，保持现状最安全。
    private func reassignLibraryByReferences() {
        var refProject: [UUID: String] = [:]
        for shot in shots {
            for ref in shot.imageRefs + shot.videoRefs + shot.audioRefs {
                refProject[ref.libraryItemID] = shot.projectKey
            }
        }
        // 生图来源的素材：按**生图条目的项目**归属（比"引用关系"更权威 —— 素材就是那个项目里生成的）
        var genProject: [UUID: String] = [:]
        for item in imageItems { genProject[item.id] = item.projectKey }
        var changed = false
        for i in library.indices {
            let target: String?
            if let p = refProject[library[i].id] {
                target = p
            } else if let gid = library[i].imageGenItemID, let p = genProject[gid] {
                target = p
            } else {
                target = nil   // 两条线索都没有 → 保持原样（原本属于谁无从判断）
            }
            guard let target, library[i].projectKey != target else { continue }
            library[i].projectKey = target
            changed = true
        }
        if changed { persistLibrary() }
    }
}

/// 批量设置参数的配置（底部工具条「批量设置参数」弹窗产出）
struct BatchParamConfig {
    var model: String = ""
    var resolution: Resolution = .p720
    var aspectRatio: AspectRatio = .ratio16x9
    var duration: Int = 5
}

enum ShotSubmitError: LocalizedError {
    case notFound
    case noAPIKey
    case materialMissing
    case materialNotUploaded

    var errorDescription: String? {
        switch self {
        case .notFound: "分镜不存在"
        case .noAPIKey: "请先在「设置」中保存 API Key"
        case .materialMissing: "引用的素材已被删除，请重新添加"
        case .materialNotUploaded: "素材尚未上传完成，请稍候或检查素材库状态"
        }
    }
}

extension Notification.Name {
    /// ⌘F：请当前页把搜索框聚焦
    static let focusPageSearch = Notification.Name("xipi.focusPageSearch")
}
