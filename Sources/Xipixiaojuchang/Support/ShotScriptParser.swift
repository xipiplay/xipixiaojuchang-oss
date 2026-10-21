import Foundation

/// 分镜脚本解析：把一集剧本的分镜提示词文本拆成逐分镜字符串
/// 分隔规则：「行首恰好三个 [标签]」（如 [场景][角色][道具]）视为新分镜开始；
/// 分镜内部的时间标签（[0.1-3 秒] …）行首只有一个标签且后面带文字，不会被误判。
enum ShotScriptParser {
    static func parse(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        // ⚠️ **不锚定行尾**（2026-10-03 修）：原来要求"整行只有三个 [..]"，
        // 但用户的分镜标题行后面紧跟「【角色初始站位与朝向】…」（同行）→ 一条都匹配不上，
        // 整段被并成 1 条（"批量解析没生效"的根因）。现在"行首是三个 [..]"即算分镜头。
        let separator = try? NSRegularExpression(pattern: #"^(\[[^\]]+\]){3}"#)
        var shots: [String] = []
        var current: [String] = []

        func flush() {
            if !current.isEmpty {
                shots.append(merge(current))
                current = []
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && current.isEmpty { continue }  // 文件头空行
            if let separator,
               separator.firstMatch(in: trimmed, options: [],
                                    range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
                flush()
                current = [line]
            } else {
                current.append(line)
            }
        }
        flush()
        return shots
    }

    /// 拖进工作台的 txt 是不是分镜（2026-10-14：空项目 / 自由创作里拖文件，自动认是分镜还是剧本）：
    /// 有行首是 `[场景][角色][道具]` 的就是分镜，返回每一段（第一个这种行之前的开场白不算）；一行都没有 = 剧本，返回 nil。
    /// ⚠️ 不能直接看 `parse` 出几个：一行头行都没有时它会把整篇当成一个分镜
    static func storyboardShots(_ text: String) -> [String]? {
        let shots = parse(text)
        let header = try? NSRegularExpression(pattern: #"^(\[[^\]]+\]){3}"#)
        func startsWithHeader(_ shot: String) -> Bool {
            let first = shot.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            return header?.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) != nil
        }
        let real = shots.filter(startsWithHeader)
        return real.isEmpty ? nil : real
    }

    /// 合并行并去掉首尾空行（保留分镜内部的空行分段）
    private static func merge(_ lines: [String]) -> String {
        var l = lines
        while let first = l.first, first.trimmingCharacters(in: .whitespaces).isEmpty { l.removeFirst() }
        while let last = l.last, last.trimmingCharacters(in: .whitespaces).isEmpty { l.removeLast() }
        return l.joined(separator: "\n")
    }

    /// 预览用：取分镜文本的首行（[场景][角色][道具]）
    static func previewLine(of shotText: String) -> String {
        shotText.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? shotText
    }
}
