import Foundation

/// 名字 + 阶段合成的「逻辑名」（2026-10-14 名字与形态分离第 3 步）：「周承山（四十岁）」。
///
/// 分镜头行里只写基础名（「周承山」），这一段用哪个阶段写在分割文本的【阶段】行里；工作台状态、选版本、匹配、提取名单
/// 都按逻辑名认这个名字，到真正选卡时才拆回（名字, 阶段）。极少数一段里同一个人两个阶段同时出现时，头行里本来就写成
/// 「周承山（四十岁）」，同样能拆。没有阶段的名字，逻辑名就是名字本身。
enum StageName {
    /// 名字 + 阶段 → 逻辑名；没有阶段就是名字
    static func compose(_ name: String, stage: String?) -> String {
        guard let stage = CardVersion.normalizedStage(stage) else { return name }
        return "\(name)（\(stage)）"
    }

    /// 逻辑名 → （名字, 阶段）：末尾一对括号里的是阶段；没有括号就是（名字, nil）
    static func split(_ logical: String) -> (name: String, stage: String?) {
        let trimmed = logical.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, last == "）" || last == ")",
              let open = trimmed.lastIndex(where: { $0 == "（" || $0 == "(" }), open > trimmed.startIndex else { return (trimmed, nil) }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        let stage = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        guard !name.isEmpty, let normalized = CardVersion.normalizedStage(stage) else { return (trimmed, nil) }
        return (name, normalized)
    }

    /// 头行里的一个名字 + 这一段的【阶段】→ 逻辑名（头行里已经写成「X（阶段）」的原样）
    static func logical(_ headName: String, stages: [String: String]) -> String {
        guard let stage = stages[headName] else { return headName }
        return compose(headName, stage: stage)
    }

    /// 这张卡算不算这个逻辑名的卡：2 一模一样 / 1 只差重名序号 / 0 不相干（见 `AssetVersionName.match`）。
    /// 先按整个逻辑名、主时间线比（旧卡就叫「沈砚（少年）」的照样认）；不行再拆成（名字, 阶段）比
    static func match(card: ImageGenItem, logical: String) -> Int {
        if card.hasStage(nil) {
            let whole = AssetVersionName.match(card.name, to: logical)
            if whole > 0 { return whole }
        }
        let (name, stage) = split(logical)
        guard stage != nil, card.hasStage(stage) else { return 0 }
        return AssetVersionName.match(card.name, to: name)
    }
}
