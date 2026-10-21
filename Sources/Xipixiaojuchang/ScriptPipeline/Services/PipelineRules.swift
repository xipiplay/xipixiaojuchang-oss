import Foundation
import CryptoKit

/// 剧本流水线核心纯规则层（无外部状态，供 UI 与回归测试共用）
enum PipelineRules {

    // MARK: - 分段与文本清理

    static func splitSegments(_ raw: String) -> [String] {
        var result: [String] = [], current: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("---") {
                let part = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty { result.append(part) }; current = []
            } else { current.append(line) }
        }
        let part = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !part.isEmpty { result.append(part) }
        return result
    }

    static func stripMissingMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "〔词典缺[:：]([^〕]+)〕") else { return text }
        let original = text as NSString
        let result = NSMutableString(string: text)
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: original.length))
        for match in matches.reversed() {
            let name = original.substring(with: match.range(at: 1))
            let prefix = original.substring(to: match.range.location)
            result.replaceCharacters(in: match.range, with: prefix.hasSuffix(name) ? "" : name)
        }
        return result as String
    }

    static func complete(_ count: Int, of total: Int) -> Bool { total > 0 && count == total }

    static func inputKey(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 分镜与校验重试准备

    /// 成功的段落前缀在重试时保留；只有输入变更才重置工作区
    static func prepareShots(_ work: inout EpWork, key: String, total: Int, requireEndState: Bool = false) -> Int {
        if work.shotsInputKey != key || work.shots.count > total {
            work.shotUsedEntries = []
            work.shots = []
            work.endState = nil; work.endStateShotKey = ""; work.continuityInputKey = ""
            work.checked = []
            work.missing = []
            work.checkedInputKey = ""
            work.shotsInputKey = key
        }
        if requireEndState, total > 0, work.shots.count == total,
           work.endState?.isComplete != true || work.endStateShotKey != inputKey([work.shots.last ?? ""]) {
            if !work.shotUsedEntries.isEmpty { work.shotUsedEntries.removeLast() }
            work.shots.removeLast(); work.endState = nil; work.endStateShotKey = ""
            work.checked = []; work.missing = []; work.checkedInputKey = ""
        }
        return work.shots.count
    }

    // MARK: - 身份继承与一致性

    static func baseIdentity(for update: DescUpdate, in dictionary: [DictEntry]) -> String? {
        var name = update.name
        var seen = Set<String>()
        while seen.insert(name).inserted {
            guard let entry = dictionary.first(where: { $0.name == name && $0.kind == update.kind }) else { return nil }
            if let base = entry.basedOn { name = base } else { return entry.identity }
        }
        return nil
    }

    static func identityIssue(for update: DescUpdate, in dictionary: [DictEntry]) -> String? {
        guard update.action == "变体" || update.action == "子场景" else { return nil }
        guard let base = baseIdentity(for: update, in: dictionary), !base.isEmpty else { return "基图身份缺失，无法校验" }
        return update.identity == base ? nil : "身份与基图不一致"
    }

    static func invalidate(_ work: inout EpWork, from step: Int) {
        work.revision += 1
        for i in max(0, step)..<work.states.count { work.states[i] = .todo }
        if step <= 0 { work.descDraft = []; work.descRaw = "" }
        if step <= 1 { work.segmentsRaw = ""; work.boundSegments = [] }
        if step <= 2 { work.shotUsedEntries = []; work.shots = []; work.shotsInputKey = ""; work.endState = nil; work.endStateShotKey = ""; work.continuityInputKey = "" }
        if step <= 3 { work.checked = []; work.missing = []; work.checkedInputKey = "" }
    }

    static func episodeEntries(updates: [DescUpdate], dictionary: [DictEntry]) -> [DictEntry] {
        var seen = Set<String>()
        return updates.compactMap { u in
            let name = (u.action == "变体" || u.action == "子场景") && !u.variantName.isEmpty ? u.variantName : u.name
            let key = u.kind + "|" + name
            guard seen.insert(key).inserted else { return nil }
            return dictionary.last(where: { $0.kind == u.kind && $0.name == name })
        }
    }

    static func firstEpisode(existing: Int?, reported: Int?, batch: ClosedRange<Int>) -> Int {
        let candidate = min(batch.upperBound, max(batch.lowerBound, reported ?? batch.lowerBound))
        return min(existing ?? candidate, candidate)
    }

    static func durationPrompt(_ original: String, seconds: Int) -> String {
        guard seconds == 15 || seconds == 30, !original.isEmpty else { return "" }
        var text = original
        if seconds == 15 {
            for (a, b) in [("30 秒", "15 秒"), ("30秒", "15秒"), ("30s", "15s"),
                           ("6-10", "3-5"), ("12-16", "6-8")] {
                text = text.replacingOccurrences(of: a, with: b)
            }
            if let regex = try? NSRegularExpression(pattern: "[0-9]{2}:[0-9]{2}") {
                let ns = text as NSString
                let result = NSMutableString(string: text)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let pieces = ns.substring(with: match.range).split(separator: ":").compactMap { Int($0) }
                    let time = (pieces[0] * 60 + pieces[1]) / 2
                    result.replaceCharacters(in: match.range, with: String(format: "%02d:%02d", time / 60, time % 60))
                }
                text = result as String
            }
        }
        return text + "\n\n【本次时长设置｜最高优先级】每段固定 \(seconds) 秒，时间标号按 \(seconds) 秒连续累加。每段对应一条完整的多镜头视频分镜文案，内部镜头不再拆成独立视频。忠实原文，台词逐字保留。"
    }

    static func referencePrompt(_ entry: DictEntry) -> String {
        [entry.identity, entry.kind == "角色" ? entry.stage : "", entry.desc]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "，")
    }

    static func descriptionIssue(for update: DescUpdate, in dictionary: [DictEntry]) -> String? {
        if update.action == "变体" || update.action == "子场景",
           let issue = relationError(name: update.displayName, kind: update.kind, relation: update.action, base: update.name, in: dictionary) { return issue }
        if update.action == "沿用", let entry = dictionary.first(where: { $0.kind == update.kind && $0.name == update.name }),
           let issue = identitySyncIssue(entry, in: dictionary), !entry.identity.isEmpty { return issue }
        if let issue = identityIssue(for: update, in: dictionary) {
            if baseIdentity(for: update, in: dictionary)?.isEmpty == false || !update.identity.isEmpty { return issue }
        }
        if update.kind == "角色", update.action == "变体", !update.stage.isEmpty,
           update.stage != dictionary.first(where: { $0.name == update.name && $0.kind == update.kind })?.stage,
           update.stageChanges.isEmpty || update.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "时间状态改变需列修订点及原文依据"
        }
        return nil
    }

    // MARK: - 词典与素材关系逻辑

    static func rootName(_ name: String, kind: String, in dictionary: [DictEntry]) -> String {
        var current = name, seen = Set<String>()
        while seen.insert(current).inserted,
              let entry = dictionary.first(where: { $0.kind == kind && $0.name == current }),
              let base = entry.basedOn { current = base }
        return current
    }

    static func pendingBaseMessage(_ update: DescUpdate, in dictionary: [DictEntry]) -> String? {
        guard update.action == "变体" || update.action == "子场景" else { return nil }
        guard baseIdentity(for: update, in: dictionary)?.isEmpty != false else { return nil }
        return "缺基图身份，待基条目出现后补：" + update.name
    }

    static func reviewDictionary(_ updates: [DescUpdate], in dictionary: [DictEntry]) -> [DictEntry] {
        var result = dictionary
        for u in updates where u.action == "新增" {
            let entry = DictEntry(kind: u.kind, name: u.name, desc: u.desc, identity: u.identity, fromEp: 1,
                                  stage: u.stage, stageChanges: u.stageChanges, identityVersion: u.identityVersion)
            if let i = result.firstIndex(where: { $0.kind == u.kind && $0.name == u.name }) { result[i] = entry }
            else { result.append(entry) }
        }
        return result
    }

    static func descriptionIssues(_ updates: [DescUpdate], in dictionary: [DictEntry]) -> [String] {
        let context = reviewDictionary(updates, in: dictionary)
        return updates.compactMap { descriptionIssue(for: $0, in: context) }
    }

    @discardableResult
    static func resolvePendingBases(_ dictionary: inout [DictEntry]) -> [String] {
        var resolved: [String] = []
        for i in dictionary.indices where dictionary[i].basedOn != nil && dictionary[i].identity.isEmpty {
            let e = dictionary[i]
            let u = DescUpdate(kind: e.kind, name: e.basedOn!, action: e.relation)
            if let identity = baseIdentity(for: u, in: dictionary), !identity.isEmpty {
                dictionary[i].identity = identity
                let base = dictionary.first { $0.kind == e.kind && $0.name == e.basedOn }
                if e.kind == "角色", e.stage.isEmpty { dictionary[i].stage = base?.stage ?? "" }
                dictionary[i].identityVersion = base?.identityVersion ?? 0
                resolved.append(e.name)
            }
        }
        return resolved
    }

    static func applyDescriptions(_ updates: [DescUpdate], episode: Int, to dictionary: inout [DictEntry]) {
        guard descriptionIssues(updates, in: dictionary).isEmpty else { return }
        let names = Set(updates.map(\.displayName))
        for i in dictionary.indices where dictionary[i].fromEp == episode && names.contains(dictionary[i].name) && dictionary[i].toEp == episode && dictionary[i].toOrder != nil {
            dictionary[i].toEp = nil; dictionary[i].toOrder = nil
        }
        let ordered = updates.enumerated().sorted { ($0.element.order > 0 ? $0.element.order : $0.offset + 1) < ($1.element.order > 0 ? $1.element.order : $1.offset + 1) }
        for (offset, u) in ordered {
            let order = u.order > 0 ? u.order : offset + 1
            guard u.action != "沿用" else { continue }
            let related = u.action == "变体" || u.action == "子场景"
            let name = related ? (u.variantName.isEmpty ? u.name + (u.action == "变体" ? "·新状态" : "·子区") : u.variantName) : u.name
            let base = dictionary.first { $0.kind == u.kind && $0.name == u.name }
            let root = related ? rootName(u.name, kind: u.kind, in: dictionary) : nil
            let identity = related ? (baseIdentity(for: u, in: dictionary) ?? "") : u.identity
            let stage = u.stage.isEmpty && related ? (base?.stage ?? "") : u.stage
            if u.action == "变体", let root {
                for bi in dictionary.indices where dictionary[bi].kind == u.kind && dictionary[bi].relation != "子场景" && dictionary[bi].toEp == nil && dictionary[bi].name != name {
                    let entry = dictionary[bi]
                    guard rootName(entry.name, kind: u.kind, in: dictionary) == root,
                          entry.fromEp < episode || (entry.fromEp == episode && entry.fromOrder < order) else { continue }
                    dictionary[bi].toEp = entry.fromEp == episode ? episode : episode - 1
                    dictionary[bi].toOrder = entry.fromEp == episode ? order - 1 : nil
                }
            }
            if let i = dictionary.firstIndex(where: { $0.kind == u.kind && $0.name == name }) {
                if !identity.isEmpty { dictionary[i].identity = identity }
                if !stage.isEmpty { dictionary[i].stage = stage }
                if !u.desc.isEmpty { dictionary[i].desc = u.desc }
                dictionary[i].basedOn = root; dictionary[i].relation = related ? u.action : ""
                dictionary[i].evidence = u.evidence; dictionary[i].stageChanges = u.stageChanges
                dictionary[i].identityVersion = u.identityVersion
                if dictionary[i].fromEp == episode || dictionary[i].fromOrder == 0 { dictionary[i].fromOrder = order }
            } else {
                dictionary.append(DictEntry(kind: u.kind, name: name, desc: u.desc, identity: identity, fromEp: episode,
                    basedOn: root, relation: related ? u.action : "", evidence: u.evidence,
                    stage: stage, stageChanges: u.stageChanges, fromOrder: order, identityVersion: u.identityVersion))
            }
        }
        resolvePendingBases(&dictionary)
    }

    static func relationError(name: String, kind: String, relation: String, base: String, in dictionary: [DictEntry]) -> String? {
        guard !relation.isEmpty else { return nil }
        guard ["变体", "子场景"].contains(relation), relation != "子场景" || kind == "场景" else { return "此素材类型不支持该关系" }
        guard !base.isEmpty else { return "请选择基条目" }
        var current = base, seen = Set<String>()
        while seen.insert(current).inserted {
            if current == name { return "不能基于自身或形成循环关系" }
            guard let entry = dictionary.first(where: { $0.name == current && $0.kind == kind }) else {
                if dictionary.contains(where: { $0.name == current }) { return "基条目必须属于相同素材类型" }
                return nil // 声明了但尚未登场的基条目允许作为悬挂引用存在
            }
            guard let next = entry.basedOn else { return nil }
            current = next
        }
        return "基于链存在循环，请先修正"
    }

    static func identitySyncIssue(_ entry: DictEntry, in dictionary: [DictEntry]) -> String? {
        guard let base = entry.basedOn else { return nil }
        let u = DescUpdate(kind: entry.kind, name: base, action: entry.relation)
        guard let identity = baseIdentity(for: u, in: dictionary), !identity.isEmpty else { return "缺基图身份，待基条目出现后补" }
        return entry.identity == identity ? nil : "基图身份已修改，此条目需同步"
    }

    static func possibleOmissions(text: String, updates: [DescUpdate], dictionary: [DictEntry]) -> [DictEntry] {
        let handled = Set(updates.flatMap { [$0.kind + "|" + $0.name, $0.kind + "|" + $0.displayName] })
        var remaining = text, found: [DictEntry] = [], seen = Set<String>()
        for e in dictionary.filter({ !$0.name.isEmpty }).sorted(by: { $0.name.count > $1.name.count }) {
            let key = e.kind + "|" + e.name
            guard remaining.contains(e.name), seen.insert(key).inserted else { continue }
            if !handled.contains(key) { found.append(e) }
            remaining = remaining.replacingOccurrences(of: e.name, with: String(repeating: " ", count: e.name.count))
        }
        return found
    }

    static func missingDescriptionFields(_ entry: DictEntry, in dictionary: [DictEntry]) -> [String] {
        var fields: [String] = []
        if entry.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("固定身份") }
        if entry.kind == "角色" {
            if entry.identityVersion == 1 && entry.stage.isEmpty { fields.append("年龄/体态") }
            if entry.desc.isEmpty { fields.append("服装") }
        }
        if identitySyncIssue(entry, in: dictionary) != nil { fields.append("基图身份关联") }
        return fields
    }
}
