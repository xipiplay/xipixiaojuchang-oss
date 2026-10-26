import Foundation

/// 批量「提取音色」（2026-10-26 用户：给角色图批量绑文本音色，音频要用时自己手动绑）。
///
/// 生图页「角色」里勾几张角色卡 → 按「名字 + 阶段」（逻辑名）去重成名单，带上卡上的外貌核心描述和出场那几集的原文发给 AI，
/// 回来的「这个人是："X"」+（阶段：Y）+「音色：…」按逻辑名写回勾选的卡的 `voiceText`。
/// 只写文本音色：不动绑的音频，也不改卡上选的是文本还是音频（没绑音频的卡默认就是文本，写完马上生效）。
/// 同一个逻辑名的几张卡（换装的变化版）是同一个人同一个阶段，写同一段。
enum VoiceExtraction {
    /// 名单里的一个人
    struct Target: Equatable {
        /// 「周承山（四十岁）」；没阶段就是名字
        let logical: String
        let cardIDs: [UUID]
        /// 卡上的外貌核心描述（「电影写实风格」之前那段）
        let look: String
        /// 出场的集（1 起）；不在任何分镜头行里的是空
        let episodes: [Int]
    }

    /// 一个请求最多写几个人
    static let namesPerRequest = StoryboardNames.namesPerRequest
    /// 一个请求带的原文上限（字）：音色只要台词和旁白的交代，不用整部剧
    static let sourceBudget = 120_000

    static func logicalName(of card: ImageGenItem) -> String {
        StageName.compose(card.baseName, stage: card.stage)
    }

    /// 勾选的卡 → 名单（按卡在生图页的先后，同一个逻辑名合成一个人）
    @MainActor
    static func targets(cards: [ImageGenItem], appearances: [String: [Int]]) -> [Target] {
        var order: [String] = []
        var grouped: [String: [ImageGenItem]] = [:]
        for card in cards where card.type == .character {
            let name = logicalName(of: card)
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(card)
        }
        return order.map { name in
            let group = grouped[name] ?? []
            let look = group.map { PipelineFlow.rosterCore(of: $0.prompt) }.first { !$0.isEmpty } ?? ""
            return Target(logical: name, cardIDs: group.map(\.id), look: look, episodes: appearances[name] ?? [])
        }
    }

    /// 各集原文里这一批人用得到的部分：总字数没超就全带；超了按每个人出场的先后轮着挑集，挑到上限为止（每个人都能分到前几集）
    static func source(episodes: [(episode: Int, text: String)], for batch: [Target]) -> String {
        let all = episodes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func join(_ numbers: Set<Int>) -> String {
            all.filter { numbers.contains($0.episode) }
                .map { "第\($0.episode)集\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n")
        }
        let lengths = Dictionary(all.map { ($0.episode, $0.text.count) }, uniquingKeysWith: { first, _ in first })
        let wanted = batch.map(\.episodes).filter { !$0.isEmpty }
        // 名单里的人都不在分镜头行里（没推理分镜的项目）：从头带到上限
        let queues = wanted.isEmpty ? [all.map(\.episode)] : wanted
        var picked = Set<Int>(), used = 0, round = 0
        while queues.contains(where: { $0.count > round }) {
            for queue in queues where queue.count > round {
                let episode = queue[round]
                guard !picked.contains(episode), let length = lengths[episode] else { continue }
                if used + length > sourceBudget, !picked.isEmpty { return join(picked) }
                picked.insert(episode)
                used += length
            }
            round += 1
        }
        return join(picked)
    }

    /// 一批的请求内容：名单（带阶段、出场集、外貌）+ 原文
    static func message(batch: [Target], source: String) -> String {
        let list = batch.enumerated().map { index, target -> String in
            let (name, stage) = StageName.split(target.logical)
            var notes = stage.map { ["阶段：\($0)"] } ?? []
            if !target.episodes.isEmpty { notes.append(StoryboardNames.episodeList(target.episodes) + "出场") }
            let head = "\(index + 1). \(stage == nil ? target.logical : name)" + (notes.isEmpty ? "" : "（\(notes.joined(separator: "；"))）")
            return target.look.isEmpty ? head : head + "\n   形象：\(target.look)"
        }.joined(separator: "\n")
        var parts = ["""
        【要写音色的角色——名字已经定好】
        只为下面这些角色写，名字一字不改；不要新增、不要合并、不要漏掉。名单里括号中写了「阶段：X」的，在名字下面单独写一行「阶段：X」（照抄），按这个年龄阶段写；同一个名字的不同阶段各写一块。
        \(list)
        """]
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(trimmed.isEmpty ? "（没有可用的原文：按名单里的形象写）" : "【原文】\n\(trimmed)")
        return parts.joined(separator: "\n\n")
    }

    /// 回复 → 逻辑名: 音色描述。「音色：」那一行起到这一块结束（连成一行）；没写音色的块不算
    static func parse(_ reply: String) -> [(logical: String, voice: String)] {
        ImagePromptParser.parse(SimplePipeline.unfenced(reply)).filter { $0.type == .character }.compactMap { block in
            let parsed = CardVersion.takeVersionLines(block)
            let logical = StageName.compose(AssetVersionName.baseName(parsed.name), stage: parsed.stage)
            var lines: [String] = []
            var inVoice = false
            for line in parsed.prompt.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !inVoice, let range = voicePrefix(of: trimmed) {
                    inVoice = true
                    lines.append(String(trimmed[range.upperBound...]))
                } else if inVoice {
                    if trimmed.isEmpty { break }
                    lines.append(trimmed)
                }
            }
            let voice = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return voice.isEmpty ? nil : (logical, voice)
        }
    }

    /// 「音色：」「音色:」「**音色**：」开头
    private static func voicePrefix(of line: String) -> Range<String.Index>? {
        ["音色：", "音色:", "**音色**：", "**音色：**", "**音色**:"].first { line.hasPrefix($0) }.flatMap { line.range(of: $0) }
    }

    /// 回复对回名单：逻辑名一样的直接对上；没写阶段、而名单里这个名字只有一个人的，也算它的。
    /// 返回 卡 → 音色，和给人看的提醒（名单外的名字、名单里没写到的）
    static func match(_ replies: [(logical: String, voice: String)], to targets: [Target]) -> (voices: [UUID: String], notes: [String]) {
        var byLogical: [String: String] = [:]
        var unexpected: [String] = []
        let names = Set(targets.map(\.logical))
        for reply in replies {
            var logical = reply.logical
            if !names.contains(logical) {
                let sameName = targets.filter { StageName.split($0.logical).name == StageName.split(logical).name }
                if StageName.split(logical).stage == nil, sameName.count == 1 { logical = sameName[0].logical }
            }
            guard names.contains(logical) else { unexpected.append(reply.logical); continue }
            if byLogical[logical] == nil { byLogical[logical] = reply.voice }
        }
        var voices: [UUID: String] = [:]
        for target in targets {
            guard let voice = byLogical[target.logical] else { continue }
            for id in target.cardIDs { voices[id] = voice }
        }
        var notes: [String] = []
        if !unexpected.isEmpty {
            notes.append("提取音色：回复里有 \(unexpected.count) 个名字不在名单里（\(preview(unexpected))），没有写")
        }
        let missing = targets.map(\.logical).filter { byLogical[$0] == nil }
        if !missing.isEmpty {
            notes.append("提取音色：名单里有 \(missing.count) 个角色没写出音色（\(preview(missing))），可以只勾它们再跑一次")
        }
        return (voices, notes)
    }

    private static func preview(_ names: [String]) -> String {
        names.count <= 6 ? names.joined(separator: "、") : names.prefix(6).joined(separator: "、") + "等"
    }
}
