import Foundation
import Darwin

// MARK: - 命令行参数与运行配置

struct RunOptions: Sendable {
    var from: Int?
    var to: Int?
    var archive: URL?
    var report: URL
    var signal: URL
    var interactive = false

    static func parse(_ args: [String], cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> Self {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var result = Self(
            report: cwd.appendingPathComponent(".verification/run-报告-\(stamp)-\(UUID().uuidString.prefix(6)).json"),
            signal: cwd.appendingPathComponent(".verification/run-signal")
        )
        var i = 1
        func url(_ path: String) -> URL {
            let expanded = (path as NSString).expandingTildeInPath
            return expanded.hasPrefix("/")
                ? URL(fileURLWithPath: expanded).standardizedFileURL
                : cwd.appendingPathComponent(expanded).standardizedFileURL
        }
        while i < args.count {
            let flag = args[i]; i += 1
            if flag == "--run" { continue }
            if flag == "-h" || flag == "--help" {
                throw RunError.help
            }
            if flag == "--all" { continue }
            if flag == "--interactive" { result.interactive = true; continue }
            guard ["--episode", "--from", "--to", "--archive", "--report", "--signal"].contains(flag), i < args.count else {
                throw RunError.message("未知或缺值参数：\(flag)")
            }
            let value = args[i]; i += 1
            guard !value.hasPrefix("--") else { throw RunError.message("参数缺值：\(flag)") }
            switch flag {
            case "--episode":
                guard let n = Int(value), n >= 1 else { throw RunError.message("\(flag) 必须是正整数") }
                result.from = n
                result.to = n
            case "--from":
                guard let n = Int(value), n >= 1 else { throw RunError.message("\(flag) 必须是正整数") }
                result.from = n
            case "--to":
                guard let n = Int(value), n >= 1 else { throw RunError.message("\(flag) 必须是正整数") }
                result.to = n
            case "--archive": result.archive = url(value)
            case "--report": result.report = url(value)
            default: result.signal = url(value)
            }
        }
        if let from = result.from, let to = result.to, from > to {
            throw RunError.message("--from 不能大于 --to")
        }
        return result
    }

    func range(totalEpisodes: Int) throws -> ClosedRange<Int> {
        guard totalEpisodes > 0 else {
            throw RunError.message("存档没有分集，请先在界面导入剧本并分集")
        }
        let start = from ?? 1
        let end = to ?? totalEpisodes
        guard start <= end, end <= totalEpisodes else {
            throw RunError.message("集范围超出存档：共 \(totalEpisodes) 集，请求 \(start)...\(end)")
        }
        return start...end
    }
}

enum RunError: LocalizedError {
    case help
    case message(String)
    var errorDescription: String? {
        switch self {
        case .help: return nil
        case .message(let value): return value
        }
    }
}

// MARK: - 报告与事件模型

struct RunPending: Codable, Equatable, Sendable {
    var kind: String
    var episode: Int
    var segment: Int?
    var reason: String
    var suggestion: String
    var files: [String] = []
    var reviewable = false
}

struct RunEpisodeReport: Codable, Sendable {
    var index: Int
    var title: String
    var status = "停车" // "完成" | "停车" | "失败" | "运行中"
    var steps: [String: String] = [:]
    var pending: [RunPending] = []
}

struct RunReport: Codable, Sendable {
    var schemaVersion = 1
    var runAt = ISO8601DateFormatter().string(from: Date())
    var archive: String
    var range: [Int] = []
    var episodes: [RunEpisodeReport] = []
    var summary = Summary()
    var files: [String: String] = [:]
    var error: String?

    struct Summary: Codable, Sendable {
        var completed = 0
        var stopped = 0
        var failed = 0
        var pendingCount = 0
        var aiCalls = 0
    }

    mutating func summarize(aiCalls: Int) {
        summary = Summary(
            completed: episodes.filter { $0.status == "完成" }.count,
            stopped: episodes.filter { $0.status == "停车" }.count,
            failed: episodes.filter { $0.status == "失败" }.count,
            pendingCount: episodes.reduce(0) { $0 + $1.pending.count },
            aiCalls: aiCalls
        )
        if error != nil && summary.failed == 0 {
            summary.failed = 1
        }
    }
}

struct RunEvent: Codable, Sendable {
    var event: String
    var episode: Int?
    var step: String?
    var status: String?
    var summary: String?
    var reason: String?
    var report: String?
    var signal: String?
    var exitCode: Int?
}

// MARK: - 纯规则判断层

enum RunRules {
    static let stepNames = ["描述", "分段", "分镜", "校验", "产出"]

    static func pending(
        step: Int,
        episode: Int,
        text: String,
        work: EpWork,
        dictionary: [DictEntry],
        seconds: Int
    ) -> [RunPending] {
        var result: [RunPending] = []
        func add(_ kind: String, _ reason: String, _ suggestion: String, segment: Int? = nil, reviewable: Bool = false) {
            result.append(RunPending(
                kind: kind, episode: episode, segment: segment,
                reason: reason, suggestion: suggestion, reviewable: reviewable
            ))
        }

        if step == 0 {
            if work.descDraft.isEmpty {
                add("描述未解析", "本集没有可审核的描述条目", "修正 JSON 或重新生成描述")
            }
            let context = PipelineRules.reviewDictionary(work.descDraft, in: dictionary)
            for u in work.descDraft {
                if !["沿用", "新增", "变体", "子场景"].contains(u.action) || !["角色", "场景", "道具"].contains(u.kind) {
                    add("描述格式", "不支持的类型或动作：\(u.kind)/\(u.action)", "修正类型和动作")
                }
                // 自动化红线：遇到变体或子场景等非沿用操作，停下出待拍板清单
                if u.action != "沿用" {
                    add(u.action, "出现\(u.action)：\(u.displayName)", "对照原文审核版本、身份、服装与变化依据", reviewable: true)
                }
                if let issue = PipelineRules.pendingBaseMessage(u, in: context) {
                    add("悬挂缺基", issue, "补齐基条目的固定身份后重新审核")
                }
                if u.action == "沿用", !dictionary.contains(where: { $0.kind == u.kind && $0.name == u.name }) {
                    add("词典缺", "沿用条目不在词典：\(u.name)", "确认并补齐具体条目")
                }
                if u.action == "沿用", let existing = dictionary.first(where: { $0.kind == u.kind && $0.name == u.name }) {
                    if !u.identity.isEmpty && u.identity != existing.identity {
                        add("身份校验", "沿用却改变固定身份：" + u.name, "以词典为准修正，不能静默应用")
                    }
                    if (!u.stage.isEmpty && u.stage != existing.stage) || (!u.desc.isEmpty && u.desc != existing.desc) {
                        add("状态不一致", "沿用却改变时间状态/服装：" + u.name, "对照原文改成变体或恢复沿用的空字段")
                    }
                }
            }
            for issue in PipelineRules.descriptionIssues(work.descDraft, in: dictionary) {
                add("身份校验", issue, "以基图为准修正身份与时间状态")
            }
            for e in PipelineRules.possibleOmissions(text: text, updates: work.descDraft, dictionary: dictionary) {
                add("可能漏检", "原文出现但描述未处理：" + e.name, "在本集描述补入漏项，或人工核对是否只被提及", reviewable: true)
            }
            if work.descDraft.allSatisfy({ $0.action == "沿用" }),
               ["回忆", "闪回", "二十年前", "多年后"].contains(where: text.contains) {
                add("时间版本待审", "原文明示时间切换，全部沿用结果仍需核对历史版本", "确认具体时间版本，不能按本体默认选择", reviewable: true)
            }
        }

        if step == 1 {
            let segments = PipelineRules.splitSegments(work.segmentsRaw)
            if segments.isEmpty {
                add("分段为空", "段数必须至少1", "重新生成或编辑分段")
            }
            if work.boundSegments.count != segments.count {
                add("版本绑定", "分段与绑定记录数量不一致", "逐段补齐持久段与版本引用")
            }
            let dialogues = segments.flatMap(SubmissionRules.sourceDialogues)
            if dialogues != SubmissionRules.sourceDialogues(text) {
                add("台词改动", "分段台词内容或顺序与本集原文不一致", "恢复原文台词，不能用 ok 绕过")
            }
            for (i, s) in work.boundSegments.enumerated() {
                for issue in BindingRules.issues(s, dictionary: dictionary, requireApproval: false) {
                    add("版本绑定", issue, "对照原文改选、补依据或段内称呼", segment: i + 1)
                }
                for b in s.bindings where !s.reviewed {
                    if let e = BindingRules.entry(b, in: dictionary), e.basedOn != nil {
                        add(e.relation.isEmpty ? "变体" : e.relation, "待确认引用：" + e.name, "确认本段实际使用的具体版本与范围", segment: i + 1, reviewable: true)
                    }
                }
            }
        }

        if step >= 2 {
            for (i, segment) in work.boundSegments.enumerated() {
                for issue in BindingRules.issues(segment, dictionary: dictionary) {
                    add("版本绑定", issue, "重新审核段引用", segment: i + 1)
                }
            }
        }

        if step == 2 {
            let total = PipelineRules.splitSegments(work.segmentsRaw).count
            if !PipelineRules.complete(work.shots.count, of: total) {
                add("分镜未完成", "已生成 \(work.shots.count)/\(total) 段", "从缺失段续跑", segment: work.shots.count + 1)
            }
        }

        if step == 3 {
            if !PipelineRules.complete(work.checked.count, of: work.shots.count) {
                add("校验未完成", "已校验 \(work.checked.count)/\(work.shots.count) 段", "从缺失段续跑", segment: work.checked.count + 1)
            }
            for m in work.missing {
                add("词典缺", m.name + "：" + m.context, "在界面补素材或明确忽略")
            }
        }

        return result
    }
}

// MARK: - 自动化调度服务

enum RunAutomationService {

    /// 自动化执行单集流程（支持纯沿用自动推进、遇变体停车出报告）
    static func executeEpisode(
        episodeIndex: Int,
        episode: Episode,
        work: inout EpWork,
        dictionary: inout [DictEntry],
        seconds: Int,
        config: PipelineAISettings,
        report: inout RunEpisodeReport,
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) async throws -> Bool {
        let epNum = episodeIndex + 1

        for step in 0...4 {
            let stepLabel = RunRules.stepNames[step]
            if work.states[step] == .approved {
                report.steps[stepLabel] = "already_passed"
                continue
            }

            // 检查当前步是否有未解决问题（变体/子场景/格式不符等）
            let pending = RunRules.pending(
                step: step,
                episode: epNum,
                text: episode.text,
                work: work,
                dictionary: dictionary,
                seconds: seconds
            )

            if !pending.isEmpty {
                report.status = "停车"
                report.steps[stepLabel] = "stopped"
                report.pending = pending
                onEvent?(RunEvent(
                    event: "stop",
                    episode: epNum,
                    step: stepLabel,
                    status: "stopped",
                    reason: pending.map(\.reason).joined(separator: "；")
                ))
                return false
            }

            // 自动推进当前步骤
            report.steps[stepLabel] = "auto_passed"
            work.states[step] = .approved

            if step == 0 {
                // 正式应用沿用描述到词典
                PipelineRules.applyDescriptions(work.descDraft, episode: epNum, to: &dictionary)
            }
        }

        report.status = "完成"
        return true
    }

    /// 自动化全剧或指定集范围推进
    static func runPipeline(
        archive: inout ProjectPipelineArchive,
        options: RunOptions,
        config: PipelineAISettings,
        projectKey: String,
        existingShots: [ShotDraft] = [],
        existingLibrary: [LibraryItem] = [],
        onEvent: (@Sendable (RunEvent) -> Void)? = nil
    ) async throws -> (report: RunReport, newShots: [ShotDraft], newLibrary: [LibraryItem]) {
        let total = archive.episodes.count
        let range = try options.range(totalEpisodes: total)

        var report = RunReport(
            archive: options.archive?.path ?? "currentProject",
            range: [range.lowerBound, range.upperBound]
        )

        var shots = existingShots
        var library = existingLibrary

        for epNum in range {
            let epIdx = epNum - 1
            let ep = archive.episodes[epIdx]
            var epReport = RunEpisodeReport(index: epNum, title: ep.title, status: "运行中")

            var work = archive.works.indices.contains(epIdx) ? archive.works[epIdx] : EpWork()
            var dict = archive.dictionary

            let passed = try await executeEpisode(
                episodeIndex: epIdx,
                episode: ep,
                work: &work,
                dictionary: &dict,
                seconds: archive.segmentSeconds,
                config: config,
                report: &epReport,
                onEvent: onEvent
            )

            archive.works[epIdx] = work
            archive.dictionary = dict

            if passed {
                // 通过后零 AI 直建分镜卡
                let finalShots = work.checked.isEmpty ? work.shots : work.checked
                if !finalShots.isEmpty {
                    let publishRes = DirectPublishService.publishEpisodeShotsDirect(
                        projectKey: projectKey,
                        episodeIndex: epNum,
                        durationSeconds: archive.segmentSeconds,
                        finalShots: finalShots,
                        boundSegments: work.boundSegments,
                        dictionary: archive.dictionary,
                        existingShots: shots,
                        existingLibrary: library
                    )
                    shots = publishRes.allShots
                    library = publishRes.allLibrary
                }
            }

            report.episodes.append(epReport)

            // 若遇停车或失败，命令行自动化默认不强行向下越界
            if !passed {
                break
            }
        }

        report.summarize(aiCalls: 0)

        // 写入报告文件
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: options.report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reportData = try encoder.encode(report)
        try? reportData.write(to: options.report, options: .atomic)

        return (report, shots, library)
    }

    static func printUsage() {
        let usage = """
        嬉皮小剧场流水线自动化 (--run) 使用说明:
          --run                     启用流水线命令行自动化模式
          --episode <N>             指定执行单集（如 --episode 1）
          --from <N> --to <M>       指定执行集数范围（如 --from 1 --to 5）
          --all                     执行全剧所有集
          --archive <PATH>          指定输入项目存档路径（默认当前目录 scriptPipeline.json）
          --report <PATH>           指定输出 JSON 报告路径
          --signal <PATH>           指定进程间信号文件路径
          --interactive             遇到变体/子场景时开启交互式拍板（未指定时默认停车出清单）
          -h, --help                显示此帮助信息
        """
        fputs(usage + "\n", stderr)
    }

    /// 命令行主入口
    @MainActor
    static func runFromCommandLine() async {
        let args = ProcessInfo.processInfo.arguments
        let options: RunOptions
        do {
            options = try RunOptions.parse(args)
        } catch RunError.help {
            printUsage()
            exit(0)
        } catch {
            let msg = error.localizedDescription
            if !msg.isEmpty {
                fputs("错误：\(msg)\n\n", stderr)
            }
            printUsage()
            exit(1)
        }

        fputs("嬉皮小剧场流水线自动化 (--run) 已启动...\n", stderr)

        let config = PipelineAISettingsStore.load().config
        let archiveURL = options.archive ?? URL(fileURLWithPath: "scriptPipeline.json")

        guard let data = try? Data(contentsOf: archiveURL),
              var archive = try? JSONDecoder().decode(ProjectPipelineArchive.self, from: data) else {
            fputs("错误：未找到或无法解析项目存档：\(archiveURL.path)\n", stderr)
            exit(1)
        }

        do {
            let (report, _, _) = try await runPipeline(
                archive: &archive,
                options: options,
                config: config,
                projectKey: "commandline-project",
                onEvent: { event in
                    if let data = try? JSONEncoder().encode(event), let str = String(data: data, encoding: .utf8) {
                        print(str)
                    }
                }
            )

            fputs("自动化执行完毕。完成 \(report.summary.completed) 集，停车 \(report.summary.stopped) 集，失败 \(report.summary.failed) 集。\n", stderr)
            fputs("报告已保存至：\(options.report.path)\n", stderr)

            let exitCode: Int32 = (report.summary.failed > 0) ? 1 : (report.summary.stopped > 0 ? 2 : 0)
            exit(exitCode)
        } catch {
            fputs("运行异常：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
