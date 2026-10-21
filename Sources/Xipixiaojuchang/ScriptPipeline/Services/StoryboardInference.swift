import Foundation

/// 推理分镜（2026-10-07）里不碰 AI 的那部分：把输出切成一段一段、核对段数、决定要不要把上一集的结尾带过来。
enum StoryboardInference {
    /// 推理分镜这一集没做成的原因（直接给人看，不套「AI 结果无法解析」那个前缀）
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: 切段

    /// 分镜提示词规定的每段头行：`[场景名][出场角色列表][关键道具列表]`（行首三个方括号）。
    /// 第一个头行之前的话（寒暄之类）丢掉；每段到下一个头行为止，段末多出来的分隔线去掉。
    static func blocks(from raw: String) -> [String] {
        var blocks: [[String]] = []
        for line in raw.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }      // 模型有时会多包代码块
            if isHeader(line) { blocks.append([line]) } else if !blocks.isEmpty { blocks[blocks.count - 1].append(line) }
        }
        return blocks.map { lines in
            var lines = lines
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty || isSeparator(last) { lines.removeLast() }
            return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static let headerPattern = #"^\s*\[[^\[\]\n]*\]\s*\[[^\[\]\n]*\]\s*\[[^\[\]\n]*\]"#
    /// 时间标号行：`--- 00:00 - 00:30`（写在这一段末尾，旧写法），或 `=== [00:00-00:30] ===`（写在这一段开头，当标题，2026-10-11 起）。
    /// 前面是两个以上的 `-` 或 `=`，后面可以再带一串 `-` / `=` 装饰；方括号可有可无
    private static let markerPattern = #"^\s*(?:-{2,}|={2,})\s*\[?\s*\d{1,2}:\d{2}\s*[-–—~～]\s*\d{1,2}:\d{2}\s*\]?\s*(?:-{2,}|={2,})?\s*$"#
    // 正则只编译一次：`String.range(of:options:.regularExpression)` 每调一次都重新编译，逐行逐集地调很慢
    // （2026-10-08：接力的状态文件每秒要数一遍所有集的段数，曾因此每秒占主线程上百毫秒）
    nonisolated(unsafe) private static let headerRegex = try! NSRegularExpression(pattern: headerPattern)
    nonisolated(unsafe) private static let markerRegex = try! NSRegularExpression(pattern: markerPattern)

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    static func isHeader(_ line: String) -> Bool {
        guard line.utf8.contains(UInt8(ascii: "[")) else { return false }       // 头行必有方括号：绝大多数行在这里就排除了
        return matches(headerRegex, line)
    }
    /// 时间标号行：`--- 00:00 - 00:30`
    static func isTimeMarker(_ line: String) -> Bool {
        guard line.utf8.contains(UInt8(ascii: "-")) || line.utf8.contains(UInt8(ascii: "=")) else { return false }   // 至少两个连字符或等号
        return matches(markerRegex, line)
    }
    private static func isSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return isTimeMarker(t)
            || (t.count >= 3 && t.allSatisfy { "-—–=_*".contains($0) })
    }

    /// 时间标号写在哪（2026-10-11）：
    /// - `.tail`：写在**这一段的末尾**，`--- 00:00 - 00:30`（旧写法；标号上面的内容属于它）
    /// - `.head`：写在**这一段的开头**当标题，`=== [00:00-00:30] ===`（新写法，不容易被误读成下一段的标题；标号下面的内容属于它）
    enum TimeMarkerStyle: Equatable { case head, tail }

    /// 一份分割文本用的是哪种写法。第一个标号是 `=` 写的、或者它前面没有任何正文 → 标号在段首；否则在段末。一个标号都没有 → nil
    static func markerStyle(of splitText: String) -> TimeMarkerStyle? {
        var sawContent = false
        for line in splitText.components(separatedBy: "\n") {
            if isTimeMarker(line) {
                return line.trimmingCharacters(in: .whitespaces).hasPrefix("=") || !sawContent ? .head : .tail
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty, !isEndMark(line) { sawContent = true }
        }
        return nil
    }

    /// 「时长分割」文本里有几个 30 秒段（按 `--- 00:00 - 00:30`（段末）/ `=== [00:00-00:30] ===`（段首）这类时间标号数）。
    /// 一个标号都没有就是 nil（不核对）。
    /// 最后一个标号之后的「结束。」「（完）」「END」这类收尾标记不是一段（2026-10-08：智能体跑出来的分割末尾常带一行 `**结束。**`，
    /// 被当成多出来的一段，推理分镜整集报「返回了 5 段，这一集有 6 段」）。
    static func expectedBlockCount(in splitText: String) -> Int? {
        guard let style = markerStyle(of: splitText) else { return nil }
        var count = 0, pending = false
        var opened = false                      // 段首写法：第一个标号之前的话（前言）不算一段
        for line in splitText.components(separatedBy: "\n") {
            if isTimeMarker(line) {
                if style == .tail || opened, pending { count += 1 }
                pending = false
                opened = true
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty, !isEndMark(line), style == .tail || opened {
                pending = true
            }
        }
        if pending { count += 1 }
        return count
    }

    private static let endWords: Set<String> = ["结束", "完", "终", "完结", "剧终", "全剧终", "本集完", "本集结束", "本集终", "本集剧终",
                                                 "end", "theend", "待续", "未完待续", "未完"]

    private static let endMarkSkipped = CharacterSet.whitespaces.union(.punctuationCharacters).union(.symbols)

    /// 只是「结束」「完」之类的收尾标记（去掉星号 / 下划线 / 括号 / 标点 / 破折号 / 空白之后整行就是这些词）
    static func isEndMark(_ line: String) -> Bool {
        guard line.utf8.count <= 48 else { return false }       // 收尾词最多几个字加标点；长句一定不是
        let core = line.unicodeScalars.filter { !endMarkSkipped.contains($0) }.map(String.init).joined().lowercased()
        return endWords.contains(core)
    }

    // MARK: 衔接上一集的结尾站位

    /// 发给 AI 的这一集内容：**【时间标号说明】+ 这一集的「时长分割」原文**；
    /// 有上一集的结尾站位要承接时（同一场景），把上一集最后一段放在前面，再加一句承接说明（提示词本身不动）。
    /// 时长分割里一个标号都没有（没法数段数）就不加说明，原文原样放在【本集剧本】下面。
    static func userMessage(splitText: String, previousPrompt: String?) -> String {
        guard let previous = previousPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty,
              !clearlyDifferentScene(previousPrompt: previous, splitText: splitText) else { return scriptSection(splitText) }
        // 统一后缀那一行很长，对站位没用，不带
        let tail = previous.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("必须按照镜头描述和角色台词生成") }
            .joined(separator: "\n")
        return """
        【上一集最后一段（只用来承接站位，不要照抄，也不要重新输出）】
        \(tail)

        【承接说明】本集第一段如果和上一集最后一段是同一场景，第一段的【角色初始站位与朝向】要从上一集最后一段结束时各角色的位置、朝向、手持道具接着写；不是同一场景就忽略上面这一段。

        \(scriptSection(splitText))
        """
    }

    /// 【时间标号说明】（有标号才有）+【本集剧本】。
    /// 2026-10-09：智能体接力里推理分镜老在第一次失败，原因是**标号写在每段末尾**（「内容 + `--- 00:00 - 00:30`」），
    /// 子智能体却当成「下一段的标题」：最后一个标号后面「没有内容」、开头那一段「没标时间」，都当成输入不完整报了失败；
    /// 另外同一场景连续几段时，模型有时把几段并成一块（软件的段数核对会拦住，整集重来）。所以这里明说。
    static func scriptSection(_ splitText: String) -> String {
        let heading = "【本集剧本（按它输出分镜）】\n\(splitText)"
        guard let segments = expectedBlockCount(in: splitText), let style = markerStyle(of: splitText) else { return heading }
        let explanation: String
        switch style {
        case .tail:
            explanation = "每个 `--- 00:00 - 00:30` 这样的时间标号写在它上面那一段的末尾，是那一段的时间标号，不是下一段的标题；最后一个标号后面没有内容是正常的，不是空段；开头第一段也不是「没标时间」。"
        case .head:
            explanation = "每个 `=== [00:00-00:30] ===` 这样的时间标号写在它下面那一段的开头，是这一段的标题，标号下面的内容属于这一段，不是上一段的结尾；标号本身不是内容，不要写进分镜；第一个标号之前没有内容是正常的。"
        }
        return """
        【时间标号说明】下面的本集剧本一共 \(segments) 段。\(explanation)请输出恰好 \(segments) 块（每块的第一行是 [场景][角色][道具]）；同一场景里连续的几段也必须每个 30 秒段单独一块，不得合并，不得少写台词。

        \(heading)
        """
    }

    /// 段数核对没过时给的原因（直接给人看，也是智能体重试的依据）：说清是少了还是多了、常见原因、该怎么写
    static func countMismatchMessage(got: Int, expected: Int) -> String {
        got < expected
            ? "AI 只写了 \(got) 块，这一集的时长分割有 \(expected) 段，少了 \(expected - got) 块（常见原因：把同一场景里相邻的几段并成了一块；也可能是输出被截断），没有建卡，请重试：每个 30 秒段单独一块，恰好 \(expected) 块"
            : "AI 写了 \(got) 块，比这一集的时长分割（\(expected) 段）多了 \(got - expected) 块（常见原因：把最后一个时间标号当成了一段，或把一段拆成了两块），没有建卡，请重试：恰好 \(expected) 块"
    }

    /// 上一集最后一段头行里的场景名 vs 这一集第一个「场景：」行：两边都认得出来、而且互不包含，才算明显不同。
    /// 认不出来（没写场景行 / 头行格式不对）就当作可能相同，交给 AI 按承接说明判断。
    static func clearlyDifferentScene(previousPrompt: String, splitText: String) -> Bool {
        guard let a = previousSceneName(previousPrompt), let b = firstSceneName(splitText) else { return false }
        return !a.contains(b) && !b.contains(a)
    }

    static func previousSceneName(_ prompt: String) -> String? {
        guard let line = prompt.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]") else { return nil }
        return normalized(String(line[line.index(after: open)..<close]))
    }

    static func firstSceneName(_ splitText: String) -> String? {
        for line in splitText.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("场景：") || t.hasPrefix("场景:") { return normalized(String(t.dropFirst(3))) }
        }
        return nil
    }

    /// 去掉「日 / 夜 / 内 / 外」这类时间、内外景标记，只留地点名
    static func normalized(_ name: String) -> String? {
        let tokens = name.split(whereSeparator: { " 　/、，,".contains($0) })
        let kept = tokens.filter { !$0.allSatisfy { "日夜内外".contains($0) } }.joined()
        return kept.isEmpty ? nil : kept
    }
}
