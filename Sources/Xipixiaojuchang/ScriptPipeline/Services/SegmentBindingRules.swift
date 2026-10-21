import Foundation
import CryptoKit

/// 段级版本绑定纯规则
enum BindingRules {

    static func entry(_ b: SegmentBinding, in dictionary: [DictEntry]) -> DictEntry? {
        dictionary.first { $0.id == b.entryId }
    }

    static func root(_ e: DictEntry, in dictionary: [DictEntry]) -> DictEntry? {
        var current = e, seen = Set<UUID>()
        while seen.insert(current.id).inserted {
            guard let base = current.basedOn else { return current }
            guard let next = dictionary.first(where: { $0.kind == current.kind && $0.name == base }) else { return nil }
            current = next
        }
        return nil
    }

    static func defaultName(_ e: DictEntry, in dictionary: [DictEntry]) -> String {
        guard e.basedOn != nil else { return e.name }
        let base = root(e, in: dictionary)?.name ?? e.basedOn ?? ""
        if e.relation == "子场景", let prefix = e.basedOn,
           e.name.hasPrefix(prefix + "·") {
            return base + e.name.dropFirst(prefix.count + 1)
        }
        return base
    }

    static func submitName(_ b: SegmentBinding, in dictionary: [DictEntry]) -> String {
        if !b.submitNameOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return b.submitNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let e = entry(b, in: dictionary) else { return "" }
        let override = e.submitNameOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? defaultName(e, in: dictionary) : override
    }

    static func entryKey(_ e: DictEntry) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var stateEntry = e
        stateEntry.sceneLayout = nil // 结构输入有单独的分镜版本锁；版本锁保持稳定
        let data = try! encoder.encode(stateEntry)
        return PipelineRules.inputKey([String(decoding: data, as: UTF8.self)])
    }

    static func key(_ segments: [BoundSegment]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return PipelineRules.inputKey([String(decoding: try! encoder.encode(segments), as: UTF8.self)])
    }

    static func issues(_ segment: BoundSegment, dictionary: [DictEntry], requireApproval: Bool = true) -> [String] {
        var result: [String] = []
        if segment.bindings.isEmpty { result.append("本段尚未指定素材版本") }
        var aliases: [String: Set<UUID>] = [:]
        var entryAliases: [UUID: Set<String>] = [:]
        for b in segment.bindings {
            guard let e = entry(b, in: dictionary), e.kind == b.kind else { result.append(b.internalName + "：待指定版本"); continue }
            let name = submitName(b, in: dictionary)
            if name.isEmpty || name.contains("·") || name.contains("\n") || name.contains("[") || name.contains("]") {
                result.append(e.name + "：提交称呼无效，请设置自然名")
            }
            if b.usage == "出镜" { aliases[name, default: []].insert(e.id) }
            entryAliases[e.id, default: []].insert(name)
            if b.scope.isEmpty || !["出镜", "画外音", "仅提及"].contains(b.usage) { result.append(e.name + "：缺有效作用范围/用途") }
            if b.evidence.isEmpty || !segment.text.contains(b.evidence) { result.append(e.name + "：原文依据须逐字存在于本段") }
            if let issue = PipelineRules.identitySyncIssue(e, in: dictionary), !e.identity.isEmpty { result.append(e.name + "：" + issue) }
            if let image = e.referenceImage, image.ownerEntryId != e.id { result.append(e.name + "：参考图不属于该版本") }
            if requireApproval && (!b.approved || b.lockedEntryKey != entryKey(e)) { result.append(e.name + "：引用待审核或词条已变化") }
        }
        for (name, ids) in aliases where ids.count > 1 { result.append("同段同名冲突：" + name + "，需要段内覆盖") }
        if entryAliases.values.contains(where: { $0.count > 1 }) { result.append("同一版本的多范围引用须使用一致的段内称呼") }
        let sceneIds = Set(segment.bindings.filter { $0.kind == "场景" }.compactMap(\.entryId))
        if segment.openingSceneId == nil || !sceneIds.contains(segment.openingSceneId!) { result.append("请指定0秒开场的内部场景") }
        if segment.closingSceneId == nil || !sceneIds.contains(segment.closingSceneId!) { result.append("请指定尾镜的内部场景") }
        if requireApproval && !segment.reviewed { result.append("本段绑定尚未确认") }
        return result
    }

    static func lock(_ segment: inout BoundSegment, dictionary: [DictEntry]) throws {
        let errors = issues(segment, dictionary: dictionary, requireApproval: false)
        guard errors.isEmpty else { throw PipelineAIError.invalidResult(errors.joined(separator: "；")) }
        for i in segment.bindings.indices {
            segment.bindings[i].approved = true
            segment.bindings[i].internalName = entry(segment.bindings[i], in: dictionary)!.name
            segment.bindings[i].lockedEntryKey = entryKey(entry(segment.bindings[i], in: dictionary)!)
        }
        segment.reviewed = true
    }

    static func parse(_ raw: String, dictionary: [DictEntry], source: String? = nil) throws -> [BoundSegment] {
        struct Ref: Decodable { var kind: String; var name: String; var scope: String; var evidence: String; var usage: String }
        struct Part: Decodable { var text: String; var openingScene: String; var closingScene: String; var bindings: [Ref]; var startSecond: Int?; var endSecond: Int? }
        struct Output: Decodable { var segments: [Part] }
        let jsonStr = PipelineAIService.extractJSON(raw)
        let data = Data(jsonStr.utf8)
        guard let output = try? JSONDecoder().decode(Output.self, from: data), !output.segments.isEmpty else {
            throw PipelineAIError.invalidResult("分段缺少 text/bindings 结构")
        }
        if let source {
            for (i, part) in output.segments.enumerated() {
                for ref in part.bindings where ref.evidence.isEmpty || !source.contains(ref.evidence) || !part.text.contains(ref.evidence) {
                    throw PipelineAIError.invalidResult("第\(i + 1)段 \(ref.name)：绑定依据未逐字出现在原始剧本及本段")
                }
            }
        }
        return output.segments.map { p in
            func resolve(_ name: String, _ kind: String) -> UUID? {
                let matches = dictionary.filter { $0.kind == kind && $0.name == name }
                return matches.count == 1 ? matches[0].id : nil
            }
            return BoundSegment(
                text: p.text,
                bindings: p.bindings.map {
                    SegmentBinding(
                        entryId: resolve($0.name, $0.kind),
                        internalName: $0.name,
                        kind: $0.kind,
                        scope: $0.scope,
                        evidence: $0.evidence,
                        usage: $0.usage
                    )
                },
                openingSceneId: resolve(p.openingScene, "场景"),
                closingSceneId: resolve(p.closingScene, "场景"),
                startSecond: p.startSecond,
                endSecond: p.endSecond
            )
        }
    }

    static func sceneName(_ segment: BoundSegment, closing: Bool = false, dictionary: [DictEntry]) -> String? {
        let id = closing ? segment.closingSceneId : segment.openingSceneId
        return dictionary.first { $0.id == id && $0.kind == "场景" }?.name
    }

    static func ambiguousEntries(_ segment: BoundSegment, dictionary: [DictEntry]) -> [DictEntry] {
        let entries = segment.bindings.compactMap { entry($0, in: dictionary) }
        let groups = Dictionary(grouping: entries) { $0.kind + "|" + (root($0, in: dictionary)?.id ?? $0.id).uuidString }
        return groups.values.filter { Set($0.map(\.id)).count > 1 }.flatMap { $0 }
    }

}
