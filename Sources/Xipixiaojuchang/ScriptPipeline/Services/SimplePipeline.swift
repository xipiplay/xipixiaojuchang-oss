import Foundation
import CryptoKit

/// 这里的阶段描述产出，完成后直接可用，没有审核或锁定状态。
enum SimplePipelineStage: String, CaseIterable, Identifiable, Sendable {
    case script = "剧本", assets = "提取素材", segments = "30 秒分割"
    case prompts = "分镜提示词", images = "生成图片", videos = "生成视频"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .script: "doc.text"
        case .assets: "square.stack.3d.up"
        case .segments: "square.split.1x2"
        case .prompts: "text.alignleft"
        case .images: "photo"
        case .videos: "film"
        }
    }
}

struct SimplePipelineAsset: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: String
    var name: String
    var description: String
    var imageItemID: UUID?
    var libraryItemID: UUID?
}

struct SimplePipelineSegment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var assetNames: [String] = []
    var prompt = ""
    var shotID: UUID?
    var sceneName: String = ""
    var initialPositions: String = ""
    var endPositions: String = ""
    var continuityKey: String = ""

    enum CodingKeys: String, CodingKey { case id, text, assetNames, prompt, shotID, sceneName, initialPositions, endPositions, continuityKey }
    init(id: UUID = UUID(), text: String, assetNames: [String] = [], prompt: String = "", shotID: UUID? = nil) {
        self.id = id; self.text = text; self.assetNames = assetNames; self.prompt = prompt; self.shotID = shotID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        assetNames = try c.decodeIfPresent([String].self, forKey: .assetNames) ?? []
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        shotID = try c.decodeIfPresent(UUID.self, forKey: .shotID)
        sceneName = try c.decodeIfPresent(String.self, forKey: .sceneName) ?? ""
        initialPositions = try c.decodeIfPresent(String.self, forKey: .initialPositions) ?? ""
        endPositions = try c.decodeIfPresent(String.self, forKey: .endPositions) ?? ""
        continuityKey = try c.decodeIfPresent(String.self, forKey: .continuityKey) ?? ""
    }
}

struct SimpleEpisodeWork: Identifiable, Codable, Equatable, Sendable {
    var id: UUID // Episode.id，重新分集不会错配到旧序号
    var sourceKey: String
    var assets: [SimplePipelineAsset] = []
    var assetsExtracted = false // 空素材结果也可以是成功的
    var segments: [SimplePipelineSegment] = []

    var promptsComplete: Bool { !segments.isEmpty && segments.allSatisfy { !$0.prompt.isEmpty } }
    var summary: String {
        if promptsComplete { return "\(segments.count) 条视频 · 提示词就绪" }
        if !segments.isEmpty { return "\(segments.count) 个片段" }
        if assetsExtracted { return "已提取 \(assets.count) 项素材" }
        return "\(assets.count) 项素材 · 待分割"
    }

    mutating func replaceAssets(_ value: [SimplePipelineAsset]) {
        // 完全相同的结果保留图片链接；改了描述的素材重新生图，历史条目保留。
        assets = value.map { asset in
            if let old = assets.first(where: { $0.kind == asset.kind && $0.name == asset.name && $0.description == asset.description }) { return old }
            return asset
        }
        assetsExtracted = true
        invalidatePrompts(from: 0)
    }

    mutating func invalidatePrompts(from index: Int) {
        for i in segments.indices where i >= index {
            segments[i].prompt = ""
            segments[i].shotID = nil
        }
    }
}

enum SimplePipeline {
    typealias Chat = @Sendable (String, String) async throws -> String

    static func key(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func stableID(_ seed: String) -> UUID {
        let h = key(seed)
        let s = Array(h.prefix(32))
        let value = [String(s[0..<8]), String(s[8..<12]), String(s[12..<16]), String(s[16..<20]), String(s[20..<32])].joined(separator: "-")
        return UUID(uuidString: value)!
    }

    /// 旧存档只读投影，忽略审核、词典锁、名字校验；读取不写回。
    static func work(in archive: ProjectPipelineArchive, index: Int) -> SimpleEpisodeWork {
        let episode = archive.episodes[index]
        let source = key(episode.text)
        if let saved = archive.simpleWorks.first(where: { $0.id == episode.id }) {
            return saved.sourceKey == source ? saved : SimpleEpisodeWork(id: episode.id, sourceKey: source)
        }
        var result = SimpleEpisodeWork(id: episode.id, sourceKey: source)
        guard archive.works.indices.contains(index) else { return result }
        let legacy = archive.works[index]
        for update in legacy.descDraft {
            let name = update.displayName
            let entry = archive.dictionary.first(where: { $0.name == name && $0.kind == update.kind })
            let description = [update.identity, update.stage, update.desc].filter { !$0.isEmpty }.joined(separator: "\n")
            let resolved = description.isEmpty ? entry.map { PipelineRules.referencePrompt($0) } ?? "" : description
            guard !name.isEmpty, !resolved.isEmpty,
                  !result.assets.contains(where: { $0.name == name && $0.kind == update.kind }) else { continue }
            result.assets.append(SimplePipelineAsset(id: entry?.id ?? stableID("\(episode.id)-\(update.kind)-\(name)"), kind: update.kind, name: name, description: resolved))
        }
        result.assetsExtracted = !result.assets.isEmpty
        let raw = PipelineRules.splitSegments(legacy.segmentsRaw)
        let count = max(raw.count, legacy.boundSegments.count)
        for i in 0..<count {
            let bound = legacy.boundSegments.indices.contains(i) ? legacy.boundSegments[i] : nil
            let text = raw.indices.contains(i) ? raw[i] : bound?.text ?? ""
            let names = bound?.bindings.compactMap { BindingRules.entry($0, in: archive.dictionary)?.name } ?? result.assets.filter { text.contains($0.name) }.map(\.name)
            let prompt = legacy.checked.indices.contains(i) ? legacy.checked[i] : (legacy.shots.indices.contains(i) ? legacy.shots[i] : "")
            result.segments.append(SimplePipelineSegment(id: bound?.id ?? stableID("\(episode.id)-segment-\(i)-\(text)"), text: text, assetNames: names, prompt: prompt))
        }
        return result
    }

    static func save(_ work: SimpleEpisodeWork, to archive: inout ProjectPipelineArchive) {
        if let i = archive.simpleWorks.firstIndex(where: { $0.id == work.id }) { archive.simpleWorks[i] = work }
        else { archive.simpleWorks.append(work) }
    }

    /// AI 常把类型写成近义词（「人物」「地点」「物品」…）：认得出的归到三类，认不出的算不可用
    static func normalizedKind(_ raw: String) -> String? {
        let kind = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case "场景", "地点", "环境", "场地": return "场景"
        case "角色", "人物", "人": return "角色"
        case "道具", "物品", "物件", "物": return "道具"
        default: return nil
        }
    }

    /// 解析素材回复。**单项写得不完整（类型认不出 / 名称或描述为空）只跳过那一项**，不让整次提取作废
    /// （2026-10-07：长剧本里 AI 偶尔漏写一项的描述，原来整次失败，一键推进只能反复重试）。
    /// 跳过的项记进日志；它如果在段落里出现，制作页的「名字对不上设定」会提醒用户确认。
    /// 一项能用的都没有才算失败。
    static func parseAssets(_ raw: String) throws -> [SimplePipelineAsset] {
        struct Reply: Decodable {
            struct Asset: Decodable { var kind: String?; var name: String?; var description: String? }
            var assets: [Asset]
        }
        guard let data = PipelineAIService.extractJSON(raw).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            AppLog.write("pipeline", "提取素材：回复不是 assets 数组。回复开头：\(raw.prefix(400))")
            throw PipelineAIError.invalidResult("素材回复需要 assets 数组")
        }
        var result: [SimplePipelineAsset] = []
        var skipped: [String] = []
        for a in reply.assets {
            let name = (a.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let description = (a.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = normalizedKind(a.kind ?? ""), !name.isEmpty, !description.isEmpty else {
                skipped.append("\(a.kind ?? "nil")|\(a.name ?? "nil")|描述\(description.isEmpty ? "空" : "有")")
                continue
            }
            guard !result.contains(where: { $0.kind == kind && $0.name == name }) else { continue }
            result.append(SimplePipelineAsset(kind: kind, name: name, description: description))
        }
        if !skipped.isEmpty {
            AppLog.write("pipeline", "提取素材：跳过 \(skipped.count) 项不完整的（类型|名称|描述）：\(skipped.joined(separator: "；"))")
        }
        if result.isEmpty, !reply.assets.isEmpty {
            throw PipelineAIError.invalidResult("素材类型、名称或描述为空（AI 返回的 \(reply.assets.count) 项都不能用）")
        }
        return result
    }

    static func parseSegments(_ raw: String) throws -> [SimplePipelineSegment] {
        struct Reply: Decodable {
            struct Segment: Decodable { var text: String; var assets: [String] }
            var segments: [Segment]
        }
        guard let data = PipelineAIService.extractJSON(raw).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.segments.isEmpty else {
            throw PipelineAIError.invalidResult("分割回复需要非空 segments 数组")
        }
        return try reply.segments.map {
            let text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw PipelineAIError.invalidResult("片段正文为空") }
            return SimplePipelineSegment(text: text, assetNames: Array(NSOrderedSet(array: $0.assets)) as? [String] ?? $0.assets)
        }
    }

    static func extract(episode: Episode, previousAssets: [SimplePipelineAsset], chat: Chat) async throws -> [SimplePipelineAsset] {
        let system = """
        你在把剧本制作成视频。提取本集生图需要的场景、角色、道具，直接写完整生图描述。
        每项只需要 kind、name、description；不用动作判定、身份分层、版本绑定或审核字段。
        只提取在画面中需要呈现的主要素材，排除只被提及的对象。名字沿用原文，跨集同一对象沿用已有名称和外观；原文明示不同状态时可用简短状态后缀区分。

        【角色规则】
        \(PipelinePromptStore.roleRule)

        【场景与道具规则】
        \(PipelinePromptStore.scenePropRule)

        只输出 JSON：{"assets":[{"kind":"场景","name":"厨房","description":"完整生图描述"}]}。
        """
        let previous = previousAssets.map { "\($0.kind) | \($0.name)：\($0.description)" }.joined(separator: "\n")
        return try parseAssets(await chat(system, "【已有素材，供保持一致】\n\(previous)\n【本集剧本】\n\(episode.text)"))
    }

    /// 只重新提取一项素材的生图描述（素材页「重新提取」）。名称与类型保持原样。
    static func reextract(episode: Episode, asset: SimplePipelineAsset, allAssets: [SimplePipelineAsset], chat: Chat) async throws -> String {
        let system = """
        你在把剧本制作成视频。这里只需要重新提取一项素材的生图描述。
        素材类型和名称固定为：\(asset.kind)「\(asset.name)」，不得改名、不得更改类型。
        读取剧本，与已有素材保持一致，重写这一项的生图描述（完整、可直接用于生图）。
        \(asset.kind == "角色" ? "【角色规则】\n\(PipelinePromptStore.roleRule)" : "【场景与道具规则】\n\(PipelinePromptStore.scenePropRule)")
        只输出 JSON：{"description":"完整生图描述"}。
        """
        let previous = allAssets.map { "\($0.kind) | \($0.name)：\($0.description)" }.joined(separator: "\n")
        let raw = try await chat(system, "【已有素材，供保持一致】\n\(previous)\n【本集剧本】\n\(episode.text)")
        struct Reply: Decodable {
            var value: String
            enum CodingKeys: String, CodingKey { case value = "description" }
        }
        guard let data = PipelineAIService.extractJSON(raw).data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw PipelineAIError.invalidResult("重新提取需要 description 字段")
        }
        let result = reply.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PipelineAIError.invalidResult("重新提取的描述为空") }
        return result
    }

    static func split(episode: Episode, assets: [SimplePipelineAsset], seconds: Int = 30, chat: Chat) async throws -> [SimplePipelineSegment] {
        let contract = """
        【输出格式，优先于原格式要求】每个片段是一条完整的 \(seconds) 秒多镜头视频，不按单镜头拆。
        保留原文剧情、动作和台词内容与顺序。assets 填该片段实际需要呈现的素材名称，不写仅被提及的对象。
        只输出 JSON：{"segments":[{"text":"本段完整剧本","assets":["厨房","林夏"]}]}。
        """
        let raw = try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.segmentPrompt) + "\n" + contract,
                                 "【本集素材】\n" + assets.map { "\($0.kind)：\($0.name)" }.joined(separator: "\n") + "\n【本集原文】\n" + episode.text)
        let segments = try parseSegments(raw)
        // 本地守住原文台词；不增加人工校验步骤，也不另调 AI。
        let original = SubmissionRules.sourceDialogues(episode.text)
        if !original.isEmpty, segments.flatMap({ SubmissionRules.sourceDialogues($0.text) }) != original {
            throw PipelineAIError.invalidResult("分割结果改动或遗漏了原文台词，请重试")
        }
        return segments
    }

    /// 批量分割（2026-10-07）：用「分割（时长）」提示词整理一集原文，**原样**返回模型输出的文字（不再解析 JSON）。
    /// 提示词规定输出成什么样（场景行、△画面、台词、`--- 00:00 - 00:30`），这一集的「时长分割」就是什么样。
    /// `note`：这一次手写的补充要求（见 `RerunNote`），放在原文前面一起发给 AI
    static func splitText(episode: Episode, note: String = "", chat: Chat) async throws -> String {
        let raw = try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.segmentPrompt), RerunNote.prefixed(episode.text, note: note))
        let text = unfenced(raw)
        guard !text.isEmpty else { throw PipelineAIError.emptyResponse }
        return text
    }

    /// 批量提取素材（2026-10-07）：用「提取角色 / 场景 / 道具」之一的提示词读全剧本原文，输出按生图页的规则切成一块一块
    /// （这个人是… / 这个场景叫… / 这个物品名称叫…），一块一张卡片。模型什么都没提取出来（空输出 / 没有一块）就是 0 块，不算失败。
    /// 提取一类的卡片（2026-10-07；2026-10-17 连原始回复一起交出去，对账要扫「沿用：」行）
    static func extractCardsReply(prompt: String, text: String, chat: Chat) async throws -> (raw: String, parsed: [ImagePromptParser.Parsed]) {
        let raw = try await chat(PipelinePromptStore.apiReady(prompt), text)
        return (raw, ImagePromptParser.parse(unfenced(raw)))
    }

    /// 去掉首尾空白，以及模型有时会多包的一层 ``` 代码块
    static func unfenced(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst()
                if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    static func infer(segment: SimplePipelineSegment, assets: [SimplePipelineAsset], previousPrompt: String, chat: Chat) async throws -> String {
        let selected = assets.filter { segment.assetNames.contains($0.name) || segment.text.contains($0.name) }
        let context = selected.map { "\($0.kind)「\($0.name)」：\($0.description)" }.joined(separator: "\n")
        let raw = try await chat(PipelinePromptStore.apiReady(PipelinePromptStore.shotsPrompt) + "\n本次生成一条完整的30秒多镜头视频提示词。仅输出提示词正文，无需名字校验、审核标记、绑定JSON。素材名按提供名称使用。",
                                 "【本段素材】\n\(context)\n【上一段提示词，若同场景则承接站位、轴线与光线】\n\(previousPrompt)\n【本段剧本】\n\(segment.text)")
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw PipelineAIError.emptyResponse }
        return prompt
    }

    /// 剧本流水线文字请求的默认超时（秒）
    static let requestTimeout: TimeInterval = 900

    /// `timeout`：单次请求的超时（秒）。默认 900（15 分钟）。
    /// 原来默认 300：会思考的模型（GLM-5.3 默认思考到最深）一集分割就要五分钟以上，一到 300 秒就被软件自己掐断报「请求超时」
    /// （2026-10-11 用户用 NVIDIA 的 GLM-5.3 跑分割，一集 301 秒后失败）。推理分镜、提取素材早就是 900，这里统一。
    /// 代价：服务商真的挂了、一直不回时，要等 15 分钟才报错，而不是 5 分钟。
    static func chat(config: PipelineAISettings, timeout: TimeInterval = requestTimeout, session: URLSession = PipelineAIService.defaultSession) -> Chat {
        { system, user in
            // 流式接收：这个请求属于哪个任务（任务抽屉里的一行），进度就往它身上报；没有任务（比如测试连接）就只管收
            guard let recordID = AgentRequestContext.current?.aiRecordID, config.usesStreaming, !config.usesAgent else {
                return try await PipelineAIService.chat(config: config, system: system, user: user, session: session, timeout: timeout)
            }
            let token = UUID()
            do {
                let reply = try await PipelineAIService.chat(config: config, system: system, user: user, session: session, timeout: timeout,
                                                             onProgress: { progress in
                    await MainActor.run { AIStreamHub.jobCenter?.aiStream(recordID, request: token, progress: progress) }
                })
                await MainActor.run { AIStreamHub.jobCenter?.aiStreamEnded(recordID, request: token) }
                return reply
            } catch {
                await MainActor.run { AIStreamHub.jobCenter?.aiStreamEnded(recordID, request: token) }
                throw error
            }
        }
    }
}
