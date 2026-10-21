import Foundation

/// 生图卡片的命名（2026-10-08 用户定）：
/// - 手动「新增图片」：「图片 N」，N = 已有的「图片 N」里最大的 + 1（原来是「现有张数 + 1」，删过卡片就会撞号）
/// - 批量解析 / 场景·角色·道具提取：**直接用识别出的名字**（张三、客厅、怀表）；识别不出来才叫「图片 N」
/// - 同一个项目里重名自动加序号：张三 → 张三 2 → 张三 3
/// - 「提交生成 / 重新生成」时仍会按提示词同步名字，但**同一个名字（含序号）不动**，不会把「张三 2」又改回「张三」
enum ImageCardNaming {
    static let placeholderPrefix = "图片"

    static func placeholder(_ number: Int) -> String { "\(placeholderPrefix)\(number)" }

    /// 是不是自动编号的占位名（「图片 7」）
    static func placeholderNumber(of name: String) -> Int? {
        guard name.hasPrefix(placeholderPrefix) else { return nil }
        let digits = name.dropFirst(placeholderPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// 下一个「图片 N」的 N：已有的「图片 N」里最大的 + 1（没有就是 1）
    static func nextPlaceholderNumber(existing names: [String]) -> Int {
        (names.compactMap(placeholderNumber(of:)).max() ?? 0) + 1
    }

    /// 同名自动加序号：张三 → 张三 2 → 张三 3
    static func unique(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// 去掉末尾的序号后缀：「张三 2」→「张三」（没有后缀就原样）
    static func baseName(_ name: String) -> String {
        guard let space = name.lastIndex(of: " "), space != name.startIndex else { return name }
        let tail = name[name.index(after: space)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isASCII), tail.allSatisfy(\.isNumber) else { return name }
        return String(name[..<space])
    }

    /// 一批解析结果在这个项目里该叫什么名字（按顺序，互相之间、和已有卡片之间都不重名）
    static func names(forParsed parsed: [ImagePromptParser.Parsed], existing: [String]) -> [String] {
        var taken = Set(existing)
        var next = nextPlaceholderNumber(existing: existing)
        var result: [String] = []
        for item in parsed {
            let name: String
            if item.name != ImagePromptParser.unnamed, !item.name.isEmpty {
                name = unique(item.name, taken: taken)
            } else {
                name = unique(placeholder(next), taken: taken)
                next += 1
            }
            taken.insert(name)
            result.append(name)
        }
        return result
    }

    /// 提交生成时按提示词同步名字：提不出名字 / 还是同一个名字（含序号）就不动；换了名字就用新的，重名加序号
    static func nameAfterSubmit(current: String, derived: String?, taken: Set<String>) -> String {
        guard let derived, !derived.isEmpty else { return current }
        if baseName(current) == derived || current == derived { return current }
        return unique(derived, taken: taken)
    }
}
