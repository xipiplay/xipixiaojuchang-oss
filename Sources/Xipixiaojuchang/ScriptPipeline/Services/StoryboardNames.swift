import Foundation

/// 提取素材的「名字」从推理分镜的头行来（2026-10-09 用户定）。
///
/// 原来提取自己读剧本起名，推理分镜又自己写一遍头行 `[场景名][出场角色列表][关键道具列表]`，两边的名字对不上，
/// 匹配素材就挂不上图。现在反过来：先推理分镜，**名字就取头行里实际出现的**，提取只负责给这些名字写描述：
/// - 角色、道具：描述去**原文**里找（外貌、年龄、穿着在原文里，分镜里没有）；
/// - 场景：描述去**用到这个场景的分镜**里找（场景图要和镜头里实际出现的陈设一致）。
/// 这个文件是不碰 AI 的那部分：从头行收集名字、挑证据、分批、拼发给 AI 的消息、核对结果。
enum StoryboardNames {
    typealias Kind = PipelineFlow.ExtractionKind

    /// 一段分镜：第几集、第几段、卡片现在的提示词
    struct Shot: Equatable, Sendable {
        let episode: Int
        let segment: Int
        let prompt: String
    }

    /// 头行里的一个名字，和用到它的所有分镜（按集、段的顺序）
    struct Entry: Equatable, Sendable {
        let name: String
        var shots: [Shot]
        /// 出现过的集号（1 起，升序、不重复）
        var episodes: [Int] {
            var seen = Set<Int>()
            return shots.map(\.episode).filter { seen.insert($0).inserted }
        }
    }

    /// 前面各集已经有的卡：基础名（去掉「第N集的」）+「名字：核心描述」
    struct Existing: Equatable, Sendable {
        let base: String
        let line: String
    }

    /// 头行里的三组名字
    struct Head: Equatable {
        var scenes: [String] = []
        var roles: [String] = []
        var props: [String] = []
    }

    // MARK: 头行 → 名字

    nonisolated(unsafe) private static let bracketRegex = try! NSRegularExpression(pattern: #"\[([^\[\]\n]*)\]"#)
    /// 匹配素材会在头行名字前插「图N」（图 / 视频 / 音频）：读名字时要去掉
    nonisolated(unsafe) private static let materialTokenRegex = try! NSRegularExpression(pattern: #"(?:图|视频|音频)\s*\d+\s*"#)
    private static let separators = CharacterSet(charactersIn: "、，,；;\n")
    private static let quotes = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"'「」『』"))
    /// 头行里写「没有」的各种写法：不是名字
    private static let placeholders: Set<String> = ["无", "没有", "暂无", "无道具", "无角色", "无关键道具", "略", "-", "—", "none", "n/a", "null"]

    /// 去掉「图1」「视频2」这类匹配素材时插进去的标记
    static func strippingMaterialTokens(_ text: String) -> String {
        materialTokenRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
    }

    /// 一段分镜提示词的头行（第一个非空行，必须是 `[..][..][..]`）里的三组名字。第一行不是头行 → nil
    /// 解析结果按头行原文记下来（2026-10-13 稳定性）：工作台每次重算分镜状态，都要把每张分镜卡的头行用正则重新解析一遍
    ///（600 段的项目里是剩下的大头），而头行没改结果就不会变。按头行查表；记太多就整个清掉重来。可能在后台线程用，所以加锁
    private static let headCacheLock = NSLock()
    nonisolated(unsafe) private static var headCache: [String: Head?] = [:]

    static func head(of prompt: String) -> Head? {
        guard let line = prompt.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        headCacheLock.lock()
        if let hit = headCache[line] { headCacheLock.unlock(); return hit }
        headCacheLock.unlock()
        let parsed = parseHead(line)
        headCacheLock.lock()
        if headCache.count >= 4096 { headCache.removeAll(keepingCapacity: true) }
        headCache[line] = parsed
        headCacheLock.unlock()
        return parsed
    }

    private static func parseHead(_ line: String) -> Head? {
        guard StoryboardInference.isHeader(line) else { return nil }
        let ns = line as NSString
        let groups = bracketRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).prefix(3)
            .map { ns.substring(with: $0.range(at: 1)) }
        guard groups.count == 3 else { return nil }
        return Head(scenes: names(in: groups[0], isScene: true), roles: names(in: groups[1]), props: names(in: groups[2]))
    }

    nonisolated(unsafe) private static let parentheticalRegex = try! NSRegularExpression(pattern: #"[（(][^）)]*[）)]"#)
    /// 括号里写着这些词的是「出场方式」之类的备注，不是名字的一部分（分割的【本段在场】常写「老孙（中途进场）」「宋文清（画外音）」）
    private static let annotationWords = ["进场", "出场", "离场", "退场", "登场", "入画", "出画", "中途", "画外", "OS", "VO", "旁白", "声音", "稍后", "随后", "先走", "后到"]

    /// 去掉名字后面的出场备注：「老孙（中途进场）」→「老孙」；「沈砚（少年）」这类区分形态的括号不动。
    /// 要在按逗号切名字**之前**做：备注里可能有逗号（「宋文清（画外音，OS）」）
    static func strippingAnnotations(_ text: String) -> String {
        guard text.contains("（") || text.contains("(") else { return text }
        let ns = text as NSString
        var result = text
        for match in parentheticalRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let inner = ns.substring(with: match.range).uppercased()
            guard annotationWords.contains(where: { inner.contains($0.uppercased()) }) else { continue }
            result = (result as NSString).replacingCharacters(in: match.range, with: "")
        }
        return result
    }

    /// 头行方括号里的一项 → 名字：去掉「图N」标记、出场备注和引号，场景再去掉「日 / 夜 / 内 / 外」；是「无」之类的占位 → 空串
    static func cleanName(_ piece: String, isScene: Bool = false) -> String {
        var name = strippingAnnotations(strippingMaterialTokens(piece)).trimmingCharacters(in: quotes)
        // 名字前多出来的「@」（提示词框里打了 @ 没选就关掉，2026-10-26）：名字不会以 @ 开头，去掉，不然读成「@周承山」对不上卡
        while let first = name.first, first == "@" || first == "＠" { name = String(name.dropFirst()).trimmingCharacters(in: quotes) }
        if isScene { name = StoryboardInference.normalized(name) ?? name }
        return placeholders.contains(name.lowercased()) ? "" : name
    }

    private static func names(in group: String, isScene: Bool = false) -> [String] {
        var result: [String] = []
        for piece in strippingAnnotations(group).components(separatedBy: separators) {
            let name = cleanName(piece, isScene: isScene)
            guard !name.isEmpty, !result.contains(name) else { continue }
            result.append(name)
        }
        return result
    }

    /// 选中各集的所有分镜里出现过的名字，按第一次出现的先后排。`episodes`：(集号 1 起, 这一集各段的提示词，按段序)。
    /// `stages`：集号 → 各段的【阶段】（和 `prompts` 按段对齐；2026-10-14 名字与形态分离第 3 步）：角色名合成逻辑名「周承山（四十岁）」（见 `StageName`）
    static func collect(_ episodes: [(episode: Int, prompts: [String])], stages: [Int: [[String: String]]] = [:]) -> [Kind: [Entry]] {
        var result: [Kind: [Entry]] = [.scene: [], .role: [], .prop: []]
        var position: [Kind: [String: Int]] = [.scene: [:], .role: [:], .prop: [:]]
        for (episode, prompts) in episodes.sorted(by: { $0.episode < $1.episode }) {
            for (offset, prompt) in prompts.enumerated() {
                guard let head = head(of: prompt) else { continue }
                let shot = Shot(episode: episode, segment: offset + 1, prompt: prompt)
                let segmentStages = stages[episode].flatMap { $0.indices.contains(offset) ? $0[offset] : nil } ?? [:]
                let roles = head.roles.map { StageName.logical($0, stages: segmentStages) }
                for (kind, names) in [(Kind.scene, head.scenes), (Kind.role, roles), (Kind.prop, head.props)] {
                    for name in names {
                        if let index = position[kind]?[name] {
                            result[kind]?[index].shots.append(shot)
                        } else {
                            position[kind]?[name] = result[kind]?.count ?? 0
                            result[kind]?.append(Entry(name: name, shots: [shot]))
                        }
                    }
                }
            }
        }
        return result
    }

    // MARK: 证据

    /// 场景证据最多带几段分镜：从用到这个场景的所有分镜里均匀挑，首尾都有（场景在后面的集里有变化也看得到）
    static let sceneShotLimit = 4
    /// 一段分镜最多带多少字
    static let shotCharacterLimit = 3000
    /// 一批请求里场景证据的总字数上限 / 名字个数上限
    static let evidenceBudget = 40_000
    static let sceneNamesPerRequest = 12
    /// 角色、道具一个请求最多写几个名字
    static let namesPerRequest = 20
    /// 角色、道具的原文超过这个字数，就只带这一批名字出现过的那几集
    static let sourceBudget = 200_000

    static func sceneShots(of entry: Entry, limit: Int = sceneShotLimit) -> [Shot] {
        let all = entry.shots
        guard all.count > limit, limit >= 2 else { return limit < 2 ? Array(all.prefix(max(limit, 0))) : all }
        return (0..<limit).map { all[Int((Double($0) * Double(all.count - 1) / Double(limit - 1)).rounded())] }
    }

    /// 一段分镜发给 AI 的样子：头行去掉「图N」标记，统一后缀那一行很长、对场景没用，去掉；太长的截断
    static func evidenceText(of prompt: String) -> String {
        var lines = prompt.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("必须按照镜头描述和角色台词生成") }
        if let first = lines.firstIndex(where: { StoryboardInference.isHeader($0) }) { lines[first] = strippingMaterialTokens(lines[first]) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > shotCharacterLimit ? String(text.prefix(shotCharacterLimit)) + "……" : text
    }

    private static func evidenceBlock(for entry: Entry) -> String {
        let shots = sceneShots(of: entry)
        let header = "■ \(entry.name)（\(episodeList(entry.episodes))，共 \(entry.shots.count) 段分镜"
            + (shots.count < entry.shots.count ? "，下面是其中均匀挑出的 \(shots.count) 段）" : "）")
        let body = shots.map { "〔第\($0.episode)集 第\($0.segment)段〕\n\(evidenceText(of: $0.prompt))" }
        return ([header] + body).joined(separator: "\n")
    }

    // MARK: 分批

    /// 场景名里「·」前面的部分 = 地点（「蕴古斋·前柜」→「蕴古斋」）；名字里没有「·」的是独立场景，没有地点
    static func location(of name: String) -> String? {
        guard let dot = name.firstIndex(of: "·") else { return nil }
        let place = name[..<dot].trimmingCharacters(in: .whitespaces)
        return place.isEmpty ? nil : place
    }

    /// 场景：每批的证据字数不超过预算、名字不超过上限（至少一个）。
    /// **同一个地点的区域放在同一批**（2026-10-11）：「地点总述」「基准区域」要求同一地点的各区域外观统一，
    /// 一批一个请求、几批同时跑，分到不同批的话后一批看不到前一批写的总述。地点按第一次出现的先后排，没有「·」的各自成一组。
    /// 一个地点的区域多到一批放不下，只能拆开（尽量少拆）
    static func sceneBatches(_ entries: [Entry]) -> [[Entry]] {
        var groups: [[Entry]] = []
        var groupOf: [String: Int] = [:]
        for entry in entries {
            if let place = location(of: entry.name) {
                if let index = groupOf[place] { groups[index].append(entry); continue }
                groupOf[place] = groups.count
            }
            groups.append([entry])
        }
        var batches: [[Entry]] = [], current: [Entry] = [], used = 0
        func flush() { if !current.isEmpty { batches.append(current); current = []; used = 0 } }
        func fits(count: Int, size: Int) -> Bool { current.count + count <= sceneNamesPerRequest && used + size <= evidenceBudget }
        for group in groups {
            let sizes = group.map { evidenceBlock(for: $0).count }
            let total = sizes.reduce(0, +)
            if fits(count: group.count, size: total) {
                current += group; used += total
                continue
            }
            flush()
            if group.count <= sceneNamesPerRequest, total <= evidenceBudget {
                current = group; used = total
                continue
            }
            // 一个地点自己就放不下一批：逐个装，装不下就换下一批
            for (entry, size) in zip(group, sizes) {
                if !fits(count: 1, size: size) { flush() }
                current.append(entry); used += size
            }
        }
        flush()
        return batches
    }

    /// 角色、道具：每批最多 `namesPerRequest` 个名字
    static func nameBatches(_ entries: [Entry]) -> [[Entry]] {
        stride(from: 0, to: entries.count, by: namesPerRequest).map { Array(entries[$0..<min($0 + namesPerRequest, entries.count)]) }
    }

    // MARK: 发给 AI 的消息

    /// 「第1、2、5集」；太多就只列前几个
    static func episodeList(_ numbers: [Int]) -> String {
        numbers.count <= 6 ? "第" + numbers.map(String.init).joined(separator: "、") + "集"
                           : "第" + numbers.prefix(6).map(String.init).joined(separator: "、") + "等 \(numbers.count) 集"
    }

    /// 一批请求的内容。
    /// - `existing`：前面各集已经有的卡（只带名字在这一批里的）；
    /// - `source`：角色 / 道具读的原文（每集前一行「第N集」），场景不用（场景读分镜）。
    static func message(kind: Kind, entries: [Entry], existing: [Existing], source: String) -> String {
        let listed = Set(entries.map(\.name))
        // 场景：同一个地点的其他区域（前面各集已经提取过的，名字不在这一批里）也带上——「地点总述」「基准区域」要看得到它们
        let places: Set<String> = kind == .scene ? Set(entries.compactMap { location(of: $0.name) }) : []
        let relevant = existing.filter { card in
            listed.contains(card.base) || (location(of: card.base).map(places.contains) ?? false)
        }
        let known = Set(relevant.map(\.base))
        let list = entries.enumerated().map { index, entry -> String in
            // 逻辑名「周承山（四十岁）」写成「周承山（阶段：四十岁；…）」：名称只写括号外的名字，阶段另起一行
            let (name, stage) = StageName.split(entry.name)
            var notes = (stage.map { ["阶段：\($0)"] } ?? []) + [episodeList(entry.episodes) + "出场"]
            if known.contains(entry.name) { notes.append("已有") }
            return "\(index + 1). \(stage == nil ? entry.name : name)（\(notes.joined(separator: "；"))）"
        }.joined(separator: "\n")
        var parts = ["""
        【要提取的\(kind.rawValue)——名称已经定好，来自分镜头行 [场景][角色][道具]】
        只为下面这些名字写，名字一字不改；不要新增、不要合并、不要漏掉：
        \(list)
        """]
        let evidence = kind == .scene ? "分镜" : "原文"
        parts.append(kind == .scene
            ? "\(kind.rawValue)的描述从下面各场景的分镜里找：只写场景本身（空间结构、陈设、固定设施、材质、光线和时间），分镜里的人物、动作、台词、运镜都不要写；镜头里反复出现的陈设要写进描述。输出格式和其余规则仍按你的提示词。"
            : "\(kind.rawValue)的描述从下面的原文里找，原文没写的按你的提示词规则补全。输出格式和其余规则仍按你的提示词。")
        parts.append("名称只写名单里的名字，不加集数、不加阶段；每一块在名称下面单独写一行「起始集：N」（这一版第一次用到的集号）。名单里括号中写了「阶段：X」的，在名称下面再单独写一行「阶段：X」（照抄），按这个年龄阶段写外貌，固定特征和同一个人的主时间线形象保持一致；同一个名字的主时间线和各个阶段各写一块。如果名单里某个名字是同一个人 / 地方 / 物品在另一个时期或状态下的形态、却换了名字（例如「周承山十岁时期」是「周承山」的另一个时期），就在它那一块里单独写一行「参考：周承山」（写名单里或前面各集已有的那个基础名字），软件据此出图时拿基础版的图当参考图；同一个名字换装 / 变化、或写了「阶段」行的不用写这一行。这几行软件会读走，不会进入出图提示词。")
        if !relevant.isEmpty {
            parts.append("""
            【项目里已经提取过的\(kind.rawValue)（供对账和保持一致）】
            \(relevant.map(\.line).joined(separator: "\n"))
            名单里标「已有」的：本次\(evidence)里没有变化的，不要输出完整块，只单独写一行「沿用：<名字>」（照抄名单里的名字，不加集数、不加阶段）；只有明确写了它们发生变化，才按规则输出新的一条（变化版），起始集写发生变化的那一集。这一条优先于提示词里「依次列出每个名字」的要求。
            """)
        }
        parts.append(kind == .scene
            ? "【各场景用到它的分镜（场景描述从这里找）】\n" + entries.map(evidenceBlock(for:)).joined(separator: "\n\n")
            : "【原文（描述从这里找）】\n\(source)")
        return parts.joined(separator: "\n\n")
    }

    /// 角色、道具读的原文：选中各集的原文接起来，每集前一行「第N集」。
    /// 总字数超过 `sourceBudget` 就只带这一批名字出现过的那几集，免得撑爆上下文。
    static func source(episodes: [(episode: Int, text: String)], for entries: [Entry]) -> String {
        let all = episodes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func join(_ items: [(episode: Int, text: String)]) -> String {
            items.map { "第\($0.episode)集\n\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "\n\n")
        }
        let whole = join(all)
        guard whole.count > sourceBudget else { return whole }
        let wanted = Set(entries.flatMap(\.episodes))
        return join(all.filter { wanted.contains($0.episode) })
    }

    // MARK: 核对结果

    /// 提取回来的卡片和名单对一下：卡片名（去掉「第N集的」前缀）不在名单里的，和名单里没人写的（本来就有卡的不算、
    /// 「沿用」行交代过的不算）。返回给人看的提醒；都对得上就是空数组。名字对不上，匹配素材就挂不上图——所以要提醒，但卡片照常建。
    static func reconcile(kind: Kind, entries: [Entry], existing: Set<String>, parsed: [ImagePromptParser.Parsed], reused: [String] = []) -> [String] {
        let listed = Set(entries.map(\.name))
        // 卡片按逻辑名比（「周承山」+ 阶段「四十岁」=「周承山（四十岁）」，和名单同一个口径）
        let produced = parsed.map { StageName.compose(AssetVersionName.baseName($0.name), stage: $0.stage) }
        var notes: [String] = []
        let unexpected = produced.filter { !listed.contains($0) }
        if !unexpected.isEmpty {
            notes.append("\(kind.rawValue)提取：有 \(unexpected.count) 张卡的名字不在分镜头行的名单里（\(preview(unexpected))），匹配素材时挂不上图，需要改成头行里的名字")
        }
        let reusedLogical = Set(reused.map { StageName.compose(StageName.split($0).name, stage: StageName.split($0).stage) })
        let reusedBases = Set(reused.map { StageName.split($0).name })
        let missing = entries.map(\.name).filter {
            !produced.contains($0) && !existing.contains($0)
                && !reusedLogical.contains($0) && !reusedBases.contains(StageName.split($0).name)
        }
        if !missing.isEmpty {
            notes.append("\(kind.rawValue)提取：名单里有 \(missing.count) 个名字没有提取出来（\(preview(missing))）")
        }
        return notes
    }

    private static func preview(_ names: [String]) -> String {
        names.prefix(5).joined(separator: "、") + (names.count > 5 ? "等" : "")
    }
}
