import Foundation

struct SubmissionPackage: Codable, Sendable {
    var schemaVersion = 1
    var projectId: UUID
    var dictionaryRevision: String
    var episodeId: UUID
    var episodeIndex: Int
    var segments: [Card]

    struct Card: Codable, Sendable {
        var segmentId: UUID
        var segmentIndex: Int
        var durationSeconds: Int
        var draftRevision: Int
        var submittedText: String
        var submittedTextHash: String
        var bindingRevision: String
        var reviewState: String
        var openingSceneEntryId: UUID?
        var closingSceneEntryId: UUID?
        var continuitySource: EndState?
        var bindings: [Ref]
    }

    struct Ref: Codable, Sendable {
        var usageId: UUID
        var kind: String
        var entryId: UUID?
        var internalNameSnapshot: String
        var submitAlias: String
        var scope: String
        var evidence: String
        var usageType: String
        var reviewState: String
        var sourceAnchors: [Int]
        var rootEntryId: UUID?
        var basedOnEntryId: UUID?
        var relation: String
        var identityVersion: Int
        var identity: String
        var stage: String
        var desc: String
        var stateHash: String
        var imageAssetId: UUID?
        var imageRevision: String?
        var imagePath: String?
        var referenceSlot: Int?
        var assetState: String
    }
}

enum SubmissionRules {
    static func stateLine(_ segment: BoundSegment, dictionary: [DictEntry]) -> String {
        let parts = segment.bindings.filter { $0.usage == "出镜" }.compactMap { b -> String? in
            guard let e = BindingRules.entry(b, in: dictionary) else { return nil }
            let values = [e.kind == "角色" ? e.stage : "", e.desc].filter { !$0.isEmpty }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "。；; ")) }
            guard !values.isEmpty else { return nil }
            return (b.scope == "全段" ? "" : b.scope + "：") + BindingRules.submitName(b, in: dictionary) + "：" + values.joined(separator: "；")
        }
        return "【画面状态】" + (parts.isEmpty ? "本段词条未提供时间状态/服装，请核对描述。" : parts.joined(separator: "。"))
    }

    /// 引号内原文不可改。仅将锁定实体表里的规范名称替换为自然提交称呼
    static func replacingNames(_ text: String, mappings: [(String, String)]) -> String {
        func replace(_ part: String) -> String {
            var out = part
            var tokens: [(String, String)] = []
            for (i, pair) in mappings.sorted(by: { $0.0.count > $1.0.count }).enumerated() {
                let token = "\u{E000}REF\(i)\u{E001}"
                if !pair.0.isEmpty { out = out.replacingOccurrences(of: pair.0, with: token); tokens.append((token, pair.1)) }
            }
            for (token, value) in tokens { out = out.replacingOccurrences(of: token, with: value) }
            return out
        }
        let pairs: [Character: Character] = ["\"": "\"", "“": "”", "「": "」", "‘": "’"]
        var result = "", part = "", close: Character?
        for ch in text {
            if let expected = close {
                part.append(ch)
                if ch == expected { result += part; part = ""; close = nil }
            } else if let expected = pairs[ch] {
                result += replace(part); part = String(ch); close = expected
            } else { part.append(ch) }
        }
        result += close == nil ? replace(part) : part
        return result
    }

    static func sourceDialogues(_ text: String) -> [String] {
        let pattern = #"(?m)^\s*\[[^\]\n]+\](?:（[^）\n]*）)?\s*[:：]\s*(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        }
    }

    static func spokenDialogues(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"说\s*[:：]\s*["“”]([^"“”]*)["“”]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func render(_ internalText: String, segment: BoundSegment, dictionary: [DictEntry]) throws -> String {
        let errors = BindingRules.issues(segment, dictionary: dictionary)
        guard errors.isEmpty else { throw PipelineAIError.invalidResult(errors.joined(separator: "；")) }
        let maps = segment.bindings.compactMap { b -> (String, String)? in
            guard let e = BindingRules.entry(b, in: dictionary) else { return nil }
            return (e.name, BindingRules.submitName(b, in: dictionary))
        }
        let ambiguous = BindingRules.ambiguousEntries(segment, dictionary: dictionary)
        let ambiguousIds = Set(ambiguous.map(\.id))
        let markerMaps = maps.map { ("〔引用:" + $0.0 + "〕", $0.1) }
        if !ambiguous.isEmpty {
            let core = internalText.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            let protected = replacingNames(core, mappings: ambiguous.map { ("〔引用:" + $0.name + "〕", "\u{E010}" + $0.id.uuidString + "\u{E011}") })
            let scanned = replacingNames(protected, mappings: ambiguous.map { ($0.name, "\u{E020}UNSCOPED\u{E021}") })
            guard !scanned.contains("\u{E020}UNSCOPED\u{E021}") else { throw PipelineAIError.invalidResult("同段双版本存在裸名/简称，须用内部引用标记明确指代") }
        }
        let tagged = replacingNames(internalText, mappings: dictionary.map { ($0.name, "\u{E100}" + $0.id.uuidString + "\u{E101}") })
        let mentioned = Set(dictionary.filter { tagged.contains("\u{E100}" + $0.id.uuidString + "\u{E101}") }.map(\.id))
        let boundIds = Set(segment.bindings.compactMap(\.entryId))
        for e in dictionary where mentioned.contains(e.id) && !boundIds.contains(e.id) && (e.kind == "角色" || e.kind == "道具" || e.name.contains("·")) {
            throw PipelineAIError.invalidResult("内部稿使用未锁定版本：" + e.name)
        }
        for b in segment.bindings where b.kind == "角色" && b.usage != "仅提及" {
            guard let id = b.entryId, mentioned.contains(id) else { throw PipelineAIError.invalidResult("内部稿缺锁定角色版本：" + b.internalName) }
        }
        var lines = internalText.components(separatedBy: "\n").filter { !$0.hasPrefix("【画面状态】") }
        guard let header = lines.first, header.hasPrefix("["), header.filter({ $0 == "[" }).count == 3,
              header.filter({ $0 == "]" }).count == 3 else { throw PipelineAIError.invalidResult("提交头行须含场景/角色/道具三组") }
        let unambiguousMaps = segment.bindings.compactMap { b -> (String, String)? in
            guard let e = BindingRules.entry(b, in: dictionary), !ambiguousIds.contains(e.id) else { return nil }
            return (e.name, BindingRules.submitName(b, in: dictionary))
        }
        lines = lines.enumerated().map { i, line in replacingNames(line, mappings: markerMaps + (i == 0 ? maps : unambiguousMaps)) }
        lines.insert(stateLine(segment, dictionary: dictionary), at: 1)
        let out = lines.joined(separator: "\n")
        guard !out.contains("·"), !out.contains("〔引用"), !out.contains("〔词典缺"), !out.contains("新:") else {
            throw PipelineAIError.invalidResult("提交稿残留内部后缀或台词标识冲突，需人工审核；未替换台词正文")
        }
        guard lines.count > 2, lines[2].hasPrefix("【角色初始站位与朝向】") else { throw PipelineAIError.invalidResult("画面状态须在头行之后、站位之前") }
        let source = sourceDialogues(segment.text)
        if !source.isEmpty, spokenDialogues(out) != source { throw PipelineAIError.invalidResult("台词内容/顺序与分段原文不一致") }
        return out
    }

    static func package(projectId: UUID, episode: Episode, episodeIndex: Int, work: EpWork, dictionary: [DictEntry], seconds: Int, continuity: EndState?) throws -> SubmissionPackage {
        let drafts = work.checked.isEmpty ? work.shots : work.checked
        guard drafts.count == work.boundSegments.count, !drafts.isEmpty else { throw PipelineAIError.invalidResult("分镜与段级绑定数量不一致，旧分镜须补审绑定") }
        let cards = try drafts.enumerated().map { i, text -> SubmissionPackage.Card in
            let s = work.boundSegments[i]
            let submitted = try render(text, segment: s, dictionary: dictionary)
            var slot = 0
            let refs = s.bindings.map { b -> SubmissionPackage.Ref in
                let e = BindingRules.entry(b, in: dictionary)!
                let needsImage = b.usage == "出镜"
                if needsImage { slot += 1 }
                let image = e.referenceImage
                let ready = image?.ownerEntryId == e.id && image?.isAvailable == true
                let anchors = episode.text.components(separatedBy: "\n").enumerated().compactMap { line, text in text.contains(b.evidence) ? line + 1 : nil }
                return SubmissionPackage.Ref(
                    usageId: b.id, kind: b.kind, entryId: e.id, internalNameSnapshot: e.name,
                    submitAlias: BindingRules.submitName(b, in: dictionary), scope: b.scope, evidence: b.evidence, usageType: b.usage,
                    reviewState: b.approved ? "已确认" : "待审", sourceAnchors: anchors,
                    rootEntryId: BindingRules.root(e, in: dictionary)?.id, basedOnEntryId: dictionary.first { $0.kind == e.kind && $0.name == e.basedOn }?.id,
                    relation: e.relation.isEmpty ? "本体" : e.relation,
                    identityVersion: e.identityVersion, identity: e.identity, stage: e.stage, desc: e.desc, stateHash: BindingRules.entryKey(e),
                    imageAssetId: image?.id, imageRevision: image?.revision, imagePath: image?.path,
                    referenceSlot: needsImage ? slot : nil, assetState: needsImage ? (ready ? "可用" : "待生成") : "无需图"
                )
            }
            let reviewed = work.states.prefix(4).allSatisfy { $0 == .approved }
            let missingDescriptions = s.bindings.contains { b in BindingRules.entry(b, in: dictionary).map { !PipelineRules.missingDescriptionFields($0, in: dictionary).isEmpty } ?? true }
            return SubmissionPackage.Card(
                segmentId: s.id, segmentIndex: i + 1, durationSeconds: seconds, draftRevision: work.revision,
                submittedText: submitted, submittedTextHash: PipelineRules.inputKey([submitted]), bindingRevision: BindingRules.key([s]),
                reviewState: reviewed ? (missingDescriptions ? "文案已审，描述待补" : (refs.allSatisfy { $0.assetState != "待生成" } ? "提交就绪" : "文案已审，图待生成")) : "草稿待审",
                openingSceneEntryId: s.openingSceneId, closingSceneEntryId: s.closingSceneId, continuitySource: i == 0 ? continuity : nil, bindings: refs
            )
        }
        return SubmissionPackage(
            projectId: projectId, dictionaryRevision: PipelineRules.inputKey(dictionary.map(BindingRules.entryKey)),
            episodeId: episode.id, episodeIndex: episodeIndex, segments: cards
        )
    }

    static func write(_ package: SubmissionPackage, to directory: URL, basename: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(package).write(to: directory.appendingPathComponent(basename + ".json"), options: .atomic)
        let text = package.segments.map { "第\($0.segmentIndex)段（\($0.durationSeconds)秒）\n\($0.submittedText)" }.joined(separator: "\n\n")
        try text.write(to: directory.appendingPathComponent(basename + ".txt"), atomically: true, encoding: .utf8)
    }
}
