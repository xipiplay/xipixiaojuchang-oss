import Foundation

// MARK: - 外部命令（`AgentBridge/commands/<id>.json`）
//
// 命令只负责「发起」：软件立刻回一份受理结果（`results/<id>.json`），真正的进度和失败原因看 `status.json`。
// 做的事和界面上点按钮完全一样（同一批 `PipelineFlow` 入口），所以软件里能看到同样的进度、同样的失败提示。
//
//   {"cmd":"ping"}
//   {"cmd":"import-script","file":"/绝对路径/剧本.txt","name":"可选，默认用文件名","split":true}   建新项目 + 存剧本 +（默认）AI 分集
//   {"cmd":"split","project":"<项目id>","episodes":[1,2,3]}                   批量分割；episodes 省略或 "all" = 全部集
//   {"cmd":"name","project":"<项目id>","episodes":[1,2,3]}                    分段命名：给每一段写【场景】【角色】【道具】【本段在场】
//                                                                              （这几集要先做过 split；一集一集按顺序跑，带着前面各集的名字）
//   {"cmd":"extract","project":"<项目id>","kinds":["角色","场景","道具"],"episodes":"all"}   提取素材；kinds 省略 = 三类都做
//   {"cmd":"infer","project":"<项目id>","episodes":[1,2],"approved":true}      推理分镜（这几集要先做过 split 和 name；
//                                                                              ⚠️ 必须用户审核过分割并明确同意，才能带 approved:true）
//   {"cmd":"stop","project":"<项目id>"}                                       停掉这个项目里所有在跑的 AI 任务
//
// 集号一律是 1 起。`id` 可省（用文件名）。

struct AgentCommand: Decodable, Equatable, Sendable {
    var id: String?
    var cmd: String
    var project: String?
    var file: String?
    var name: String?
    var split: Bool?
    var kinds: [String]?
    var episodes: EpisodeSelection?
    /// 用户已审核并明确同意（`infer` 必须带）。闸门本身在智能体的 skill 里，这里是兜底：没带就拒绝，免得漏掉审核
    var approved: Bool?
    /// 这一次手写的补充要求（`split` / `extract` / `infer` 可带，见 `RerunNote`）：用户跟智能体说「第 3 集把第 2、3 段合并再重分」，
    /// 智能体把这句话原样放在这里；只对这一次的请求生效
    var note: String?
    /// `extract` 可带：只提取这几个名字（分镜头行里的名字）。不带 = 选中各集里这一类的全部名字。
    /// 用户说「只重提周承山」「补一个漏掉的道具」时用，别把整类都重提一遍（已有卡的再提会多出一张「名字 2」）
    var names: [String]?
}

enum EpisodeSelection: Decodable, Equatable, Sendable {
    case all
    case numbers([Int])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let word = try? container.decode(String.self) {
            guard word == "all" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "episodes 只能是 \"all\"、集号或集号数组")
            }
            self = .all
        } else if let number = try? container.decode(Int.self) {
            self = .numbers([number])
        } else {
            self = .numbers(try container.decode([Int].self))
        }
    }
}

struct AgentCommandResult: Codable, Equatable, Sendable {
    var id: String
    var ok: Bool
    var message: String
    /// 命令涉及的项目 ID（`import-script` 在这里返回新建项目的 ID）
    var project: String?
    var finishedAt: Date
}

@MainActor
enum AgentCommandRunner {
    struct Outcome: Equatable {
        var ok: Bool
        var message: String
        var project: String?
    }

    private struct Rejection: Error { var message: String }

    static func run(_ command: AgentCommand, app: AppModel, chat: SimplePipeline.Chat?) -> Outcome {
        do {
            switch command.cmd {
            case "ping":
                return Outcome(ok: true, message: "在线", project: nil)
            case "import-script":
                return try importScript(command, app: app, chat: chat)
            case "split":
                let (key, archive) = try resolve(command, app: app)
                let indices = try episodeIndices(command.episodes, in: archive)
                try requireIdle(key, app: app)
                app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: indices, note: command.note ?? "", chat: chat)
                return Outcome(ok: true, message: "已开始批量分割：\(describe(indices, of: archive.episodes.count))", project: key)
            case "name":
                let (key, archive) = try resolve(command, app: app)
                let indices = try episodeIndices(command.episodes, in: archive)
                let missing = indices.filter { (archive.episodes[$0].splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard missing.isEmpty else {
                    throw Rejection(message: "\(describe(missing, of: archive.episodes.count))还没有时长分割，先发 split")
                }
                try requireIdle(key, app: app)
                app.pipelineFlow.batchName(app: app, project: key, episodeIndices: indices, note: command.note ?? "", chat: chat)
                return Outcome(ok: true, message: "已开始分段命名：\(describe(indices, of: archive.episodes.count))（一集一集按顺序跑）", project: key)
            case "extract":
                return try extract(command, app: app, chat: chat)
            case "infer":
                let (key, archive) = try resolve(command, app: app)
                guard command.approved == true else {
                    throw Rejection(message: "推理分镜要先让用户审核时长分割并明确同意；用户同意之后，在命令里加 \"approved\":true 再发")
                }
                let indices = try episodeIndices(command.episodes, in: archive)
                let missing = indices.filter { (archive.episodes[$0].splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard missing.isEmpty else {
                    throw Rejection(message: "\(describe(missing, of: archive.episodes.count))还没有时长分割，先发 split")
                }
                let unnamed = indices.filter { !SplitSegments.isNamed(archive.episodes[$0].splitText ?? "") }
                guard unnamed.isEmpty else {
                    throw Rejection(message: "\(describe(unnamed, of: archive.episodes.count))的各段还没有命名（场景 / 角色 / 道具），先发 name")
                }
                try requireIdle(key, app: app)
                app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: indices, note: command.note ?? "", chat: chat)
                return Outcome(ok: true, message: "已开始推理分镜：\(describe(indices, of: archive.episodes.count))（一集一集按顺序跑）", project: key)
            case "stop":
                guard let key = command.project, app.projectMetas[key] != nil else {
                    throw Rejection(message: "项目不存在（project 填 status.json 里的 id）")
                }
                app.pipelineFlow.cancelAll(project: key)
                return Outcome(ok: true, message: "已停止这个项目里所有在跑的 AI 任务（已完成的结果保留）", project: key)
            default:
                throw Rejection(message: "不认识的命令：\(command.cmd)（可用：ping / import-script / split / name / extract / infer / stop）")
            }
        } catch let rejection as Rejection {
            return Outcome(ok: false, message: rejection.message, project: command.project)
        } catch {
            return Outcome(ok: false, message: error.localizedDescription, project: command.project)
        }
    }

    // MARK: 各命令

    private static func importScript(_ command: AgentCommand, app: AppModel, chat: SimplePipeline.Chat?) throws -> Outcome {
        guard let path = command.file, !path.isEmpty else { throw Rejection(message: "缺少 file（剧本 TXT 的绝对路径）") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard url.pathExtension.lowercased() == "txt" else { throw Rejection(message: "只支持 TXT 剧本：\(url.lastPathComponent)") }
        guard let text = EpisodeSplitter.loadText(url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Rejection(message: "读不出剧本（文件不存在、没有权限，或是空文件）：\(url.path)")
        }
        let name = (command.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        app.startNewProject(named: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
        guard let key = app.currentProjectKey else { throw Rejection(message: "项目没有建出来") }
        app.savePipelineArchive(ProjectPipelineArchive(projectId: UUID(uuidString: key) ?? UUID(), wholeScript: text,
                                                       loadedFileName: url.lastPathComponent), for: key)
        guard command.split != false else {
            return Outcome(ok: true, message: "已导入「\(app.projectName(for: key))」（\(text.count) 字），没有自动分集", project: key)
        }
        app.pipelineFlow.splitScript(app: app, project: key, chat: chat)
        let how = EpisodeSplitter.split(text).isEmpty ? "正在 AI 分集" : "正在按「第 N 集」标题分集（本地处理，很快）"
        return Outcome(ok: true, message: "已导入「\(app.projectName(for: key))」（\(text.count) 字），\(how)（完成后 status.json 里会出现各集）", project: key)
    }

    private static func extract(_ command: AgentCommand, app: AppModel, chat: SimplePipeline.Chat?) throws -> Outcome {
        let (key, archive) = try resolve(command, app: app)
        let kinds: [PipelineFlow.ExtractionKind]
        if let names = command.kinds {
            kinds = try names.map { name in
                guard let kind = PipelineFlow.ExtractionKind(rawValue: name) else {
                    throw Rejection(message: "不认识的素材类型：\(name)（可用：角色 / 场景 / 道具）")
                }
                return kind
            }
        } else {
            kinds = PipelineFlow.ExtractionKind.allCases
        }
        guard !kinds.isEmpty else { throw Rejection(message: "kinds 是空的") }
        // 项目没分集时提取整篇剧本，集号忽略
        let indices = archive.episodes.isEmpty ? [] : try episodeIndices(command.episodes, in: archive)
        // 提取的名字取自分镜头行（先推理分镜、后提取）：没推理分镜的集先发 infer；没分集的项目读整篇剧本
        let missing = PipelineFlow.episodesMissingStoryboard(app: app, project: key, archive: archive, episodeIndices: indices)
        guard missing.isEmpty else {
            throw Rejection(message: "\(describe(missing, of: archive.episodes.count))还没有推理分镜，先发 infer（提取的名字取自分镜头行，角色 / 道具再去原文里找描述，场景去分镜里找）")
        }
        if archive.episodes.isEmpty, archive.wholeScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Rejection(message: "没有可提取的文本")
        }
        if let running = app.pipelineFlow.batches[key], !running.finished, running.kind != .extract {
            throw Rejection(message: "这个项目上一轮「\(running.title)」还没跑完（\(running.completed)/\(running.total)），等它结束或先 stop")
        }
        if let busy = kinds.first(where: { app.pipelineFlow.active(project: key, slot: "extract-\($0.rawValue)") }) {
            throw Rejection(message: "「提取\(busy.rawValue)」还在跑")
        }
        let wanted = command.names.map { Set($0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
        if let wanted, wanted.isEmpty { throw Rejection(message: "names 是空的（不想限定名字就别带这个字段）") }
        for kind in kinds {
            app.pipelineFlow.batchExtract(app: app, project: key, kind: kind, episodeIndices: indices, note: command.note ?? "", names: wanted, chat: chat)
        }
        let scope = archive.episodes.isEmpty ? "整篇剧本" : describe(indices, of: archive.episodes.count)
        let only = wanted.map { "（只提取：\($0.sorted().joined(separator: "、"))）" } ?? ""
        return Outcome(ok: true, message: "已开始提取素材：\(kinds.map(\.rawValue).joined(separator: "、"))\(only)，范围 \(scope)", project: key)
    }

    // MARK: 工具

    private static func resolve(_ command: AgentCommand, app: AppModel) throws -> (String, ProjectPipelineArchive) {
        guard let key = command.project, !key.isEmpty else { throw Rejection(message: "缺少 project（status.json 里的项目 id）") }
        guard let archive = app.pipelineArchive(for: key) else { throw Rejection(message: "项目不存在，或还没导入剧本：\(key)") }
        return (key, archive)
    }

    /// 0 起的集序号
    private static func episodeIndices(_ selection: EpisodeSelection?, in archive: ProjectPipelineArchive) throws -> [Int] {
        guard !archive.episodes.isEmpty else { throw Rejection(message: "这个项目还没分集（AI 分集完成后才有各集）") }
        switch selection ?? .all {
        case .all:
            return Array(archive.episodes.indices)
        case .numbers(let numbers):
            guard !numbers.isEmpty else { throw Rejection(message: "episodes 是空的") }
            if let bad = numbers.first(where: { !(1...archive.episodes.count).contains($0) }) {
                throw Rejection(message: "第 \(bad) 集不存在（共 \(archive.episodes.count) 集，集号从 1 起）")
            }
            return Array(Set(numbers.map { $0 - 1 })).sorted()
        }
    }

    private static func requireIdle(_ key: String, app: AppModel) throws {
        if let running = app.pipelineFlow.batches[key], !running.finished {
            throw Rejection(message: "这个项目上一轮「\(running.title)」还没跑完（\(running.completed)/\(running.total)），等它结束或先 stop")
        }
    }

    private static func describe(_ indices: [Int], of total: Int) -> String {
        indices.count == total ? "全部 \(total) 集" : indices.count <= 12
            ? "第 " + indices.map { String($0 + 1) }.joined(separator: "、") + " 集（共 \(total) 集）"
            : "\(indices.count) 集（共 \(total) 集）"
    }
}
