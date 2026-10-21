import Foundation

/// 任务阶段（含本地「已暂停」，平台无取消接口）
enum TaskPhase: String, Codable, Sendable {
    case queued
    case inProgress
    case completed
    case failed
    case paused

    var displayName: String {
        switch self {
        case .queued: "排队中"
        case .inProgress: "生成中"
        case .completed: "已完成"
        case .failed: "失败"
        case .paused: "已暂停"
        }
    }

    /// 服务端状态字符串 → 本地阶段；未知返回 nil
    init?(serverStatus: String) {
        switch serverStatus.lowercased() {
        case "not_start", "queued", "pending", "waiting", "created", "submitted", "initialized", "init", "idle":
            self = .queued
        case "in_progress", "processing", "running", "generating", "started":
            self = .inProgress
        case "completed", "succeed", "succeeded", "success", "done", "finished", "finish":
            self = .completed
        case "failed", "fail", "failure", "error", "cancelled", "canceled":
            self = .failed
        default:
            return nil
        }
    }
}

/// 本地任务记录（JSON 持久化）
struct LocalTask: Codable, Identifiable, Equatable, Sendable {
    let id: String                    // 服务端 task_id
    var model: String                 // 模型名（渠道里配置的 ChannelModel.name）
    var providerID: String = ""       // 生成渠道名（追溯用；老值原样保留）
    var prompt: String
    var duration: Int
    var aspectRatio: AspectRatio = .adaptive
    var resolution: Resolution? = nil // 视频分辨率档位（显示用；旧数据可能缺失）
    var generateAudio: Bool = true
    var phase: TaskPhase
    var createdAt: Date
    var updatedAt: Date
    var costFen: Int = 0              // 预估费用（分）
    var localVideoPath: String?
    /// 结果直链（完成时存住；下载失败后的自动重试 / 断点续传要用，链接一般有时效）
    var resultURL: String? = nil
    var errorMessage: String?
    var progressPercent: Double? = nil  // 进度 0~100（瞬态，不落盘）
    var queuePosition: Int? = nil       // 排队位置（瞬态，不落盘）
    var referenceImageURLs: [String]?  // 提交时的参考图直链（用于「重新编辑」恢复）
    var referenceVideoURLs: [String]?
    var referenceAudioURLs: [String]?
    var sourceLibraryItemIDs: [UUID]?   // 来源素材库条目（追溯）
    var sourceImageResultIDs: [UUID]?   // 来源图片生成版本（追溯）
    var groupID: String?               // 重新编辑链分组：组内任务共享同一 groupID（源任务无 groupID 时用源任务 id）
    var fileName: String? = nil             // 下载文件名（「X-分镜-Y」，视频缓存命名用）

    /// 分组键：无 groupID 的任务自成一组
    var groupKey: String { groupID ?? id }

    /// 模型 + 分辨率摘要（任务列表显示用）
    var modeSummary: String {
        let name = model.isEmpty ? "视频" : model
        if let resolution { return "\(name) · \(resolution.displayName)" }
        return name
    }
}

// 自定义解码放扩展里：保留成员初始化器（调用方大量使用显式 init 创建任务）
extension LocalTask {
    /// 这一版的版本号：文件名最后一段（「1-2-8」→ 8）。所有历史版本列表、预览左上角都用它（2026-10-16 用户：工作台和生视频侧对不上）；
    /// 没有文件名的老任务退回它在分镜 `taskIDs` 里的序号
    func versionNumber(in taskIDs: [String]) -> Int {
        if let name = fileName, let last = name.split(separator: "-").last, let v = Int(last) { return v }
        return (taskIDs.firstIndex(of: id) ?? 0) + 1
    }
}

extension LocalTask {
    enum CodingKeys: String, CodingKey {
        case id, model, providerID, prompt, duration, aspectRatio, resolution, generateAudio, phase
        case createdAt, updatedAt, costFen, localVideoPath, resultURL, errorMessage
        case referenceImageURLs, referenceVideoURLs, referenceAudioURLs
        case sourceLibraryItemIDs, sourceImageResultIDs, groupID
        case fileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // 旧数据里 model 是 WanModel rawValue（String）→ 原样保留
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        // 旧数据里 providerID 是 VideoProviderID rawValue（String）→ 原样保留
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? ""
        prompt = try c.decode(String.self, forKey: .prompt)
        duration = try c.decode(Int.self, forKey: .duration)
        aspectRatio = try c.decodeIfPresent(AspectRatio.self, forKey: .aspectRatio) ?? .adaptive
        resolution = try? c.decodeIfPresent(Resolution.self, forKey: .resolution) ?? nil
        generateAudio = try c.decodeIfPresent(Bool.self, forKey: .generateAudio) ?? true
        phase = try c.decode(TaskPhase.self, forKey: .phase)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        costFen = try c.decodeIfPresent(Int.self, forKey: .costFen) ?? 0
        localVideoPath = try c.decodeIfPresent(String.self, forKey: .localVideoPath)
        resultURL = try c.decodeIfPresent(String.self, forKey: .resultURL)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        referenceImageURLs = try c.decodeIfPresent([String].self, forKey: .referenceImageURLs)
        referenceVideoURLs = try c.decodeIfPresent([String].self, forKey: .referenceVideoURLs)
        referenceAudioURLs = try c.decodeIfPresent([String].self, forKey: .referenceAudioURLs)
        sourceLibraryItemIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceLibraryItemIDs)
        sourceImageResultIDs = try c.decodeIfPresent([UUID].self, forKey: .sourceImageResultIDs)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
    }
}
