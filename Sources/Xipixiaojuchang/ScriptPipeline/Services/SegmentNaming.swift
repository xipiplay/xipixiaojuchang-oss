import Foundation

/// 分段命名（2026-10-11 用户定）：分割这一步只管切，**名字（场景 / 角色 / 道具 / 本段在场）由单独的一步写**。
///
/// 为什么拆开：分割的提示词又要切段、又要转 △ 画面、又要统一各种名字，规则太多，AI 的注意力被分散，哪一样都做不好；
/// 而且分割是一集一集各自跑的，互相看不到，同一个场景在不同集里名字会漂（「年度赛车颁奖礼·后台」→「颁奖礼·后台」）。
/// 命名这一步一集一集串行跑，每一集都带着前面各集已经用过的名字，同一个对象沿用同一个写法；年龄阶段（「周承山四十岁时期」）也在这里判断。
///
/// 做法：AI 只返回每段的四行头行，代码把它们写回这一集分割文本里**每一段文字的最上面**（原来的头行去掉，不重复）。
/// 底层仍是同一份分割文本，所以推理分镜、素材匹配、`SplitSegments` 都不用改；工作台详情页把这一段的头行和正文分成上下两个格子。
enum SegmentNaming {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// 一段的头行（值是冒号后面的原样文字）。`stages`：【阶段】行（2026-10-14 名字与形态分离第 3 步），空 = 这一段都在主时间线，不写这一行
    struct Head: Equatable {
        var scene: String
        var roles: String
        var props: String
        var present: String
        var stages: String = ""

        var lines: [String] {
            ["【场景】：\(scene)", "【角色】：\(roles)"] + (stages.isEmpty ? [] : ["【阶段】：\(stages)"])
                + ["【道具】：\(props)", "【本段在场】：\(present)"]
        }
    }

    /// 前面各集已经用过的名字（按第一次出现的先后）
    struct Names: Equatable {
        var scenes: [String] = []
        var roles: [String] = []
        var props: [String] = []
        /// 用过的阶段写法（「周承山=四十岁」），同一个人同一阶段要一字不差
        var stages: [String] = []
        var isEmpty: Bool { scenes.isEmpty && roles.isEmpty && props.isEmpty && stages.isEmpty }
    }

    /// 每一类最多带多少个名字（再多就是一份很长的名册，AI 也看不过来）
    static let namesLimit = 300

    // MARK: 发给 AI 的内容

    /// 第 `index` 集（0 起）之前各集分割里用过的名字：只认已经有头行的集；没有的集（还没命名）不带
    static func existingNames(in episodes: [Episode], before index: Int) -> Names {
        var names = Names()
        func add(_ value: String?, to list: inout [String]) {
            guard let value, !value.isEmpty, !list.contains(value), list.count < namesLimit else { return }
            list.append(value)
        }
        for episode in episodes.prefix(max(0, index)) {
            guard let split = episode.splitText, SplitSegments.isNamed(split) else { continue }
            for segment in SplitSegments.parse(split) {
                for scene in segment.allScenes { add(scene, to: &names.scenes) }
                for role in segment.roles { add(role, to: &names.roles) }
                for prop in segment.props { add(prop, to: &names.props) }
                for (name, stage) in segment.stages.sorted(by: { $0.key < $1.key }) { add("\(name)=\(stage)", to: &names.stages) }
            }
        }
        return names
    }

    /// 命名请求的用户消息：前面各集的名字 + 本集原文 + 本集每一段（不带头行，只给正文，按「第N段」编号）
    static func userMessage(episode: Episode, names: Names, note: String = "") -> String {
        func list(_ items: [String]) -> String { items.isEmpty ? "（还没有）" : items.joined(separator: "、") }
        let segments = SplitSegments.parse(episode.splitText ?? "")
        let body = segments.map { "第\($0.number)段\n" + SplitSegments.splitHead($0.text).body }.joined(separator: "\n\n")
        let message = """
        【项目里前面各集已经用过的名字（同一个对象必须沿用这里的写法，一字不差）】
        场景：\(list(names.scenes))
        角色：\(list(names.roles))
        道具：\(list(names.props))
        阶段：\(list(names.stages))

        【本集原文（判断年龄阶段、时间跳跃、地点用，不要输出）】
        \(episode.text.trimmingCharacters(in: .whitespacesAndNewlines))

        【本集分段（共 \(segments.count) 段，逐段写头行）】
        \(body)
        """
        return RerunNote.prefixed(message, note: note)
    }

    // MARK: 读 AI 的回复

    nonisolated(unsafe) private static let blockRegex = try! NSRegularExpression(
        pattern: #"^[\s#=*\[【(（]*第\s*(\d+)\s*段[\s\]】)）=*:：]*$"#)

    /// 把 AI 的回复读成每一段的四行头行（按段序）。段数对不上 / 段号不对 / 第一段没有场景 → 报错，什么都不写。
    /// 宽松的地方：没写【场景】的段沿用上一段的；没写【本段在场】就用【角色】；没写的列表写成「无」
    static func parse(_ raw: String, expected: Int) throws -> [Head] {
        let text = SimplePipeline.unfenced(raw)
        var blocks: [(number: Int, lines: [String])] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = clean(rawLine)
            let ns = line as NSString
            if let match = blockRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               let number = Int(ns.substring(with: match.range(at: 1))) {
                blocks.append((number, []))
            } else if !blocks.isEmpty, !line.isEmpty {
                blocks[blocks.count - 1].lines.append(line)
            }
        }
        guard !blocks.isEmpty else {
            throw Failure("AI 的回复里没有识别到分段（找不到「第1段」这样的标题行），没有写入名字，请重试")
        }
        guard blocks.map(\.number) == Array(1...max(expected, 1)), blocks.count == expected else {
            throw Failure("AI 写了 \(blocks.count) 段的名字，这一集有 \(expected) 段（或段号对不上），没有写入，请重试")
        }
        var heads: [Head] = []
        for block in blocks {
            var scene: String?, roles: String?, props: String?, present: String?, stages: String?
            for line in block.lines {
                guard let (kind, value) = SplitSegments.headLine(line) else { continue }
                switch kind {
                case .scene: scene = scene ?? value
                case .roles: roles = roles ?? value
                case .props: props = props ?? value
                case .present: present = present ?? value
                case .stages: stages = stages ?? value
                }
            }
            guard let sceneValue = scene ?? heads.last?.scene else {
                throw Failure("AI 没有写第 \(block.number) 段的【场景】，没有写入名字，请重试")
            }
            func filled(_ value: String?) -> String? {
                guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
                return value
            }
            let rolesValue = filled(roles) ?? "无"
            let stagesValue = filled(stages).flatMap { ["无", "没有", "暂无"].contains($0) ? nil : $0 } ?? ""
            heads.append(Head(scene: sceneValue, roles: rolesValue, props: filled(props) ?? "无",
                              present: filled(present) ?? rolesValue, stages: stagesValue))
        }
        return heads
    }

    /// 去掉 Markdown 的星号、反引号和列表符号（AI 常写成「**【场景】**：…」「- 【角色】：…」）
    private static func clean(_ line: String) -> String {
        var text = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "-•·>".contains(first) { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
        return text
    }

    // MARK: 写回

    /// 把每段的头行写到这一集分割文本里对应那一段的最上面：这一段原来的头行去掉（不重复），时间标号和别的段原样不动。
    /// 段数对不上返回 nil
    static func merge(_ heads: [Head], into splitText: String) -> String? {
        let segments = SplitSegments.parse(splitText)
        guard !segments.isEmpty, segments.count == heads.count else { return nil }
        var lines = splitText.components(separatedBy: "\n")
        // 从后往前换：前面的行号不受影响
        for (segment, head) in zip(segments, heads).reversed() {
            let body = SplitSegments.splitHead(segment.text).body
            lines.replaceSubrange(segment.lineRange, with: head.lines + (body.isEmpty ? [] : body.components(separatedBy: "\n")))
        }
        return lines.joined(separator: "\n")
    }

    /// 工作台详情页上面那个格子改完之后：把格子里的文字当作这一段的头行，写回整集
    /// （`SplitSegments.replacing` 不许带时间标号；这里再把头行放在正文前面）
    static func combine(head: String, body: String) -> String {
        [head, body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
