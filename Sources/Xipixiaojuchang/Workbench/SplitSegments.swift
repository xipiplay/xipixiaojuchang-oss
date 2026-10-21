import Foundation

/// 把一集的「时长分割」文本按时间标号切成一段一段（2026-10-09 工作台第 2 步）。
///
/// 时间标号有两种写法（见 `StoryboardInference.markerStyle`）：
/// - 段末（旧）`--- 00:00 - 00:30`，写在**它上面那一段的末尾**：一段 = 上一个标号之后到这个标号之前的文字，标号只给这一段的起止时间。
///   最后一个标号之后的「结束。」之类收尾词不算一段；收尾词以外还有文字的，算最后一段（没有时间）。
/// - 段首（2026-10-11 起）`=== [00:00-00:30] ===`，写在**它下面那一段的开头**当标题：一段 = 这个标号之后到下一个标号之前的文字；
///   第一个标号之前的话（前言）不算一段。
/// 段数和 `StoryboardInference.expectedBlockCount` 同一个口径，也就是推理分镜要求的块数。
///
/// 还顺带估一下每段用到的场景 / 角色 / 道具（分镜还没推理出来时，段卡片上先显示这个，标成「预估」）：
/// 来源是分割文本里的 `场景：` `【场景】：` `【角色】：` `【道具】：` 行，和台词前的说话人（`林知夏：…`）。
/// 分割提示词规定同一场景只在第一个 30 秒列角色 / 道具，所以后面的段**沿用同一场景里已经列过的**；换了场景就重新算。
enum SplitSegments {
    struct Segment: Equatable {
        /// 1 起
        var number: Int
        /// 「00:00」「00:30」；最后一段没有标号时为 nil
        var start: String?
        var end: String?
        /// 这一段的文字（不含时间标号行），首尾空白去掉
        var text: String
        /// 这一段的文字在整集分割文本里占的行（0 起，去掉首尾空行；不含时间标号行）。改一段文字写回整集时用
        var lineRange: Range<Int> = 0..<0
        /// 预估：这一段的场景名（本段没写就沿用上一段的）；一段里换了场（并进来的短场）时是出场的第一个
        var scene: String?
        /// 这一段里依次出场的场景名（2026-10-11 放宽「换场必断段」：不够一段的短场并进相邻段，一段可以有两个场景）。
        /// 空 = 没解析出来（手工构造的 `Segment` 只设了 `scene`）：用 `allScenes`
        var scenes: [String] = []
        var roles: [String]
        var props: [String]
        /// 【阶段】行（2026-10-14 名字与形态分离第 3 步）：这一段里不在主时间线的人用哪个阶段（名字 → 阶段，如「周承山」→「四十岁」）。
        /// 名字只写基础名，阶段写在这一行，不进分镜提示词；匹配按（名字, 阶段）找卡
        var stages: [String: String] = [:]

        /// 这一段的全部场景名（按出场先后）
        var allScenes: [String] { scenes.isEmpty ? (scene.map { [$0] } ?? []) : scenes }

        var timeRange: String? {
            guard let start, let end else { return nil }
            return "\(start)–\(end)"
        }
    }

    nonisolated(unsafe) private static let timeRegex = try! NSRegularExpression(pattern: #"(\d{1,2}):(\d{2})\s*[-–—~～]\s*(\d{1,2}):(\d{2})"#)
    nonisolated(unsafe) private static let sceneRegex = try! NSRegularExpression(pattern: #"^\s*【?场景】?\s*[：:]\s*(.+?)\s*$"#)
    nonisolated(unsafe) private static let rolesRegex = try! NSRegularExpression(pattern: #"^\s*【?(?:角色|人物)】?\s*[：:]\s*(.+?)\s*$"#)
    nonisolated(unsafe) private static let propsRegex = try! NSRegularExpression(pattern: #"^\s*【?道具】?\s*[：:]\s*(.+?)\s*$"#)
    /// 【本段在场】：本段画面里在场的人物（每段都写；有人进出场时标「老孙（中途进场）」）。写了它就以它为准，不再用整场的角色名单估
    nonisolated(unsafe) private static let presentRegex = try! NSRegularExpression(pattern: #"^\s*【?本段在场】?\s*[：:]\s*(.+?)\s*$"#)
    /// 【阶段】：周承山=四十岁、许曼=二十岁。必须带【】（正文里「阶段：」开头的句子不算）
    nonisolated(unsafe) private static let stageRegex = try! NSRegularExpression(pattern: #"^\s*【阶段】\s*[：:]\s*(.+?)\s*$"#)
    nonisolated(unsafe) private static let parentheticalRegex = try! NSRegularExpression(pattern: #"[（(][^）)]*[）)]"#)
    /// 台词行：开头一个短名字（名字可以用 [ ] 或【 】括起来，后面可带括号备注，如「齐掌柜（OS）：」「[房东大妈]（拍着引擎盖嚎啕大哭）：」）后面跟冒号
    nonisolated(unsafe) private static let speakerRegex = try! NSRegularExpression(
        pattern: #"^\s*[\[【]?([一-鿿A-Za-z0-9·]{1,8})[\]】]?\s*(?:[（(][^）)]*[）)])?\s*[：:]"#)
    private static let notSpeakers: Set<String> = ["场景", "角色", "人物", "道具", "旁白", "画外音", "字幕", "备注", "说明", "画面", "时间", "地点", "本段在场", "阶段"]
    private static let listSeparators = CharacterSet(charactersIn: "、，,；;")

    /// 场景行里地点后面跟的时间 / 内外景标记（「黄昏 外」「日 内」）：这些不是地点名
    private static let sceneMarkers: Set<String> = ["日", "夜", "晨", "昏", "内", "外", "黄昏", "清晨", "早晨", "傍晚", "凌晨", "午后", "深夜", "夜晚",
                                                     "白天", "上午", "中午", "下午", "晚上", "内景", "外景", "日内", "日外", "夜内", "夜外"]

    /// 「蕴古斋前柜 日 内」→「蕴古斋前柜」：按空白切开，从第一个标记起往后都不要；全是标记就原样留着，不凭空丢名字
    static func sceneName(_ raw: String) -> String {
        let tokens = raw.split(whereSeparator: { " 　\t".contains($0) }).map(String.init)
        let kept = Array(tokens.prefix { !sceneMarkers.contains($0) && !$0.allSatisfy { "日夜内外晨昏".contains($0) } })
        return kept.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : kept.joined(separator: " ")
    }

    /// 「A 日 内、B 夜 外」→ [A, B]：按顿号 / 逗号切开再各自去掉日夜内外；同一个名字只留一个
    static func sceneNames(_ raw: String) -> [String] {
        var result: [String] = []
        for piece in raw.components(separatedBy: listSeparators) {
            let name = sceneName(piece.trimmingCharacters(in: .whitespaces))
            if !name.isEmpty, !result.contains(name) { result.append(name) }
        }
        return result
    }

    private static func capture(_ regex: NSRegularExpression, in line: String) -> String? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func names(in list: String) -> [String] {
        list.components(separatedBy: listSeparators)
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "「」“”\"'"))) }
            .filter { !$0.isEmpty && !["无", "没有", "暂无"].contains($0) }
    }

    /// 「齐掌柜、老孙（中途进场）」→ [齐掌柜, 老孙]：括号里的备注先去掉（里面可能有逗号），再按顿号切
    private static func presentNames(in list: String) -> [String] {
        let range = NSRange(location: 0, length: (list as NSString).length)
        return names(in: parentheticalRegex.stringByReplacingMatches(in: list, range: range, withTemplate: ""))
    }

    /// 「周承山=四十岁、许曼=二十岁」→ [周承山: 四十岁, 许曼: 二十岁]；「无」或写不成「名字=阶段」的忽略
    static func stagePairs(in value: String) -> [String: String] {
        var result: [String: String] = [:]
        for piece in value.components(separatedBy: listSeparators) {
            let parts = piece.components(separatedBy: CharacterSet(charactersIn: "=＝"))
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces), stage = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, !stage.isEmpty, result[name] == nil { result[name] = stage }
        }
        return result
    }

    private static func appendUnique(_ names: [String], to list: inout [String]) {
        for name in names where !list.contains(name) { list.append(name) }
    }

    /// 解析结果按原文记下来（2026-10-12）：工作台每次重算都要把每一集的分割文本解析一遍（20 集约 31ms），
    /// 而文本没改结果就不会变。按整段文本查表（比一遍正则快得多）；记太多就整个清掉重来。可能在后台线程用，所以加锁
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [Segment]] = [:]

    static func parse(_ splitText: String) -> [Segment] {
        cacheLock.lock()
        if let hit = cache[splitText] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let segments = parseUncached(splitText)
        cacheLock.lock()
        if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
        cache[splitText] = segments
        cacheLock.unlock()
        return segments
    }

    private static func parseUncached(_ splitText: String) -> [Segment] {
        // 先按标号切出（文字行, 起止）
        var pieces: [(lines: [String], start: String?, end: String?, range: Range<Int>)] = []
        var current: [String] = []
        var currentIndices: [Int] = []
        func hasContent(_ lines: [String]) -> Bool { lines.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        /// 这一段占的行：第一个到最后一个**有字**的行（收尾词、首尾空行不算）
        func tightRange() -> Range<Int> {
            let filled = zip(current, currentIndices).filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.1)
            return (filled.first ?? 0)..<((filled.last ?? -1) + 1)
        }
        func times(of line: String) -> (String?, String?) {
            let ns = line as NSString
            guard let match = timeRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return (nil, nil) }
            func part(_ i: Int) -> Int { Int(ns.substring(with: match.range(at: i))) ?? 0 }
            return (String(format: "%02d:%02d", part(1), part(2)), String(format: "%02d:%02d", part(3), part(4)))
        }
        let headStyle = StoryboardInference.markerStyle(of: splitText) == .head
        var opened = false                                    // 段首写法：见到第一个标号之前的话是前言，不算
        var openingTimes: (String?, String?) = (nil, nil)     // 段首写法：这一段开头那个标号写的时间
        for (lineIndex, line) in splitText.components(separatedBy: "\n").enumerated() {
            if StoryboardInference.isTimeMarker(line) {
                if headStyle {
                    if opened, hasContent(current) { pieces.append((current, openingTimes.0, openingTimes.1, tightRange())) }
                    openingTimes = times(of: line)
                    opened = true
                } else if hasContent(current) {
                    let t = times(of: line)
                    pieces.append((current, t.0, t.1, tightRange()))
                }
                current = []
                currentIndices = []
            } else if !StoryboardInference.isEndMark(line), !headStyle || opened {
                current.append(line)
                currentIndices.append(lineIndex)
            }
        }
        if hasContent(current) { pieces.append((current, headStyle ? openingTimes.0 : nil, headStyle ? openingTimes.1 : nil, tightRange())) }

        // 再估每段的场景 / 角色 / 道具：同一场景里后面的段沿用前面列过的
        var scene: String?
        var sceneRoles: [String] = [], sceneProps: [String] = []
        var segments: [Segment] = []
        for (offset, piece) in pieces.enumerated() {
            var declaredScenes: [String] = []
            var declaredRoles: [String] = [], declaredProps: [String] = [], speakers: [String] = [], present: [String] = []
            var stages: [String: String] = [:]
            for line in piece.lines {
                if let value = capture(stageRegex, in: line) {
                    stages.merge(stagePairs(in: value)) { first, _ in first }
                } else if let value = capture(presentRegex, in: line) {
                    appendUnique(presentNames(in: value), to: &present)
                } else if let value = capture(sceneRegex, in: line) {
                    declaredScenes = sceneNames(value)
                } else if let value = capture(rolesRegex, in: line) {
                    appendUnique(names(in: value), to: &declaredRoles)
                } else if let value = capture(propsRegex, in: line) {
                    appendUnique(names(in: value), to: &declaredProps)
                } else if let name = capture(speakerRegex, in: line), !notSpeakers.contains(name) {
                    appendUnique([name], to: &speakers)
                }
            }
            if let first = declaredScenes.first, first != scene {
                scene = first
                sceneRoles = []
                sceneProps = []
            }
            appendUnique(declaredRoles, to: &sceneRoles)
            appendUnique(declaredProps, to: &sceneProps)
            var roles = sceneRoles
            appendUnique(speakers, to: &roles)
            if !present.isEmpty { roles = present }            // 写了【本段在场】就以它为准：画面里到底谁在
            segments.append(Segment(number: offset + 1, start: piece.start, end: piece.end,
                                    text: piece.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                                    lineRange: piece.range, scene: scene, scenes: declaredScenes.isEmpty ? (scene.map { [$0] } ?? []) : declaredScenes,
                                    roles: roles, props: sceneProps, stages: stages))
            if let last = declaredScenes.last { scene = last }       // 这一段里换过场：后面没写场景的段接着最后那个场景
        }
        return segments
    }

    /// 每张分镜卡这一段的【阶段】（段和卡按位置配对，见 `Episode.pairedShotIDs`；配不上 = 空）
    static func stagesByShot(_ episode: Episode) -> [UUID: [String: String]] {
        let ids = episode.pairedShotIDs
        guard !ids.isEmpty, let split = episode.splitText else { return [:] }
        var result: [UUID: [String: String]] = [:]
        for (id, segment) in zip(ids, parse(split)) where !segment.stages.isEmpty { result[id] = segment.stages }
        return result
    }

    // MARK: 头行（2026-10-11 分段命名：名字和正文分开放）

    /// 头行的几种：【场景】【角色】【阶段】【道具】【本段在场】（【阶段】只在有人不在主时间线时写）
    enum HeadKind: Equatable { case scene, roles, stages, props, present }

    /// 一行是不是头行：是就返回种类和冒号后面的内容（原样，不拆名字）
    static func headLine(_ line: String) -> (kind: HeadKind, value: String)? {
        for (kind, regex) in [(HeadKind.present, presentRegex), (.stages, stageRegex), (.scene, sceneRegex), (.roles, rolesRegex), (.props, propsRegex)] {
            if let value = capture(regex, in: line) { return (kind, value) }
        }
        return nil
    }

    /// 一段的文字拆成「头行」和「正文」：头行 = 四种头行（在哪一行都算），按原来的顺序；正文 = 其余的行，首尾空行去掉。
    /// 工作台详情页的两个格子就是这么分的：上面名字、下面本段剧情
    static func splitHead(_ text: String) -> (head: String, body: String) {
        var head: [String] = [], body: [String] = []
        for line in text.components(separatedBy: "\n") {
            if headLine(line) != nil { head.append(line.trimmingCharacters(in: .whitespaces)) } else { body.append(line) }
        }
        func trimmed(_ lines: [String]) -> String { lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        return (trimmed(head), trimmed(body))
    }

    /// 这一集的分割文本算不算「已经命名」：有分段，而且每一段都有场景（本段没写就沿用上一段的）。
    /// 旧的分割自己带着头行（同一场景只在第一段写）也算；一行头行都没有的分割（分割只管切之后的样子）不算。
    /// 只看场景、不看角色：一段里没人（【角色】：无）是正常的，不能因此永远显示「待命名」
    static func isNamed(_ splitText: String) -> Bool {
        let segments = parse(splitText)
        return !segments.isEmpty && segments.allSatisfy { $0.scene != nil }
    }

    /// 只重新推理一段时发给 AI 的内容：这一段的文字 + 它自己的时间标号（和整集分割文本同一种写法：段末 `--- 00:00 - 00:30`，
    /// 或段首 `=== [00:00-00:30] ===`）。
    /// 同一场景的后几段不重写【场景】【角色】【道具】（沿用前面的）：单独发一段，AI 看不到前面，所以缺的话把软件估出来的补在最前面
    static func standaloneText(for segment: Segment, style: StoryboardInference.TimeMarkerStyle?) -> String {
        let lines = segment.text.components(separatedBy: "\n")
        func declares(_ regex: NSRegularExpression) -> Bool { lines.contains { capture(regex, in: $0) != nil } }
        var added: [String] = []
        if !declares(sceneRegex), !segment.allScenes.isEmpty { added.append("【场景】：" + segment.allScenes.joined(separator: "、")) }
        if !declares(rolesRegex), !segment.roles.isEmpty { added.append("【角色】：" + segment.roles.joined(separator: "、")) }
        if !declares(propsRegex), !segment.props.isEmpty { added.append("【道具】：" + segment.props.joined(separator: "、")) }
        let body = (added + [segment.text]).joined(separator: "\n")
        guard segment.timeRange != nil else { return body }
        let range = "\(segment.start ?? "00:00")-\(segment.end ?? "00:30")"
        return style == .head ? "=== [\(range)] ===\n" + body : body + "\n--- \(segment.start ?? "00:00") - \(segment.end ?? "00:30")"
    }

    /// 把整集分割文本里第 `number` 段的文字换成 `newText`，别的段、时间标号行原样不动。
    /// 新文字里**不能有时间标号行**（会把一段拆成两段、让段数和已经推理好的分镜卡对不上）：有就返回 nil。找不到这一段也返回 nil。
    static func replacing(segment number: Int, in splitText: String, with newText: String) -> String? {
        guard let segment = parse(splitText).first(where: { $0.number == number }) else { return nil }
        let replacement = newText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard !replacement.contains(where: StoryboardInference.isTimeMarker) else { return nil }
        var lines = splitText.components(separatedBy: "\n")
        lines.replaceSubrange(segment.lineRange, with: replacement)
        return lines.joined(separator: "\n")
    }
}
