import Foundation

/// 批量粘贴提示词解析：按「这个人是：/这个场景叫：/这个物品名称叫：」切分识别类型与名字
/// 关键字后必须紧跟冒号（全角/半角）或引号才视为分段锚点，避免正文误切
enum ImagePromptParser {
    /// 提不出名字时 `Parsed.name` 的占位（调用方据此改叫「图片 N」，见 `ImageCardNaming`）
    static let unnamed = "未命名"

    struct Parsed {
        let type: ImageSubjectType
        let name: String
        let prompt: String
        /// 这一版从第几集起（提取输出里单独一行「起始集：N」，或旧写法名字里的「第N集的」；见 `CardVersion.takeVersionLines`）
        var fromEpisode: Int? = nil
        /// 阶段（单独一行「阶段：四十岁」）
        var stage: String? = nil
    }

    private struct Hit {
        let type: ImageSubjectType
        let keyword: String
        let range: Range<String.Index>
    }

    static func parse(_ text: String) -> [Parsed] {
        var hits: [Hit] = []
        for type in ImageSubjectType.allCases {
            let keyword = type.keyword
            var searchStart = text.startIndex
            while let r = text.range(of: keyword, range: searchStart..<text.endIndex) {
                // 关键字后必须紧跟冒号或引号（允许中间有空白），才视为分段锚点
                let after = text[r.upperBound...].drop { $0 == " " || $0 == "　" }
                if let first = after.first, isPunctuation(first) {
                    hits.append(Hit(type: type, keyword: keyword, range: r))
                }
                searchStart = r.upperBound
            }
        }
        hits.sort { $0.range.lowerBound < $1.range.lowerBound }
        guard !hits.isEmpty else { return [] }

        var results: [Parsed] = []
        for (i, hit) in hits.enumerated() {
            let end = i + 1 < hits.count ? hits[i + 1].range.lowerBound : text.endIndex
            let segment = String(text[hit.range.lowerBound..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            let name = extractName(from: segment, keyword: hit.keyword) ?? unnamed
            results.append(Parsed(type: hit.type, name: name, prompt: segment))
        }
        return results
    }

    /// 从**单条提示词**里提取名字。改提示词后同步卡片名用（`parse` 是批量切分，这里只针对一条）。
    /// - `type` 为 nil 时依次尝试所有类型的关键字。
    /// - 沿用与 `parse` 相同的**锚点判定**（关键字后必须紧跟冒号/引号），避免正文里的关键字误命中。
    /// - 提不出名字返回 nil（调用方保持原名不动）。
    static func name(forPrompt prompt: String, type: ImageSubjectType?) -> String? {
        for t in (type.map { [$0] } ?? ImageSubjectType.allCases) {
            guard let kwRange = prompt.range(of: t.keyword) else { continue }
            let after = prompt[kwRange.upperBound...].drop { $0 == " " || $0 == "　" }
            guard let first = after.first, isPunctuation(first) else { continue }
            if let name = extractName(from: prompt, keyword: t.keyword) { return name }
        }
        return nil
    }

    /// 是否为"关键字后紧跟"的合法标点（冒号/引号）
    private static func isPunctuation(_ ch: Character) -> Bool {
        ["：", ":", "\"", "'", "“", "”", "「", "」", "『", "』"].contains(ch)
    }

    /// 从一条提示词里提取名字：关键字后（跳过冒号/引号/空白）到第一个逗号或右引号为止
    private static func extractName(from segment: String, keyword: String) -> String? {
        guard let kwRange = segment.range(of: keyword) else { return nil }
        var rest = segment[kwRange.upperBound...]
        while let first = rest.first, isPunctuation(first) || first == " " || first == "　" {
            rest = rest.dropFirst()
        }
        var name = ""
        for ch in rest {
            if ch == "，" || ch == "," || isClosingQuote(ch) { break }
            name.append(ch)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 右引号（名字的结束边界之一）
    private static func isClosingQuote(_ ch: Character) -> Bool {
        ["\"", "'", "”", "」", "』"].contains(ch)
    }
}
