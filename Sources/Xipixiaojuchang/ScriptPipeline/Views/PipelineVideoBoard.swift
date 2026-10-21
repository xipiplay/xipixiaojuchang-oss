import SwiftUI

/// 一张卡片对应一条完整的多镜头视频；状态由真实文案、引用素材和任务推导。
struct PipelineVideoCard: Identifiable {
    struct Reference: Identifiable {
        var id: UUID
        var name: String
        var kind: String
        var ready: Bool
        var libraryItemID: UUID?
    }
    var id: Int { index }
    var index: Int
    var text: String
    var prompt: String
    var references: [Reference]
    var status: String
    var action: String
    var shotID: UUID?
    var hasVideo: Bool
    var canProduce: Bool

    static func preparationStep(_ work: EpWork) -> Int {
        (0..<4).first { !work.states.indices.contains($0) || work.states[$0] != .approved } ?? 4
    }

    static func prepareTitle(_ work: EpWork) -> String {
        switch preparationStep(work) {
        case 0: return work.descDraft.isEmpty ? "提取本集素材" : "确认本集素材"
        case 1: return work.segmentsRaw.isEmpty ? "分割 30 秒视频" : "确认段落方案"
        case 2:
            let total = PipelineRules.splitSegments(work.segmentsRaw).count
            return work.shots.count < total ? (work.shots.isEmpty ? "推理本集分镜" : "继续推理分镜") : "确认本集分镜"
        case 3:
            return work.checked.count < work.shots.count ? (work.checked.isEmpty ? "检查本集分镜" : "继续检查分镜") : "确认检查结果"
        default: return "制作详情"
        }
    }

    static func make(work: EpWork, dictionary: [DictEntry], projectKey: String, episode: Int,
                     library: [LibraryItem], shots: [ShotDraft], tasks: [LocalTask]) -> [Self] {
        let texts = PipelineRules.splitSegments(work.segmentsRaw)
        let count = max(texts.count, work.boundSegments.count, work.shots.count, work.checked.count)
        let step = preparationStep(work)
        return (0..<count).map { index in
            let segment = work.boundSegments.indices.contains(index) ? work.boundSegments[index] : nil
            let references = (segment?.bindings ?? []).filter { $0.usage == "出镜" }.map { binding in
                let entry = BindingRules.entry(binding, in: dictionary)
                let name = entry?.name ?? binding.internalName
                let candidates = library.filter {
                    $0.projectKey == projectKey && $0.kind == .image &&
                    ($0.name == name || ($0.name?.hasPrefix(binding.kind + "-") == true && $0.matchKeyword == name))
                }
                let item = candidates.first { $0.existingLocalImageURL != nil || !($0.remoteURL ?? "").isEmpty } ?? candidates.first
                let ready = item.map { $0.existingLocalImageURL != nil || !($0.remoteURL ?? "").isEmpty } ?? false
                return Reference(id: binding.id, name: name, kind: binding.kind, ready: ready, libraryItemID: item?.id)
            }
            let shot = shots.first { $0.projectKey == projectKey && $0.numbering?.a == episode && $0.numbering?.b == index + 1 }
            let taskIDs = Set((shot?.taskIDs ?? []) + (shot?.taskID.map { [$0] } ?? []))
            let task = tasks.filter { taskIDs.contains($0.id) }.max { $0.createdAt < $1.createdAt }
            let prompt = work.checked.indices.contains(index) ? work.checked[index] :
                (work.shots.indices.contains(index) ? work.shots[index] : "")
            let bindingReady = segment.map { BindingRules.issues($0, dictionary: dictionary, requireApproval: true).isEmpty } ?? false
            let canProduce = step == 4 && work.missing.isEmpty && work.checked.count == count && texts.count == count && work.boundSegments.count == count &&
                !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bindingReady
            let missing = references.filter { !$0.ready }.count
            var status: String
            var action: String
            switch step {
            case 0: status = work.descDraft.isEmpty ? "本集素材待提取" : "本集素材待确认"; action = prepareTitle(work)
            case 1: status = work.segmentsRaw.isEmpty ? "视频段落待准备" : "段落方案待确认"; action = prepareTitle(work)
            case 2: status = prompt.isEmpty ? "分镜待准备" : "分镜待确认"; action = prepareTitle(work)
            case 3: status = "分镜待检查"; action = prepareTitle(work)
            default:
                status = !canProduce ? "制作内容待确认" : (missing > 0 ? "缺 \(missing) 张参考图" : "可以生成视频")
                action = !canProduce ? "查看制作详情" : (missing > 0 ? "准备参考图" : "视频生成设置")
            }
            let hasVideo = task?.localVideoPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if let task {
                let preparationStatus = status
                switch task.phase {
                case .queued: status = "视频排队中"; action = "查看生成任务"
                case .inProgress: status = "视频生成中"; action = "查看生成任务"
                case .completed: status = hasVideo ? "视频已完成" : "视频已生成 · 待下载"; action = hasVideo ? "查看视频" : "查看生成任务"
                case .failed: status = "视频生成失败"; action = "查看失败并重试"
                case .paused: status = "视频任务已暂停"; action = "查看生成任务"
                }
                // 历史任务仍可查看，但不能把已经失效的本轮制作标成完成。
                if !canProduce || shot?.prompt != prompt {
                    status = preparationStatus + " · 历史" + status
                    if hasVideo { action = "查看历史视频" }
                }
            }
            return Self(index: index, text: texts.indices.contains(index) ? texts[index] : (segment?.text ?? ""),
                        prompt: prompt, references: references, status: status, action: action,
                        shotID: shot?.id, hasVideo: hasVideo, canProduce: canProduce)
        }
    }
}

