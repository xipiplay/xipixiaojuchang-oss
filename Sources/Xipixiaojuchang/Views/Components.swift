import SwiftUI
import AVKit
import ImageIO
import CryptoKit
import Combine

/// 状态胶囊：**视频 / 生图任务行共用的外观**（不透明底 + 0.15 色味、圆角、字号一套）。
///
/// 抽出来的原因（2026-09-27 用户）：生图任务行的状态原来是右边一行纯文字，跟生视频侧的
/// 胶囊徽章不一样。生图的状态文案/配色跟 `TaskPhase` 不是一套（有「下载中」「共 N 版」），
/// 所以这里只共用**外观**，标题与颜色由调用方给。
struct StatusCapsule: View, Equatable {
    // `nonisolated`：`Equatable` 的 `==` 在非主线程上下文求值，属性必须 nonisolated 才不越界
    nonisolated let title: String
    nonisolated let color: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // ⚠️ 胶囊底必须**不透明**（2026-09-19 二修"浅色模式胶囊闪边框"）：
            // 一修（equatable + compositingGroup）后用户实测"有时闪有时不闪、没规律"——
            // 说明光跳过重绘不够：胶囊原来用 `color.opacity(0.15)` 直接压在预览弹窗的**液态玻璃**上，
            // 面板每次重新合成（轮询/进度/背后窗口变化）都会让半透明层重新混合一次，
            // 浅色下析出一圈细边。现在改成「不透明底（浅色近白 / 深色近面板灰）+ 0.15 色味」——
            // 观感几乎一样，但不再和背后的玻璃混合，怎么重绘都是同一张图。
            .background(
                Capsule()
                    .fill(Self.baseColor(for: colorScheme))
                    .overlay(Capsule().fill(color.opacity(0.15)))
            )
            .foregroundStyle(color)
            .compositingGroup()
    }

    /// 手写 `==`（不能自动合成：`@Environment` 的存储属性不参与比较，自动合成会报不满足协议）。
    nonisolated static func == (lhs: StatusCapsule, rhs: StatusCapsule) -> Bool {
        lhs.title == rhs.title && lhs.color == rhs.color
    }

    /// 胶囊的不透明底：浅色近白、深色近面板灰（让 0.15 色味叠出来接近原来"透"的效果）
    private static func baseColor(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? SolidTheme.card(.dark)
            : SolidTheme.card(.light)
    }
}

/// 任务状态徽章（视频侧）：`StatusCapsule` 的 phase 版 —— 外观与生图侧共用，别再各写一套。
struct StatusBadge: View, Equatable {
    // `nonisolated`：`Equatable` 的 `==` 在非主线程上下文求值，属性必须是 nonisolated 才不越界
    //（Swift 6 严格并发；`TaskPhase` 是 Sendable 的简单枚举，比较是安全的）
    nonisolated let phase: TaskPhase

    var body: some View {
        StatusCapsule(title: phase.displayName, color: Self.color(for: phase))
    }

    /// 手写 `==`（不能自动合成：`@Environment` 的存储属性不参与比较，自动合成会报不满足协议）。
    /// 只比 `phase` —— 胶囊的全部外观都由它决定，环境色由 SwiftUI 自己处理。
    nonisolated static func == (lhs: StatusBadge, rhs: StatusBadge) -> Bool {
        lhs.phase == rhs.phase
    }

    /// 按阶段配色：排队中赭 / 进行中主色（琥珀）/ 完成鼠尾草绿 / 失败砖红 / 暂停灰
    static func color(for phase: TaskPhase) -> Color {
        switch phase {
        case .queued: Theme.warning
        case .inProgress: Theme.accent
        case .completed: Theme.success
        case .failed: Theme.danger
        case .paused: .gray
        }
    }
}

/// 🎯 B 弹窗结构模板（统一标题 / 说明 / 内容 / 底部操作按钮行）：
/// - 统一 padding: 20，spacing: 16
/// - 统一底部按钮间距: spacing: 10
/// - 支持语义角色：取消默认 .cancel，主操作可指定 .destructive 等
struct ModalShell<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    var confirmLabel: String = "确认"
    var confirmRole: ButtonRole? = nil
    var confirmTint: Color? = nil
    var cancelLabel: String? = "取消"
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        confirmLabel: String = "确认",
        confirmRole: ButtonRole? = nil,
        confirmTint: Color? = nil,
        cancelLabel: String? = "取消",
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.confirmLabel = confirmLabel
        self.confirmRole = confirmRole
        self.confirmTint = confirmTint
        self.cancelLabel = cancelLabel
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            content()

            HStack(spacing: 10) {
                Spacer()
                if let cancelLabel {
                    Button(cancelLabel, role: .cancel) { onCancel() }
                        .buttonStyle(OutlineButtonStyle())
                }
                Button(confirmLabel, role: confirmRole) { onConfirm() }
                    .buttonStyle(AccentButtonStyle(tint: confirmTint))
            }
        }
        .padding(20)
    }
}

/// 内嵌视频预览播放器。
/// 注意：不用 SwiftUI 的 VideoPlayer——它在当前 macOS 上会触发 _AVKit_SwiftUI 崩溃，
/// 改用 AppKit 原生 AVPlayerView 规避。
struct VideoPreviewView: View {
    let path: String

    @State private var player: AVPlayer?
    @State private var loadedPath: String?

    var body: some View {
        Group {
            if let player {
                AVPlayerContainer(player: player)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: path) { loadIfNeeded() }
        .onDisappear {
            player?.pause()
        }
    }

    /// path 变化（组内切换视频）时重建播放器；相同 path 不重复加载
    private func loadIfNeeded() {
        guard loadedPath != path else { return }
        loadedPath = path
        player?.pause()
        player = AVPlayer(url: URL(fileURLWithPath: path))
        // 不自动播放，点击播放
    }
}

/// AppKit AVPlayerView 包装
struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        PlayerLayerView()
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    /// 图层根视图：裸的 `AVPlayerLayer`，**背景全透明**，视频以外的区域（上下黑边）
    /// 因此能透出后面的玻璃。
    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            playerLayer.videoGravity = .resizeAspect   // 保持比例、留边（留出来的边透玻璃）
            playerLayer.backgroundColor = NSColor.clear.cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            // 关掉隐式动画：否则弹窗缩放时视频图层会"追着"放大，看着像卡顿
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// 自绘播放控制条：**替代 `AVPlayerView.controlsStyle = .inline`**
///（系统那套控制条随 AVPlayerView 一起被换掉了，见 `AVPlayerContainer`）。
/// 提供：播放/暂停、进度拖拽、当前/总时长、全屏。
/// 注意：全屏是**窗口全屏**（`toggleFullScreen`），不是系统播放器那种独立播放窗口。
struct VideoControlBar: View {
    let player: AVPlayer
    /// 点全屏按钮时执行。默认是「窗口全屏」；分镜预览会传入「浮层铺满 + 窗口全屏」，
    /// 这样按下去是**视频占满屏幕**，而不是只把软件窗口放大。
    var onToggleFullscreen: (() -> Void)?
    /// 全屏按钮的图标状态由调用方决定（默认按窗口是否全屏显示；预览里按浮层是否全屏）
    var isFullscreen: Bool = false
    /// 给了就在播放条最右边放一个「在访达中显示」（视频大窗口预览的右下角按钮，同生图大图预览）
    var onReveal: (() -> Void)? = nil

    @State private var isPlaying = false
    /// 拖动进度条期间不被定时刷新覆盖，否则滑块会被"拽回去"（进度状态在子视图里，这里只做转发）
    @State private var scrubbing = false

    /// 只用来切换播放/暂停**图标**，不需要高频。进度的高频刷新在 `VideoProgressSection` 里。
    private let stateTick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    /// 播到结尾后再点播放：AVPlayer 的播放头停在末尾，直接 `play()` 会"播 0 秒立刻又停"，
    /// 表现就是**图标闪一下暂停又变回播放、视频不动**。所以要先回到开头。
    /// 容差 0.15s：拖动到极接近末尾也算"已播完"。
    /// 注意：这里只 seek、不改进度显示值 —— 进度条在子视图里，它的 60Hz 刷新会立刻跟上。
    private func rewindIfAtEnd() {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        let end = item.duration.seconds
        guard end > 0, player.currentTime().seconds >= end - 0.15 else { return }
        player.seek(to: .zero)
    }

    /// **不能用 `player.rate` 判断是否在播**：`play()` 是**异步**的，刚调用完那一刻 rate 仍是 0
    ///（要等真正开始播才变 1），拿它当判据会读到中间态 —— 表现就是「点完播放再点没反应」。
    /// `timeControlStatus` 才是可靠判据：`.waitingToPlayAtSpecifiedRate` 表示"已请求播放、在缓冲"。
    private var isActuallyPlaying: Bool {
        player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if isActuallyPlaying {
                    player.pause()
                    isPlaying = false
                } else {
                    rewindIfAtEnd()       // 播完了要先回到开头，否则 play() 无效
                    player.play()
                    isPlaying = true      // 乐观更新，随后由 tick 校正
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 20)
            }
            .buttonStyle(HoverHighlightButtonStyle(expandX: 5, expandY: 3))

            // 进度区**单独成视图**：它以 60Hz 更新，必须让重绘只发生在这里面，
            // 否则外层的玻璃背景（要采样背景，贵）会跟着每秒重绘 60 次，刷新率越高越卡。
            VideoProgressSection(player: player, scrubbing: $scrubbing)

            Button {
                if let onToggleFullscreen {
                    onToggleFullscreen()
                } else {
                    (NSApp.mainWindow ?? NSApp.keyWindow)?.toggleFullScreen(nil)
                }
            } label: {
                Image(systemName: isFullscreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(HoverHighlightButtonStyle(expandX: 5, expandY: 3))

            if let onReveal {
                Button("在访达中显示", action: onReveal)
                    .buttonStyle(OutlineButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 14)
        .padding(10)
        .onReceive(stateTick) { _ in isPlaying = isActuallyPlaying }
    }
}

/// 播放进度区：当前时间 / 滑块 / 总时长。
/// **单独成视图是刻意的**——这里的状态 60Hz 变化，独立出来才能把重绘限制在它自己内部，
/// 不带累外层的玻璃背景。全屏后进度条很长，刷新率不够时滑块会肉眼可见地一格一格跳。
/// 播放进度区：当前时间 / 进度条 / 总时长。
/// **单独成视图是刻意的**——这里的状态 60Hz 变化，独立出来才能把重绘限制在它自己内部，
/// 不带累外层的玻璃背景。
///
/// 进度条是**自定义拖动条**（2026-09-17，和全屏那条同一套）：不用 `Slider` ——
/// 松手后 seek 是异步的，Slider 会被 60Hz 刷新按"播放器旧时间"拉回去（不跟手）；
/// 这里滑块严格跟鼠标、拖动中 30Hz 持续 seek（帧跟着变）、松手**钉住**目标值等播放器追上。
private struct VideoProgressSection: View {
    let player: AVPlayer
    @Binding var scrubbing: Bool

    @State private var current: Double = 0
    @State private var duration: Double = 0
    @State private var dragging = false
    @State private var pinnedTarget: Double?
    @State private var lastSeekAt = Date.distantPast
    @State private var lastScrubAt = Date.distantPast

    /// 60Hz：全屏后进度条很长，30Hz 都能看出步进，所以拉到 60Hz
    private let tick = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Text(timeText(current))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)

            GeometryReader { geo in
                let f = fraction
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.3)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: max(0, geo.size.width * f), height: 4)
                    Circle().fill(Theme.accent)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, geo.size.width * f - 6))
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            pinnedTarget = nil
                            scrubbing = true
                            let frac = min(1, max(0, value.location.x / max(1, geo.size.width)))
                            current = frac * duration
                            // 拖动中持续 seek（30Hz 节流）：帧跟着手指变
                            if Date().timeIntervalSince(lastScrubAt) > 1.0 / 30.0 {
                                lastScrubAt = Date()
                                lastSeekAt = Date()
                                seek(to: current)
                            }
                        }
                        .onEnded { value in
                            let frac = min(1, max(0, value.location.x / max(1, geo.size.width)))
                            current = frac * duration
                            dragging = false
                            scrubbing = false
                            pinnedTarget = current          // 钉住：等播放器追上再交回刷新
                            lastSeekAt = Date()
                            seek(to: current)
                        }
                )
            }
            .frame(height: 16)

            Text(timeText(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .onReceive(tick) { _ in refresh() }
    }

    private var fraction: Double {
        duration > 0 ? min(1, max(0, current / duration)) : 0
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func refresh() {
        guard !dragging else { return }      // 拖动中不刷新（跟手的关键）
        let t = player.currentTime().seconds
        if t.isFinite {
            if let target = pinnedTarget {
                // seek 还没生效：钉住目标值；播放器追上（±0.4s）或 0.8s 超时再交回
                if abs(t - target) < 0.4 || Date().timeIntervalSince(lastSeekAt) > 0.8 {
                    pinnedTarget = nil
                } else {
                    return
                }
            }
            current = t
        }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// 视频首帧缩略图（异步生成 + 内存缓存 + 后台磁盘缓存）
/// 🧪 **实验 10 开关（2026-09-27 用户定：先不限流试试）**：
/// `true` = 缩略图读盘/解帧过限流闸门（最多 3 并发）；`false` = 不限流（A/B 对照）。
/// —— 文件级 `let`（nonisolated）方便两处 nonisolated 静态函数读。
private let videoThumbUseLoadGate = false

/// 🧪 **实验 10（2026-09-27）缩略图后台限流闸门**：
/// 治"刚进项目快滑"的卡 —— 原来每个进屏的格子各自往全局队列丢"读盘+解码"（几百个一起上），
/// 磁盘解码 + 解帧把系统打爆、主线程跟着挨饿。这里统一限流（最多 3 个在跑），
/// 且**排队等到的任务先查取消**（格子滚走了就不干活 ✓）。
actor ThumbWorkGate {
    static let shared = ThumbWorkGate(limit: 3)
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    /// 名额**直接转交**给下一个等待者（没有等待者才真正释放）
    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
enum VideoThumbnailCache {
    /// 首帧内存缓存（path → NSImage）。2026-09-27 从字典升 **NSCache**：
    /// 上限 400 张 / 384MB（按解码后字节算；首帧限过 `maximumSize 640×360` ≈ 0.9MB/张）。
    /// 🧪 实验 4（2026-09-27）：原来 300/128MB **装不下 300 段视频的工作集**（≈264MB）→
    /// 缓存被挤爆后，每次滚回来都要重读盘/重新生成首帧 + 先闪一下转圈（用户对比即梦："加载出来就丝滑"）。
    /// 调大后"加载过的格子"滚回来就是贴图 ✓ **与生图缩略图缓存各自独立设限额**，别共用一个数 ✓。
    static let images = ImageMemoryCache(countLimit: 400, totalCostLimit: 384 * 1024 * 1024)

    /// 缓存文件名用完整路径的 SHA256：不同项目里可能有同名视频文件（如「分镜一 第1版.mp4」），
    /// 用文件名做 key 会跨项目撞车、互相覆盖缩略图。
    private nonisolated static func cacheKey(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func thumbURL(for path: String) -> URL {
        // 文件名带尺寸版本（2026-09-18）：之前是 160×90，时间轴胶片条放大后糊。
        // 带上尺寸后旧缓存自然失效、自动按 480×270 重新生成（旧文件成为孤儿，几 MB，可忽略）。
        let name = cacheKey(for: path) + "-480x270.png"
        return FileLocations.appSupport.appendingPathComponent("Thumbs", isDirectory: true).appendingPathComponent(name)
    }

    /// 先查内存，再查磁盘缓存
    ///
    /// ⚠️ 磁盘那一路必须用 `NSImage.decoded(from:)`（当场解码）✗ 不能用 `NSImage(data:)` ——
    /// 后者是懒解码，会把没解码的图存进内存缓存，之后每次"命中"却不解码，
    /// 直到第一次绘制才在**主线程**解 ✗（就是"新卡片第一次出现卡一下"的根因，同 `LocalImageCache`）
    /// **后台**读盘 + 当场解码，回主线程进内存缓存。
    ///
    /// 🧪 **实验 10（2026-09-27）**：读盘+解码走 `loadDiskImage`（↔ `ThumbWorkGate` 限流 + 可取消）。
    /// 兼容旧签名：内部仍回主线程回调（老调用点用不到取消联动）。
    static func loadFromDisk(path: String, completion: @escaping @MainActor (NSImage?) -> Void) {
        Task { @MainActor in
            let img = await loadDiskImage(path: path)
            if let img { images[path] = img }
            completion(img)
        }
    }

    /// 🧪 实验 10：后台读盘 + 当场解码（**限流/取消**由 `videoThumbUseLoadGate` 控制；跑在协作线程池，不是主线程）
    nonisolated static func loadDiskImage(path: String) async -> NSImage? {
        if videoThumbUseLoadGate { await ThumbWorkGate.shared.acquire() }
        if Task.isCancelled {
            if videoThumbUseLoadGate { await ThumbWorkGate.shared.release() }
            return nil
        }
        let url = Self.thumbURL(for: path)      // nonisolated ✓
        let img: NSImage? = (try? Data(contentsOf: url)).flatMap { NSImage.decoded(from: $0) }
        if videoThumbUseLoadGate { await ThumbWorkGate.shared.release() }
        return img
    }

    static func cached(for path: String) -> NSImage? {
        if let img = images[path] { return img }
        if let data = try? Data(contentsOf: thumbURL(for: path)),
           let img = NSImage.decoded(from: data) {
            images[path] = img
            return img
        }
        return nil
    }

    /// 仅存内存（磁盘缓存已在生成时后台写入，避免主线程重复编码）
    static func store(_ img: NSImage, for path: String) {
        images[path] = img
    }

    /// 预热：任务视频下载完成后预生成缩略图（内存+磁盘），滚动卡片时直接内存命中
    static func warmUp(path: String) {
        guard images[path] == nil else { return }
        Task {
            guard let generated = await generateThumbnail(path: path) else { return }
            images[path] = generated
        }
    }

    /// 后台生成缩略图并写磁盘缓存（🧪 实验 10：限流/取消由 `videoThumbUseLoadGate` 控制）
    nonisolated static func generateThumbnail(path: String) async -> NSImage? {
        if videoThumbUseLoadGate { await ThumbWorkGate.shared.acquire() }
        if Task.isCancelled {
            if videoThumbUseLoadGate { await ThumbWorkGate.shared.release() }
            return nil
        }
        let img = await generateThumbnailBody(path: path)
        if videoThumbUseLoadGate { await ThumbWorkGate.shared.release() }
        return img
    }

    /// 实际生成（AVAssetImageGenerator + CGImageDestination 均线程安全，不占主线程）
    ///
    /// ⚠️ 2026-09-12 曾怀疑它是滚动顿挫的元凶（解一帧视频要抢硬解 ✗），
    /// 加了时间戳埋点去对 —— **结果是排除了** ✓：滚动全程 `thumb.gen` 一条都没出
    /// （缩略图全命中缓存，后台解帧压根没发生）。真要再怀疑它，先把缩略图缓存删掉再复现。
    nonisolated private static func generateThumbnailBody(path: String) async -> NSImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // 2026-09-18：160×90 太小 —— 时间轴胶片条一格是 213×120pt（2x = 426×240px），
        // 放大后首帧明显糊（尾帧走 VideoFrameCache 是全尺寸所以正常，用户实测对比）。
        // 提到 480×270：卡片缩略图照样够用，胶片条不再糊。
        // 2026-09-27 实验 2：480×270 → **640×360**（格子 2x 下约 600px，避免滚动时放大重采样）。
        generator.maximumSize = CGSize(width: 640, height: 360)
        let time = CMTime(seconds: 0, preferredTimescale: 600)   // 首帧（用户 2026-09-18：原来取 0.5 秒）
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        let url = thumbURL(for: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cgImage, nil)
            CGImageDestinationFinalize(destination)
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

/// 拖动框选的卡片 frame 缓存（**普通 class**：写入不触发 SwiftUI 重算，同 `IconDropdown.FrameBox` 的思路）。
/// 用法：卡片 `.background(GeometryReader { … })` 上报 frame（同一命名坐标空间，滚动时自动更新），
/// 拖动手势里用 `hit(_:)` 求与选框相交的卡片（2026-09-26 用户定：拖动框选多张，**每次替换**）。
final class MarqueeFrameStore<Key: Hashable> {
    private var frames: [Key: CGRect] = [:]

    func update(_ id: Key, _ rect: CGRect) {
        if frames[id] != rect { frames[id] = rect }
    }

    /// 读某条目的 frame（nil = 最近没上报过）。🧪 2026-09-27 诊断用（跳转落点核对）。
    func rect(for id: Key) -> CGRect? { frames[id] }

    /// 🧹 **只保留这些条目的 frame**（其余清掉）。
    ///
    /// 为什么需要（2026-09-27 用户实测）：条目被删后它的 frame 会**留在缓存里** ——
    /// 顶上来的那条正好占着同一个位置，勾选/拖选走 `hit()` 时会把"幽灵 frame"一起算上，
    /// 表现为「已选 2」（多出来的那个是已删条目的 ID，屏幕上根本没有对应的勾）。
    /// 列表一变就把不在列表里的清掉；格子重建时会重新上报，不影响在屏条目。
    func keepOnly(_ ids: Set<Key>) {
        guard !frames.isEmpty else { return }
        frames = frames.filter { ids.contains($0.key) }
    }

    func hit(_ rect: CGRect) -> Set<Key> {
        Set(frames.filter { $0.value.intersects(rect) }.keys)
    }
}

struct VideoThumbnailView: View {
    let path: String
    /// 2026-09-26：视频缩略图页卡片改成**方形 + 等比内缩**（对齐生图侧卡片）——
    /// 传 true 时按 fit 显示（留边交给外层 `.insetFill` 底），默认 false = 原来的 fill 裁切
    ///（时间轴 / 素材库 / 欢迎页等其他使用处不受影响）。
    var fitsAspect: Bool = false

    @State private var image: NSImage?

    /// 用**内存缓存**做初始值：`LazyVGrid` 在窗口缩放时会重建单元格，`@State` 随之重置 ——
    /// 不预置的话会先闪一下转圈再出图（用户反馈的"缩略图会跳"）。
    /// 只查内存、不碰磁盘（`VideoThumbnailCache.cached` 会同步读盘，不适合放进 init）。
    @MainActor
    init(path: String, fitsAspect: Bool = false) {
        self.path = path
        self.fitsAspect = fitsAspect
        _image = State(initialValue: VideoThumbnailCache.images[path])
    }

    var body: some View {
        // 图片放在 background 层：只负责显示、天然不参与点击命中（避免 fill 图片在窗口缩放后命中区域错位/溢出）；
        // 前景矩形提供稳定命中体（布局尺寸由使用处 frame 决定），外层 Button 靠它响应点击
        Rectangle()
            .fill(fitsAspect ? Color.clear : Color.secondary.opacity(0.15))
            .background {
                if let image {
                    if fitsAspect {
                        // 等比内缩（留边透出外层的 .insetFill 底）——与生图卡片一致
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .clipped()
            // 🧪 实验 7B：池子复用槽位（视图不重建）——路径一变**立即**换成新缓存图/占位，
            // 不残留上一段的画面（`.task(id:)` 要等一拍，不够）。
            .onChange(of: path) { _, newPath in
                image = VideoThumbnailCache.images[newPath]
            }
            .task(id: path) {
                // ① 内存命中：纯查表（主线程安全 ✓）
                if let cached = VideoThumbnailCache.images[path] {
                    image = cached
                    return
                }
                // ② 磁盘缓存（🧪 实验 10：读盘+解码在后台、**过限流闸门、可取消**）——
                //    格子滚出屏幕 → 本任务被取消 → 排队中的活儿直接作废。
                if let fromDisk = await VideoThumbnailCache.loadDiskImage(path: path) {
                    guard !Task.isCancelled else { return }
                    VideoThumbnailCache.store(fromDisk, for: path)
                    image = fromDisk
                    return
                }
                guard !Task.isCancelled else { return }
                // ③ 磁盘也没有 → 生成首帧（同样过闸门）
                if let generated = await VideoThumbnailCache.generateThumbnail(path: path) {
                    guard !Task.isCancelled else { return }
                    VideoThumbnailCache.store(generated, for: path)
                    image = generated
                }
            }
    }
}

/// 虚线投放区（空状态用）：背景比周围略亮 + 四周虚线框，像"拖拽上传区"。
/// **撑满可用空间**（整个空白区域即投放区）；点击触发 action，拖入由外层 dropDestination 提供。
struct DropZone<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.primary.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            Color.secondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(QuietButtonStyle(hover: .none))
    }
}

/// 「提交生成」这类**整宽主按钮**的悬浮反馈：底色提亮一点（「暗房」：不再放大、不再有光晕——只动亮度，不做位移）。
struct ProminentSubmitHover: ViewModifier {
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { hovered = $0 }
            .brightness(hovered ? 0.06 : 0)
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// 生成中的**呼吸光晕**（2026-09-27 用户要的"点提交后详情页的动画/光效"）——
/// ⚠️ **已停用**（2026-09-27 用户："太卡了"）：`repeatForever` 的连续动画挂在常驻的共享面板上，
/// 每帧都在重绘那一块 ✗。**别直接再用它**；要"生成中"的视觉反馈请走**非连续**效果
///（比如进/出状态各闪一下，或干脆靠转圈 + 状态徽章）。
struct GeneratingGlow: ViewModifier {
    var isActive: Bool
    var cornerRadius: CGFloat = 14

    @State private var breathing = false
    @State private var finishedFlash = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.accent.opacity(breathing ? 0.55 : 0.18),
                                  lineWidth: (isActive || finishedFlash) ? 2 : 0)
                    .opacity(isActive || finishedFlash ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard isActive else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .onChange(of: isActive) { _, active in
                if active {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                        breathing = true
                    }
                } else {
                    // 结束：亮一下再收掉
                    withAnimation(.easeOut(duration: 0.12)) {
                        breathing = false
                        finishedFlash = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        withAnimation(.easeOut(duration: 0.4)) { finishedFlash = false }
                    }
                }
            }
    }
}

extension View {
    /// 提交按钮的悬浮光效（见 `ProminentSubmitHover`）
    func prominentSubmitHover() -> some View { modifier(ProminentSubmitHover()) }
    /// 生成中的呼吸光晕（见 `GeneratingGlow`）
    func generatingGlow(isActive: Bool, cornerRadius: CGFloat = 14) -> some View {
        modifier(GeneratingGlow(isActive: isActive, cornerRadius: cornerRadius))
    }
}

/// **工作区页面壳**（2026-09-27 用户定"方案 A：生图 / 生视频不再各写一套页面"）：
/// 空态 → 头部容器（筛选横滑区 + 搜索框）→ 内容区（卡片 / 网格切换）**一份实现**，
/// 模式差异全部从插槽进来（空态 / 筛选 / 网格 / 卡片）。
///
/// 两个模式**各实例化一份、都常驻**（切换仍旧只翻透明度，滚动/筛选状态留在自己的实例里不丢）；
/// 以后改头部/搜索/切换逻辑只改这里一处。
struct WorkspacePage<EmptyState: View, Filters: View, GridContent: View, CardsContent: View>: View {
    @Environment(AppModel.self) private var app
    /// 这一页属于哪个模式（只用于日志/语义；样式是全局的 `app.viewStyle`）
    let mode: AppModel.WorkspaceMode
    /// 这一页有没有内容（空项目 → 显示空态）
    let isEmpty: Bool
    @Binding var searchText: String
    let searchPlaceholder: String
    /// 搜索框焦点由**页面自己持有**（点卡片/点标签时页面要收焦点），壳这里只负责挂上
    var searchFocus: FocusState<Bool>.Binding
    @ViewBuilder var emptyState: EmptyState
    @ViewBuilder var filters: Filters
    @ViewBuilder var gridContent: GridContent
    @ViewBuilder var cardsContent: CardsContent
    @State private var headerOverflowing = false

    var body: some View {
        if isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                header
                // 卡片 / 网格：两个都常驻，只切透明度/命中（滚动位置天然保留）
                // ⚠️ 实验 12（2026-09-27）已否：进项目首帧只挂当前样式、另一份延迟补挂 ——
                //    实测进项目卡顿总量不变（只是从"第一帧"搬到"+0.4s 那一下"，因为补挂时
                //    它自己的格子照样要建要烤）。别再试"延迟挂载"。
                ZStack(alignment: .topLeading) {
                    // 🔒 2026-10-03（用户定）：卡片视图下线——只在 cards 样式时才构建
                    //    （现恒为缩略图 → 卡片子树不再白白构建、常驻）
                    if app.viewStyle == .cards {
                        cardsContent
                    }
                    gridContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // ⚠️ **不做过渡动画**（2026-09-17 用户定）——瞬时切换，别再往回加。
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 头部：左侧筛选区**横向可滑**（窄窗口不折行）、搜索框钉右边、点空白收焦点
    private var header: some View {
        // 2026-09-29 用户定：**放大镜移进搜索框内**（左端、gap 8，系统搜索框样式）；
        // 「卡片/详情」两段图标切换**从 `WorkspaceSwitches` 搬到搜索框右边**（省右端空间、和搜索成组）；
        // 间距：筛选区↔搜索区 16→12、搜索框↔切换 10（粘一起会被读成"搜索的模式"）。
        HStack(spacing: 12) {
            // 从工作台的分段详情跳过来时才有（见 `WorkbenchBackButton`）
            WorkbenchBackButton()
            HorizontalScrollRow(isOverflowing: $headerOverflowing) {
                filters
                    .fixedSize(horizontal: true, vertical: false)   // 内容按理想宽度（不压缩、不截断）
                    .frame(height: 30)
            }
            .frame(maxWidth: .infinity)   // 撑满剩余宽度（内容超了才滚）
            .frame(height: 30)
            // ⚠️ 溢出渐隐**已去掉**（2026-09-27 用户："太突兀了，还不如不加呢"）——浅色下像贴了块白条。
            // ⚠️ 这里**不要 Spacer**（2026-09-29 用户："两个间距不一样"）：筛选区本身
            //    `.frame(maxWidth: .infinity)` 已把它推到左边，Spacer 只会让"筛选↔搜索"
            //    的间隙比"搜索↔切换"大出一截（12+8+12 vs 12）。
            // 搜索框（放大镜在框内）；窄窗口先压这一整块（100~140），别挤坏筛选区
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                QuietSearchField(placeholder: searchPlaceholder, text: $searchText, focus: searchFocus)
            }
            // ⌘F：生视频 / 生图两页都常驻，只有当前这一页的搜索框响应
            .onReceive(NotificationCenter.default.publisher(for: .focusPageSearch)) { _ in
                if app.isProductionWorkspaceVisible, app.workspaceMode == mode { searchFocus.wrappedValue = true }
            }
            .frame(minWidth: 100, maxWidth: 140)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.insetFill))
            .inputChrome(focused: searchFocus.wrappedValue)
            // 页面入口统一位于 AppNavigationRail。
        }
        // 2026-09-29 用户定：左右 16 → **14**（与卡片列表容器对齐；原来页头比卡片多缩 2pt）
        .padding(.horizontal, 14)
        .frame(height: ProjectPageHeaderLayout.height)
        // 点空白处 → 收掉搜索框焦点（2026-09-26 用户："点了之后鼠标再点其他地方，光标还在闪"）。
        // 用 background 垫层：点搜索框本身不经过它（不受影响），只有没被内容吃掉的点击落到这里。
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { searchFocus.wrappedValue = false }
        }
    }
}

/// 搜索框：平时是一行字（没有输入框，也就没有插入竖线指针），点一下才变成真正的输入框，点外面（失去焦点）变回去。
/// 和剧本页的原文 / 时长分割框（`ScriptTextEditor`）、集标题一个做法（2026-10-10 用户：「改法应该一样」）。
///
/// 为什么：AppKit 的指针区域不被弹窗的遮罩挡住，页头的搜索框在默认窗口里正好落在编辑提示词弹窗标题行的底下，
/// 鼠标滑过弹窗上那一块就变成插入竖线。试过弹窗开着时把它禁用——禁用后旧的竖线区域还留着，没用。平时根本没有输入框就没有这个问题。
struct QuietSearchField: View {
    let placeholder: String
    @Binding var text: String
    /// 焦点由使用处持有（点别处时页面要收焦点）；失去焦点就变回文字
    var focus: FocusState<Bool>.Binding
    @State private var editing = false

    var body: some View {
        Group {
            if editing {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused(focus)
                    .onAppear { DispatchQueue.main.async { focus.wrappedValue = true } }
            } else {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.7) : Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .hoverHighlight(radius: 6)
                    .onTapGesture { editing = true }
            }
        }
        // 没点过就被外面要求聚焦（比如快捷键）：直接变成输入框
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused { editing = true } else { editing = false }
        }
    }
}

/// 横向可滑一行（2026-09-27 用户定：缩略图页头部**窄窗口不折行**，改成横向滑动）。
///
/// ⚠️ 用**自持 `NSScrollView`** 而不是 SwiftUI 的 `ScrollView(.horizontal)`，**为的是鼠标滚轮**：
/// SwiftUI 的横向 ScrollView 不响应竖向滚轮（普通鼠标滑不动 ✗）；这里把竖向滚轮映射成横向滚动 ✓
///（触控板/横向滚轮照常交给系统）。项目里时间轴的 `TimelineScrollContainer` 是同一个路子。
///
/// 不需要滚动条（`hasHorizontalScroller = false`）；有没有溢出通过 `isOverflowing` 报出去，
/// 调用方据此在右缘加一条渐隐提示"还有内容"。
struct HorizontalScrollRow<Content: View>: NSViewRepresentable {
    /// 内容是否比可视区宽（调用方拿它显示/隐藏边缘渐隐）
    /// ⚠️ 声明必须在 `content` **前面**：成员初始化器参数顺序跟着声明走，尾随闭包只认最后一个参数
    ///（同 `WorkspaceBar.replaceContent` 那条注释）。
    @Binding var isOverflowing: Bool
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> WheelScrollView {
        let scroll = WheelScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = NSHostingView(rootView: content)
        return scroll
    }

    func updateNSView(_ scroll: WheelScrollView, context: Context) {
        guard let host = scroll.documentView as? NSHostingView<Content> else { return }
        host.rootView = content
        // 文档视图 = 内容的**自适应宽**（高=可视区高）：内容比可视区窄时贴左显示，宽时才能滚
        let fitting = host.fittingSize
        let clipSize = scroll.contentSize
        host.frame = NSRect(x: 0, y: 0,
                            width: max(fitting.width, 1),
                            height: max(clipSize.height, fitting.height))
        // 溢出状态回传（延迟一拍，别在视图更新里写状态）
        let overflow = fitting.width > clipSize.width + 0.5
        if overflow != isOverflowing {
            DispatchQueue.main.async { self.isOverflowing = overflow }
        }
    }

    /// 竖向滚轮 → 横向滚动（鼠标也能滑）；横向滚动/触控板原样交给系统
    final class WheelScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaX) < abs(event.scrollingDeltaY) {
                let clip = contentView
                let maxX = max(0, (documentView?.frame.width ?? 0) - clip.bounds.width)
                let newX = min(max(0, clip.bounds.origin.x - event.scrollingDeltaY), maxX)
                clip.scroll(to: NSPoint(x: newX, y: 0))
                reflectScrolledClipView(clip)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}

/// 工具条容器（生图/生视频共用）：**悬浮胶囊条**（2026-09-17 改，参考 Apple Music 的悬浮播放条）。
/// 内容布局见 `WorkspaceBar`。
///
/// ⚠️ **条按内容定宽**（不撑满窗口）——宽度由里面按钮的总宽 + 内边距决定，
/// 外面用 `maxWidth: .infinity` 把它**居中**（2026-09-17 用户要求："条状尺寸跟着里面的按钮" + "居中"）。
///
/// 背景用 `.regularMaterial`（与卡片/弹窗/抽屉同一套）：**有"透"、又没有液态玻璃的圆角色带**——
/// 这是项目里踩过两次的结论（见 `materialCard()` 的注释）。条形浮层是静态的、不在滚动列表里，
/// 所以 `popupShadow()` 的离屏开销可以接受（同抽屉/弹窗）。
enum ToolbarRowLayout {
    /// 🧪 玻璃态下是否在材质底下垫一层实色（true = 原来的做法；false = 只剩材质，见 `ToolbarRow.body` 里的说明）
    static let keepsSolidBase = false

    /// 🧪 玻璃态 + macOS 26 下胶囊用液态玻璃（2026-10-10 用户要试试）。false = 退回原来的材质胶囊
    static let usesLiquidGlass = true

    /// 工具条浮在页面底部，会盖住它下面的内容；需要「能滚到它上面」的滚动区（右栏）底部要留出这么高
    /// （胶囊约 52 + 离窗口底 12 + 一点呼吸 8）
    static let clearance: CGFloat = 72

    /// 抽屉打开时，胶囊右端离抽屉左边至少留这么多
    static let drawerGap: CGFloat = 12

    /// **抽屉打开时胶囊要往左让多少**（pt，≥ 0）。
    ///
    /// 根因（2026-10-08）：素材库 / 任务抽屉是盖在最上面的毛玻璃，胶囊在窗口居中、宽 ~650，窗口窄于 ~1322 时它的右端会被抽屉盖住一截；
    /// 两层毛玻璃叠在一起会互相采样闪烁，原来的补法是抽屉一开就把胶囊换成实色（不管叠没叠到）→ 开抽屉时胶囊外观跳一下。
    /// 现在从源头解：**不叠**——胶囊整窗居中（中心 = 容器中心 − `contentCenterOffset`），抽屉靠右宽 `drawerWidth`；
    /// 右端会碰到抽屉就往左挪刚好够的距离，用不着挪就是 0。胶囊永远不被抽屉盖住，也就不用再换外观。
    /// 挪到容器左缘为止（再窄放不下的情况由紧凑档接手）。
    static func drawerAvoidanceShift(containerWidth: CGFloat, capsuleWidth: CGFloat, drawerOpen: Bool) -> CGFloat {
        guard drawerOpen, containerWidth > 0, capsuleWidth > 0 else { return 0 }
        let center = containerWidth / 2 - AppWindowShellLayout.contentCenterOffset
        let rightEdge = center + capsuleWidth / 2
        let limit = containerWidth - AppWindowShellLayout.drawerWidth - drawerGap
        let needed = max(0, rightEdge - limit)
        let leftRoom = max(0, center - capsuleWidth / 2)
        return min(needed, leftRoom)
    }
}

/// 工具条所在的可用宽度（窗口窄时里面的参数下拉切紧凑档，见 `ToolbarGenerationParams`）。0 = 还没量到
private struct ToolbarContainerWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    var toolbarContainerWidth: CGFloat {
        get { self[ToolbarContainerWidthKey.self] }
        set { self[ToolbarContainerWidthKey.self] = newValue }
    }
}

/// 胶囊挂液态玻璃（macOS 26+）。和 `GlassPanelModifier` 的区别：不再裁里面的内容（工具条按钮的悬停放大 2026-09-29 已去掉，里面的东西本来就不会超出胶囊）
private struct LiquidGlassCapsule: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, #available(macOS 26.0, *) {
            // 玻璃挂在**背景**上，不包住里面的内容：胶囊宽度变化（选中 ↔ 参数条）时，包住内容的玻璃会让里面的东西相对胶囊滑动
            //（2026-10-10 用户：变回参数条时右边有个白色的东西往左滑——是「提交生成」按钮里的字）
            content.background { Capsule().fill(Color.clear).glassEffect(.regular, in: Capsule()) }
        } else {
            content
        }
    }
}

struct ToolbarRow<Content: View>: View {
    @Environment(AppModel.self) private var app
    @State private var containerWidth: CGFloat = 0
    /// 胶囊自己的宽度（让位计算用）
    @State private var capsuleWidth: CGFloat = 0
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme
    private var drawerOpen: Bool { app.showLibraryDrawer || app.showTaskDrawer }
    /// 玻璃效果开着就用材质，**抽屉开不开都一样**。
    /// 原来抽屉一开就换成实色（避免和抽屉的毛玻璃叠在一起互相采样闪烁）；现在胶囊给抽屉让位、不叠（见 `ToolbarRowLayout.drawerAvoidanceShift`），不用换了。
    private var usesMaterial: Bool { glassEnabled }
    /// 里面的参数下拉按「抽屉没占的那部分」宽度决定用常规还是紧凑档
    private var availableWidth: CGFloat {
        containerWidth > 0 ? containerWidth - (drawerOpen ? AppWindowShellLayout.drawerWidth : 0) : 0
    }
    /// 胶囊的上下内边距（条高 = 内容高 + 2×这个值 —— **跟着按钮走**）
    var verticalPadding: CGFloat = 6
    /// 把胶囊的位置记进 `app.workspaceToolbarFrame`（生图 / 生视频页的卡片双击要避开它）。
    /// 工作台页的胶囊不报：它盖不到那两页的卡片，报了反而会把那两页记的位置冲掉。
    var reportsFrame = true
    /// 胶囊的位置变了时通知（不碰 `app.workspaceToolbarFrame`）：工作台详情页的右栏据此决定底部按钮要不要抬高避开它
    var onFrame: ((CGRect) -> Void)? = nil
    @ViewBuilder var content: Content

    /// 玻璃开 + macOS 26：胶囊底是**液态玻璃**（2026-10-10 用户：「试试液态玻璃」，生图 / 生视频 / 工作台 / 主页多选条共用）。
    /// 玻璃直接挂在胶囊上（和 `glassPanel` 一样的做法，只是没有再裁一遍里面的内容）。
    /// 想退回原来的材质胶囊 → 把 `ToolbarRowLayout.usesLiquidGlass` 改成 false。
    private var usesLiquidGlass: Bool {
        guard ToolbarRowLayout.usesLiquidGlass, glassEnabled else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 液态玻璃时玻璃直接挂在胶囊本身上（`LiquidGlassCapsule`，和 `glassPanel` 同一个做法、只是不裁内容），这里就不画底了
    @ViewBuilder
    private var barBackground: some View {
        if usesLiquidGlass {
            EmptyView()
        } else {
            Capsule()
                // **常驻实色底**（2026-09-27 用户："点一下工具条会消失一下然后变白"）：
                // 抽屉开关会刻意摘掉上面的材质（避免两个材质互相采样闪）——材质被摘掉的那一两帧
                // 露出的是"什么都没有" ✗。先铺一层和"无玻璃"同色的实底，材质只是叠在它上面，
                // 摘掉时底下一直有东西 → 不再有空白帧，视觉上只剩一点点"糊感消失"。
                //
                // 🧪 实验（2026-10-08 用户："主页和项目里的胶囊底色去掉看看什么效果"）：
                // `keepsSolidBase = false` → 玻璃态下**不垫实色底，只剩材质**（更透）；没有材质的时候（纯色模式）
                // 仍然是实色，不然胶囊就看不见了。用透明度开关而不是增删这一层：视图结构不变，切换时不会多出空白帧。
                // 不喜欢 → 把 `ToolbarRowLayout.keepsSolidBase` 改回 true 即可（主页多选条和项目里的工具条共用这一个）。
                .fill(SolidTheme.overlay(colorScheme).opacity(ToolbarRowLayout.keepsSolidBase || !usesMaterial ? 1 : 0))
                .overlay {
                    if usesMaterial {
                        Capsule()
                            .fill(.regularMaterial)
                            // 顶部高光（同卡片材质）：让胶囊有一点"厚度"，不是一块平色
                            .overlay(
                                Capsule().fill(
                                    LinearGradient(colors: [Color.white.opacity(0.07), Color.clear],
                                                   startPoint: .top, endPoint: .center)
                                )
                            )
                    }
                }
                // ⚠️ 材质 ↔ 实色这一下必须"瞬时"（别被抽屉的 `withAnimation(0.2)` 裹上动画）
                .transaction { $0.disablesAnimations = true }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .environment(\.toolbarContainerWidth, availableWidth)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 12)
        .modifier(LiquidGlassCapsule(enabled: usesLiquidGlass))
        .background { barBackground }
        // 液态玻璃自带边缘高光；材质 / 实色底才需要这一圈细线
        .overlay { if !usesLiquidGlass { Capsule().strokeBorder(Theme.hairline) } }
        .popupShadow()
        // 胶囊本身的范围：缩略图 / 卡片的双击监听要避开它（它浮在滚动内容上面，见 `DoubleClickRegion`）
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            if reportsFrame { app.workspaceToolbarFrame = $0 }
            onFrame?($0)
            capsuleWidth = $0.width
        }
        .onDisappear { if reportsFrame { app.workspaceToolbarFrame = .zero } }
        // 16 只是"条太宽时"离窗口边缘的保底间距；平时条比窗口窄，由外层 frame 居中
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .padding(.bottom, 12)
        // 在**整个窗口**里居中（和弹窗对齐）：内容区比窗口中心偏右 `contentCenterOffset`，往左挪回来；
        // 抽屉打开且会碰到胶囊时再多挪一点让位（和抽屉同一个 0.2 秒动画）。主页多选条和项目里的工具条共用这里。
        .offset(x: -(AppWindowShellLayout.contentCenterOffset
                     + ToolbarRowLayout.drawerAvoidanceShift(containerWidth: containerWidth, capsuleWidth: capsuleWidth,
                                                              drawerOpen: drawerOpen)))
        .animation(.easeInOut(duration: 0.2), value: drawerOpen)
    }
}

/// 程序坞式悬停标签：与"放大后的图标顶"的间隙 + 标签自身的近似高度
/// —— `BarIconButton` 和 `CapsuleSegmented` **共用这两个数**，保证两处标签高度一致
/// （2026-09-17 用户实测：算法/常数不一致会让标签错位；间隙 4 嫌小，定 8）
private let dockLabelGap: CGFloat = 8
private let dockLabelHeight: CGFloat = 19

/// 底栏**等尺寸图标按钮**（2026-09-17 用户要求）：只留图标，固定 30×30。
///
/// 为什么去掉文字：文案长度不一（清除/导入/匹配/参数/提交、素材库/任务/设置）会让按钮宽窄不一，
/// 用户要求"每个按钮尺寸一样" —— 文字改到**悬停时弹出的标签**里（见下）。
/// 颜色只区分语义：`.destructive` 红（不可撤销）、`.prominent` 主题色（主操作）。
///
/// **程序坞式悬停**（2026-09-17 用户要求）：悬停时图标以**底边为锚向上放大**（不影响布局），
/// 并在放大后的图标上方弹出文字标签。放大用 `scaleEffect`（渲染期变换、不参与布局），
/// 所以条的尺寸仍然只由按钮的布局尺寸决定 ✓。
/// ⚠️ **不要再加 `.help()`** —— 会和自绘标签同时弹两个（系统 tooltip 有延迟，观感重复）。
struct BarIconButton: View {
    enum Kind { case normal, destructive, prominent }

    @Environment(\.colorScheme) private var colorScheme
    /// 悬停标签使用实色底：避免工具条 hover 时再叠一层动态材质，导致玻璃抽屉背景闪烁。
    private var hoverLabelFill: AnyShapeStyle {
        AnyShapeStyle(SolidTheme.overlay(colorScheme))
    }

    let icon: String
    let help: String
    var kind: Kind = .normal
    var isDisabled = false
    /// > 0 时在图标右上角显示红色计数（任务抽屉的进行中任务数）
    var badge: Int = 0
    /// true 时在图标右上角显示**橙色三角叹号**（有失败项；优先于计数显示）
    var hasFailure: Bool = false
    let action: () -> Void

    /// 图标槽位；**放大倍数从设置来**（`AppModel.dockHoverScale`，设置页「界面」可调）
    private let iconSize: CGFloat = 30
    private var hoverScale: CGFloat { CGFloat(app.dockHoverScale) }
    /// 🎯 2026-09-29 用户定：**悬停提示全部去掉**（想恢复改 `true`；标签排版代码原样留着）
    private let showsHoverLabels = false
    @Environment(AppModel.self) private var app
    @State private var hovered = false

    /// 标签相对按钮框顶部的偏移：贴在**放大后的图标顶**上方 4pt。
    /// ⚠️ **不能拿"框的顶"当图标顶**：图标（约 15pt）在 30 框里是居中的，框放大到 40.5 时
    /// 图标顶只到 ≈0、不是 −10.5 —— 用框算会让标签多悬空 10pt（2026-09-17 用户发现
    /// "分段开关那四个的标签位置和别的按钮不一样"，根因就是这里）。
    private var labelOffset: CGFloat {
        let glyph: CGFloat = 15                                    // SF Symbol 在 15pt 字号下的近似高度
        let iconTop = (iconSize - glyph) / 2                       // 图标在框内居中
        let magnifiedTop = iconSize - (iconSize - iconTop) * hoverScale   // 以框底为锚放大后的图标顶
        return magnifiedTop - dockLabelGap - dockLabelHeight       // 间隙 + 标签高（共用常量）
    }

    private var foreground: Color {
        switch kind {
        case .normal: return .primary
        case .destructive: return Theme.danger
        case .prominent: return Theme.accent
        }
    }

    private var dockActive: Bool { hovered && !isDisabled }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    // 2026-09-29 用户定：与批量条对齐（图标 15 → 20pt）
                    .font(.system(size: 20))
                    // **固定槽位**：所有按钮严格同尺寸（SF Symbols 各图标宽高不一，不固定就大小不一）
                    .frame(width: iconSize, height: 28)   // 2026-09-29 与批量条的盒子对齐（30×28）
                if hasFailure {
                    // 有失败项：橙色三角叹号（2026-09-18 用户要求）
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Theme.warning))
                } else if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.danger))
                }
            }
            .foregroundStyle(isDisabled ? Color.secondary : foreground)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            // 🎯 2026-09-29 用户定：悬停放大动画**去掉**（标签保留）。
            // 原来这里锚底边向上放大：.scaleEffect(dockActive ? hoverScale : 1, anchor: .bottom)
            // 程序坞式标签：悬停时弹出 —— 🎯 2026-09-29 用户定：**已关**（见 `showsHoverLabels`）
            .overlay(alignment: .top) {
                if dockActive && showsHoverLabels {
                    Text(help)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(hoverLabelFill))
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                        .fixedSize()
                        .offset(y: labelOffset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovered)
        }
        // 悬停高亮比 30×30 那一格**左右各宽 5pt**（2026-09-19 用户要求：图标小、点不准，
        // 触发区域"加宽"）。12pt 的按钮间距里只剩 2pt 死区；上下不加（用户明确"是加宽"）。
        // 2026-09-29 用户定：与批量条对齐（原来 expandX 5 / expandY 0，高亮块明显偏小）
        .buttonStyle(HoverHighlightButtonStyle(expandX: 10, expandY: 7))
        .disabled(isDisabled)
        .onHover { hovered = $0 }
    }
}

/// 通用**悬停高亮**按钮样式：悬停出现淡色圆角底，按下没有变化。
/// 给原本 `.plain` / `.borderless`（**一点悬停反馈都没有**）的按钮用，让全 App 按钮行为一致。
/// 系统样式的按钮（`.bordered` / `.borderedProminent`）自带反馈，不用套这个。
struct HoverHighlightButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    /// 按钮在内容外再撑开的边距（pt）——高亮块和可点/可悬停范围**一起变大**。
    /// 太大在紧凑的行里可能挤到换行，看着不对就调小这一对数字。
    var expandX: CGFloat = 8
    var expandY: CGFloat = 4
    /// 悬停高亮的底色。默认 `Color.secondary` 只适用于**深色底**：
    /// 深色模式下 secondary 是近白色，压在白底浮层上等于没有高亮（选择模式的删除条实测"没反应"）。
    /// 白底浮层必须显式传深色，如 `highlight: .black.opacity(0.08)`。
    var highlight: Color = Color.secondary.opacity(0.12)

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, cornerRadius: cornerRadius,
                  expandX: expandX, expandY: expandY, highlight: highlight)
    }

    private struct HoverBody: View {
        let configuration: HoverHighlightButtonStyle.Configuration
        let cornerRadius: CGFloat
        let expandX: CGFloat
        let expandY: CGFloat
        let highlight: Color

        @State private var hovered = false
        /// 禁用态不给悬停高亮——否则灰掉的按钮看着还像能点
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                // 先撑开，再铺高亮：这样高亮块和命中/悬停范围严格一致，不会出现"看着能点其实点不到"
                .padding(.horizontal, expandX)
                .padding(.vertical, expandY)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(hovered && isEnabled ? highlight : Color.clear)
                )
                // ⚠️ 按下**不做任何变化**（原来是变透明 0.6 + 缩 0.98）：一次点击只有几十毫秒，
                // 按下变暗、松手弹回看着就是"点击区域闪一下"（2026-10-08 用户）。
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// 纯 SwiftUI 的分段切换（胶囊）—— **底栏专用**，替代 `NSSegmentedControl`。
///
/// 为什么不用 `SegmentedBar`（那个包的就是 NSSegmentedControl）：**AppKit 控件永远画在
/// SwiftUI 浮层之上** —— 顶栏那个生图/生视频当年就为此专门挂了一层罩子（见 RootView 的历史注释）。
/// 搬到工作区底栏后，弹窗/抽屉会盖住整窗，AppKit 分段控件会浮在弹窗上面穿帮 ✗，
/// 所以这里用纯 SwiftUI 自绘：外观是「胶囊底 + 选中段高亮」，行为等价。
/// ⚠️ 选中/未选中的**字重保持一致**（都用 regular）—— 改字重会改文字宽度，
/// 切换时整条会左右跳一下（同顶栏"图标固定槽位"那条教训）。
/// 在两份工作区底栏之间交接悬停目标，但不触发 AppModel Observation。
@MainActor
private enum CapsuleHoverMemory {
    static var mode: Int?
    static var style: Int?
}

struct CapsuleSegmented<Value: Hashable>: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 悬停标签使用实色底，避免与玻璃抽屉/工具条叠加采样。
    private var hoverLabelFill: AnyShapeStyle {
        AnyShapeStyle(SolidTheme.overlay(colorScheme))
    }

    struct Option {
        let icon: String
        /// 段内文字。**nil = 只显示图标**（底栏要求所有按钮等尺寸，2026-09-17）
        var title: String? = nil
        /// 悬停提示（图标模式下的说明；给了 title 时可省）
        var help: String? = nil
        let value: Value
    }

    /// 悬停态存哪个槽（跨底栏实例共享）
    enum HoverSlot { case mode, style }

    let options: [Option]
    @Binding var selection: Value
    let hoverSlot: HoverSlot
    /// 图标模式的**单段宽度**（默认 30：与 `BarIconButton` 同宽）。
    /// 2026-09-29 用户定：页头那组「卡片 / 详情」要更宽 → 传 40。
    let iconSegmentWidth: CGFloat
    /// 图标模式的**图标字号**（默认 14；2026-09-29 底栏「生图/生视频」要跟批量条一样大 → 传 18）
    let iconFontSize: CGFloat

    @Environment(AppModel.self) private var app
    @State private var localHoveredIndex: Int?

    /// 选中块的滑动命名空间（2026-09-19）：选中块的 `matchedGeometryEffect` 用它，
    /// 换段时同一个"块"从旧段补间到新段。**每个实例一份**（生图/生视频两个开关各滑各的）。
    @Namespace private var selectionPill

    /// **选中块的本地位置**（2026-09-19 补）：滑动的动画只作用于它，外部 `selection`
    /// 照调用点原来的节奏切（该瞬时还是瞬时）。
    ///
    /// ⚠️ **别把 `withAnimation` 直接包在 `selection = ...` 上**（第一版就是这么写的）：
    /// 那会让这次切换的**所有布局变化**都带上动画 —— 而"卡片 ↔ 详情"切换会**插/拔右侧翻页栏**，
    /// 内容宽度跟着变，于是整页跟着滑一下（用户实测："切换视图的时候页面怎么也滑动起来了"）。
    @State private var pillSelection: Value

    init(options: [Option], selection: Binding<Value>, hoverSlot: HoverSlot,
         iconSegmentWidth: CGFloat = 30, iconFontSize: CGFloat = 14) {
        self.options = options
        self._selection = selection
        self.hoverSlot = hoverSlot
        self.iconSegmentWidth = iconSegmentWidth
        self.iconFontSize = iconFontSize
        self._pillSelection = State(initialValue: selection.wrappedValue)
    }

    /// hover 只改当前控件的局部状态，跨工作区交接则使用非观察缓存。
    private var hoveredIndex: Int? { localHoveredIndex }

    private func setHoveredIndex(_ value: Int?) {
        localHoveredIndex = value
        switch hoverSlot {
        case .mode: CapsuleHoverMemory.mode = value
        case .style: CapsuleHoverMemory.style = value
        }
    }

    private func rememberedHoveredIndex() -> Int? {
        switch hoverSlot {
        case .mode: CapsuleHoverMemory.mode
        case .style: CapsuleHoverMemory.style
        }
    }

    private var hoverScale: CGFloat { CGFloat(app.dockHoverScale) }
    /// 🎯 2026-09-29 用户定：**悬停提示全部去掉**（同 `BarIconButton`；想恢复改 `true`）
    private let showsHoverLabels = false

    /// 标签偏移：贴在**放大后的图标顶**上方 4pt（几何算法同 `BarIconButton`，见那边的注释——
    /// 两边必须同款算法，否则标签高度对不齐，2026-09-17 用户实测）
    private var labelOffset: CGFloat {
        let segmentHeight: CGFloat = 24
        let glyph: CGFloat = 14                                    // SF Symbol 在 14pt 字号下的近似高度
        let iconTop = (segmentHeight - glyph) / 2
        let magnifiedTop = segmentHeight - (segmentHeight - iconTop) * hoverScale
        return magnifiedTop - dockLabelGap - dockLabelHeight       // 间隙 + 标签高（共用常量）
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                // 视觉（选中块 + 图标颜色）跟**本地**位置走 → 块滑动时颜色一起过渡
                let isSelected = option.value == pillSelection
                Button {
                    guard option.value != selection else { return }
                    // ① 先让选中块滑（只动本地状态，动画不外溢到页面布局）
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        pillSelection = option.value
                    }
                    // ② 外部状态照常切：调用点自己决定要不要动画
                    //（生图/生视频那个 setter 自带 withAnimation 做工作区交叉淡入；
                    //  卡片/详情则是瞬时的 —— 页面布局变化不该跟着块一起滑）
                    selection = option.value
                } label: {
                    segmentLabel(option, isSelected: isSelected, isHovered: hoveredIndex == i)
                }
                .buttonStyle(QuietButtonStyle(hover: .none))
                .accessibilityLabel(option.title ?? option.help ?? option.icon)
                .onHover { inside in
                    if inside { setHoveredIndex(i) }
                    else if hoveredIndex == i { setHoveredIndex(nil) }
                }
            }
        }
        // 外部改了 `selection`（开项目设模式、其它入口改样式）→ 本地块**瞬时**跟上
        .onChange(of: selection) { _, newValue in
            if pillSelection != newValue { pillSelection = newValue }
        }
        .onAppear { localHoveredIndex = rememberedHoveredIndex() }
        .onChange(of: app.workspaceMode) { _, _ in
            localHoveredIndex = rememberedHoveredIndex()
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.06))
        )
    }

    /// 段内容：有 `title` 走「图标 + 文字」；**没有 title 走等尺寸图标模式**
    /// （30×24 + 胶囊内 3pt 垫边 = 整条 30 高，与 `BarIconButton` 的 30×30 同高）。
    /// 图标模式带**程序坞式悬停**：只放大图标（选中底块不动）+ 上方弹标签 —— 同 `BarIconButton`。
    @ViewBuilder
    private func segmentLabel(_ option: Option, isSelected: Bool, isHovered: Bool) -> some View {
        if let title = option.title {
            HStack(spacing: 5) {
                Image(systemName: option.icon)
                    .frame(width: 16, height: 16)
                Text(title).lineLimit(1)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // 选中段：**蓝底白字**（2026-09-17 用户要求 —— 系统分段控件在 macOS 27 只剩灰的，
            // 自绘之后可以精确做成蓝色，见当初"以后想变回蓝色就自绘"那条结论）
            .foregroundStyle(isSelected ? Theme.onAccent : Color.secondary)
            .background {
                // 选中块挂 matchedGeometryEffect：换段时**滑动**过去（2026-09-19）。
                // 只在选中段存在这一块；换段瞬间旧块被移除、新块插入，同 id → SwiftUI 补间几何。
                // ⚠️ **别给选中块加 `.transition(.identity)`**：实测那会把补间一并禁掉（变回瞬跳）。
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent)
                        .matchedGeometryEffect(id: "selection", in: selectionPill)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack {
                // 选中底块**不参与放大**（放大的是图标本身）；跨段滑动同上
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.accent)
                        .matchedGeometryEffect(id: "selection", in: selectionPill)
                }
                Image(systemName: option.icon)
                    .font(.system(size: iconFontSize))
                    .foregroundStyle(isSelected ? Theme.onAccent : Color.secondary)
                    // 🎯 2026-09-29 用户定：悬停放大动画**去掉**（标签保留）。
                    // 原来：.scaleEffect(isHovered ? hoverScale : 1, anchor: .bottom)
                    //      + .animation(.spring(response: 0.26, dampingFraction: 0.72), value: isHovered)
            }
            .frame(width: iconSegmentWidth, height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            // 🎯 2026-09-29 用户定：悬停提示**已关**（见 `showsHoverLabels`）
            .overlay(alignment: .top) {
                if isHovered && showsHoverLabels {
                    Text(option.help ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(hoverLabelFill))
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
                        .fixedSize()
                        .offset(y: labelOffset)   // 贴在放大后的图标上方（算法见 `labelOffset`）
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
            }
        }
    }
}

/// 底栏左侧的**工作区开关组**：生图/生视频 +（仅生视频的）卡片/缩略图。
/// 两个工作区各有一份底栏，用这个组件保证两边的开关位置/样式完全一致。
/// **只显示图标**（2026-09-17 用户要求：所有按钮等尺寸）——文字说明在悬停提示里。
struct WorkspaceSwitches: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        // 🆕 2026-10-03（用户定）：生图/生视频切换**已搬到页头**（原"卡片/缩略图"的位置）；
        // 这里不再有任何开关，保留空组件以免动两处底栏的调用点。
        EmptyView()
    }
}

/// 选中工具条里的图标按钮（20pt 图标、固定 30×28 的盒子、悬停高亮）。
/// 项目里的批量条和主页的多选条**共用**（2026-10-08 用户："主页多选条怎么和项目里的不一样"）——别在两处各画各的。
struct SelectionBarIconButton: View {
    let icon: String
    var color: Color? = nil
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color ?? Color.primary)
                // 按钮统一盒子大小（2026-09-26 用户："按钮怎么不一样大"）
                .frame(width: 30, height: 28)
        }
        // 悬停高亮 + 更大的触发区：expandX/Y 一起撑大高亮块和命中范围
        .buttonStyle(HoverHighlightButtonStyle(expandX: 10, expandY: 7))
        .help(help)
    }
}

/// 选中工具条里的「取消」（退出选择模式），同上共用
struct SelectionBarCancelButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("取消")
                .frame(width: 30, height: 28)
        }
        .buttonStyle(HoverHighlightButtonStyle(expandX: 10, expandY: 7))
        .foregroundStyle(.primary)
        .help("退出选择模式")
    }
}

/// 工作区底栏（生图/生视频共用）—— 悬浮胶囊条的内容布局（2026-09-17 定）：
///
/// `[开关组] [批量操作（各工作区自己传）]` —— 导航和抽屉入口位于全局左栏。
/// **所有条目等间距、平均分布**（不再用分隔线/Spacer 分组；条宽由按钮总宽决定，见 `ToolbarRow`）。
/// 所有按钮都是等尺寸图标按钮（`BarIconButton` / 图标模式分段）。
///
/// 抽屉打开时胶囊会往左让位，不被抽屉盖住（2026-10-08，见 `ToolbarRowLayout.drawerAvoidanceShift`）。
struct WorkspaceBar<Actions: View>: View {
    @Environment(AppModel.self) private var app
    /// 选中态时**整条替换**成的内容（2026-09-27：工具条随选中态换内容）——nil = 没有这个功能。
    /// ⚠️ 用 `AnyView`、并且和 `actions` 在**同一个 `ToolbarRow` 里**：两条分支如果视图类型不同
    ///（`WorkspaceBar` vs `ToolbarRow`），SwiftUI 会整棵换掉，**宽度动画不跟手**
    ///（2026-09-27 用户："看着没区别"）。同一个 ToolbarRow 里换内容，宽度才会弹簧收放。
    ///
    /// ⚠️ 两份内容**常驻**、居中叠放，靠透明度切换（`showsSelection`），不是 `if / else` 插入移除：
    /// 开着液态玻璃时，被移除的那一份会挂在胶囊的**左边缘**上，胶囊从两边收窄，它就跟着往右滑再淡出
    ///（2026-10-10 用户发现，逐帧抓过）。胶囊宽度改成按两份内容各自量出来的宽度做弹簧动画。
    ///
    /// ⚠️ 声明顺序是有意的：这两个必须在 `actions` **前面** —— 成员初始化器的参数顺序跟着声明走，
    /// 尾随闭包只认最后一个参数；放在后面的话 `WorkspaceBar(selectionContent:) { ... }` 编译不过。
    var selectionContent: AnyView? = nil
    var showsSelection = false
    @ViewBuilder var actions: Actions

    @State private var normalWidth: CGFloat = 0
    @State private var selectionWidth: CGFloat = 0

    /// 胶囊里内容区现在该有多宽（还没量到 = 按内容自然宽）
    private var targetWidth: CGFloat? {
        let width = showsSelection ? selectionWidth : normalWidth
        return width > 0 ? width : nil
    }

    var body: some View {
        ToolbarRow {
            HStack(spacing: 12) {
                WorkspaceSwitches()
                actions
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { normalWidth = $0 }
            .opacity(showsSelection ? 0 : 1)
            .disabled(showsSelection)                       // 藏起来的那份不能再响应点击 / 快捷键
            .accessibilityHidden(showsSelection)
            .frame(width: targetWidth)
            // 批量按钮叠在上面（overlay 不参与尺寸；居中）
            .overlay {
                if let selectionContent {
                    selectionContent
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { selectionWidth = $0 }
                        .opacity(showsSelection ? 1 : 0)
                        .disabled(!showsSelection)
                        .accessibilityHidden(!showsSelection)
                }
            }
        }
        // 换内容时的过渡（2026-09-27 用户要的）：胶囊**宽度弹性收放** + 新旧内容交叉淡入。
        // 手感：spring 0.32 / 0.8 ≈ 轻微回弹；想更"稳"就换 `easeInOut(0.2)`（无回弹）。
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: showsSelection)
    }
}

/// 全局「刚刚在滚动」标记 —— 专门给**悬停预览**用。
///
/// **要解决的问题**（用户 2026-09-12 反馈"滑动发涩、一顿一顿"）：
/// 用触控板滚动时**鼠标光标一直悬在卡片上** ✓，于是悬停判断照常跑 ✓ →
/// 大缩略图弹窗会在**滚动过程中被排上队、甚至真弹出来** ✗ —— 而它是个独立的 `NSPanel`
/// 加一段 spring 入场动画 ✗✓，等于在滚动的那几帧里抢合成资源 ✓
///
/// **用户定的语义**：弹窗只在**静止**时才有意义（而且本来就要求停够 0.2~0.3 秒才弹）✓
/// 所以只要"滚动一发生就把待触发的弹出作废" ✓ 语义自然成立 ✓（配合 `HoverPreviewPanel.hide()`
/// 里那句 `pendingShow?.cancel()` ✓）
///
/// **实现**：一个全局 `.scrollWheel` 本地监听 ✓（`addLocalMonitorForEvents` 在主线程回调 ✓），
/// 每次只写一个 `Date` ✓ 开销可忽略 ✓
@MainActor
final class ScrollActivity {
    static let shared = ScrollActivity()

    /// **正在进行一次滚动** —— 由 `NSScrollView` 的 `willStartLiveScroll` / `didEndLiveScroll`
    /// 通知**精确维护** ✓（SwiftUI 的 ScrollView 底层就是 NSScrollView ✓ 触控板滚动走的就是 live scroll ✓）
    private var liveScrolling = false
    /// 兜底：最近一次滚动事件的时间（惯性滚动、非 live scroll 不保证配一对通知 ✓）
    private var lastScrollAt = Date.distantPast
    /// 兜底的宽限（秒）。**必须很短** —— 用户 2026-09-12 明确要求"静止就立即开始监听" ✓
    /// ⚠️ 第一版写的是 0.45 秒，**那是错的** ✗：滚动停下后悬停高亮要等半秒才回来 ✗，
    /// 手感上是"卡住了" ✓ 而弹窗本身自带 0.22 秒延迟 ✓ 不需要靠它来压 ✓
    private let safetyLinger: TimeInterval = 0.12

    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?

    /// 最近是否在滚动
    var isScrolling: Bool {
        liveScrolling || Date().timeIntervalSince(lastScrollAt) < safetyLinger
    }

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrolling = true }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.liveScrolling = false
            }
        })
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // 本地监听一定在主线程回调 ✓ —— 这里只是把这个事实告诉编译器
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastScrollAt = Date()
            }
            return event      // ⚠️ **必须原样返回**，别把滚动事件吞掉 ✗
        }
    }
}


/// 悬停放大预览浮层（NSPanel：浮在所有视图之上，跟随触发位置、不被相邻卡片遮挡）
///
/// ## ⚠️ 核心约束：**面板的 frame 永远不动，动画全部交给 SwiftUI 内容**
///
/// 早期版本用 AppKit 的 `animator()` 直接动画面板 frame（缩放 + 位移），在"快速切换素材"时
/// 连续踩了一串同类竞态（2026-09-12 实测五轮）：
///   · 动画被打断后 frame 停在中间态 → **越滑越靠下、越来越小**；
///   · 退场收尾的 `orderOut` 把刚弹出来的新面板收掉 → **滑到下一张不弹**；
///   · 退场把 alpha 降到 0 后收尾被跳过 → 面板卡在"可见但全透明" → **彻底不弹**；
///   · 反复打断让 frame 停在非目标位置 → **位置变高/变偏**。
/// 这些全是"异步动画 + 状态在回调之间被改写"导致的，靠加标志位补不干净。
///
/// 现在 frame 只在 `show` 里**直接赋值一次**、此后不参与任何动画，位置物理上不可能漂移；
/// 入场（从素材那一侧弹上来）与退场（缩回淡出）全由 `HoverPreviewContent` 的 SwiftUI spring
/// 驱动 —— 它支持打断重放：每次切换都是一次完整、方向一致的入场。
@MainActor
final class HoverPreviewPanel {
    static let shared = HoverPreviewPanel()
    private var panel: NSPanel?

    /// 待执行的退场（悬停意图去抖）
    private var pendingHide: DispatchWorkItem?

    /// 待执行的**弹出**（悬停触发延时），见 `hoverDelay`
    private var pendingShow: DispatchWorkItem?

    /// 悬停**触发**延时：面板还没显示时，鼠标得在同一处停够这么久才弹。
    ///
    /// 用户 2026-09-12 定标："增加鼠标悬停时长才会触发弹窗"。调的历程：0.8 → 0.5 → 0.3 → 0.4 → **0.22**。
    /// 目的是**划过去不弹、停下来才弹**：之前只要鼠标扫过缩略图就会弹，浏览时满屏乱闪。
    ///
    /// **每一张都要重新计时**（包括面板已经显示着、滑到下一张时）——
    /// 用户明确要求："快速滑到第二张时，没有延时触发，而是立即触发"是**不对**的。
    /// 所以滑动途中，面板会**停在上一张已经停留过的那张**上，直到在新的那张停够时长才换过去。
    /// 中途移开会被 `hide()` 取消计时。
    private let hoverDelay: TimeInterval = 0.22

    /// 内容状态。**整个生命周期只有这一个**，`contentViewController` 也只设一次 ——
    /// 理由见 `show` 里那段"为什么不再每次重设 VC"。
    private let state = HoverPreviewState()

    /// **弹出 / 弹回共用的时长**（用户 2026-09-12："弹出改成和弹回一样"）。
    ///
    /// 两边都从这里取，**改一个数就同时改两个** —— 这个项目踩过
    /// "同一个量在两处各写一遍、早晚漂移"的坑（滑块与刻度那次），所以合成一个常量。
    /// 曲线是镜像的：入场 `easeOut`（快起慢收）、退场 `easeIn`（慢起快收），
    /// 这样一进一出节奏对称，不会一个"急刹"一个"猛冲"。
    ///
    /// （原来入场是 `spring(0.45, 0.84)`，实际要 ~0.41s 才停 —— 比退场长得多，用户嫌不对称。）
    private let popDuration: TimeInterval = 0.12

    /// 把内容扳回起点姿态之后、真正开播入场动画之前的等待。
    /// **必须大于一帧**（60Hz ≈ 16.7ms）：否则 SwiftUI 会把"回起点 + 播动画"合并进同一帧，
    /// 动画就从**半途的值**接着跑、时长被压缩 —— 快速来回滑时表现为"弹出时长变短"。
    private let popStartDelay: TimeInterval = 0.02

    /// `show` 的代次。退场延时收尾时用它判断"这期间有没有新的 show 进来" ——
    /// 有的话就放弃本次 orderOut，否则会把刚弹出来的新面板收掉。
    /// （用代次而不是 `state.appeared`：新 state 的 appeared 要等 `onAppear` 才置 true，
    ///   在那之前读到的还是 false，会误判成"没在显示"。）
    private var generation = 0

    /// 退场去抖时长。鼠标从 A 划到 B 时会**掠过中间的空隙**，那一刻会收到一次 hide ——
    /// 立刻执行的话退场当场开播，人还没到 B 就已淡了一半，看着就是
    ///"上一个还没关就切到下一个了"（用户 2026-09-12 实测）。
    /// 压这么一小段，期间只要有新的 show 进来就把退场整个取消。
    /// （只需覆盖"掠过空隙"那几十毫秒，所以不用长。）
    private let hideDelay: TimeInterval = 0.06

    /// ⚠️ **"鼠标滑开到面板消失"是个总时长预算，等于这三段之和**：
    /// `hideDelay + popDuration + 0.02` = 0.06 + 0.12 + 0.02 = **0.20s**（用户 2026-09-12 定标）。
    /// 调总时长时要**回头改这两个常量**，改一个不够。
    /// （`popDuration` 同时管入场和退场，见上。）

    /// 弹窗的**固定宽度**：取 9:16 竖图的宽度。原来是"长边固定 280"，于是竖图窄、横图宽，
    /// 尺寸不统一；用户 2026-09-12 定标："不管是 16:9 还是 1:1 还是 3:4 还是 4:3，宽度都是一样的，
    /// 然后高度等比例缩小" —— 所以现在**宽恒定、高 = 宽 ÷ 比例**。
    /// 折算：16:9 → 158×89 ｜ 1:1 → 158×158 ｜ 4:3 → 158×118 ｜ 3:4 → 158×211 ｜ 9:16 → 158×281。
    private let fixedWidth: CGFloat = 158

    /// 高度上限。用户导入的素材不受 9:16 约束，极端竖长图会算出很大的高度、把面板撑出屏幕。
    /// 超上限时按这个高度、**宽度内留边**（内容用 `.fit`，会自己加边），而不是破坏"宽度固定"这条。
    private let maxHeight: CGFloat = 420

    /// 内容与触发素材之间的**间距**（面板在上方时是"内容底边距素材顶边"，翻到下方时对称）。
    /// **想让它离素材更远就调大这个数** —— 用户 2026-09-12："最终位置再加一些"（原值 4 太贴）。
    private let gap: CGFloat = 12
    private let inset: CGFloat = 6
    /// 内容四周的**透明留白**：给入场动画留空间 —— 入场时内容会缩到 96% 并**下移 14pt**
    ///（从素材那一侧弹上来），不留白的话底部会被面板边缘裁掉。
    private let margin: CGFloat = 24


    func show(image: NSImage, above screenRect: NSRect) {
        // 有排着队的退场就取消它：鼠标只是从 A 划向 B、中途掠过了空隙，
        // 并不是真的要离开（这就是 A→B 不闪的关键）
        pendingHide?.cancel()
        pendingHide = nil

        // ⚠️ **每一张都重新计时**，包括面板已经显示着的情况 ——
        // 用户 2026-09-12 实测反馈："快速滑到第二张时立即触发"是不对的，要同样延时。
        // 所以这里**故意不做"已显示就立即换"的优化**（那会让第二张享受不到延时）。
        // 代价：滑动途中面板会停在上一张上，直到在新的那张停够 `hoverDelay`。
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performShow(image: image, above: screenRect)
        }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: work)
    }

    /// 真正把面板摆好并播放入场（`show` 计时结束、或已在显示时直接调到这里）
    private func performShow(image: NSImage, above screenRect: NSRect) {
        pendingShow = nil

        // 布局/窗口刚出现时，AppKit 可能补发短暂的 onHover 进入事件；
        // 仅靠 show() 的延时去抖不够，因为有些视图在消失前不会及时送出退出事件。
        // 真正弹窗前再确认应用仍在前台、鼠标仍停在触发图上，避免启动时在屏幕边缘闪一下。
        let mouseLocation = NSEvent.mouseLocation
        let startupMilliseconds = StartupClock.ms()
        guard startupMilliseconds >= 2_500,
              NSApp.isActive,
              screenRect.contains(mouseLocation) else {
            AppLog.write(
                "hoverPreview",
                "取消过期悬停预览 startup=\(startupMilliseconds)ms active=\(NSApp.isActive) mouse=(\(Int(mouseLocation.x)),\(Int(mouseLocation.y))) anchor=\(NSStringFromRect(screenRect))"
            )
            return
        }

        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return }
        // **宽度固定、高度按比例**（见 `fixedWidth` 的注释）。
        // 原来按"长边固定"算，所以竖图窄、横图宽；换成固定宽度后各比例的弹窗左右边界就齐了。
        let ratio = imgSize.width / imgSize.height
        let display = NSSize(width: fixedWidth, height: min((fixedWidth / ratio).rounded(), maxHeight))
        let contentSize = NSSize(width: display.width + inset * 2, height: display.height + inset * 2)
        // 画布**紧贴内容**（只多一圈给入场动画用的留白）—— 内容正好填满画布，
        // 于是"内容底边 = 触发元素上方 4pt"这个关系对横图竖图都成立。
        let panelSize = NSSize(width: contentSize.width + margin * 2, height: contentSize.height + margin * 2)
        generation += 1   // 让所有"排着队的退场收尾"失效（见 hide()）

        // ⚠️ **先让内容隐去，再改几何**：内容此刻可能正显示着上一张图，
        // 不先隐去的话下面 setFrame 的尺寸/位置变化会被看见（闪一下）。
        // 用 `disablesAnimations` 确保这一下是**立刻**归零、不是又起一段短动画
        //（若正有入场动画在跑，普通赋值会从当前值继续动画，同样会压缩时长）。
        var resetTxn = Transaction()
        resetTxn.disablesAnimations = true
        withTransaction(resetTxn) { state.appeared = false }

        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .floating
            p.ignoresMouseEvents = true   // 不抢鼠标，避免与 onHover 抖成闪烁
            // ⚠️ `contentViewController` **只在这里设一次，之后再也不动**。
            //
            // 之前是每次 show 重设一个新 VC（为了让入场动画重播），代价是：
            // AppKit 会按"内容变了"重排窗口 —— 实测每设一次窗口就往**上顶一整个面板高度**
            //（日志：设 VC 前 y=812，设完 y=1030），再靠 setFrame 拉回来。
            // 而这一顶一拉发生在入场动画播放期间，用户看到的就是**面板从别处飞过来**。
            // 现在内容变化全部走 `state`（@Published），VC 不动、窗口尺寸也不动（固定画布），
            // AppKit 就没有任何理由去重排窗口了。
            p.contentViewController = NSHostingController(
                rootView: HoverPreviewContent(state: state, inset: inset)
            )
            panel = p
        }
        guard let panel else { return }

        // 定位：**内容**优先贴在触发元素正上方，上方空间不足翻到下方；左右不出屏。
        // 面板紧贴内容，所以由内容位置直接推出面板原点。
        let screen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: screenRect.midX, y: screenRect.midY))
        } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var placedAbove = true
        var contentY = screenRect.maxY + gap
        if contentY + contentSize.height > visible.maxY {
            placedAbove = false
            let below = screenRect.minY - contentSize.height - gap
            contentY = below >= visible.minY ? below : max(visible.minY + gap, visible.maxY - contentSize.height - gap)
        }
        var contentX = screenRect.midX - contentSize.width / 2
        contentX = max(visible.minX + 4, min(contentX, visible.maxX - contentSize.width - 4))

        let panelRect = NSRect(x: contentX - (panelSize.width - contentSize.width) / 2,
                               y: contentY - (panelSize.height - contentSize.height) / 2,
                               width: panelSize.width, height: panelSize.height)
        panel.setFrame(panelRect, display: false)

        // 换内容 + **重播入场**。
        state.image = image
        state.displaySize = display
        state.panelSize = panelSize
        // 入场起点永远在**素材那一侧**：面板在上方就从下面弹上来，翻到下方就从上面落下来。
        state.popOffset = placedAbove ? 14 : -14

        // 先准备好内容再显示新面板。否则首次 orderFront 会把透明空面板露一帧，
        // 玻璃预览紧贴抽屉时看起来像抽屉背景突然闪白/闪透。
        if !panel.isVisible { panel.orderFront(nil) }

        // ⚠️ 必须**真的跨一帧**再播动画。
        // `DispatchQueue.main.async` 很可能落在同一帧内 —— SwiftUI 只看到"终态"这一个变化，
        // 于是从**半途的值**接着动画，剩余时长变短：快速来回滑时就是"弹出时长也变短了"
        //（用户 2026-09-12 实测）。下面那个 asyncAfter 保证上一行的 `appeared = false`
        // 已经被渲染出来，弹簧才会老老实实从起点跑满全程。
        DispatchQueue.main.asyncAfter(deadline: .now() + popStartDelay) { [state, popDuration] in
            // `easeOut`：快起慢收，是退场 `easeIn` 的镜像（见 popDuration 的注释）
            withAnimation(.easeOut(duration: popDuration)) {
                state.appeared = true
            }
        }
    }

    /// 退场：内容**缩回 + 淡出**着离开（不是原地"啪"地消失）。
    /// 参数对齐素材库预览关闭时的 `scale 0.97 / offsetY 8 / easeIn 0.14`，但同样**只动内容**。
    func hide() {
        // 还没弹出来就被移开 → 取消那次待触发的弹出（"停够才弹"靠这一步成立）
        pendingShow?.cancel()
        pendingShow = nil
        guard panel?.isVisible == true else { return }
        // 去抖：不立刻收，压 `hideDelay`。期间若来了新的 show 就整个取消（见 show 的开头）——
        // 鼠标从 A 划到 B 必然掠过空隙、必然先收到一次 hide，不压这一下就会"上一个还没关就切到下一个"。
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let gen = self.generation

            withAnimation(.easeIn(duration: self.popDuration)) {
                self.state.appeared = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.popDuration + 0.02) { [weak self] in
                guard let self, let panel = self.panel else { return }
                // 期间又 show 过 → 这面板已经归新的那次 show 了，别收
                guard self.generation == gen else { return }
                panel.orderOut(nil)
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: work)
    }
}

/// 悬停浮层的内容状态：**整个生命周期只建一个**（`contentViewController` 也只挂一次）。
/// 换图靠改这里的属性，而不是换视图 —— 换视图会让 AppKit 重排窗口、位置就漂了。
@MainActor
private final class HoverPreviewState: ObservableObject {
    @Published var image: NSImage?
    @Published var displaySize: NSSize = .zero
    /// 画布尺寸（= 内容 + 四周留白，**紧贴内容、不固定**）。
    /// 早先为了让窗口尺寸恒定试过固定画布，结果是"内容在画布中央、竖图横图留白不同 → 看着靠下"。
    /// 现在 `contentViewController` 只挂一次、窗口尺寸变化不再触发 AppKit 重排，所以可以紧贴。
    @Published var panelSize: NSSize = .zero
    /// 入场起点的纵向偏移：**正数 = 起点在下（向上弹），负数 = 起点在上（向下落）**。
    ///
    /// 面板优先放在素材上方、放不下时翻到下方；翻到下方时如果还用固定的 +14，
    /// 就成了"从更下面弹上来"——竖图（高、容易翻下去）看着就是**往下弹**（用户 2026-09-12 实测）。
    /// 所以偏移必须跟着面板实际在哪一侧走，永远"从素材那一侧冒出来"。
    @Published var popOffset: CGFloat = 14
    /// 入场/退场的**唯一**开关，由 `HoverPreviewPanel` 在 show/hide 里驱动。
    @Published var appeared = false
}

/// 悬停浮层的内容：**只负责渲染，不自己播动画**（动画由 `show` 驱动 `state.appeared`）。
///
/// 用 SwiftUI 的 spring 而不是 AppKit 的 `animator()`，是因为它天然支持"打断后重放"——
/// 快速在素材间滑动时，每次都是一次完整、方向一致的入场，
/// 而不会像动画面板 frame 那样留下中间态（那正是"越滑越靠下越小""位置变高"的成因）。
private struct HoverPreviewContent: View {
    @ObservedObject var state: HoverPreviewState
    let inset: CGFloat
    /// 面板画布尺寸（**紧贴内容** + 四周留白；见 `HoverPreviewState.panelSize`）
    var panelSize: NSSize { state.panelSize }

    var body: some View {
        Group {
            if let image = state.image, state.displaySize != .zero {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: state.displaySize.width, height: state.displaySize.height)
                    // 图片**自身**也要圆角：glassPanel 的 clipShape 只裁到外层（含 inset 内边距），
                    // 内缩的那张图仍是直角，四个角会在圆角面板里露出来（半径 = 面板 16 − 内边距 6）
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(inset)
                    // shadow: false —— 同样装在 NSPanel 里，阴影由面板自己画（见 DropdownPanel）
                    .glassPanel(cornerRadius: 14, shadow: false)
            }
        }
        // 入场姿态：**从素材那一侧（下方）14pt、96% 大小**弹上来
        //（`RootView.fadeInPreviewOverlay` 是这份参数的原版：scale 0.96→1 + offsetY 14→0）。
        // 这几个变换作用在内容自己的坐标系里，面板四周的 `margin` 留白正好容纳
        //"缩小 + 下移"的起点姿态，不会被画布边缘裁掉。
        .scaleEffect(state.appeared ? 1 : 0.96)
        .offset(y: state.appeared ? 0 : state.popOffset)
        .opacity(state.appeared ? 1 : 0)
        .frame(width: panelSize.width, height: panelSize.height)
    }
}

/// 标记「和左右同样标了的子视图紧挨着、中间不加 spacing」——提示词里被拆成小块的文字用
private struct FlowGlueKey: LayoutValueKey { static let defaultValue = false }

extension View {
    func flowGlue() -> some View { layoutValue(key: FlowGlueKey.self, value: true) }
}

/// 简单流式布局：子视图按行排列、放不下换行（提示词里文字与缩略图混排用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 5
    /// 一行里高矮不一的子视图（文字 17pt、缩略图 18pt）是否垂直居中；默认顶对齐
    var centersLines = false

    /// 每个子视图的理想尺寸只量一次（`sizeThatFits` 和 `placeSubviews` 都要用，文字块一多就是重复开销）
    struct Cache {
        var sizes: [CGSize] = []
        var glued: [Bool] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) }, glued: subviews.map { $0[FlowGlueKey.self] })
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews, cache: Cache) -> (frames: [CGRect], used: CGFloat, height: CGFloat) {
        var frames = [CGRect](repeating: .zero, count: subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, used: CGFloat = 0
        var lineStart = 0
        func closeLine(upTo end: Int) {
            guard centersLines else { return }
            for j in lineStart..<end { frames[j].origin.y += (lineH - frames[j].height) / 2 }
        }
        for (i, sv) in subviews.enumerated() {
            var w = cache.sizes[i].width, h = cache.sizes[i].height
            if w > maxWidth { w = maxWidth; h = sv.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil)).height }
            var gap: CGFloat = i == lineStart ? 0 : (cache.glued[i] && cache.glued[i - 1] ? 0 : spacing)
            if i > lineStart && x + gap + w > maxWidth {
                closeLine(upTo: i)
                y += lineH + lineSpacing; x = 0; lineH = 0; lineStart = i; gap = 0
            }
            frames[i] = CGRect(x: x + gap, y: y, width: w, height: h)
            x += gap + w
            lineH = max(lineH, h)
            used = max(used, x)
        }
        closeLine(upTo: subviews.count)
        return (frames, used, subviews.isEmpty ? 0 : y + lineH)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let result = arrange(maxWidth: proposal.width ?? 10000, subviews: subviews, cache: cache)
        return CGSize(width: proposal.width ?? result.used, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrange(maxWidth: bounds.width, subviews: subviews, cache: cache)
        for (sv, frame) in zip(subviews, result.frames) {
            sv.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                     anchor: .topLeading,
                     proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

/// 提示词里「文字与缩略图混排」的那几行，文字要拆成能自己换行的小块：
/// 一整段文字当一个不可拆的块，放不下就整块跳到下一行 —— 缩略图旁边剩一大片空白、文字被推到下面（用户 2026-10-08 报的"@ 素材保存后排版乱"）。
/// 拆法：中日韩文字**逐字**成块；英文/数字**整词**成块（不把单词劈开）；
/// 标点贴着前一块（句号逗号不出现在行首）、开括号/开引号贴着后一块（不出现在行尾）；空白贴在前一块后面。
/// 逗号句号后面的那个字也并进同一块：系统会把**一块文字末尾**的全角标点收窄半格，
/// 标点落在块末尾的话每个逗号都比编辑框里（连续排版）挤。
enum PromptTextPieces {
    private static let noLineStart = Set("，。、；：！？）】》〉〕」』”’,.;:!?)]}%…—·")
    private static let noLineEnd = Set("（【《〈〔「『“‘([{")

    /// 中日韩及全角字符：每个字自成一块（Unicode 2E80 起是 CJK 部首/符号/假名/汉字/谚文/全角形式）
    private static func isWide(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return v >= 0x2E80 || (0x2018...0x201D).contains(v)
    }

    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var currentIsWide = false
        var holdOpener = false      // 刚放进一个开括号：下一个字符不许另起一块
        var absorbNext = false      // 刚放进一个标点：后面紧跟的全角字符并进同一块（见上）
        func flush() { if !current.isEmpty { pieces.append(current); current = "" } }

        for ch in text {
            if ch.isWhitespace {
                absorbNext = false
                if !current.isEmpty { current.append(ch); flush() }
                else if !pieces.isEmpty { pieces[pieces.count - 1].append(ch) }
                else { current.append(ch) }
                continue
            }
            if noLineStart.contains(ch) && !holdOpener {
                if !current.isEmpty { current.append(ch); absorbNext = currentIsWide }
                else if !pieces.isEmpty { pieces[pieces.count - 1].append(ch) }
                else { current.append(ch); currentIsWide = isWide(ch); absorbNext = currentIsWide }   // 开头就是标点（缩略图后面的「，坐下」）
                continue
            }
            let wide = isWide(ch)
            if !current.isEmpty, !holdOpener, !(absorbNext && wide), wide || currentIsWide { flush() }
            absorbNext = false
            current.append(ch)
            currentIsWide = wide
            holdOpener = noLineEnd.contains(ch)
        }
        flush()
        return pieces
    }
}

/// 只读提示词展示（纯 SwiftUI 流式布局）：把「图N/视频N/音频N」token 渲染成独立缩略图视图。
/// 不含 NSViewRepresentable，SwiftUI 能自己确定并缓存高度 → 滚动时零桥接、零尺寸探测（滚动不卡）。
/// 图片是独立视图（不是 Text 内联图），所以支持鼠标悬停放大。
struct ReadonlyPromptText: View {
    @Environment(AppModel.self) private var app
    let text: String
    let slots: [SlotItem]
    /// 占位文案（如「（无提示词，点此编辑）」）：整体用灰色显示，和真实内容区分开
    var isPlaceholder: Bool = false
    /// 是否启用「悬停放大浮层」。预览弹窗里用 false —— 只要缩略图、鼠标移上去不弹东西。
    var enablesHover: Bool = true
    @State private var images: [String: NSImage] = [:]
    /// token → 这张缩略图**是从哪个源加载的**（本地路径或远程直链）。
    ///
    /// ⚠️ 光按 token 缓存是不够的：token 是「图1/图2」这种**位置编号**，
    /// 把图1换成另一张素材时 token 没变、`images["图1"]` 还在 ——
    /// 于是卡片上继续显示**上一张素材的缩略图**（用户 2026-09-12 实测：
    /// "加进去的素材和保存后看到的对不上"）。记下源、源变了就重载。
    @State private var imageSources: [String: String] = [:]
    /// 当前悬停的是**哪一个 token 出现**。
    ///
    /// ⚠️ **必须带下标、不能只记 token 字符串**：同一个 token 在提示词里可能出现多次
    ///（用户 @ 了两次同一个素材），只记 token 的话浮窗定位会查到"最后一次写入"的那个坐标 ——
    /// 表现为「两个一模一样的素材，浮窗都弹在同一个位置」（用户实测 2026-09-13）。
    @State private var hoveredSlot: HoveredSlot?

    private struct HoveredSlot: Equatable {
        let token: String
        /// 该 token 所在的 segment 下标（`ForEach` 的 `id: \.offset`）—— 同 token 的多次出现靠它区分
        let index: Int
    }

    /// 非观察缓存：屏幕坐标只在「悬停浮层定位」时读，body 里不用。
    /// 用普通 class 持有 → 写入不触发 SwiftUI 重算。**别换回 @State**：滚动时元素坐标每帧都在变，
    /// @State 每帧被写 → 视图反复标脏重算 → 掉帧（2026-09-11 sample 实锤的卡顿根因之一）。
    @State private var frames = FrameCache()
    /// 分行结果缓存：字符串搜索是滚动热点，内容没变就复用
    @State private var segmentCache = SegmentCache()

    private final class FrameCache {
        /// ⚠️ **按 segment 下标存，不按 token** —— 同一个 token 可能出现多次（见 `hoveredSlot`），
        /// 按 token 存会互相覆盖，浮窗全部定位到最后一次写入的位置。
        var byIndex: [Int: CGRect] = [:]
    }

    private final class SegmentCache {
        var text = ""
        var tokens: [String] = []
        var rows: [[RowItem]] = []
    }

    private enum Seg {
        /// 整段文字（这一行没有缩略图 → 让 Text 自己折行）
        case text(String)
        /// 文字拆出来的小块（这一行里有缩略图 → 文字要能在缩略图旁边接着排，见 `PromptTextPieces`）
        case piece(String)
        case token(String)
        /// 🆕 2026-10-03：显式换行（只读渲染按行排版用；旧版换行被 FlowLayout 吃掉 → "@ 素材保存后行错乱"）
        case newline
    }

    /// 🆕 行内条目（全局下标 + 段）——按 `.newline` 分行后每行一个数组；
    /// 全局下标保证同一 token 跨行出现时悬停定位也唯一（见 `hoveredSlot` 的说明）
    private struct RowItem: Identifiable {
        let id: Int
        let seg: Seg
    }

    /// 🆕 2026-10-03：按 `.newline` 把 segments 切成行（空白行保留成空行）。
    /// 🆕 2026-10-08：**带缩略图的行**里文字拆成小块（`.piece`），没有缩略图的行保持整段 `.text`（一个 Text 折行最省）。
    private static func makeRows(_ segments: [Seg]) -> [[RowItem]] {
        var lines: [[Seg]] = [[]]
        for seg in segments {
            if case .newline = seg { lines.append([]) } else { lines[lines.count - 1].append(seg) }
        }
        var nextID = 0
        return lines.map { line in
            let hasToken = line.contains { if case .token = $0 { true } else { false } }
            var items: [RowItem] = []
            func add(_ seg: Seg) { items.append(RowItem(id: nextID, seg: seg)); nextID += 1 }
            for seg in line {
                if hasToken, case .text(let s) = seg {
                    for piece in PromptTextPieces.split(s) { add(.piece(piece)) }
                } else {
                    add(seg)
                }
            }
            return items
        }
    }

    var body: some View {
        // 🆕 2026-10-03：**按行渲染**——外层 VStack 保行、行内 FlowLayout 拼 token/文字。
        // 旧版整段丢进一个 FlowLayout，换行会被流式重排吃掉（"@ 素材保存后行错乱"的根因）。
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                FlowLayout(spacing: 3, lineSpacing: 5, centersLines: true) {
                    if row.isEmpty {
                        Color.clear.frame(height: 17)   // 空行保留一行高度
                    } else {
                        ForEach(row) { item in
                            switch item.seg {
                            case .text(let s):
                                Text(s)
                                    .font(.system(size: 14))
                                    // 占位文案（「（无提示词，点此编辑）」）走灰色，和真实内容区分开
                                    .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                            case .token(let t):
                                // 带上 segment 下标：同 token 多次出现时靠它区分（见 hoveredSlot 的说明）
                                tokenView(t, at: item.id)
                            case .piece(let s):
                                Text(s)
                                    .font(.system(size: 14))
                                    .foregroundStyle(isPlaceholder ? Color.secondary : Color.primary)
                                    .fixedSize()
                                    .flowGlue()
                            case .newline:
                                EmptyView()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 悬停预览：浮层显示在触发图片的正上方（跟随图片位置）
        .onChange(of: hoveredSlot) { _, _ in updateHoverPreview() }
        // ⚠️ 图片**异步加载完成**时也要重算一次：鼠标先压上去、图后加载完的情况，
        // 只看 `hoveredToken` 的变化会整个漏掉 —— 表现为"移过去没反应，移开再移回来才有"
        //（用户报的"@ 素材保存后移过去没弹窗，再试一次又有"，就是这个，不是个例）。
        .onChange(of: images.count) { _, _ in updateHoverPreview() }
        // 抽屉覆盖主内容时，底栏又特意保持可交互；底栏下面的提示词缩略图不能因此
        // 继续响应悬停，否则会从覆盖层后弹出玻璃预览面板，看起来像抽屉材质在闪。
        .onChange(of: app.showLibraryDrawer) { _, isOpen in
            if isOpen { cancelHoverPreview() }
        }
        .onChange(of: app.showTaskDrawer) { _, isOpen in
            if isOpen { cancelHoverPreview() }
        }
        .onDisappear { HoverPreviewPanel.shared.hide() }
        .onAppear { loadImages() }
        .onChange(of: text) { _, _ in loadImages() }
        // ⚠️ **素材变了也要重载**，不能只盯着 `text`：拖拽加素材是**不插 token** 的
        //（提示词文字不变），只靠上面那条的话缩略图不会刷新。
        // 这个 key 同时带上"源"，所以换素材（token 不变、源变了）也能触发。
        .onChange(of: slots.map { "\($0.token)|\($0.thumbnailURL?.path ?? $0.remoteThumbnailURL?.absoluteString ?? "")" }) { _, _ in
            loadImages()
        }
    }

    @ViewBuilder
    private func tokenView(_ token: String, at index: Int) -> some View {
        // 只读展示（如预览弹窗）时 `enablesHover == false`：**连坐标追踪和 onHover 都不挂**，
        // 不只是"弹窗不显示"——省掉每个 token 的 GeometryReader，代价更低。
        if enablesHover {
            tokenThumbnail(token)
                // 记录该图片的屏幕坐标，供悬停浮层定位（写入非观察缓存，见 FrameCache 注释）。
                // ⚠️ 存**segment 下标**而不是 token：同一个 token 出现两次时按 token 存会互相覆盖。
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { frames.byIndex[index] = screenRect(geo) }
                            .onChange(of: geo.frame(in: .global)) { _, _ in frames.byIndex[index] = screenRect(geo) }
                    }
                )
                .onHover { hovering in
                    if hovering {
                        hoveredSlot = HoveredSlot(token: token, index: index)
                    } else if hoveredSlot?.index == index {
                        hoveredSlot = nil
                    }
                }
        } else {
            tokenThumbnail(token)
        }
    }

    /// token 的视觉：有缩略图就显示图，否则退回文字
    @ViewBuilder
    private func tokenThumbnail(_ token: String) -> some View {
        if let img = images[token], MediaTokenThumbnail.isChip(img) {
            // 音频 / 没有本地文件的视频：「图标 + 名字」小标签，按原比例、同样 18 高
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 18)
        } else if let img = images[token] {
            Image(nsImage: img)
                .resizable()
                // ⚠️ 2026-09-13 用户两次调尺寸：先是「竖图太细」→ 改方形 ✓；又说「方形还是有点小」→
                // **16:9 的 32×18** ✓（和提示词框里那套 `SlotAttachment` 用同一组尺寸 ✓ 两边要一起改 ✗）
                // `.fill` + 固定框 + 裁剪 = 居中裁成 16:9 ✓ 不会压扁变形 ✓
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // 绑了音色的角色图：右下角小喇叭（和编辑框里的 `SlotAttachment` 一样，2026-10-26）
                .overlay(alignment: .bottomTrailing) {
                    if slots.first(where: { $0.token == token })?.hasVoice == true {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 11, height: 11)
                            .background(Circle().fill(Color.black.opacity(0.65)))
                    }
                }
        } else {
            Text(token)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
        }
    }

    /// SwiftUI 全局坐标（窗口内容坐标，原点左上）→ 屏幕坐标（AppKit 原点左下）
    private func screenRect(_ geo: GeometryProxy) -> CGRect {
        let frame = geo.frame(in: .global)
        // 同 `IconDropdown.buttonScreenRect`：别用 `NSApp.keyWindow` 单吊（未激活时是 nil，
        // 面板还可能是 key）—— 见 `hostWindowForScreenRect()`。
        guard let window = hostWindowForScreenRect(), let contentView = window.contentView else { return .zero }
        let appKitRect = NSRect(
            x: frame.minX,
            y: contentView.bounds.height - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        return window.convertToScreen(appKitRect)
    }

    /// 按 token 切分文本（连续文字合并为一段，token 单独成段），长 token 优先避免「图1」误匹配「图10」。
    /// 结果缓存在非观察的 SegmentCache 里：内容没变直接复用，避免每次 body 重算——
    /// 这是 O(轮数 × token 数 × 文本长度) 的**字素感知**搜索，中文下极贵（2026-09-11 sample 里的最大单块热点）。
    private var rows: [[RowItem]] {
        let tokens = slots.map(\.token).sorted { $0.count > $1.count }
        if segmentCache.text == text, segmentCache.tokens == tokens {
            return segmentCache.rows
        }
        let result = Self.makeRows(Self.split(text: text, tokens: tokens))
        segmentCache.text = text
        segmentCache.tokens = tokens
        segmentCache.rows = result
        return result
    }

    private static func split(text: String, tokens: [String]) -> [Seg] {
        var result: [Seg] = []
        var remaining = Substring(text)
        var buffer = ""

        // 🆕 2026-10-03：flush 时把文字按 `\n` 拆开，换行变成显式 `.newline` 段——
        // 只读渲染靠它按行排版（旧版换行被 FlowLayout 吃掉 → "@ 素材保存后行错乱"）
        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let lines = buffer.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                if !line.isEmpty { result.append(.text(line)) }
                if i < lines.count - 1 { result.append(.newline) }
            }
            buffer = ""
        }

        while !remaining.isEmpty {
            var earliest: (range: Range<Substring.Index>, token: String)?
            for t in tokens {
                if let r = remaining.range(of: t),
                   earliest == nil || r.lowerBound < earliest!.range.lowerBound {
                    earliest = (r, t)
                }
            }
            guard let e = earliest else {
                buffer += String(remaining)
                break
            }
            if e.range.lowerBound > remaining.startIndex {
                buffer += String(remaining[remaining.startIndex..<e.range.lowerBound])
            }
            flushBuffer()
            result.append(.token(e.token))
            remaining = remaining[e.range.upperBound...]
        }
        flushBuffer()
        return result
    }

    /// 同步取缓存小图（命中即用），未命中后台加载后回填
    /// 当前悬停目标 → 显示/收起放大浮窗。抽出来是因为它有**两个**触发时机
    /// （悬停目标变了、图片异步加载完成），见上面两处 `onChange`。
    private func updateHoverPreview() {
        guard enablesHover else { return }
        guard !app.showLibraryDrawer, !app.showTaskDrawer else {
            HoverPreviewPanel.shared.hide()
            return
        }
        // ⚠️ **滚动中一律不弹**（同 `PromptEditor.handleHover`，理由见 `ScrollActivity` 的说明）
        // 这条路径其实**更容易在滚动时中招** —— 光标本来就在卡片上 ✓
        // `hide()` 即使没显示也会取消"待触发的弹出" ✓ → 滚动一发生，延迟触发就作废 ✓
        if ScrollActivity.shared.isScrolling {
            HoverPreviewPanel.shared.hide()
            return
        }
        guard let slot = hoveredSlot else {
            HoverPreviewPanel.shared.hide()
            return
        }
        // 图还没加载好 / 拿不到屏幕坐标 → 先收起，等它们就绪时（images.count 变化）会再调一次
        guard let img = images[slot.token] else {
            HoverPreviewPanel.shared.hide()
            return
        }
        guard let rect = frames.byIndex[slot.index], rect != .zero else {
            HoverPreviewPanel.shared.hide()
            return
        }
        HoverPreviewPanel.shared.show(image: img, above: rect)
    }

    private func cancelHoverPreview() {
        hoveredSlot = nil
        HoverPreviewPanel.shared.hide()
    }

    private func loadImages() {
        // 先清掉已经不存在的 token：否则删掉「图2」之后再加一张新的「图2」，
        // 会直接继承旧图（同一个键）。
        let liveTokens = Set(slots.map(\.token))
        images = images.filter { liveTokens.contains($0.key) }
        imageSources = imageSources.filter { liveTokens.contains($0.key) }

        for slot in slots {
            // 源标识：与下面两个加载分支一一对应（本地路径优先，否则远程直链）
            let source = slot.thumbnailURL?.path ?? slot.remoteThumbnailURL?.absoluteString ?? ""
            guard !source.isEmpty else { continue }
            // 源没变、且已经加载好了 → 跳过；否则（新素材 / 换了素材）重载
            if imageSources[slot.token] == source, images[slot.token] != nil { continue }
            imageSources[slot.token] = source
            images[slot.token] = nil      // 先清掉旧图，避免重载期间显示错的那张

            if let url = slot.thumbnailURL {
                // 滚动热点只允许查内存缓存：`image(at:)` 还会同步读磁盘并解码，
                // 卡片第一次出现带参考图的提示词时会把主线程堵在 ImageIO 上。
                // 未命中时走后台缩略图加载，和 AsyncThumbImage / 生视频卡片一致。
                if let cached = LocalImageCache.memoryThumb(atPath: url.path) {
                    images[slot.token] = cached
                } else {
                    LocalImageCache.loadThumbnail(at: url) { img in
                        // 异步回来时核对源：期间若又换过素材，这次结果作废（否则会把新图覆盖成旧图）
                        if let img, imageSources[slot.token] == source { images[slot.token] = img }
                    }
                }
            } else if let remote = slot.remoteThumbnailURL {
                // ⚠️ 本地文件已丢失时的**兜底**（实测素材库 131 张图里 48 张如此）：
                // `thumbnailURL` 只在本地文件真的存在时才非空，只走本地分支的话
                // 这些素材永远拿不到缩略图 → 悬停放大**永远不弹**。
                LocalImageCache.loadRemoteThumbnail(at: remote) { img in
                    if let img, imageSources[slot.token] == source { images[slot.token] = img }
                }
            }
        }
    }
}

/// 本地图片异步缩略图：命中缓存立即显示小图，未命中后台降采样补齐（避免主线程解码大图；滚动/路径变化重识别）
struct AsyncThumbImage: View {
    let path: String?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    init(path: String?, contentMode: ContentMode = .fill) {
        self.path = path
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        // 首次出现即加载一次；命中内存/磁盘缓存就直接显示，否则后台生成后回到主线程
        .onAppear {
            guard let path, image == nil else { return }
            // ⚠️ 快速路径只能用 **memoryThumb**（纯查表）✗ 不能用 `image(atPath:)` ——
            // 后者会在这条主线程路径上同步读盘 + 解码 ✗，卡片第一次出现就卡一下
            if let cached = LocalImageCache.memoryThumb(atPath: path) {
                image = cached
                return
            }
            LocalImageCache.loadThumbnail(atPath: path) { img in
                image = img
            }
        }
        .onChange(of: path) { _, newPath in
            image = nil
            guard let newPath else { return }
            // ⚠️ 同 onAppear：快速路径只能查**内存**（`image(atPath:)` 会同步读盘+解码 ✗）
            // 磁盘缓存由 `loadThumbnail` 在**后台**读 ✓
            if let cached = LocalImageCache.memoryThumb(atPath: newPath) {
                image = cached
                return
            }
            LocalImageCache.loadThumbnail(atPath: newPath) { img in
                image = img
            }
        }
    }
}

/// 本地图片异步全尺寸图（预览大图 .fit 用）：未命中后台解码原图，避免主线程卡顿
struct AsyncFullImage: View {
    let path: String?
    @State private var image: NSImage?

    init(path: String?) { self.path = path }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard let path, image == nil else { return }
            LocalImageCache.loadFull(atPath: path) { img in
                image = img
            }
        }
        .onChange(of: path) { _, newPath in
            image = nil
            guard let newPath else { return }
            LocalImageCache.loadFull(atPath: newPath) { img in
                image = img
            }
        }
    }
}

/// 生成中进度动画：环形进度 + 百分比（进度与任务 progressPercent 同步）
///
/// ⚠️ **不要在这里加任何 `repeatForever` 动画**（原来有过一个 opacity 呼吸脉冲，2026-09-16 删除）：
/// 只要它在，SwiftUI 就**逐帧重算整棵视图树的渲染**，任务在跑期间 CPU 常驻 ~35%、鼠标操作全卡
/// （sample 实锤：`UpdateCycle → CA flush → NSHostingView.layout → ViewGraph.render`）。
/// 任务结束卡片离开「生成中」→ 动画停 → CPU 回 0。要脉冲就用 Core Animation 驱动，别用 SwiftUI 动画。
struct GenerationProgressView: View {
    let progress: Double  // 0~100

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.18), lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(max(progress, 2), 100) / 100)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)
            VStack(spacing: 2) {
                Text("\(Int(progress.rounded()))%")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text("生成中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// 任务进行中状态：排队中显示队列信息；生成中统一用**环形进度**
///（有百分比用真实进度，没有就写 0 —— 2026-09-27 用户定"不要转圈、统一"）
struct TaskInProgressView: View {
    let task: LocalTask

    var body: some View {
        if task.progressPercent == nil {
            VStack(spacing: 8) {
                if task.phase == .queued {
                    // 排队中：保留"时钟 + 第 N 位"（队列位置只有这里有地方显示）
                    Image(systemName: "clock.badge.questionmark")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(task.queuePosition.map { "排队中 · 第 \($0) 位" } ?? "排队中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // 🎨 2026-09-27 用户定（"统一"）：平台没给百分比时**不再转圈** ——
                    // 与缩略图、生图侧统一，改用环形进度、固定写 0。
                    GenerationProgressView(progress: 0)
                }
            }
        } else {
            GenerationProgressView(progress: task.progressPercent ?? 0)
        }
    }
}

/// 中文序号：1 → 分镜一 … 12 → 分镜十二
enum ShotNumber {
    static let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]

    static func chinese(_ n: Int) -> String {
        guard n > 0, n < 100 else { return "\(n)" }
        if n < 10 { return digits[n] }
        let tens = n / 10, ones = n % 10
        var text = tens == 1 ? "十" : digits[tens] + "十"
        if ones > 0 { text += digits[ones] }
        return text
    }

    static func title(_ n: Int) -> String { "分镜\(chinese(n))" }
}

// MARK: - 右键捕获

/// **只吃右键、左键穿透**的捕获器（SwiftUI 没有右键手势）。
/// 用来把系统自带的 `.contextMenu` 换成我们自绘的弹层——系统菜单给不了
/// "已打开时再右键 = 关闭"这个行为（它会把新菜单重新弹出来）。
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        CatcherView(onRightClick: onRightClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    final class CatcherView: NSView {
        var onRightClick: () -> Void

        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// **只在右键时接受命中**，其余一律返回 nil 让下层视图接住 ——
        /// 否则这层会把卡片的左键点击（打开项目）也一并挡掉。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  event.type == .rightMouseDown || event.type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            // 诊断日志：右键没反应时先看 app.log 里有没有这条
            AppLog.write("rightClick", "捕获到右键 at=\(NSEvent.mouseLocation)")
            onRightClick()
        }
    }
}

// MARK: - 翻页

/// **竖排**的圆形数字页码钮（右侧翻页栏用）：点哪个跳哪页，当前页填主题色 + 白字。
/// 一屏最多露出 `maxVisible` 个（**默认 9，取奇数**——居中需要一格真正的"正中"，8 个的话
/// 中心落在第 4、5 个之间，居中位置没有定义）；页数更多时**鼠标悬停在该栏上直接滚轮**即可
/// 查看其余页码。左右翻页靠直接点页码，不再需要上一页/下一页箭头。
///
/// 滚动策略：**当前页还在可视范围内就一动不动**（只有高亮在移，数字不跳）；
/// 只有它**快要滑出视野**时才重新居中。早期版本每翻一页都 `anchor: .center` 强制居中，
/// 整列数字跟着挪一格，表现为「翻一页页码跳一下」。
struct PageDotRail: View {
    let pageCount: Int
    let currentPage: Int
    let onSelect: (Int) -> Void
    var maxVisible: Int = 9

    /// 上次让当前页居中的位置。只有当前页离它超过半个视窗时才重新居中。
    /// 这里用 @State 是安全的：只在**翻页时**写一次，不在滚动热路径上。
    @State private var centeredOn: Int = -1

    private static let dotSize: CGFloat = 30
    private static let spacing: CGFloat = 6
    private static let railPadding: CGFloat = 1

    /// 最多露出 maxVisible 个圆钮时的高度；页数少时按实际个数收缩
    private var railHeight: CGFloat {
        let n = CGFloat(min(maxVisible, max(pageCount, 1)))
        return n * Self.dotSize + (n - 1) * Self.spacing + Self.railPadding * 2
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: Self.spacing) {
                    ForEach(Array(0..<max(pageCount, 0)), id: \.self) { page in
                        dot(page).id(page)
                    }
                }
                .padding(.vertical, Self.railPadding)
            }
            .scrollIndicators(.hidden)
            .frame(height: railHeight)
            .onAppear {
                centeredOn = currentPage
                proxy.scrollTo(currentPage, anchor: .center)
            }
            .onChange(of: currentPage) { _, newValue in
                recenterIfNeeded(to: newValue, proxy: proxy)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 当前页还在视窗内就**什么都不做**；快滑出去（离中心超过半个视窗）才挪，且挪到正中间
    private func recenterIfNeeded(to page: Int, proxy: ScrollViewProxy) {
        let half = maxVisible / 2          // 9 → 4：居中时上下各还能容纳 4 个
        if centeredOn >= 0, abs(page - centeredOn) <= half { return }
        centeredOn = page
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(page, anchor: .center)
        }
    }

    private func dot(_ page: Int) -> some View {
        Button {
            onSelect(page)
        } label: {
            Text("\(page + 1)")
                .font(.system(size: 13, weight: page == currentPage ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: Self.dotSize, height: Self.dotSize)
                .background(
                    Circle().fill(
                        page == currentPage
                            ? Theme.accent.opacity(0.85)
                            : Color.secondary.opacity(0.1)
                    )
                )
                .foregroundStyle(page == currentPage ? Color.white : Color.primary)
                .contentShape(Circle())
        }
        .buttonStyle(QuietButtonStyle(hover: .capsule))
    }
}

// MARK: - 滚到边界后继续滚 → 翻页

/// 「**到边界之后再滑一次**」就翻页。
///
/// **判据是「次数」不是「距离」**：一次滑动动作**开始时**是否已经停在顶/底边界上，
/// 是则本次动作有翻页资格（armed），滑动量超过很小的 `minimumPush` 就翻。
///
/// **为什么不做成"在边界上累计滚够 N pt"（试过 60/120/240，都被反馈"轻"）**：
/// 那样会把**「把你送到边界的那次滑动的尾巴」**也算进去——你还没到底、正在到底的路上，
/// 距离就攒满了，感觉是"还没滑到位就切了"。用户要的是：滑到底 → **再单独滑一次** → 切页。
/// 所以正在把你送到边界的那次动作没有资格，必须松手后再滑一次。
///
/// **也不用橡皮筋位移**：①它是**渐近曲线**，位移越大越费劲，阈值永远卡在"费很大力气"那一段
/// （70/35pt 档实测都要"费很大力气"，极狠才拉到 230pt）；②**内容不满一屏时压根没有橡皮筋**。
///
/// ⚠️ **性能纪律**：本组件挂在滚动热路径上。所有判定状态放**非观察的普通 class**，
/// 只有真正翻页那一下才回调。**绝对不要在事件回调里写 `@State`**——那是本项目
/// 已经踩过两次的坑（2026-09-09 高度、2026-09-11 几何坐标，见项目记忆）。
struct OverscrollPager: NSViewRepresentable {
    /// ⛔ **总开关**（2026-09-13，用户要求先关掉）。
    ///
    /// `false` = **完全不装那个滚轮监视器**（零开销、零行为）：滚到底/顶就只剩橡皮筋回弹，
    /// 不再翻页。**翻页本身没坏** —— 右侧页码栏、点任务跳转、工具条上的翻页都照常 ✓
    /// 关的只是"**滑到边界后再滑一次**"这个手势。
    ///
    /// ⚠️ **曾经的病（2026-09-13 已修）**：这个监视器只需要"看到"滚轮事件、不需要事件送达，
    /// 而它当时判断"指针在不在我这个列表里"用的是 `sv.bounds`（**布局位置**，不考虑遮挡）——
    /// 于是**弹层开着时滚轮会误触发翻页**：① 抽屉压在列表右半边，在抽屉里滚也算"在列表里"；
    /// ② 下拉菜单（独立 `NSPanel`）的坐标被当成主窗口坐标去比对列表矩形。
    /// 修法见 `handle()` 开头那条注释：判据换成 AppKit 的 `hitTest`（**事件按规则会送到谁**）。
    ///
    /// **要停用：把下面这行改成 `false`**（连监视器都不装，零开销）。
    static let enabled = true

    /// 本次滑动动作要翻页所需的**最小**累计量（pt）：只为滤掉抖动误触，不是"手感"旋钮
    var minimumPush: CGFloat = 15
    var canGoNext: Bool = false
    var canGoPrevious: Bool = false
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let c = context.coordinator
        c.minimumPush = minimumPush
        c.canGoNext = canGoNext
        c.canGoPrevious = canGoPrevious
        c.onNext = onNext
        c.onPrevious = onPrevious
        (nsView as? ObserverView)?.attach()
    }

    /// 零尺寸探针：上树后向上找到所属的 NSScrollView（用于命中判定 + 边界判定）
    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { coordinator?.detach() } else { attach() }
        }

        func attach() { coordinator?.attach(from: self) }
    }

    @MainActor
    final class Coordinator: NSObject {
        var minimumPush: CGFloat = 15
        var canGoNext = false
        var canGoPrevious = false
        var onNext: () -> Void = {}
        var onPrevious: () -> Void = {}

        /// `NSEvent.addLocalMonitorForEvents` 返回的是非 Sendable 的 `Any`，
        /// 包一层才能在非隔离的 `deinit` 里安全移除（不然那个 token 类型根本访问不了）
        private final class MonitorToken: @unchecked Sendable {
            let value: Any
            init(_ value: Any) { self.value = value }
        }

        private weak var scrollView: NSScrollView?
        private var monitor: MonitorToken?
        /// 本次滑动动作已累计的滚动量（只在有翻页资格时累加）
        private var push: CGFloat = 0
        /// 本次滑动动作**开始时**是否已经停在边界上——这是「再滑一次」的判据
        private var armedAtBottom = false
        private var armedAtTop = false
        private var lastEventAt: TimeInterval = 0

        /// 两帧事件间隔超过这么久就当作新手势重新累计（鼠标滚轮没有 phase，只能靠时间判断）
        private static let gestureGap: TimeInterval = 0.4
        /// 鼠标滚轮一行约合多少 pt（`hasPreciseScrollingDeltas == false` 时换算用）
        private static let pointsPerLine: CGFloat = 10

        func attach(from view: NSView) {
            if let sv = Self.enclosingScrollView(of: view) { scrollView = sv }
            // 初值必须设成「现在」：留 0 的话第一个事件必然被当成新手势（见 handle 里的说明）
            if lastEventAt == 0 { lastEventAt = ProcessInfo.processInfo.systemUptime }
            startMonitorIfNeeded()
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor.value) }
            monitor = nil
            scrollView = nil
            push = 0
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor.value) }
        }

        private func startMonitorIfNeeded() {
            // ⛔ **总开关**：关掉时连监视器都不装（见 `OverscrollPager.enabled` 的说明）
            guard OverscrollPager.enabled else { return }
            guard monitor == nil else { return }
            let raw = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                // NSEvent 不是 Sendable，不能跨进 MainActor 闭包——先把要用的标量取出来
                let deltaY = event.scrollingDeltaY
                let precise = event.hasPreciseScrollingDeltas
                let location = event.locationInWindow
                let phase = event.phase
                let momentumPhase = event.momentumPhase
                let windowNumber = event.windowNumber   // Int：Sendable，可安全带进主线程闭包
                MainActor.assumeIsolated {
                    self.handle(deltaY: deltaY, precise: precise, locationInWindow: location,
                                phase: phase, momentumPhase: momentumPhase, windowNumber: windowNumber)
                }
                return event
            }
            monitor = raw.map { MonitorToken($0) }
        }

        private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let v = current {
                if let sv = v as? NSScrollView { return sv }
                current = v.superview
            }
            return nil
        }

        /// 事件一律放行（调用方返回原 event）——保留系统橡皮筋的视觉阻尼反馈
        private func handle(deltaY: CGFloat, precise: Bool, locationInWindow: NSPoint,
                            phase: NSEvent.Phase, momentumPhase: NSEvent.Phase, windowNumber: Int) {
            guard let sv = scrollView, let doc = sv.documentView else { return }

            // ⚠️ **"在不在列表里"必须问 AppKit 的命中测试，不能算布局位置**（2026-09-13 探针定案）。
            //
            // 老判据 `sv.bounds.contains(sv.convert(locationInWindow, from: nil))` 会错两次：
            //   ① 事件来自**别的窗口**（下拉菜单 `DropdownPanel` 是 NSPanel、素材选择是 NSPopover）时，
            //      `locationInWindow` 是**那个窗口的**坐标，却被当成主窗口坐标去比对列表矩形 → 判成"在列表里"
            //      （探针：13 条 `同窗口=false 位置判据=true`，紧跟翻页）；
            //   ② 同窗口的弹层（浮层/抽屉，遮罩是 `OverlayEventShieldView`）**接走了**滚轮 ——
            //      事件根本到不了列表，位置判据却仍是 true（探针：13 条 `命中=OverlayEventShieldView 位置判据=true`）。
            //
            // 翻页器是 local monitor **旁观**事件的（事件被谁吃掉它管不着），所以只能自己问一句
            // "**这个事件按 AppKit 规则会送到谁**" —— `hitTest` 就是那个事实。
            // 对照组（正常在列表上滚）：命中 `PlatformGroupContainer` / `NSClipView`，都在这棵树里，
            // 22 条无一例外 ✓。拿不到命中（nil）时**一律不翻** —— 宁可少翻，也不要误翻。
            guard let win = NSApp.window(withWindowNumber: windowNumber), win === sv.window,
                  let hit = win.contentView?.hitTest(locationInWindow),
                  hit === sv || hit.isDescendant(of: sv)
            else { return }

            let now = ProcessInfo.processInfo.systemUptime
            // 是否属于**新的一次滑动动作**。
            // 触控板只认 `phase == .began`——**不能用时间间隔兜底**：翻页会重建 Coordinator，
            // 新实例的 lastEventAt 是 0，第一个事件必然满足「> gap」，于是同一次滑动的惯性
            // 会被误判成新动作、立刻重新武装 → 一次滑动连翻好几页（2026-09-11 实测 8 秒 12 次）。
            // 惯性阶段的相位是 momentumPhase、不是 .began，所以只认 .began 天然就把惯性排除在外。
            // 鼠标滚轮完全没有相位信息，只能退回时间间隔判断。
            let hasPhaseInfo = !phase.isEmpty || !momentumPhase.isEmpty
            let isNewGesture = phase.contains(.began)
                || (!hasPhaseInfo && now - lastEventAt > Self.gestureGap)
            lastEventAt = now

            let clip = sv.contentView
            let maxOffset = max(0, doc.frame.height - clip.bounds.height)
            let raw = clip.bounds.origin.y
            let offset = doc.isFlipped ? raw : maxOffset - raw
            // 内容不满一屏时 maxOffset = 0、offset = 0 → 顶和底同时成立，两个方向都能翻
            let atBottom = offset >= maxOffset - 1
            let atTop = offset <= 1

            if isNewGesture {
                // 「再滑一次」的资格：本次动作**开始时**就已经停在边界上。
                // 正在把你送到边界的那次动作没有资格——否则会变成"还没滑到底就切页"。
                armedAtBottom = atBottom && canGoNext
                armedAtTop = atTop && canGoPrevious
                push = 0
            }

            // AppKit 约定：scrollingDeltaY > 0 向上滚（朝顶部），< 0 向下滚
            let delta = precise ? deltaY : deltaY * Self.pointsPerLine

            if delta < 0, armedAtBottom, atBottom, canGoNext {
                push += -delta
                if push >= minimumPush {
                    armedAtBottom = false   // 一次动作只翻一页
                    push = 0
                    AppLog.write("overscroll", "边界上再滑一次 → 下一页")
                    onNext()
                }
            } else if delta > 0, armedAtTop, atTop, canGoPrevious {
                push += delta
                if push >= minimumPush {
                    armedAtTop = false
                    push = 0
                    AppLog.write("overscroll", "边界上再滑一次 → 上一页")
                    onPrevious()
                }
            } else {
                push = 0
            }
        }
    }
}

// MARK: - App 配色

extension Color {
    /// App 背景色（**暖灰**，「暗房」配色）：随系统浅色/深色外观自动切换。
    /// 窗口背景 + 所有"实底"面板都用它 —— **改这一处，全局背景就变了**。
    /// ⚠️ 卡片是玻璃，会**采样这个颜色**，所以改它也会连带改变卡片的透出观感。
    @MainActor static var appBackground: Color {
        let theme = ColorThemeStore.shared.current
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: theme.mode(dark: isDark).inset)
        })
    }
}

/// 窗口毛玻璃底的参数。
enum BackdropStyle {
    /// 压在毛玻璃之上的**色调覆盖**浓度：0 = 全透（只看壁纸）、1 = 等于原来的实底。
    ///
    /// 壁纸颜色不可控，深色模式下壁纸一亮文字就糊；系统的 vibrancy 语义在 SwiftUI 里拿不到，
    /// 所以对比度全靠这一层保。**这是「透 ↔ 能读」之间唯一的调节旋钮，改这一个数就行**：
    /// 嫌不够透往 0 调，嫌文字不稳往 0.5 调。
    ///
    /// 0.5 → 0.2（2026-09-12）：用户实测"边栏有点深色、不像毛玻璃"，根因是这层太厚
    /// ——深色模式下它是 #1C1F24 近黑压 50%，等于给整窗盖半层黑纱，把采样到的桌面压平了。
    ///
    /// 0.2 → 0.35（2026-09-12 当天稍后）：毛玻璃**真正生效之后**再实测，用户反馈"整体有点透"。
    /// 注意 0.2 那个值是在 backdrop 还没生效、整窗等于纯色的情况下定的，**不能作为参考**。
    /// ⚠️ **2026-09-12 对照实验结论：这层不是"整体偏灰"的原因。**
    /// 把它设成 0（完全去掉）之后用户实测**还是灰** —— 说明灰来自**毛玻璃材质本身**
    /// （见 `WindowBackdrop` 的 material），**调这个数没用**。
    /// 这个结论也解释了更早那次"调 4 轮浓度全部无效"：**两次都调错了层**。
    /// 要改善整体对比度，改的是 `WindowBackdrop` 的 `material`，不是这里。
    /// ⚠️ **2026-09-12 对照实验结论**：把这一层换成**纯红 + 不透明**时，**窗口确实泛红** ——
    /// 说明**这层是生效的**（曾被 `WindowBackdrop` 那层材质压着，所以只是"淡红"、效果被削弱）。
    /// 也说明它**不是"完全不起作用"**：更早那次"调 4 轮浓度全部无效"，是因为**浓淡本身的影响就被材质盖得很弱**。
    ///
    /// 现在配色改成了**中性黑**（见 `RootView` 里那行），浓度也从 0.35 提到 **0.5** ——
    /// 用户诉求是"整体偏灰、对比度不够"，那就把底压暗；原来的冷灰蓝本身就是灰的。
    /// **这是「透 ↔ 能读」唯一的旋钮**：嫌不够透往小调，嫌文字不稳往大调。
    static let tintOpacity: Double = 0.5

    /// 压在毛玻璃上的**色调颜色**：深色用黑、浅色用白（2026-09-18）。
    /// 原来写死 `Color.black` → 浅色模式下等于给整窗盖一层黑纱，看着"太灰" ✗。
    static let tintColor = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .black : .white
    })

    /// **唯一一处例外**：任务抽屉（浮在卡片列表之上的那 260pt）。
    ///
    /// 其余条状面板（app 顶栏 / 工作区顶栏 / 两条工具条 / 两条翻页竖栏）**一律不设背景**，
    /// 直接露窗口那一层，与背景同浓度。
    ///
    /// ⚠️ **顶栏别再单独调**：曾经按"顶栏底下没有内容、需要压住"的思路给它单独加过 0.9 的实底，
    ///    结果 38pt 处出现一道横带、比统一时更违和，用户明确要求去掉、回到和其余面板一致。
    ///
    /// 抽屉（浮在卡片列表之上的那 260pt）**不再用纯色板调 alpha** —— 它改用
    /// `FrostedPanel()`（`.withinWindow` 毛玻璃，糊底下的卡片），见 RootView 的 taskDrawer。
    ///
    /// **为什么放弃纯色板（试错记录，别再走一遍）**：纯色板只能在"挡不挡得住卡片"这一维上滑 alpha，
    /// 0.85（"有点太透"）→ 0.95（"再浓一些"）→ 1.0（"稍微再透一点"）→ 0.97，
    /// **区间只剩 0.95~1.0 五个千分点，本质上是在二分逼近一个不存在的最优点**。
    /// 换成模糊之后"透"和"读得清"不再互相打架，也没有 alpha 要标定。
    ///
    /// 附：抽屉用纯色时还踩过一次 —— 用 `Color.appBackground`（刻意的"冷灰蓝"，深色 #1C1F24
    /// 的蓝比红高 8）在 0.95 近实底下会把蓝调**满强度**摆出来，用户一眼看出"任务栏偏蓝"。
    /// **同一个颜色在"低浓度叠加"和"近满强度"下观感完全不同。**
}

// MARK: - 玻璃效果开关（纯色模式）

/// **玻璃效果开关**（2026-09-19 用户要求）：设置里关掉后，全软件从「毛玻璃 / 材质」变纯色。
/// 浅色 = 白，深色 = 原来的深底（卡片 / 面板比底亮一档，靠描边分层）。
/// 默认开（保持玻璃观感），设置持久化。
///
/// ⚠️ 通过**环境值**下发（不是各视图直接读 UserDefaults）：切开关时 SwiftUI 会重算所有依赖它的视图。
private struct GlassEffectEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var glassEffectEnabled: Bool {
        get { self[GlassEffectEnabledKey.self] }
        set { self[GlassEffectEnabledKey.self] = newValue }
    }
}

/// 玻璃效果开关的持久化键（AppKit 侧读它；SwiftUI 侧走环境值 `\.glassEffectEnabled`）
enum GlassEffectSetting {
    static let key = "glassEffectEnabled"

    /// 默认开（保持玻璃观感）
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// **卡内分区 / 占位的填充**（跟着「玻璃效果」开关走）：
/// - 玻璃开 → 半透明叠加（原来的观感，会透出底下的材质）
/// - 玻璃关 → 方案 A 的明确灰阶（浅色 `#F7F7F8` / 深色 `#262A2F`）
///
/// 用 `ShapeStyle.resolve(in:)` 直接拿环境值 —— 调用点只写 `.fill(.insetFill)`，
/// 不用每个视图各自读 `glassEffectEnabled` / `colorScheme`。
struct InsetFillStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        if environment.glassEffectEnabled {
            return AnyShapeStyle(Color.secondary.opacity(0.08))
        }
        // 用环境里的配色主题取色（不走 @Observable 的 Store）：换主题时环境值变了，用到它的填充才会重新解析
        return AnyShapeStyle(SolidTheme.color(\.inset, scheme: environment.colorScheme, theme: environment.colorTheme))
    }
}

extension ShapeStyle where Self == InsetFillStyle {
    static var insetFill: InsetFillStyle { InsetFillStyle() }
}

/// 纯色模式（玻璃关闭）的配色 —— **明度阶梯（方案 A，2026-09-19）**：
/// 页面(灰) → 卡片(白) → 卡内分区(浅灰) → 浮层(白 + 深一档描边)，每档差 3~5% 明度，不靠阴影。
@MainActor
enum SolidTheme {
    // 「面」的配色来自当前配色主题（见 `ColorTheme`；默认「暗房」：偏暖的近黑 / 纸白）。
    // 明暗三档的步长沿用最初的设计：页面 < 卡片 > 内容区，浮层比卡片亮一档。
    // （最初的数值是用户 2026-09-19 的三张截图采样的：背景 #141414 / 卡片 #262626 / 内容区 #1C1C1C，现在是「经典」主题。）
    // `ColorThemeStore` 是 @Observable：视图 body 里调这些函数会自动订阅，换主题后跟着重算。

    private static func mode(_ scheme: ColorScheme) -> ColorTheme.Mode {
        ColorThemeStore.shared.current.mode(dark: scheme == .dark)
    }
    private nonisolated static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    /// 指定主题取一档颜色（给 `ShapeStyle.resolve(in:)` 这种拿不到 Store 的地方用）
    nonisolated static func color(_ pick: KeyPath<ColorTheme.Mode, UInt32>, scheme: ColorScheme, theme: ColorTheme) -> Color {
        rgb(theme.mode(dark: scheme == .dark)[keyPath: pick])
    }

    /// 窗口 / 页面底色 —— 深色**最暗的一档**
    static func background(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).background) }
    /// 卡片底 —— 深色比页面亮一档
    static func card(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).card) }
    /// 卡内内容区（预览区 / 提示词区 / 分镜条 / 资产库格 / 占位）—— 深色比卡片**暗**一档
    static func inset(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).inset) }
    /// 浮层底（下拉 / 弹窗 / 抽屉 / 工具条）—— 浅色纯白（靠描边区分）；深色比卡片亮一档
    static func overlay(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).overlay) }
    /// 卡片描边（比卡片亮一点点的线勾边）
    static func cardStroke(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).cardStroke) }
    /// 浮层描边（浮在卡片上时靠它分界，不用阴影）
    static func overlayStroke(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).overlayStroke) }
    /// 悬停 / 选中：所在面再深一档
    static func hover(_ scheme: ColorScheme) -> Color { rgb(mode(scheme).hover) }

    /// 窗口底色是不是深色（按「主题设置」取，不看窗口的 `effectiveAppearance`）。
    ///
    /// ⚠️ **按「主题设置」取，不看窗口的 `effectiveAppearance`**（2026-09-19 修）：
    /// 那个在切主题时会滞后 / 和设置不一致 —— 用户实测"切成浅色后窗口底还是黑的"（截图实锤）。
    static var isDarkSetting: Bool {
        switch AppThemeStore.current {
        case .dark: true
        case .light: false
        case .system: SystemAppearance.isDark
        }
    }

    /// AppKit 侧（窗口底色）用的版本：当前配色主题的页面底。
    static func windowBackgroundColor() -> NSColor {
        NSColor(hex: ColorThemeStore.shared.current.mode(dark: isDarkSetting).background)
    }
}

// MARK: - 背景样式（液态玻璃 / 回退）

extension View {
    /// 浮层 / 条状面板背景：macOS 26+ 用**液态玻璃**，低版本回退到「纯色 + 圆角裁剪」，保证 macOS 15 仍可运行。
    ///
    /// 苹果的 `GlassEffectContainer` 用于**同屏相邻的多个玻璃元素**（让它们融合/互相影响）。
    /// 这里每块面只产生**一个**玻璃元素、彼此隔着间距，所以不需要容器。
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat, shadow: Bool = true) -> some View {
        glassPanel(in: RoundedRectangle(cornerRadius: cornerRadius), shadow: shadow)
    }

    /// 同上，但可以指定任意形状——例如只圆左侧两个角用 `UnevenRoundedRectangle`。
    ///
    /// - Parameter shadow: 是否自带 SwiftUI 阴影。**装在独立窗口里的内容（NSPanel / sheet）必须传 false**：
    ///   那些窗口自己就有一层系统阴影，而 SwiftUI 的阴影画到窗口边界外会被**裁掉**，
    ///   结果是在圆角处留一道生硬的暗边（用户说的"圆角有个印子"）。两层的取舍见调用处注释。
    @ViewBuilder
    func glassPanel<S: Shape>(in shape: S, shadow: Bool = true) -> some View {
        modifier(GlassPanelModifier(shape: shape, shadow: shadow))
    }
}

/// 浮层面板底：玻璃开 → 液态玻璃（低版本回退实色）；玻璃关 → 纯色（浅色白 / 深色深底）
private struct GlassPanelModifier<S: Shape>: ViewModifier {
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme
    let shape: S
    let shadow: Bool

    func body(content: Content) -> some View {
        Group {
            if glassEnabled {
                if #available(macOS 26.0, *) {
                    content
                        .glassEffect(.regular, in: shape)
                        // **必须显式裁内容**：`glassEffect` 只把玻璃画成这个形状，并不裁剪里面的内容。
                        // 不裁的话，弹窗里的视频/图片是直角矩形，四个角会**顶出圆角外面**露出来。
                        .clipShape(shape)
                        .modifier(OptionalPopupShadow(enabled: shadow))
                } else {
                    content
                        .background(Color.appBackground)
                        .clipShape(shape)
                        .modifier(OptionalPopupShadow(enabled: shadow))
                }
            } else {
                content
                    .background(SolidTheme.overlay(colorScheme), in: shape)
                    .overlay(shape.stroke(SolidTheme.overlayStroke(colorScheme), lineWidth: 1))
                    .clipShape(shape)
                    .modifier(OptionalPopupShadow(enabled: shadow))
            }
        }
    }
}

/// 可开关的浮层阴影（`@ViewBuilder` 里不方便写条件修饰符，包一层）
private struct OptionalPopupShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.popupShadow()
        } else {
            content
        }
    }
}

extension View {
    /// 卡片背景：macOS 26+ 用液态玻璃；低版本回退到 `solidCard()`。
    ///
    /// ⚠️ **卡片是滚动热点区**（一屏多张卡 × 每卡一个玻璃采样）。实测若掉帧，
    /// 把调用处 `glassCard()` 换成 `solidCard()` 即可一行回退——2026-09-06 的
    /// `thickMaterial` 就是在这里炸过，所以才有的 `solidCard` 那套纯色 + 高光渐变。
    /// ⚠️ **2026-09-12 起卡片不再用它，改用 `solidCard()`** —— 原因是**观感**，不是性能：
    /// 液态玻璃会在**圆角处做折射**，析出一圈彩色细边（用户："卡片的边角出现了色带"✗）。
    /// 圆角越大弧越长越明显，而且强度随窗口背后的壁纸变化 —— 所以它会"时有时无" ✗
    ///
    /// **试过但没用的办法**（别再走一遍）：在玻璃正下方垫一层 0.85 的实色 ✗ ——
    /// 色带照旧。因为 Liquid Glass 的边缘折射会**采到卡片范围之外**一圈 ✗，
    /// 垫层只盖得住卡片自己那块 ✓ 所以这条路到头了。
    ///
    /// **性能上玻璃和纯色没差**（2026-09-12 实测：滚动帧间隔「超 50ms 的 3~6 次 vs 4~9 次」，
    /// 基本一样 ✗）—— 所以当年那条"掉帧就换 solidCard"的退路，**这次不是因为掉帧用的** ✓
    /// 想恢复玻璃质感：把调用处换回 `glassCard()` 即可（但色带会回来 ✗）。
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
                // 显式裁内容（glassEffect 只把玻璃画成这个形状，不裁里面的图/视频）
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .cardShadow()
        } else {
            self.solidCard(cornerRadius: cornerRadius)
        }
    }

    /// 卡片**材质**背景：SwiftUI 原生 `.regularMaterial`（上一代模糊）+ 顶部高光 + 描边。
    ///
    /// **为什么用它**（2026-09-12）：卡片原来是 macOS 26 的液态玻璃（`.glassEffect`），
    /// 但它在**圆角处有折射**、会析出彩色色带 ✗（用户："卡片的边角出现了色带"）。
    /// `Material` **没有边缘折射** ✓ → 色带消失 ✓，同时**保留了"透"** ✓ ——
    /// 正好是"既要透、又要没色带"那条中间路线 ✓
    ///
    /// 而且它和 app 其他部分是统一的：弹窗（`AppModal`）、任务抽屉用的都是 `.regularMaterial` ✓
    ///
    /// ⚠️ 顶部高光那层要放在 **background 内部**（和 `solidCard` 一样）——
    /// 放到外面当 `.overlay` 会**盖住卡片内容、吃掉点击** ✗
    func materialCard(cornerRadius: CGFloat = 18) -> some View {
        modifier(MaterialCardModifier(cornerRadius: cornerRadius))
    }
}

/// 卡片底：玻璃开 → `.regularMaterial`（+ 顶部高光 + 描边）；玻璃关 → 纯色（浅色白 / 深色深底）
private struct MaterialCardModifier: ViewModifier {
    @Environment(\.glassEffectEnabled) private var glassEnabled
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(glassEnabled ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(SolidTheme.overlay(colorScheme)))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(glassEnabled ? 0.07 : 0.0), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(glassEnabled ? Theme.hairline : SolidTheme.cardStroke(colorScheme)))
            // ⚠️ **卡片不加阴影**（2026-09-13 实测定案，不是省事，是因为它真的卡）：
            // 排查滚动顿挫一整晚，最后是用户的一句话定的案 ——
            //「**卡片里什么都没有、全是空卡片的时候，滑动也会卡**」→ 内容类原因（图片/提示词/素材）
            // 全部排除 ✓ 空卡片上仍然存在的只剩「材质」和「阴影」两样 ✓ 材质先 A/B 掉了（数字好一截
            // 但大顿挫没少、用户说手感变化不大 ✗）→ 剩下的就是它 ✓ **去掉后用户实测「好多了」** ✓✓
            // 原因：**阴影强制离屏渲染，开销在 GPU**（一屏 4~6 张卡 × 每张一趟）——
            // 正好同时解释用户的两条观察：「CPU 才二十几」（不是 CPU 的活）+「空卡片也卡」（跟内容无关）✓
            // ⚠️ 别的浮层（弹窗/抽屉/下拉/悬停浮窗）**仍然用 `cardShadow()`/`popupShadow()`** ✓
            // 它们是静态的、不在滚动列表里 ✓ 离屏代价可以接受 ✓ 别一起删了 ✗
            // .cardShadow()
    }
}

extension View {
    /// 卡片纯色背景：纯色提亮 + 顶部高光渐变（模拟材质观感但**无模糊开销**）+ 描边。
    /// 既是低版本回退路径，也是卡片玻璃化的**性能对比基线**。
    func solidCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.07), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.hairline))
            .cardShadow()
    }
}

// MARK: - 卡片投影

/// 卡片投影参数。**嫌重就先把 `cardShadowRadius` 调小，设成 0 即等于关掉。**
/// ⚠️ 阴影要离屏渲染，而卡片在**滚动列表**里 —— 每张可见卡每帧一次。
///   比材质模糊便宜得多，但仍在滚动热点上；掉帧就调小这里。
private let cardShadowOpacity: Double = 0.16
private let cardShadowRadius: CGFloat = 7
private let cardShadowY: CGFloat = 2

extension View {
    /// 给卡片加投影（只作用于卡片自身的圆角轮廓）
    func cardShadow() -> some View {
        shadow(color: .black.opacity(cardShadowOpacity), radius: cardShadowRadius, x: 0, y: cardShadowY)
    }

    /// 浮层投影：弹窗 / sheet / 下拉面板 / 悬停浮窗 / 任务抽屉 / 播放控制条都用它
    /// （它们都是**静态浮层**、不在滚动列表里，所以离屏渲染的代价可以接受）。
    ///
    /// **两层叠加**：单层阴影要么"糊成一片"要么"像一圈黑边"，很难同时有重量感和距离感。
    /// 近处一层紧而实（贴边、给边缘重量），远处一层散而淡（给"浮起来"的空间感）。
    func popupShadow() -> some View {
        self
            .shadow(color: .black.opacity(popupShadowNearOpacity),
                    radius: popupShadowNearRadius, x: 0, y: popupShadowNearY)
            .shadow(color: .black.opacity(popupShadowFarOpacity),
                    radius: popupShadowFarRadius, x: 0, y: popupShadowFarY)
    }
}

/// 浮层投影参数（两层）。**嫌不够就加 `...FarOpacity`，嫌重就减**；两层半径都设 0 即等于关掉。
private let popupShadowNearOpacity: Double = 0.38
private let popupShadowNearRadius: CGFloat = 8
private let popupShadowNearY: CGFloat = 3
private let popupShadowFarOpacity: Double = 0.60
private let popupShadowFarRadius: CGFloat = 50
private let popupShadowFarY: CGFloat = 22

/// 等宽分段切换条 —— 用来替代 `Picker(.segmented)`。
///
/// ## 为什么不用原生 `Picker`
/// macOS 的分段控件**只按内容自适应宽度**：给它 `maxWidth: .infinity` 或强制 `.frame(width:)`
/// 都没用。实测：素材库那条（4 项 8 个字）**固有宽度只有 188**，即使给它 244 的框，
/// 它照样画 188（`segmentDistribution` 默认是 `.fit`，多余空间留白）。
/// 结果就是**任务抽屉（4 项 10 字）和素材库抽屉两条切换条宽度永远对不齐**（用户实测）。
///
/// 原来靠包一层 `NSSegmentedControl` + `.fillEqually` 解决；**2026-09-19 用户要求"选中块滑动"**
/// （系统控件只能"跳"不能"滑"），于是改成**纯 SwiftUI 自绘**：
/// - 等宽：每段 `.frame(maxWidth: .infinity)`（与原 `fillEqually` 等价）；
/// - 滑动：选中块 `matchedGeometryEffect` 从旧段补间到新段（同底栏 `CapsuleSegmented`）；
/// - 外观：**保持系统那套"浅底 + 深色选中块"**（不抢底栏蓝色开关的视觉）。
///
/// 用法不变：
/// ```swift
/// SegmentedBar(options: LibraryCategory.allCases.map { ($0.displayName, $0) },
///              selection: $category)
///     .frame(width: 244, height: 24)
/// ```
struct SegmentedBar<Value: Hashable>: View {
    /// 分段（顺序即显示顺序）
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    /// 选中块的滑动命名空间（见类型注释）
    @Namespace private var selectionPill

    /// **选中块的本地位置**（同 `CapsuleSegmented`）：滑动动画只作用于它，
    /// 外部 `selection` 照旧瞬时切 —— 否则列表内容（筛选后的行）也会跟着做过渡动画。
    @State private var pillSelection: Value

    init(options: [(label: String, value: Value)], selection: Binding<Value>) {
        self.options = options
        self._selection = selection
        self._pillSelection = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let isSelected = option.value == pillSelection
                Button {
                    guard option.value != selection else { return }
                    // ① 块先滑（只动本地状态）② 外部状态照常切（列表内容瞬时变）
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        pillSelection = option.value
                    }
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)   // 窄条里"进行中"这类词也不截断
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .background {
                            // 选中块跨段滑动（同底栏 `CapsuleSegmented`）。
                            // ⚠️ **别给选中块加 `.transition(.identity)`**：实测那会把
                            // matchedGeometryEffect 的补间一并禁掉（变回瞬跳）。
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: selectionPill)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(QuietButtonStyle(hover: .fill(radius: 6)))
            }
        }
        // 外部改了 `selection` → 本地块瞬时跟上
        .onChange(of: selection) { _, newValue in
            if pillSelection != newValue { pillSelection = newValue }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.06))
        )
    }
}

// MARK: - 屏幕坐标换算的宿主窗口

/// 找一个能用来做「窗口坐标 ↔ 屏幕坐标」换算的**普通窗口**。
///
/// ⚠️ **别直接用 `NSApp.keyWindow` 单吊**（本项目三处锚点计算原来都这么写，2026-09-13 踩到）：
/// - **app 未激活时 `keyWindow` 是 nil** —— 而"从别的 App 点回来、`activate()` 没成功"时，
///   后续点击是**放行**的（见 `AppDelegate` 里 clickSwallow 的兜底，不放行会把用户锁死），
///   于是那段窗口期里点下拉 → 锚点算出 `.zero` → **面板弹到屏幕左下角**。
///   （日志实锤：某次 152 条弹出里 6 条 `anchor=(0,0,0,0) keyWindow=nil`，
///    全部落在 `[clickSwallow] 本段未激活期已吞过一次 → 放行` 那一段。）
/// - 就算激活，**keyWindow 也可能是下拉面板（`NSPanel`）本身** —— 用它的 `contentView.bounds.height`
///   去做 y 翻转会算错（面板和主窗口高度不一样）。
///
/// 所以依次退：`mainWindow`（面板不算 main window）→ `keyWindow` → 任意可见的非面板窗口。
@MainActor
func hostWindowForScreenRect() -> NSWindow? {
    NSApp.mainWindow
        ?? NSApp.keyWindow
        ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) }
}

/// 鼠标位置 → **SwiftUI 窗口坐标**（y 向下、原点 = 窗口内容左上）——窗口内浮层定位用。
///
/// 换算链：`NSEvent.mouseLocation`（屏幕、y 向上）→ `window.convertPoint`（窗口、y 向上）
/// → 用内容高度翻转成 SwiftUI 的 y 向下 —— 与 `geo.frame(in: .global)` 同一空间。
@MainActor
func mousePointInWindow() -> CGPoint {
    guard let window = hostWindowForScreenRect() ?? NSApp.keyWindow,
          let content = window.contentView else { return .zero }
    let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
    return CGPoint(x: p.x, y: content.bounds.height - p.y)
}

// MARK: - 弹层遮罩（真 AppKit）

/// **真 AppKit 遮罩层** —— 弹层（应用内浮层 / 两个抽屉 / 三个预览浮层）共用的"事件拦截层"。
///
/// **为什么要它**：SwiftUI 画的 `Color` 遮罩**不是 AppKit 视图**，AppKit 的 `hitTest`
/// 看不见它 → 滚轮事件直接命中它**下面**那个真正的 `NSScrollView`（= 弹层开着时后面列表照滚）。
/// 点击没这问题：点击走 SwiftUI 自己的手势分发，遮罩拦得住 ——
/// **「遮罩挡住了」≠「滚轮也挡住了」，这是两条不同的路径。**
///
/// ⚠️ 它**刻意参与命中**，与本项目其它 NSView（`WindowBackdropView` / `FrostedPanelView`）
/// 一律 `hitTest → nil` 的约定**相反**：它存在的唯一目的就是被 AppKit 命中。
/// 一旦被命中，滚轮事件就落到它手里 —— 不实现 `scrollWheel` 转发 = **消费掉**，
/// 不会再沿响应者链"往下钻"到弹层背后。
///
/// **实测（2026-09-13，`AppModal` 首轮验证）**：三个预期全部成立 ——
/// ① 滚轮不再穿透（日志里滚轮被接住 259 次）② 面板照常可点（没有一次点击误落到遮罩上）
/// ③ 面板内部的滚动区照常可滚。z-order 上 **SwiftUI 内容盖得住它**（与"内容区 SwiftUI 能盖住 AppKit 视图"一致）。
///
/// **用法**：在弹层 ZStack 里、`Color` 遮罩**之后**、内容**之前**放一层，
/// 并让它铺满（`.frame(maxWidth: .infinity, maxHeight: .infinity)`，需要时再 `.ignoresSafeArea()`）。
final class OverlayEventShieldView: NSView {
    /// 点遮罩 → 关闭（与 SwiftUI 那层 `Color` 的 `onTapGesture` 同一语义）
    var onTap: (() -> Void)?
    /// 可选：滚轮回调（不设 = 只吞不通知，现有用法行为不变）
    var onScroll: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        // point 在**父视图坐标系**里；本视图没有子视图，命中即自己
        return frame.contains(point) ? self : nil
    }

    /// **空实现 = 事件到此为止**（既不往上到窗口，更不会钻到背后的滚动视图）。
    /// ⚠️ 别"顺手"补一句 `super.scrollWheel(with:)` —— 那正是穿透的来源。
    override func scrollWheel(with event: NSEvent) { onScroll?() }

    override func mouseDown(with event: NSEvent) {
        onTap?()
    }

    /// 配对吞掉，别让"没有 down 的 up"漏给底下（本项目踩过：顶栏罩子会响应裸 up）
    override func mouseUp(with event: NSEvent) {}
}

struct OverlayEventShield: NSViewRepresentable {
    var onTap: () -> Void
    /// 可选：滚轮回调（默认 nil = 只吞不通知）
    var onScroll: (() -> Void)? = nil

    func makeNSView(context: Context) -> OverlayEventShieldView {
        let view = OverlayEventShieldView()
        view.onTap = onTap
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: OverlayEventShieldView, context: Context) {
        nsView.onTap = onTap
        nsView.onScroll = onScroll
    }
}


/// 播放条只在鼠标移到画面上时出来（2026-10-15 用户：二级页面的小预览和视频大预览一样）：移进淡入、移开淡出，看不见时不挡点击
private struct HoverRevealControls<Controls: View>: ViewModifier {
    let controls: () -> Controls
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                controls()
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

extension View {
    func hoverRevealControls<Controls: View>(@ViewBuilder _ controls: @escaping () -> Controls) -> some View {
        modifier(HoverRevealControls(controls: controls))
    }
}
