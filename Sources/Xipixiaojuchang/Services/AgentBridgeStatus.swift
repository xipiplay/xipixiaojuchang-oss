import Foundation

// MARK: - 状态快照（`AgentBridge/status.json`）
//
// 外部智能体靠它回答三件事：软件在不在线、有哪些请求在等我回答、每个项目每一集做到哪了 / 哪里失败了。
// 只放「进度和结果」，不放剧本正文。内容没变时每 3 秒刷新一次 `updatedAt` 当心跳：超过十几秒没更新 = 软件没开 / 接力关了。

struct AgentStatus: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var updatedAt: Date
    /// 设置里的「外部智能体接力」是否开着（关着时这个文件只写最后一次）
    var agentMode: Bool
    var appVersion: String
    var bridgeDirectory: String
    var pendingRequests: [PendingRequest]
    var projects: [Project]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol", updatedAt, agentMode, appVersion, bridgeDirectory, pendingRequests, projects
    }

    struct PendingRequest: Codable, Equatable, Sendable {
        var id: String
        var kind: String
        var project: String?
        var projectName: String?
        var episode: Int?
        var createdAt: Date
        var file: String
        var responseFile: String
        /// 已有子智能体领走在做（`xipi.py unpack` 会登记）
        var claimed: Bool
    }

    /// 只列导入过剧本的项目
    struct Project: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var episodes: [Episode]
        /// 这个项目里生图页的卡片数（提取素材建的）/ 生视频页的卡片数（推理分镜建的）
        var imageCards: Int
        var videoCards: Int
        var batch: Batch?
        /// 正在跑或刚结束的任务（含失败的原因）
        var jobs: [Job]
    }

    struct Episode: Codable, Equatable, Sendable {
        var number: Int
        var title: String
        var chars: Int
        /// 做过「时长分割」
        var split: Bool
        var splitChars: Int
        /// 分割结果里有几个 30 秒段（按时间标号数，末尾的「结束。」不算）；没分割过、或一个时间标号都没有 = 没有这个字段。
        /// 推理分镜要求输出的分镜块数必须等于它——分割完先核对，别等推理时才发现
        var segments: Int?
        /// 每一段都有场景头行了（做过「分段命名」，或分割自带头行）。推理分镜要先命名
        var named: Bool
        /// 「推理分镜」给这一集建的生视频卡数（没推理过 = 0）
        var storyboardCards: Int
    }

    struct Batch: Codable, Equatable, Sendable {
        var kind: String          // split / name / extract / infer
        var title: String
        var total: Int
        var succeeded: Int
        var failed: [Failure]
        /// 提取素材 / 推理分镜：建出（或更新）的卡片数
        var created: Int
        /// 推理分镜停在某一集后没轮到的集数
        var skipped: Int
        var finished: Bool
    }

    struct Failure: Codable, Equatable, Sendable {
        var label: String
        var message: String
    }

    struct Job: Codable, Equatable, Sendable {
        var step: String
        /// 集号（1 起）；不挂在某一集上的任务（提取素材、推理分镜、剧本分集）没有
        var episode: Int?
        var slot: String?
        var note: String
        var active: Bool
        var failed: Bool
    }
}

/// 一集的原文 / 分割没变，字数和分割段数就不用重算（每秒一次，这些在主线程上算：60 集 × 多个项目曾每次占 ~180 ms）
struct EpisodeStatusCacheEntry {
    var text: String
    var splitText: String?
    var chars: Int
    var splitChars: Int
    var hasSplit: Bool
    var segments: Int?
    var named: Bool
}

extension AgentBridge {
    func buildStatus(now: Date) -> AgentStatus {
        let info = Bundle.main.infoDictionary
        let version = [info?["CFBundleShortVersionString"] as? String, (info?["CFBundleVersion"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        var projects: [AgentStatus.Project] = []
        if let app {
            // 卡片数一遍数完（不要每个项目各扫一遍全部卡片）
            var imageCards: [String: Int] = [:], videoCards: [String: Int] = [:]
            // 按下标只读 projectKey：`for item in` 会把每张卡整个复制一遍（两千多张，每秒一次，抓栈里占了一大块）
            let items = app.imageItems, shots = app.shots
            for i in items.indices { imageCards[items[i].projectKey, default: 0] += 1 }
            for i in shots.indices { videoCards[shots[i].projectKey, default: 0] += 1 }
            var seen = Set<UUID>()
            for (key, meta) in app.projectMetas.sorted(by: { $0.value.updatedAt > $1.value.updatedAt }) {
                guard let archive = app.pipelineArchive(for: key) else { continue }
                projects.append(project(key: key, name: meta.name, archive: archive, app: app,
                                        imageCards: imageCards[key] ?? 0, videoCards: videoCards[key] ?? 0, seen: &seen))
            }
            episodeStatusCache = episodeStatusCache.filter { seen.contains($0.key) }      // 删掉的集不留缓存
        }
        return AgentStatus(
            protocolVersion: Self.protocolVersion, updatedAt: now, agentMode: isRunning,
            appVersion: version.isEmpty ? "?" : version, bridgeDirectory: root.path,
            pendingRequests: pendingRequests().map { request in
                AgentStatus.PendingRequest(
                    id: request.id, kind: request.kind, project: request.project, projectName: request.projectName,
                    episode: request.episode, createdAt: request.createdAt,
                    file: requestsDirectory.appendingPathComponent("\(request.id).json").path, responseFile: request.responseFile,
                    claimed: claimedIDs.contains(request.id))
            },
            projects: projects
        )
    }

    private func project(key: String, name: String, archive: ProjectPipelineArchive, app: AppModel,
                         imageCards: Int, videoCards: Int, seen: inout Set<UUID>) -> AgentStatus.Project {
        let episodes = archive.episodes.enumerated().map { index, episode -> AgentStatus.Episode in
            seen.insert(episode.id)
            let cached: EpisodeStatusCacheEntry
            if let hit = episodeStatusCache[episode.id], hit.text == episode.text, hit.splitText == episode.splitText {
                cached = hit
            } else {
                cached = EpisodeStatusCacheEntry(
                    text: episode.text, splitText: episode.splitText, chars: episode.text.count,
                    splitChars: episode.splitText?.count ?? 0,
                    hasSplit: !(episode.splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    segments: episode.splitText.flatMap { StoryboardInference.expectedBlockCount(in: $0) },
                    named: SplitSegments.isNamed(episode.splitText ?? ""))
                episodeStatusCache[episode.id] = cached
            }
            return AgentStatus.Episode(
                number: index + 1, title: episode.title, chars: cached.chars, split: cached.hasSplit,
                splitChars: cached.splitChars, segments: cached.segments, named: cached.named,
                storyboardCards: episode.shotIDs?.count ?? 0)
        }
        let batch = app.pipelineFlow.batches[key].map { state in
            AgentStatus.Batch(
                kind: Self.kindName(state.kind), title: state.title, total: state.total, succeeded: state.succeeded,
                failed: state.failures.sorted { $0.order < $1.order }.map { AgentStatus.Failure(label: $0.label, message: $0.message) },
                created: state.created, skipped: state.skipped, finished: state.finished)
        }
        let prefix = key + "/"
        let jobs = app.pipelineFlow.jobs.filter { $0.key.hasPrefix(prefix) }.map { entry -> AgentStatus.Job in
            let suffix = String(entry.key.dropFirst(prefix.count))
            let episode = UUID(uuidString: suffix).flatMap { id in archive.episodes.firstIndex { $0.id == id } }.map { $0 + 1 }
            return AgentStatus.Job(
                step: entry.value.stage.rawValue, episode: episode, slot: episode == nil && suffix != "script" ? suffix : nil,
                note: entry.value.note, active: entry.value.active, failed: entry.value.failed)
        }.sorted { ($0.episode ?? 0, $0.slot ?? "", $0.step) < ($1.episode ?? 0, $1.slot ?? "", $1.step) }
        return AgentStatus.Project(
            id: key, name: name, episodes: episodes, imageCards: imageCards, videoCards: videoCards,
            batch: batch, jobs: jobs)
    }

    private static func kindName(_ kind: PipelineFlow.BatchState.Kind) -> String {
        switch kind {
        case .split: "split"
        case .extract: "extract"
        case .infer: "infer"
        case .naming: "name"
        }
    }
}
