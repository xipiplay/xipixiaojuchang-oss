import Foundation
import Observation

@MainActor
@Observable
final class PollingManager {
    private var loops: [String: Task<Void, Never>] = [:]
    /// 「完成但下载失败」的自动重试循环（每 5 分钟一次、最多 2 小时；带断点续传）
    private var downloadRetries: [String: Task<Void, Never>] = [:]
    private let store: TaskStore
    /// 按渠道名取渠道配置（新提交的 `providerID` 存的就是渠道名）
    private let channelProvider: @MainActor (String) -> ModelChannel?
    private let projectNameProvider: @MainActor (String) -> String

    init(store: TaskStore,
         channelProvider: @escaping @MainActor (String) -> ModelChannel?,
         projectNameProvider: @escaping @MainActor (String) -> String) {
        self.store = store
        self.channelProvider = channelProvider
        self.projectNameProvider = projectNameProvider
    }

    var isPollingAny: Bool { !loops.isEmpty }

    /// 🎯 **上游超时兜底**（2026-10-01 用户定：**80 分钟**）：阶段的 `updatedAt` 超过这么久没变化
    /// → 判失败。原因：上游"超时"后可能仍返回"排队中/生成中"（或 App 不认识的状态），
    /// 以前会**永远停在排队中**（用户实测：器风后台已超时，App 还在排队）。
    private static let upstreamTimeout: TimeInterval = 80 * 60

    /// 上游报错要连续出现多久才判失败（2026-10-14 用户定 2 分钟）：防中转偶尔查询抽风、把还在跑的任务误判失败
    static let upstreamErrorGrace: TimeInterval = 2 * 60

    /// 这次查询带了上游报错（`error.message`）、状态又不是已完成 / 失败时怎么办：
    /// 返回新的「从什么时候开始一直报错」（`since`，没报错 = nil，中间有一次正常就重新计时）和要不要判失败（`fail` = 失败原因）
    static func upstreamErrorVerdict(_ status: VideoStatusResponse, since: Date?, now: Date) -> (since: Date?, fail: String?) {
        guard let reason = status.upstreamError, status.phase != .completed, status.phase != .failed else { return (nil, nil) }
        let start = since ?? now
        return (start, now.timeIntervalSince(start) >= upstreamErrorGrace ? reason : nil)
    }

    /// 启动时恢复所有进行中任务（各自按渠道配置；未配 Key / 渠道已删的跳过），
    /// 并给「完成但下载失败、且还在 2 小时链接有效期内的任务」续上自动重试。
    func resumeAllInProgress() {
        // 「不再等待」的（.paused）不自动恢复：用户在任务抽屉点「继续等待」才接着查（2026-10-06 P2）
        for task in store.tasks where task.phase == .queued || task.phase == .inProgress {
            // 防御：占位任务（pending-…）不是上游任务号，查不到 → 不恢复轮询。
            // （启动时 `TaskStore.loadFromDisk` 已清理遗留占位；这里只是别让漏网的也开始空转）
            guard !task.id.hasPrefix("pending-") else { continue }
            resumePolling(task)
        }
        for task in store.tasks {
            switch Self.downloadRecovery(for: task, now: Date()) {
            case .none: break
            case .retryLoop(let immediate): startDownloadRetryLoop(taskID: task.id, immediate: immediate)
            case .recoverURL: recoverResultURLAndRetry(taskID: task.id)
            }
        }
    }

    /// 启动时对一个任务该怎么处理它的下载
    enum DownloadRecovery: Equatable {
        case none
        /// 有直链：进 5 分钟一次的重试循环（`immediate` = 先立刻试一次）
        case retryLoop(immediate: Bool)
        /// 没存直链：查一次状态把直链补回来再试
        case recoverURL
    }

    /// 「完成了、却没有本地视频」的任务启动时怎么办：
    /// - 记着下载失败的（有错误信息）：直链在 2 小时有效期内就接着自动重试；没存直链的旧任务 24 小时内补查一次。
    /// - **没记下载失败**（没有错误信息）：下载到一半软件退出了——任务先被标成「已完成」、再开始下载，
    ///   中间退出（比如装新版本）就停在「已完成」却永远没有视频，也没人再管它（2026-10-10 分镜 1-3-1 就是这样）。
    ///   重启后接着下：链接是渠道自己的内容端点（带 key、不像公开直链那样很快过期），所以窗口放宽到 7 天，并且先立刻试一次。
    static func downloadRecovery(for task: LocalTask, now: Date) -> DownloadRecovery {
        guard task.phase == .completed, task.localVideoPath == nil else { return .none }
        let age = now.timeIntervalSince(task.updatedAt)
        if task.errorMessage == nil {
            guard age < interruptedDownloadWindow else { return .none }
            return task.resultURL != nil ? .retryLoop(immediate: true) : .recoverURL
        }
        if task.resultURL != nil { return age < downloadRetryWindow ? .retryLoop(immediate: false) : .none }
        return age < downloadRecoveryWindow ? .recoverURL : .none
    }

    /// 旧任务补直链：查一次状态 → 存住 → 立刻试下载一次（链接可能快过期），失败进 5 分钟循环
    private func recoverResultURLAndRetry(taskID: String) {
        guard loops[taskID] == nil, downloadRetries[taskID] == nil else { return }
        guard let task = store.task(id: taskID),
              let channel = channelProvider(task.providerID), !channel.apiKey.isEmpty else { return }
        let client = APIClient(channel: channel)
        loops[taskID] = Task { [weak self] in
            defer { self?.loops[taskID] = nil }
            do {
                let status = try await client.status(of: taskID)
                guard let url = status.videoURL else {
                    AppLog.write("download-retry", "补查直链：上游没给直链，放弃 task=\(taskID)")
                    return
                }
                AppLog.write("download-retry", "补到直链，立刻重试 task=\(taskID)")
                self?.store.updateResultURL(id: taskID, url: url.absoluteString)
                self?.startDownloadRetryLoop(taskID: taskID, immediate: true)
            } catch {
                AppLog.write("download-retry", "补查直链失败 task=\(taskID)：\(error.localizedDescription)")
            }
        }
    }

    /// 自动重试的窗口（秒）：链接一般 2 小时内有效，过了就没必要再试
    private static let downloadRetryWindow: TimeInterval = 2 * 3600
    /// 「没存直链」的旧任务补查窗口（秒）：只查一次状态、不反复试，所以放宽到 24 小时
    private static let downloadRecoveryWindow: TimeInterval = 24 * 3600
    /// 下载到一半软件退出了的任务，启动时接着下的窗口（秒）：7 天
    private static let interruptedDownloadWindow: TimeInterval = 7 * 24 * 3600
    /// 重试间隔（秒）
    private static let downloadRetryInterval: TimeInterval = 300

    /// 恢复/开始轮询（本地暂停的任务先置回排队中，等待下次状态刷新）
    func resumePolling(_ task: LocalTask) {
        guard loops[task.id] == nil else { return }
        if task.phase == .paused {
            store.update(id: task.id, phase: .queued)
        }
        guard let channel = channelProvider(task.providerID), !channel.apiKey.isEmpty else { return }
        let client = APIClient(channel: channel)
        loops[task.id] = Task { [weak self] in
            await self?.pollLoop(taskID: task.id, client: client)
        }
    }

    /// 取消单个任务的轮询（删除任务时调用）
    func cancelPolling(taskID: String) {
        loops[taskID]?.cancel()
        loops[taskID] = nil
    }

    /// 应用退出前调用
    func stopAll() {
        for loop in loops.values { loop.cancel() }
        loops.removeAll()
        for retry in downloadRetries.values { retry.cancel() }
        downloadRetries.removeAll()
    }

    private func pollLoop(taskID: String, client: APIClient) async {
        var consecutiveFailures = 0
        /// 从什么时候开始一直带上游报错（见 `upstreamErrorVerdict`）
        var upstreamErrorSince: Date?
        while !Task.isCancelled {
            do {
                let status = try await client.status(of: taskID)
                consecutiveFailures = 0
                if let progress = status.progress {
                    store.updateProgress(id: taskID, progress: progress)
                }
                let verdict = Self.upstreamErrorVerdict(status, since: upstreamErrorSince, now: Date())
                if upstreamErrorSince == nil, verdict.since != nil {
                    AppLog.write("status", "上游报错，连续 \(Int(Self.upstreamErrorGrace / 60)) 分钟就判失败 task=\(taskID)：\(status.upstreamError ?? "")")
                }
                upstreamErrorSince = verdict.since
                if let reason = verdict.fail {
                    store.update(id: taskID, phase: .failed, error: reason)
                    AppLog.write("status", "上游报错持续 \(Int(Self.upstreamErrorGrace / 60)) 分钟 → 标失败 task=\(taskID)")
                    AppAttention.notify(title: "视频生成失败", body: store.task(id: taskID)?.fileName ?? "", failed: true)
                    loops[taskID] = nil
                    return
                }
                guard let phase = status.phase else {
                    // 无法识别的状态：保持当前阶段继续轮询，不打断
                    try await Task.sleep(for: .seconds(4))
                    continue
                }
                // 🎯 2026-10-01（用户定：**只要进度有变化，就变成"生成中"**）：
                // 有的上游生成期间**一直**报 status=pending（映射成 queued），
                // 如果照原样写回去，会把"生成中"又打回"排队中"（用户实测：一直显示排队中）。
                // 规则：**只要已经有过进度**（progress > 0），阶段就不再退回排队中。
                var effectivePhase = phase
                if effectivePhase == .queued, (store.task(id: taskID)?.progressPercent ?? 0) > 0 {
                    effectivePhase = .inProgress
                }
                store.update(id: taskID, phase: effectivePhase)
                switch phase {
                case .completed:
                    await handleCompleted(taskID: taskID, client: client, status: status)
                    loops[taskID] = nil
                    return
                case .failed:
                    store.update(id: taskID, phase: .failed,
                                 error: status.failureReason ?? "平台返回失败")
                    AppAttention.notify(title: "视频生成失败", body: store.task(id: taskID)?.fileName ?? "", failed: true)
                    loops[taskID] = nil
                    return
                case .queued, .inProgress, .paused:
                    // 🎯 超时兜底：阶段 80 分钟没变化 → 判失败（上游可能"超时"但状态仍是排队/生成中）
                    if let live = store.task(id: taskID),
                       Date().timeIntervalSince(live.updatedAt) > Self.upstreamTimeout {
                        let what = live.phase == .queued ? "排队" : "生成"
                        store.update(id: taskID, phase: .failed,
                                     error: "上游超时：\(what)超过 \(Int(Self.upstreamTimeout / 60)) 分钟没有进展")
                        AppLog.write("status", "上游超时兜底 → 标失败 task=\(taskID) 阶段=\(live.phase)")
                        loops[taskID] = nil
                        return
                    }
                    try await Task.sleep(for: .seconds(4))
                }
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                let delay: Duration = consecutiveFailures >= 5 ? .seconds(15) : .seconds(4)
                try? await Task.sleep(for: delay)
            }
        }
        loops[taskID] = nil
    }

    /// 完成后立即下载转存（直链有时效）
    private func handleCompleted(taskID: String, client: APIClient, status: VideoStatusResponse) async {
        // 优先用完成状态响应里的视频直链
        if let url = status.videoURL {
            // **先把直链存住**：下载失败后自动重试 / 断点续传都要用它（链接会过期）
            store.updateResultURL(id: taskID, url: url.absoluteString)
            await downloadWithRetry(from: url, taskID: taskID)
            return
        }
        // 回退：内容端点（直接返回视频二进制）
        var lastError: Error = APIError.invalidContent
        for attempt in 0..<3 {
            do {
                let data = try await client.downloadContent(of: taskID)
                await downloadDataWithRetry(data, taskID: taskID)
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        store.update(id: taskID, phase: .completed,
                     error: "视频已生成，但下载转存失败：\(lastError.localizedDescription)")
    }

    /// 对已完成但下载失败的任务重新下载（不重复计费）：
    /// 有存住的直链就直接下（带断点续传），没有才去查状态拿直链。
    func retryDownload(taskID: String) {
        guard loops[taskID] == nil else { return }
        guard let task = store.task(id: taskID) else { return }
        if let urlString = task.resultURL, let url = URL(string: urlString) {
            downloadRetries[taskID]?.cancel()
            downloadRetries[taskID] = Task { [weak self] in
                guard let self else { return }
                do {
                    let localURL = try await DownloadService.downloadVideo(
                        from: url,
                        fileName: self.downloadFileName(taskID: taskID),
                        projectKey: self.downloadProjectKey(taskID: taskID),
                        authorization: self.downloadAuthorization(for: url, taskID: taskID)
                    )
                    self.finishDownload(taskID: taskID, localURL: localURL)
                } catch {
                    self.store.update(id: taskID, phase: .completed,
                                      error: "重新下载失败：\(error.localizedDescription)")
                }
                self.downloadRetries[taskID] = nil
            }
            return
        }
        guard let channel = channelProvider(task.providerID), !channel.apiKey.isEmpty else { return }
        let client = APIClient(channel: channel)
        loops[taskID] = Task { [weak self] in
            await self?.retryDownloadLoop(taskID: taskID, client: client)
        }
    }

    private func retryDownloadLoop(taskID: String, client: APIClient) async {
        defer { loops[taskID] = nil }
        do {
            let status = try await client.status(of: taskID)
            if let url = status.videoURL {
                await downloadWithRetry(from: url, taskID: taskID)
            } else {
                let data = try await client.downloadContent(of: taskID)
                await downloadDataWithRetry(data, taskID: taskID)
            }
        } catch {
            store.update(id: taskID, phase: .completed,
                         error: "重新下载失败：\(error.localizedDescription)")
        }
    }

    /// 结果链接要渠道认证时才返回 `"Bearer <key>"`（2026-09-26 修「下载 401」）。
    ///
    /// 有些中转的结果直链就是**它自己的内容端点**（`{base}/v1/videos/{id}/content`），
    /// 要它自己的 key —— 裸 GET 一律 401，重试 2 小时也没用（用户实测）。
    /// **只在链接与渠道同域时带**：其它渠道给的是公开直链（r2.dev 等），不带、也不该带。
    private func downloadAuthorization(for url: URL, taskID: String) -> String? {
        guard let task = store.task(id: taskID),
              let channel = channelProvider(task.providerID),
              !channel.apiKey.isEmpty,
              let baseHost = URL(string: channel.baseURL)?.host?.lowercased(),
              let host = url.host?.lowercased(),
              host == baseHost else { return nil }
        return "Bearer \(channel.apiKey)"
    }

    /// 下载并转存，失败重试 3 次
    private func downloadWithRetry(from url: URL, taskID: String) async {
        var lastError: Error = APIError.transport("下载失败")
        for attempt in 0..<3 {
            do {
                let localURL = try await DownloadService.downloadVideo(
                    from: url,
                    fileName: downloadFileName(taskID: taskID),
                    projectKey: downloadProjectKey(taskID: taskID),
                    authorization: downloadAuthorization(for: url, taskID: taskID)
                )
                finishDownload(taskID: taskID, localURL: localURL)
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        store.update(id: taskID, phase: .completed,
                     error: "视频已生成，但下载转存失败：\(lastError.localizedDescription)")
        // 上游慢链 / 转存抽风时靠它自动补：每 5 分钟一次、最多 2 小时（带断点续传）
        startDownloadRetryLoop(taskID: taskID)
    }

    /// 「完成但下载失败」的自动重试：每 5 分钟一次、最多 2 小时（24 次）。
    /// 下载本身带断点续传（只补缺的字节）——上游恢复后视频会自动下来，不用人盯。
    private func startDownloadRetryLoop(taskID: String, immediate: Bool = false) {
        guard downloadRetries[taskID] == nil else { return }
        guard let task = store.task(id: taskID), task.resultURL != nil else { return }
        AppLog.write("download-retry", "启动自动重试 task=\(taskID)（每 5 分钟，最多 2 小时\(immediate ? "，先立即试一次" : "")）")
        downloadRetries[taskID] = Task { [weak self] in
            for attempt in 1...24 {
                if !(immediate && attempt == 1) {
                    try? await Task.sleep(for: .seconds(Self.downloadRetryInterval))
                }
                guard !Task.isCancelled, let self else { return }
                guard let task = self.store.task(id: taskID),
                      let urlString = task.resultURL,
                      let url = URL(string: urlString) else {
                    self.downloadRetries[taskID] = nil
                    return
                }
                do {
                    let localURL = try await DownloadService.downloadVideo(
                        from: url,
                        fileName: self.downloadFileName(taskID: taskID),
                        projectKey: self.downloadProjectKey(taskID: taskID),
                        authorization: self.downloadAuthorization(for: url, taskID: taskID)
                    )
                    self.finishDownload(taskID: taskID, localURL: localURL)
                    AppLog.write("download-retry", "第 \(attempt) 次重试成功 task=\(taskID)")
                    self.downloadRetries[taskID] = nil
                    return
                } catch {
                    AppLog.write("download-retry", "第 \(attempt) 次重试失败：\(error.localizedDescription)")
                    // 之前没记过失败的（比如启动时接着下「下载到一半退出」的任务）：记上，任务列表里才看得到「下载失败」而不是一直「已完成」
                    if self.store.task(id: taskID)?.errorMessage == nil {
                        self.store.update(id: taskID, phase: .completed, error: "视频已生成，但下载转存失败：\(error.localizedDescription)")
                    }
                }
            }
            AppLog.write("download-retry", "重试上限已到（2 小时），放弃 task=\(taskID)")
            self?.downloadRetries[taskID] = nil
        }
    }

    /// 内容端点的二进制落盘（同 `downloadWithRetry` 的重试与收尾）
    private func downloadDataWithRetry(_ data: Data, taskID: String) async {
        var lastError: Error = APIError.transport("下载失败")
        for attempt in 0..<3 {
            do {
                let localURL = try DownloadService.downloadVideo(
                    data: data,
                    fileName: downloadFileName(taskID: taskID),
                    projectKey: downloadProjectKey(taskID: taskID)
                )
                finishDownload(taskID: taskID, localURL: localURL)
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
        store.update(id: taskID, phase: .completed,
                     error: "视频已生成，但下载转存失败：\(lastError.localizedDescription)")
    }

    private func downloadFileName(taskID: String) -> String {
        store.task(id: taskID)?.fileName ?? taskID
    }

    /// 视频下载进所属项目的文件夹（2.0 按项目 ID）
    private func downloadProjectKey(taskID: String) -> String {
        store.task(id: taskID)?.groupKey ?? ""
    }

    private func finishDownload(taskID: String, localURL: URL) {
        let start = Date()
        store.attachVideo(id: taskID, localPath: localURL.path)
        AppAttention.notify(title: "视频生成完成", body: store.task(id: taskID)?.fileName ?? "")
        // 预生成首帧缩略图，滚动卡片时直接内存命中
        VideoThumbnailCache.warmUp(path: localURL.path)
        // 批量回传卡顿排查（2026-10-21）：主线程上这一步花了多久（界面重画另算，见「工作台状态重算」）
        AppLog.write("perf", "视频回传 task=\(taskID) 写回任务 \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
}
