import Foundation

/// 跨集结尾状态与承接规则
enum ContinuityRules {

    static func sceneHeader(_ text: String) -> String? {
        let pattern = "(?m)^\\s*(?:【|\\[)?场景\\s*[:：]\\s*([^\\n]+)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "】]"))
    }

    static func shotScene(_ text: String) -> String? {
        guard let first = text.split(separator: "\n").first,
              first.hasPrefix("["), let end = first.firstIndex(of: "]") else { return nil }
        return String(first[first.index(after: first.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
    }

    static func firstScene(segment: String, updates: [DescUpdate], dictionary: [DictEntry]) -> String? {
        guard let header = sceneHeader(segment) else { return nil }
        func matches(_ name: String) -> Bool {
            header == name || header.hasPrefix(name + " ") || header.hasPrefix(name + "\t")
        }
        let scenes = PipelineRules.episodeEntries(updates: updates, dictionary: dictionary).filter { $0.kind == "场景" }
        let exact = scenes.filter { matches($0.name) }.sorted { $0.name.count > $1.name.count }
        if let first = exact.first { return first.name }
        let aliases = Set(updates.filter { $0.kind == "场景" && matches($0.name) }
            .map(\.displayName).filter { name in scenes.contains { $0.name == name } })
        return aliases.count == 1 ? aliases.first : nil
    }

    static func stateIssue(_ state: EndState?, episode: Int, tail: String, dictionary: [DictEntry], expectedScene: String? = nil) -> String? {
        guard let state, state.isComplete else { return "尾段尚无完整结尾状态，请补齐或重新生成尾段。" }
        guard state.episode == episode else { return "结尾状态的来源集号不正确。" }
        guard dictionary.contains(where: { $0.kind == "场景" && $0.name == state.sceneName }),
              (expectedScene ?? shotScene(tail)) == state.sceneName else { return "结尾状态场景须与尾段场景及词典规范名一致。" }
        return nil
    }

    static func approvedState(_ work: EpWork, episode: Int, dictionary: [DictEntry]) -> EndState? {
        guard work.boundSegments.isEmpty || (work.boundSegments.count == PipelineRules.splitSegments(work.segmentsRaw).count && work.boundSegments.allSatisfy { BindingRules.issues($0, dictionary: dictionary).isEmpty }) else { return nil }
        guard work.states.prefix(4).count == 4, work.states.prefix(4).allSatisfy({ $0 == .approved }),
              !work.checked.isEmpty, work.checked.count == work.shots.count,
              work.shots.count == PipelineRules.splitSegments(work.segmentsRaw).count,
              let tail = work.checked.last, work.missing.isEmpty,
              work.endStateShotKey == PipelineRules.inputKey([work.shots.last ?? ""]),
              stateIssue(work.endState, episode: episode, tail: tail, dictionary: dictionary, expectedScene: work.boundSegments.last.flatMap { BindingRules.sceneName($0, closing: true, dictionary: dictionary) }) == nil else { return nil }
        return work.endState
    }

    static func incoming(episodeIndex: Int, works: [EpWork], dictionary: [DictEntry]) -> EndState? {
        guard episodeIndex > 0, works.indices.contains(episodeIndex), works.indices.contains(episodeIndex - 1),
              let state = approvedState(works[episodeIndex - 1], episode: episodeIndex, dictionary: dictionary),
              let first = PipelineRules.splitSegments(works[episodeIndex].segmentsRaw).first,
              openingScene(work: works[episodeIndex], raw: first, dictionary: dictionary) == state.sceneName else { return nil }
        return state
    }

    static func openingScene(work: EpWork, raw: String, dictionary: [DictEntry]) -> String? {
        if let first = work.boundSegments.first {
            guard BindingRules.issues(first, dictionary: dictionary).isEmpty else { return nil }
            return BindingRules.sceneName(first, dictionary: dictionary)
        }
        return firstScene(segment: raw, updates: work.descDraft, dictionary: dictionary)
    }

    static func injection(_ state: EndState?, episode: Int, segmentIndex: Int, sceneName: String?) -> String {
        guard let state, state.isComplete, segmentIndex == 0, state.episode + 1 == episode,
              sceneName == state.sceneName else { return "" }
        return """
        【上一集结尾状态】
        \(state.summary)
        本集第一段的0秒开局必须从上述尾镜落点起手，承接角色站位、朝向、轴线、光线及道具状态；不得瞬移、反转左右或无依据改变光线。原文明示的移动/变化须从这个起点连续演出。
        为便于审核，【角色初始站位与朝向】逐字列入上述站位/朝向、轴线和关键道具状态，再开始首镜动作；统一后缀的光影描述逐字使用上述光线时间。不要在分镜中重复来源集号或状态块标题，不重复上一集剧情与台词。
        """
    }

    static func contextKey(_ state: EndState?) -> String {
        guard let state else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PipelineRules.inputKey([String(decoding: try! encoder.encode(state), as: UTF8.self)])
    }

    /// 仅实际消费了前一状态的生成集具有跨集依赖
    static func reconcile(_ works: inout [EpWork], dictionary: [DictEntry]) -> EndState? {
        for i in works.indices where i > 0 && !works[i].continuityInputKey.isEmpty {
            let expected = contextKey(incoming(episodeIndex: i, works: works, dictionary: dictionary))
            if works[i].continuityInputKey != expected { PipelineRules.invalidate(&works[i], from: 2) }
        }
        for i in works.indices.reversed() {
            if let state = approvedState(works[i], episode: i + 1, dictionary: dictionary) { return state }
        }
        return nil
    }
}
