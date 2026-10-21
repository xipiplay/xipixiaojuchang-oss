import Foundation

/// 变化版的卡认「基础版」（2026-10-09 用户定）。
///
/// 同一个人 / 地方 / 物品随时间变了样（换装、变老、被毁、损坏），变化版出图时要拿**第一次出现的那张**当参考图，
/// 才还是同一个人。这里是不碰 AI、不碰界面的那部分：认关联。
/// - 有起始集的（`第24集的周承山`，2026-10-14 起存成卡上的起始集）：基础版 = 同名同阶段里起始集更早的**最近一版**，代码直接认；
/// - 换了名字的（`周承山十岁时期`）：提取时让 AI 在这一块里单独写一行「参考：周承山」，代码读出来、把这行去掉，再按名字找最早的一张。
///   **不靠「名字里包含另一个名字」去猜**：「沈砚」会猜成「沈砚之父」，猜错了比没有更糟。
/// 关联只记在卡上（`ImageGenItem.referenceCardID`）；真正挂参考图是点「生成」的时候（`AppModel.prepareBaseReference`），因为提取时基础版还没有图。
enum ReferenceLinks {
    nonisolated(unsafe) private static let lineRegex = try! NSRegularExpression(pattern: #"^\s*[-*•·]?\s*参考\s*[：:]\s*(.*?)\s*$"#)
    private static let quotes = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"'「」『』《》。，,.；;"))

    /// 一块提取输出里单独一行的「参考：基础名字」：返回去掉这些行之后的文字 + 第一个写出来的名字。
    /// 只认**整行**以「参考：」开头的（「参考图1」「参考了……」这类描述里的字不会被误认）。
    static func splitReferenceLine(_ prompt: String) -> (prompt: String, name: String?) {
        var name: String?
        var kept: [String] = []
        for line in prompt.components(separatedBy: "\n") {
            let ns = line as NSString
            if let match = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let written = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: quotes)
                if name == nil, !written.isEmpty { name = written }
                continue
            }
            kept.append(line)
        }
        return (kept.joined(separator: "\n"), name)
    }

    /// 这张卡的基础版（没有 → nil）。只在同项目、同类型的卡里找。
    /// - `referenceName` 有值（AI 写了「参考：…」）：同一个基础名里（主时间线）最早的一张，不管它比这张早还是晚；
    /// - 没有：这张卡有起始集（`versionEpisode` > 0，旧卡是名字里的「第N集的」）→ 同一个名字、同一个阶段里起始集更早的**最近一版**
    ///   （变化版只写「改了什么」，是在上一版的基础上改的；2026-10-14 用户定，原来取最早一版）；没有起始集的不是变化版。
    /// 同起始集取列表里靠前的。
    static func base(for card: ImageGenItem, referenceName: String?, among items: [ImageGenItem]) -> ImageGenItem? {
        let pool = items.filter { $0.projectKey == card.projectKey && $0.type == card.type && $0.id != card.id }
        if let referenceName {
            let target = AssetVersionName.baseName(referenceName)
            let mains = pool.filter { $0.baseName == target && $0.hasStage(nil) }
            return (mains.isEmpty ? pool.filter { $0.baseName == target } : mains)
                .enumerated().min { ($0.element.versionEpisode, $0.offset) < ($1.element.versionEpisode, $1.offset) }?.element
        }
        let episode = card.versionEpisode
        let earlier = episode > 0
            ? pool.filter { $0.baseName == card.baseName && $0.hasStage(card.stage) && $0.versionEpisode < episode }
                .enumerated().max { ($0.element.versionEpisode, -$0.offset) < ($1.element.versionEpisode, -$1.offset) }?.element
            : nil
        if let earlier { return earlier }
        // 另一个阶段的第一版（「周承山」阶段「四十岁」）：拿同名主时间线最早那张当参考——固定特征（五官、痣）要一致（2026-10-14 第 3 步）
        guard card.stage != nil else { return nil }
        return pool.filter { $0.baseName == card.baseName && $0.hasStage(nil) }
            .enumerated().min { ($0.element.versionEpisode, $0.offset) < ($1.element.versionEpisode, $1.offset) }?.element
    }

    /// 把 `base` 当作 `card` 的基础版，会不会绕成圈（A 的基础版是 B、B 的基础版又是 A）。
    /// 绕成圈的话出图会互相等：一律不关联。`links`：现有的「卡 → 基础版」。
    static func wouldCycle(card: UUID, base: UUID, links: [UUID: UUID]) -> Bool {
        var current: UUID? = base
        var steps = 0
        while let id = current, steps < 32 {
            if id == card { return true }
            current = links[id]
            steps += 1
        }
        return false
    }

    struct Assignment: Equatable {
        /// 卡 → 基础版
        var links: [UUID: UUID] = [:]
        /// 给人看的提醒（AI 写了参考但找不到对应的卡）
        var notes: [String] = []
    }

    /// 给刚提取出来的几张卡认基础版。`referenceNames` 和 `cards` 一一对应（没写参考行的是 nil）；`items`：项目里现在所有的生图卡（含这几张）。
    static func assign(cards: [ImageGenItem], referenceNames: [String?], items: [ImageGenItem]) -> Assignment {
        var known = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.referenceCardID.map { (item.id, $0) } })
        var result = Assignment()
        for (card, referenceName) in zip(cards, referenceNames) {
            guard let base = base(for: card, referenceName: referenceName, among: items) else {
                if let referenceName {
                    result.notes.append("「\(card.name)」写了「参考：\(referenceName)」，但没找到对应的卡，没有关联参考图（可以在它的素材区手动加）")
                }
                continue
            }
            guard !wouldCycle(card: card.id, base: base.id, links: known) else { continue }
            result.links[card.id] = base.id
            known[card.id] = base.id
        }
        return result
    }

    /// 出图时挂上基础版的图以后，提示词里要有一句「根据图N参考生成。」（AI 不认识图号，所以由代码补）。
    /// 放在「描述：」那一行前面——和手动做的一样：「这个人是……」→「根据图1参考生成。」→「描述：……」；没有「描述」行就放在第一行后面。
    /// 提示词里已经有这一句就原样返回（可以反复生成）。
    static func promptWithReferenceLine(_ prompt: String, token number: Int) -> String {
        if prompt.contains("根据图\(number)参考生成") { return prompt }
        let line = "根据图\(number)参考生成。"
        var lines = prompt.components(separatedBy: "\n")
        if let described = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("描述") }) {
            lines.insert(line, at: described)
        } else if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            lines.insert(line, at: first + 1)
        } else {
            return line                          // 提示词是空的
        }
        return lines.joined(separator: "\n")
    }
}
