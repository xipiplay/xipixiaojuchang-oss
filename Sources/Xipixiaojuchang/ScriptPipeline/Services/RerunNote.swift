import Foundation

/// 项目的「时代背景」（2026-10-11）：提取场景 / 角色 / 道具的提示词都写着「用户提供了时代背景时逐字照抄」，
/// 软件把它放在每个提取请求里（分批、三类同时跑也是同一个说法）。没填就什么都不加
enum EraBackground {
    static func block(_ era: String?) -> String {
        let trimmed = era?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "" : "【时代背景（用户指定：逐字照抄，所有条目用同一个说法）】\n\(trimmed)\n\n"
    }
    static func prefixed(_ message: String, era: String?) -> String { block(era) + message }
}

/// 重跑时用户手写的「补充要求」（2026-10-09）：分割 / 分镜 / 提取 / 重新推理一段，点开选择框都有一个给 AI 打字的地方。
/// 只对**这一次**请求生效，不改设置里的提示词规则：软件把它放在这次发给 AI 的内容最前面，和平常的内容用一行分隔线隔开。
/// 外部智能体接力时它出现在 `user.txt` 开头，子智能体照做。
/// 典型用法：「把第 2 段和第 3 段合并成一段」「第 4 段在『你走吧』那句之后拆成两段」「这一集分段再细一点，台词别拆开」。
enum RerunNote {
    static let opening = "【补充要求（用户这一次手写的：照着做；但输出格式和「台词一字不改」这些规定不能违背）】"
    static let closing = "【补充要求到此为止，下面是要处理的内容】"

    /// 没写（或只有空白）就是空串
    static func block(_ note: String) -> String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\(opening)\n\(trimmed)\n\(closing)\n\n"
    }

    /// 把补充要求放在发给 AI 的内容前面；没写就原样
    static func prefixed(_ message: String, note: String) -> String { block(note) + message }
}
