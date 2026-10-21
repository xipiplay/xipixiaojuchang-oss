import Foundation

/// 分镜校验：新协议下线了「系列 / 能力矩阵」，只保留通用约束，
/// 具体模型是否接受某类素材由服务端决定。
/// 供分镜卡片提交按钮与批量提交共用。
enum ShotValidator {
    static func validate(_ shot: ShotDraft) -> [String] {
        var issues: [String] = []
        if shot.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append("请先在设置里添加渠道与模型，并在卡片上选择模型")
        }
        if shot.duration < 1 || shot.duration > 30 {
            issues.append("时长必须在 1~30 秒之间")
        }
        issues += danglingTokenIssues(shot)
        return issues
    }

    /// 提示词里引用了没挂上的素材（2026-10-16 用户：提示词写了「音频1」，分镜上却没有音频，提交时音频悄悄没了）：
    /// 「图N / 视频N / 音频N」的 N 超过这一类已挂的个数就拦下，说清楚缺什么
    static func danglingTokenIssues(_ shot: ShotDraft) -> [String] {
        [("图", "张图", shot.imageRefs.count), ("视频", "段视频", shot.videoRefs.count), ("音频", "段音频", shot.audioRefs.count)]
            .compactMap { prefix, unit, attached in
                guard let regex = try? NSRegularExpression(pattern: "\(prefix)(\\d+)") else { return nil }
                let ns = shot.prompt as NSString
                let highest = regex.matches(in: shot.prompt, range: NSRange(location: 0, length: ns.length))
                    .compactMap { Int(ns.substring(with: $0.range(at: 1))) }.max() ?? 0
                guard highest > attached else { return nil }
                return attached == 0
                    ? "提示词里写了「\(prefix)\(highest)」，但这一段还没有挂\(prefix)，先在素材区添加"
                    : "提示词里写到「\(prefix)\(highest)」，但只挂了 \(attached) \(unit)"
            }
    }
}
