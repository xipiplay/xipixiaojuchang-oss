import Foundation
import CryptoKit
import SwiftUI

// MARK: - 基础枚举与状态

enum StepState: String, Codable, Sendable, CaseIterable {
    case todo, reviewing, approved

    var label: String {
        switch self {
        case .todo: "未开始"
        case .reviewing: "待审核"
        case .approved: "已通过"
        }
    }

    var color: Color {
        switch self {
        case .todo: .secondary.opacity(0.6)
        case .reviewing: Theme.warning
        case .approved: Theme.success
        }
    }
}

// MARK: - 集模型

struct Episode: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var title: String
    var text: String
    /// 「批量分割」的结果（2026-10-07）：用分割（时长）提示词整理出来的这一集文本，AI 返回什么就存什么。
    /// 和原文 `text` 各存一份，**不覆盖原文**——漏改了台词随时可以切回原文对照。nil = 还没分割过。
    var splitText: String? = nil
    /// 「推理分镜」给这一集建出来的生视频卡，按段的顺序（2026-10-07）。重推这一集时按位置覆盖它们的提示词；
    /// 下一集同场景衔接站位时，读的是这里**最后一张卡**现在的提示词（用户改过的也算）。nil = 还没推理过。
    var shotIDs: [UUID]? = nil
    /// 推理分镜时这一集分割的「段落结构」（段数 + 每段的时间标号，见 `splitSignature`）。
    /// 分镜卡和段是**按位置**配对的（第 N 段 ↔ `shotIDs[N-1]`）：之后重新分割 / 手改分割让段落结构变了，旧卡就和段对不上——
    /// 这时 `pairedShotIDs` 交出空的，工作台把这一集当成「分割改过，待重新推理分镜」，不拿旧卡硬配（2026-10-12 逻辑审查）。
    /// nil = 老数据（没记过）：照旧按位置配
    var storyboardSplitSignature: String? = nil

    /// 段落结构的指纹：只看段数和时间标号，改段里的字（剧情 / 名字）不算变
    static func splitSignature(_ splitText: String?) -> String {
        let segments = SplitSegments.parse(splitText ?? "")
        return "\(segments.count)|" + segments.map { $0.timeRange ?? "?" }.joined(separator: "|")
    }

    /// 推理过分镜、但之后分割的段落结构变了：旧的分镜卡和段对不上
    var storyboardIsStale: Bool {
        guard let shotIDs, !shotIDs.isEmpty, let signature = storyboardSplitSignature else { return false }
        return signature != Self.splitSignature(splitText)
    }

    /// 按位置和段配对用的分镜卡：对不上（`storyboardIsStale`）时是空的
    var pairedShotIDs: [UUID] { storyboardIsStale ? [] : (shotIDs ?? []) }
}

// MARK: - 词典与素材模型

struct ReferenceAsset: Codable, Equatable, Hashable, Sendable {
    var id = UUID()
    var ownerEntryId: UUID
    var path: String
    var revision: String

    static func fileRevision(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var isAvailable: Bool { Self.fileRevision(path) == revision }
}

struct SceneLayoutData: Codable, Hashable, Sendable {
    var text = ""
    var relativePosition = ""
    var reviewed = false
    var source = "人工填写"
    var imagePath: String?
    var imageRevision: String?
    var rawReply = ""
    var uncertainties = ""
    var lastError = ""
}

struct DictEntry: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var kind: String          // 角色 / 场景 / 道具
    var name: String          // 规范名（变体带「·状态」后缀）
    var desc: String          // 可变部分（角色=服装；场景/道具=状态；清单阶段为空）
    var identity: String = "" // 固定骨相 / 结构，含风格要求
    var fromEp: Int           // 起始集（1 起）
    var toEp: Int?            // 结束集；nil = 至今
    var basedOn: String?      // 变体/子场景：锚定的基图名字（生图参考图来源）
    var relation: String = "" // "变体"（时间状态变化）/ "子场景"（同一地点的子区域/视角）
    var evidence: String?     // 变体：原文变化点

    var stage = ""            // 角色年龄、发色、肤质、体态；场景/道具留空
    var stageChanges: [String] = []
    var fromOrder = 0
    var toOrder: Int?
    var identityVersion = 0   // 0 = 旧两层描述，1 = 已拆为三层

    var submitNameOverride = ""
    var referenceImage: ReferenceAsset?
    var sceneLayout: SceneLayoutData?

    var intervalText: String {
        if fromOrder > 0 {
            if let toEp { return "第 \(fromEp) 集·序 \(fromOrder) — 第 \(toEp) 集" + (toOrder.map { "·序 \($0)" } ?? "末") }
            return "第 \(fromEp) 集·序 \(fromOrder) 起"
        }
        if let toEp {
            return fromEp == toEp ? "第 \(fromEp) 集" : "第 \(fromEp)-\(toEp) 集"
        }
        return "第 \(fromEp) 集起"
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, desc, identity, fromEp, toEp, basedOn, relation, evidence, stage, stageChanges, identityVersion, fromOrder, toOrder, submitNameOverride, referenceImage, sceneLayout
    }

    init(
        id: UUID = UUID(),
        kind: String = "角色",
        name: String = "",
        desc: String = "",
        identity: String = "",
        fromEp: Int = 1,
        toEp: Int? = nil,
        basedOn: String? = nil,
        relation: String = "",
        evidence: String? = nil,
        stage: String = "",
        stageChanges: [String] = [],
        fromOrder: Int = 0,
        toOrder: Int? = nil,
        identityVersion: Int = 0,
        submitNameOverride: String = "",
        referenceImage: ReferenceAsset? = nil,
        sceneLayout: SceneLayoutData? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.desc = desc
        self.identity = identity
        self.fromEp = fromEp
        self.toEp = toEp
        self.basedOn = basedOn
        self.relation = relation
        self.evidence = evidence
        self.stage = stage
        self.stageChanges = stageChanges
        self.fromOrder = fromOrder
        self.toOrder = toOrder
        self.identityVersion = identityVersion
        self.submitNameOverride = submitNameOverride
        self.referenceImage = referenceImage
        self.sceneLayout = sceneLayout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "角色"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? ""
        fromEp = try c.decodeIfPresent(Int.self, forKey: .fromEp) ?? 1
        toEp = try c.decodeIfPresent(Int.self, forKey: .toEp)
        basedOn = try c.decodeIfPresent(String.self, forKey: .basedOn)
        relation = try c.decodeIfPresent(String.self, forKey: .relation) ?? ""
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence)
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        stageChanges = try c.decodeIfPresent([String].self, forKey: .stageChanges) ?? []
        identityVersion = try c.decodeIfPresent(Int.self, forKey: .identityVersion) ?? 0
        fromOrder = try c.decodeIfPresent(Int.self, forKey: .fromOrder) ?? 0
        toOrder = try c.decodeIfPresent(Int.self, forKey: .toOrder)
        submitNameOverride = try c.decodeIfPresent(String.self, forKey: .submitNameOverride) ?? ""
        referenceImage = try c.decodeIfPresent(ReferenceAsset.self, forKey: .referenceImage)
        sceneLayout = try c.decodeIfPresent(SceneLayoutData.self, forKey: .sceneLayout)
    }
}

// MARK: - 描述更新与校验模型

struct DescUpdate: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var kind: String
    var name: String          // 沿用/变体 = 现有条目名；新增 = 新名字
    var action: String        // 沿用 / 新增 / 变体
    var variantName = ""      // 变体：新名字（名字·状态）
    var evidence = ""         // 变体：原文依据
    var identity = ""         // 稳定身份（新增必填；变体=逐字复制基图）
    var desc = ""             // 可变部分（角色=服装；场景/道具=状态）

    var stage = ""
    var stageChanges: [String] = []
    var identityVersion = 0
    var order = 0

    var displayName: String { (action == "变体" || action == "子场景") && !variantName.isEmpty ? variantName : name }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, action, variantName, evidence, identity, desc, stage, stageChanges, identityVersion, order
    }

    init(
        id: UUID = UUID(),
        kind: String = "角色",
        name: String = "",
        action: String = "沿用",
        variantName: String = "",
        evidence: String = "",
        identity: String = "",
        desc: String = "",
        stage: String = "",
        stageChanges: [String] = [],
        identityVersion: Int = 0,
        order: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.action = action
        self.variantName = variantName
        self.evidence = evidence
        self.identity = identity
        self.desc = desc
        self.stage = stage
        self.stageChanges = stageChanges
        self.identityVersion = identityVersion
        self.order = order
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "角色"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? "沿用"
        variantName = try c.decodeIfPresent(String.self, forKey: .variantName) ?? ""
        evidence = try c.decodeIfPresent(String.self, forKey: .evidence) ?? ""
        identity = try c.decodeIfPresent(String.self, forKey: .identity) ?? ""
        desc = try c.decodeIfPresent(String.self, forKey: .desc) ?? ""
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? ""
        stageChanges = try c.decodeIfPresent([String].self, forKey: .stageChanges) ?? []
        identityVersion = try c.decodeIfPresent(Int.self, forKey: .identityVersion) ?? 0
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    }
}

struct MissingName: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var kind: String
    var context: String
    var id: String { kind + "|" + name }
}

// MARK: - 段落绑定与跨集承接

struct SegmentBinding: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var entryId: UUID?
    var internalName: String
    var kind: String
    var submitNameOverride = ""
    var scope = "全段"
    var evidence = ""
    var usage = "出镜"
    var approved = false
    var lockedEntryKey = ""
}

struct BoundSegment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var bindings: [SegmentBinding] = []
    var openingSceneId: UUID?
    var closingSceneId: UUID?
    var reviewed = false
    var startSecond: Int?
    var endSecond: Int?
}

struct EndState: Codable, Equatable, Sendable {
    var episode: Int
    var sceneEntryId: UUID? = nil
    var sceneName: String
    var positions: String
    var axis: String
    var lightingTime: String
    var props: String

    var isComplete: Bool {
        episode > 0 && [sceneName, positions, axis, lightingTime, props].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var summary: String {
        "来源：第 \(episode) 集；场景：\(sceneName)\n站位/朝向：\(positions)\n轴线：\(axis)\n光线时间：\(lightingTime)\n关键道具：\(props)"
    }
}

// MARK: - 单集工作区状态

struct EpWork: Equatable, Codable, Sendable {
    var descDraft: [DescUpdate] = []
    var descRaw = ""          // 解析失败时的原始回复
    var segmentsRaw = ""
    var shots: [String] = []
    var checked: [String] = [] // 名字校验后的分镜（标记已剥离）
    var missing: [MissingName] = [] // 校验发现的词典缺名字（待处理）
    var boundSegments: [BoundSegment] = []
    var shotUsedEntries: [[String]] = []
    var revision = 0
    var shotsInputKey = ""
    var checkedInputKey = ""
    var endState: EndState?
    var endStateShotKey = ""
    var continuityInputKey = ""
    var states: [StepState] = Array(repeating: .todo, count: 5)
}

extension EpWork {
    enum CodingKeys: String, CodingKey {
        case boundSegments, shotUsedEntries, descDraft, descRaw, segmentsRaw, shots, checked, missing, revision, shotsInputKey, checkedInputKey, states, endState, endStateShotKey, continuityInputKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boundSegments = try c.decodeIfPresent([BoundSegment].self, forKey: .boundSegments) ?? []
        shotUsedEntries = try c.decodeIfPresent([[String]].self, forKey: .shotUsedEntries) ?? []
        descDraft = try c.decodeIfPresent([DescUpdate].self, forKey: .descDraft) ?? []
        descRaw = try c.decodeIfPresent(String.self, forKey: .descRaw) ?? ""
        segmentsRaw = try c.decodeIfPresent(String.self, forKey: .segmentsRaw) ?? ""
        shots = try c.decodeIfPresent([String].self, forKey: .shots) ?? []
        checked = try c.decodeIfPresent([String].self, forKey: .checked) ?? []
        missing = try c.decodeIfPresent([MissingName].self, forKey: .missing) ?? []
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        shotsInputKey = try c.decodeIfPresent(String.self, forKey: .shotsInputKey) ?? ""
        checkedInputKey = try c.decodeIfPresent(String.self, forKey: .checkedInputKey) ?? ""
        states = try c.decodeIfPresent([StepState].self, forKey: .states) ?? Array(repeating: .todo, count: 5)
        endState = try c.decodeIfPresent(EndState.self, forKey: .endState)
        endStateShotKey = try c.decodeIfPresent(String.self, forKey: .endStateShotKey) ?? ""
        continuityInputKey = try c.decodeIfPresent(String.self, forKey: .continuityInputKey) ?? ""
    }
}

// MARK: - 项目流水线存档（与小样《项目存档.json》完全双向兼容）

struct ProjectPipelineArchive: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var projectId = UUID()
    var wholeScript: String = ""
    var loadedFileName: String = ""
    var episodes: [Episode] = []
    var dictionary: [DictEntry] = []
    var works: [EpWork] = []
    var rosterLocked: Bool = false
    var rosterBatchDone: Int = 0
    var rosterBatchTotal: Int = 0
    var epIndex: Int = 0
    var epStep: Int = 0
    var splitStage: Int = 0
    var dictOpen: Bool = false
    var segmentSeconds: Int = 30
    var contextCharacterLimit = 0
    var layoutCharacterLimit = 0
    var lastEndState: EndState? = nil
    /// 简化制作流程按集 ID 存储；旧五步数据保留供只读兼容。
    var simpleWorks: [SimpleEpisodeWork] = []
    /// 时代背景（2026-10-11）：提取场景 / 角色 / 道具时，每个请求都带上这一句，AI「逐字照抄」，所以分批、三类同时跑也是同一个说法。
    /// nil / 空 = 没填（提取提示词里写了「没有提供就自己定」，各请求的措辞会不一致）
    var eraBackground: String?

    /// 校验不通过时的原因（载入诊断用）；通过则为 nil。
    var validationIssue: String? {
        do {
            try validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func validate() throws {
        guard lastEndState == nil || (lastEndState!.isComplete && lastEndState!.episode <= works.count) else {
            throw PipelineArchiveError.invalid("结尾状态数据不完整")
        }
        guard schemaVersion == 1,
              contextCharacterLimit >= 0,
              layoutCharacterLimit >= 0,
              [15, 30].contains(segmentSeconds),
              (0...4).contains(epStep),
              (0...2).contains(splitStage),
              epIndex >= 0,
              epIndex < max(episodes.count, 1),
              works.count <= episodes.count,
              works.allSatisfy({ $0.states.count == 5 }),
              rosterBatchDone >= 0,
              rosterBatchTotal >= rosterBatchDone else {
            throw PipelineArchiveError.invalid("存档结构或字段取值不符合规范")
        }
    }

    enum CodingKeys: String, CodingKey {
        case projectId, schemaVersion, wholeScript, loadedFileName, episodes, dictionary, works
        case rosterLocked, rosterBatchDone, rosterBatchTotal, epIndex, epStep, splitStage, dictOpen
        case segmentSeconds, contextCharacterLimit, layoutCharacterLimit, lastEndState, simpleWorks, eraBackground
    }

    init(
        schemaVersion: Int = 1,
        projectId: UUID = UUID(),
        wholeScript: String = "",
        loadedFileName: String = "",
        episodes: [Episode] = [],
        dictionary: [DictEntry] = [],
        works: [EpWork] = [],
        rosterLocked: Bool = false,
        rosterBatchDone: Int = 0,
        rosterBatchTotal: Int = 0,
        epIndex: Int = 0,
        epStep: Int = 0,
        splitStage: Int = 0,
        dictOpen: Bool = false,
        segmentSeconds: Int = 30,
        contextCharacterLimit: Int = 0,
        layoutCharacterLimit: Int = 0,
        lastEndState: EndState? = nil,
        simpleWorks: [SimpleEpisodeWork] = [],
        eraBackground: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectId = projectId
        self.wholeScript = wholeScript
        self.loadedFileName = loadedFileName
        self.episodes = episodes
        self.dictionary = dictionary
        self.works = works
        self.rosterLocked = rosterLocked
        self.rosterBatchDone = rosterBatchDone
        self.rosterBatchTotal = rosterBatchTotal
        self.epIndex = epIndex
        self.epStep = epStep
        self.splitStage = splitStage
        self.dictOpen = dictOpen
        self.segmentSeconds = segmentSeconds
        self.contextCharacterLimit = contextCharacterLimit
        self.layoutCharacterLimit = layoutCharacterLimit
        self.lastEndState = lastEndState
        self.simpleWorks = simpleWorks
        self.eraBackground = eraBackground
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId) ?? UUID()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        wholeScript = try c.decodeIfPresent(String.self, forKey: .wholeScript) ?? ""
        loadedFileName = try c.decodeIfPresent(String.self, forKey: .loadedFileName) ?? ""
        episodes = try c.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
        dictionary = try c.decodeIfPresent([DictEntry].self, forKey: .dictionary) ?? []
        works = try c.decodeIfPresent([EpWork].self, forKey: .works) ?? []
        rosterLocked = try c.decodeIfPresent(Bool.self, forKey: .rosterLocked) ?? false
        rosterBatchDone = try c.decodeIfPresent(Int.self, forKey: .rosterBatchDone) ?? 0
        rosterBatchTotal = try c.decodeIfPresent(Int.self, forKey: .rosterBatchTotal) ?? 0
        epIndex = try c.decodeIfPresent(Int.self, forKey: .epIndex) ?? 0
        epStep = try c.decodeIfPresent(Int.self, forKey: .epStep) ?? 0
        splitStage = try c.decodeIfPresent(Int.self, forKey: .splitStage) ?? 0
        dictOpen = try c.decodeIfPresent(Bool.self, forKey: .dictOpen) ?? false
        segmentSeconds = try c.decodeIfPresent(Int.self, forKey: .segmentSeconds) ?? 30
        lastEndState = try c.decodeIfPresent(EndState.self, forKey: .lastEndState)
        simpleWorks = try c.decodeIfPresent([SimpleEpisodeWork].self, forKey: .simpleWorks) ?? []
        contextCharacterLimit = try c.decodeIfPresent(Int.self, forKey: .contextCharacterLimit) ?? 0
        layoutCharacterLimit = try c.decodeIfPresent(Int.self, forKey: .layoutCharacterLimit) ?? 0
        eraBackground = try c.decodeIfPresent(String.self, forKey: .eraBackground)
    }
}

typealias ProjectArchive = ProjectPipelineArchive

enum PipelineArchiveError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

// MARK: - 剧本加载与切分辅助器

enum EpisodeSplitter {
    /// 本地按「第N集 / 第N章」标记切分（两集以上触发本地切分）
    static func split(_ text: String) -> [Episode] {
        let pattern = "(?m)^[ \\t#【]*第\\s*[0-9０-９一二三四五六七八九十百零两]+\\s*[集章]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count >= 2 else { return [] }
        var episodes: [Episode] = []
        for (i, m) in matches.enumerated() {
            let start = m.range.location
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let lineRange = ns.lineRange(for: NSRange(location: start, length: 0))
            var title = ns.substring(with: NSRange(location: lineRange.location,
                                                   length: min(lineRange.length, 80)))
            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 30 { title = String(title.prefix(30)) }
            let body = ns.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            episodes.append(Episode(title: title.isEmpty ? "第 \(i + 1) 集" : title, text: body))
        }
        return episodes
    }

    /// 读取文本（兼容 UTF-8、GB18030 / GBK、UTF-16）
    static func loadText(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = try? String(contentsOf: url, encoding: gb) { return s }
        if let s = try? String(contentsOf: url, encoding: .utf16) { return s }
        return nil
    }
}

// MARK: - 文件导入结果类型

enum ScriptImportResult {
    case text(content: String, fileName: String)
    case archive(ProjectPipelineArchive, fileName: String)
}

enum ScriptFileImporter {
    /// 自动判断导入纯文本还是已有项目存档
    static func load(from url: URL) throws -> ScriptImportResult {
        let isJSON = url.pathExtension.lowercased() == "json"
        if isJSON, let data = try? Data(contentsOf: url) {
            if let archive = try? JSONDecoder().decode(ProjectPipelineArchive.self, from: data) {
                try archive.validate()
                return .archive(archive, fileName: url.lastPathComponent)
            }
        }

        if let text = EpisodeSplitter.loadText(url) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw PipelineArchiveError.invalid("选择的文件内容为空。")
            }
            return .text(content: text, fileName: url.lastPathComponent)
        }

        throw PipelineArchiveError.invalid("无法解析该文件格式或编码，请选择 UTF-8/GBK 格式的 txt 剧本。")
    }
}
