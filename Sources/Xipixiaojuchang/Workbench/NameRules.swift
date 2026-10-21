import Foundation

// MARK: - 名字确认（2026-10-07 P3-2 第 2 步）
//
// AI 给每段写的素材名，有些和设定对不上（「热饭饭盒」「蒸蛋」「床」…）。用户一次确认后：
// - 对应到已有设定：把所有段里的这个名字改成设定名，并把它记成该设定的别名；
// - 新建设定：给用到它的每一集加一项素材（类型 + 名字 + 描述，描述可以先空着）；
// - 忽略：从所有段里去掉，并记进项目的「忽略名单」。
// 之后各集新分出来 / 新提取出来的名字按别名和忽略名单自动处理（`NameRules.normalize`）。
// 别名 / 忽略名单只存在项目文件里（`SettingRecord.aliases`、`ProjectDocument.ignoredNames`）。
// 这里全是纯函数；写数据在 `AppModel.applyNameDecisions`。

/// 一个名字的处理方式
enum NameChoice: Equatable, Sendable {
    /// 对应到已有设定（用设定名，不是 ID：段里存的就是名字）
    case alias(settingName: String)
    case create(kind: SettingKind, description: String)
    case ignore
}

struct NameDecision: Equatable, Sendable {
    var name: String
    var choice: NameChoice
}

/// 项目里确认过的名字规则
struct NameRules: Equatable, Sendable {
    /// 别名 → 设定名
    var aliases: [String: String] = [:]
    var ignored: Set<String> = []

    init() {}

    init(doc: ProjectDocument?) {
        guard let doc else { return }
        for setting in doc.settings {
            for alias in setting.aliases where alias != setting.name { aliases[alias] = setting.name }
        }
        ignored = Set(doc.ignoredNames ?? [])
    }

    /// 一串名字过一遍规则：忽略的去掉，别名换成设定名，去重保序
    func normalize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names where !ignored.contains(name) {
            let mapped = aliases[name] ?? name
            if seen.insert(mapped).inserted { result.append(mapped) }
        }
        return result
    }

    /// 本项目新提取出来的素材：忽略的、已经是别名的（用已有设定就行）不再新建
    func keepsExtractedAsset(named name: String) -> Bool {
        !ignored.contains(name) && aliases[name] == nil
    }
}

enum NameConfirmation {
    /// 没有对应设定时，按原文猜新建什么类型：写在「场景：」后面的是场景；
    /// 以「[名字]：」当台词人出现的是角色；其余当道具。只是预选，用户可以改。
    static func inferKind(of name: String, in texts: [String]) -> SettingKind {
        if texts.contains(where: { text in ["场景：", "场景:", "场景: "].contains { text.contains($0 + name) } }) { return .scene }
        if texts.contains(where: { $0.contains("[\(name)]") || $0.contains("\n\(name)：") || $0.hasPrefix("\(name)：") }) { return .character }
        return .prop
    }

    /// 预先给一个建议：设定名包含这个名字、或这个名字包含设定名（至少 2 个字）→ 对应到最长的那个；
    /// 否则建议新建（类型按原文猜，见 `inferKind`）。只是预选，用户可以改。
    static func suggest(for name: String, settings: [SettingRecord], texts: [String] = []) -> NameChoice {
        let candidates = settings.filter { setting in
            guard setting.kind != .imported, setting.kind != .other, setting.name.count >= 2, name.count >= 2 else { return false }
            return name.contains(setting.name) || setting.name.contains(name)
        }
        if let best = candidates.max(by: { $0.name.count < $1.name.count }) { return .alias(settingName: best.name) }
        return .create(kind: inferKind(of: name, in: texts), description: "")
    }

    // MARK: 写进剧本里的一集

    /// 把决定应用到一集的工作区。返回有没有改动。
    @discardableResult
    static func apply(_ decisions: [NameDecision], to work: inout SimpleEpisodeWork) -> Bool {
        var changed = false
        for decision in decisions {
            let name = decision.name
            let used = work.segments.contains { $0.assetNames.contains(name) }
            switch decision.choice {
            case .alias(let target):
                for i in work.segments.indices where work.segments[i].assetNames.contains(name) {
                    var seen = Set<String>()
                    work.segments[i].assetNames = work.segments[i].assetNames.map { $0 == name ? target : $0 }
                        .filter { seen.insert($0).inserted }
                    changed = true
                }
            case .ignore:
                for i in work.segments.indices where work.segments[i].assetNames.contains(name) {
                    work.segments[i].assetNames.removeAll { $0 == name }
                    changed = true
                }
            case .create(let kind, let description):
                guard used, let pipelineKind = kind.pipelineKind,
                      !work.assets.contains(where: { $0.name == name && $0.kind == pipelineKind }) else { continue }
                work.assets.append(SimplePipelineAsset(kind: pipelineKind, name: name,
                                                       description: description.trimmingCharacters(in: .whitespacesAndNewlines)))
                changed = true
            }
        }
        return changed
    }

    // MARK: 写进项目文件的别名 / 忽略名单

    /// 别名记到对应设定上、忽略名单记到项目上。返回有没有改动。
    @discardableResult
    static func record(_ decisions: [NameDecision], in doc: inout ProjectDocument) -> Bool {
        var changed = false
        for decision in decisions {
            switch decision.choice {
            case .alias(let target):
                guard let i = doc.settings.firstIndex(where: { $0.name == target }), target != decision.name,
                      !doc.settings[i].aliases.contains(decision.name) else { continue }
                doc.settings[i].aliases.append(decision.name)
                changed = true
            case .ignore:
                var list = doc.ignoredNames ?? []
                guard !list.contains(decision.name) else { continue }
                list.append(decision.name)
                doc.ignoredNames = list
                changed = true
            case .create:
                continue
            }
        }
        return changed
    }
}
