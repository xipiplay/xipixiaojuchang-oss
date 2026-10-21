import Foundation

/// 生图卡的「版本身份」（2026-10-14 名字与形态分离）：一个版本 = （类型, 名字, 阶段, 起始集）。
///
/// 名字只放基础名（「周承山」）；「哪个形态」存成卡上的字段——`stage`（四十岁 / 少年；nil = 主时间线）和
/// `fromEpisode`（这一版从第几集起；nil = 全程）。原来这些写在名字里（「第3集的沈惊澜」「周承山四十岁时期」），
/// 名字又会被抄进生图 / 生视频提示词，模型看了会误解。
///
/// 旧卡名字里的「第N集的」前缀格式固定，读进来 / 新建时直接拆成起始集（`splitLegacyPrefix`）；
/// 拆不了的老名字（「周承山四十岁时期」）原样当名字，不去猜（「周家客厅」不是「周家」的阶段版）。
enum CardVersion {
    /// 名字是「第N集的X」→ 名字改成 X，起始集记 N（已经有起始集的不覆盖）
    static func splitLegacyPrefix(_ card: inout ImageGenItem) {
        guard let parsed = AssetVersionName.parse(card.name) else { return }
        card.name = parsed.base
        if card.fromEpisode == nil { card.fromEpisode = parsed.episode }
    }

    /// 提交生成时按提示词同步名字（见 `ImageCardNaming.nameAfterSubmit`）。提示词里写的还是「第3集的沈惊澜」时：
    /// 名字取「沈惊澜」，起始集卡上还没有才用它（卡上设过的以卡上为准）；重名只在同一个版本槽里算
    static func syncNameFromPrompt(_ card: inout ImageGenItem, others: [ImageGenItem]) {
        var derived = ImagePromptParser.name(forPrompt: card.prompt, type: card.type)
        if let written = derived, let parsed = AssetVersionName.parse(written) {
            derived = parsed.base
            if card.fromEpisode == nil { card.fromEpisode = parsed.episode }
        }
        let id = card.id, project = card.projectKey, mine = slot(card)
        let taken = Set(others.filter { $0.projectKey == project && $0.id != id && slot($0) == mine }.map(\.name))
        card.name = ImageCardNaming.nameAfterSubmit(current: card.name, derived: derived, taken: taken)
    }

    /// 版本槽：起始集 + 阶段。重名只在同一个槽里算（「第1集的周承山」和「第3集的周承山」都叫「周承山」，是两个版本）
    static func slot(_ card: ImageGenItem) -> String {
        "\(card.versionEpisode)|\(normalizedStage(card.stage) ?? "")"
    }

    nonisolated(unsafe) private static let episodeLine = try! NSRegularExpression(pattern: #"^\s*[-*•·]?\s*起始集\s*[：:]\s*(.*?)\s*$"#)
    nonisolated(unsafe) private static let stageLine = try! NSRegularExpression(pattern: #"^\s*[-*•·]?\s*阶段\s*[：:]\s*(.*?)\s*$"#)
    /// 旧写法里名字前的「第N集的」：只认紧跟在引号 / 冒号后面的（名字开头），同一行描述里的「第一集的旧物」不动
    nonisolated(unsafe) private static let episodePrefix = try! NSRegularExpression(pattern: #"(?<=[：:“"「『])\s*第\s*[0-9０-９零〇一二两三四五六七八九十百]+\s*集\s*的"#)
    /// 旧写法变化版的「，基于"第1集的沈惊澜"修改」
    nonisolated(unsafe) private static let basedOnClause = try! NSRegularExpression(pattern: #"\s*[，,]?\s*基于\s*[“"「『]?[^”"」』\n]*?[”"」』]?\s*修改"#)
    private static let edgeQuotes = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"'「」『』。，,；;"))

    /// 一块提取输出里的版本信息拿出来，**不留在提示词里**（2026-10-14 名字与形态分离第 2 步——提示词是要发给生图模型的）：
    /// - 单独一行的「起始集：N」「阶段：X」→ 字段，这两行删掉；
    /// - 关键字那一行（这个人是：…）里旧写法的「第N集的」和「，基于"第M集的X"修改」去掉（起始集没写那一行时用前缀里的集号）；
    /// - 名字只留基础名。
    static func takeVersionLines(_ parsed: ImagePromptParser.Parsed) -> ImagePromptParser.Parsed {
        var episode = parsed.fromEpisode, stage = parsed.stage
        var kept: [String] = []
        var cleanedKeywordLine = false
        for line in parsed.prompt.components(separatedBy: "\n") {
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            if let m = episodeLine.firstMatch(in: line, range: all) {
                let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: edgeQuotes)
                    .replacingOccurrences(of: "第", with: "").replacingOccurrences(of: "集", with: "")
                if episode == nil, let n = AssetVersionName.number(value.trimmingCharacters(in: .whitespaces)) { episode = n }
                continue
            }
            if let m = stageLine.firstMatch(in: line, range: all) {
                if stage == nil { stage = normalizedStage(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: edgeQuotes)) }
                continue
            }
            if !cleanedKeywordLine, line.contains(parsed.type.keyword) {
                cleanedKeywordLine = true
                var text = basedOnClause.stringByReplacingMatches(in: line, range: all, withTemplate: "")
                text = episodePrefix.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
                kept.append(text)
                continue
            }
            kept.append(line)
        }
        var name = parsed.name
        if let legacy = AssetVersionName.parse(name) {
            name = legacy.base
            if episode == nil { episode = legacy.episode }
        }
        return ImagePromptParser.Parsed(type: parsed.type, name: name, prompt: kept.joined(separator: "\n"),
                                        fromEpisode: episode, stage: stage)
    }

    /// 阶段的统一写法：去掉首尾空白；空的算没有
    static func normalizedStage(_ stage: String?) -> String? {
        guard let trimmed = stage?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

extension ImageGenItem {
    /// 这一版从第几集起（没有 = 0，全程有效）。名字里还带「第N集的」的旧写法也认
    var versionEpisode: Int { fromEpisode ?? AssetVersionName.parse(name)?.episode ?? 0 }

    /// 基础名（旧写法的「第N集的」前缀去掉）
    var baseName: String { AssetVersionName.baseName(name) }

    /// 是不是这个阶段的卡（nil 和空白算同一个：主时间线）
    func hasStage(_ other: String?) -> Bool {
        CardVersion.normalizedStage(stage) == CardVersion.normalizedStage(other)
    }

    /// 版本说明：「四十岁 · 第3集起」；只有一样就只写那一样；都没有 = nil
    var versionNote: String? {
        let parts = [CardVersion.normalizedStage(stage), versionEpisode > 0 ? "第\(versionEpisode)集起" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 给人看的名字：「周承山 · 四十岁 · 第3集起」；没有阶段 / 起始集就只是名字
    var displayName: String { versionNote.map { "\(baseName) · \($0)" } ?? baseName }
}
