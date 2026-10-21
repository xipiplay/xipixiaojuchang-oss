import SwiftUI

/// 工作台底部的**流水线胶囊**（2026-10-09 用户定；10-10 一度改成贴底整条的进度条，用户还是觉得胶囊好看，改回来，
/// 按钮保持进度条那套样式：图标 + 名字 + 完成数，下面一小条进度）：浮在卡片上面、居中，页面一直通到窗口底边。
/// 按顺序放整条流水线的每一步，跑着的发光；点开是「全部集 / 指定范围」的选择框（默认只做当前这一集）。
///
/// 分割 → 命名 → 分镜 → 场景 / 角色 / 道具。
/// 原来后面还有「出图 / 匹配 / 视频」三步，2026-10-15 用户定去掉（打开抽屉时胶囊太挤；中间加回来过一次又去掉）：
/// 工作台也不再拖选——匹配在二级页面右栏的「自动匹配」，生视频在二级页面 / 生视频页，出图去生图页。各集的「下一步」状态照旧显示这三步。

struct WorkbenchCapsule: View {
    @Environment(AppModel.self) private var app
    /// 当前选中的集（0 起；还没分集 = nil）
    let currentEpisode: Int?

    @State private var infoTitle = ""
    @State private var infoMessage = ""
    @State private var showInfo = false

    var body: some View {
        WorkbenchBoardReader { board in
            ToolbarRow(reportsFrame: false) {
                // 只剩六步以后宽松了（2026-10-15 用户：图标、文字、数字有些挤）：步与步之间、步里面都放宽一点
                HStack(spacing: 8) {
                    // 还没分集的项目只能做「场景 / 角色 / 道具」提取（读整篇剧本）和等分集
                    let hasBoard = !(board?.episodes.isEmpty ?? true)      // 没分集时也有状态（「其他分镜」要用），步骤照旧按有没有分集
                    step(.split, board, hasBoard)
                    step(.name, board, hasBoard)
                    step(.infer, board, hasBoard)
                    divider
                    step(.scene, board, hasBoard || noEpisodes)
                    step(.role, board, hasBoard || noEpisodes)
                    step(.prop, board, hasBoard || noEpisodes)
                }
            }
        }
        .alert(infoTitle, isPresented: $showInfo) {
            Button("好", role: .cancel) {}
        } message: {
            Text(infoMessage)
        }
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 4).opacity(0.5)
    }

    // MARK: 步骤

    enum Step: CaseIterable {
        case split, name, infer, scene, role, prop

        var title: String {
            switch self {
            case .split: "分割"
            case .name: "命名"
            case .infer: "分镜"
            case .scene: "场景"
            case .role: "角色"
            case .prop: "道具"
            }
        }
        var icon: String {
            switch self {
            case .split: "scissors"
            case .name: "tag"
            case .infer: "film.stack"
            case .scene: PipelineFlow.ExtractionKind.scene.icon
            case .role: PipelineFlow.ExtractionKind.role.icon
            case .prop: PipelineFlow.ExtractionKind.prop.icon
            }
        }
        var kind: PipelineFlow.ExtractionKind? {
            switch self {
            case .scene: .scene
            case .role: .role
            case .prop: .prop
            default: nil
            }
        }
    }

    private func progress(_ step: Step, _ board: WorkbenchStatus.Board?) -> WorkbenchStatus.Progress? {
        guard let totals = board?.totals else { return nil }
        switch step {
        case .split: return totals.split
        case .name: return totals.naming
        case .infer: return totals.infer
        case .scene, .role, .prop: return step.kind.flatMap { totals.names[$0] }
        }
    }

    private func running(_ step: Step, _ board: WorkbenchStatus.Board?) -> Bool {
        guard let key = app.currentProjectKey else { return false }
        let batch = app.pipelineFlow.batches[key]
        switch step {
        case .split: return batch.map { !$0.finished && $0.kind == .split } ?? false
        case .name: return batch.map { !$0.finished && $0.kind == .naming } ?? false
        case .infer: return batch.map { !$0.finished && $0.kind == .infer } ?? false
        case .scene, .role, .prop: return step.kind.map { app.pipelineFlow.active(project: key, slot: "extract-\($0.rawValue)") } ?? false
        }
    }

    @ViewBuilder
    private func step(_ step: Step, _ board: WorkbenchStatus.Board?, _ usable: Bool) -> some View {
        let blockedByOther = otherBatchRunning(step)
        WorkbenchStepButton(title: step.title, icon: step.icon, progress: progress(step, board),
                            running: running(step, board)) {
            panel(for: step, board: board)
        }
        .opacity(usable && !blockedByOther ? 1 : 0.45)
        .allowsHitTesting(usable && !blockedByOther)
        // 点不了的时候悬停说为什么（2026-10-12 逻辑审查：原来只是变灰）；这一层在 allowsHitTesting 外面，悬停得到
        .overlay {
            if let reason = blockedReason(step, usable: usable, blockedByOther: blockedByOther) {
                Color.clear.contentShape(Rectangle()).help(reason)
            }
        }
        .accessibilityIdentifier("workbench-step-\(step.title)")
    }

    /// 这一步现在点不了的原因（点得了 = nil）
    private func blockedReason(_ step: Step, usable: Bool, blockedByOther: Bool) -> String? {
        if !usable { return noEpisodes ? "先导入剧本、分好集" : "先导入剧本" }
        guard blockedByOther, let key = app.currentProjectKey else { return nil }
        if let kind = step.kind, app.pipelineFlow.active(project: key, slot: "extract-\(kind.rawValue)") {
            return "「\(kind.rawValue)」正在提取，做完才能再点"
        }
        let title = app.pipelineFlow.batches[key].map { $0.title } ?? "批量任务"
        return "正在跑「\(title)」（同一个项目同时只跑一个批量任务），做完才能点"
    }

    /// 和原来各页按钮的规则一样：分割 / 分镜在任何批量任务跑着时都不能点；提取在分割 / 分镜跑着、或这一类自己还在跑时不能点
    private func otherBatchRunning(_ step: Step) -> Bool {
        guard let key = app.currentProjectKey else { return false }
        let batch = app.pipelineFlow.batches[key]
        let batchRunning = batch.map { !$0.finished } ?? false
        switch step {
        case .split, .name, .infer: return batchRunning
        case .scene, .role, .prop:
            guard let kind = step.kind else { return false }
            return (batchRunning && batch?.kind != .extract) || app.pipelineFlow.active(project: key, slot: "extract-\(kind.rawValue)")
        }
    }

    // MARK: 选择框

    private var episodeCount: Int { app.currentPipelineArchive?.episodes.count ?? 0 }
    private var noEpisodes: Bool { episodeCount == 0 }

    private func close() { DropdownPanel.shared.dismiss() }

    private func inform(_ title: String, _ message: String) {
        infoTitle = title
        infoMessage = message
        showInfo = true
    }

    @ViewBuilder
    private func panel(for step: Step, board: WorkbenchStatus.Board?) -> some View {
        let key = app.currentProjectKey ?? ""
        switch step {
        case .split:
            BatchRangePanel(
                title: "批量分割",
                summary: { "将同时分割 \($0) 集" },
                // 说明文字都去掉了（2026-10-10 用户：占地方、弹出来还会撑高窗口）；只留会丢东西时才出现的一句提醒
                warning: { indices in
                    let episodes = app.currentPipelineArchive?.episodes ?? []
                    let done = indices.filter { episodes.indices.contains($0) && !(episodes[$0].splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    guard let first = done.first else { return nil }
                    var text = "第 \(first + 1) 集" + (done.count > 1 ? "等 \(done.count) 集" : "") + "已经有分割，会被整个替换（手改的也没了）。"
                    // 分镜卡和段按位置配对：段落变了旧卡就对不上（2026-10-12 逻辑审查）
                    let inferred = done.filter { !(episodes[$0].shotIDs ?? []).isEmpty }
                    if let one = inferred.first {
                        text += "第 \(one + 1) 集" + (inferred.count > 1 ? "等 \(inferred.count) 集" : "") + "已经推理过分镜：段落变了的话旧的分镜卡会对不上，分割完要重新推理分镜。"
                    }
                    return text
                },
                episodeCount: episodeCount, currentEpisode: currentEpisode,
                notePlaceholder: "比如：把第 2 段和第 3 段合并成一段；第 4 段在「你走吧」那句之后拆成两段；这一集分段再细一点，台词别拆开。",
                onStart: { indices, note in app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: indices, note: note) },
                onClose: close)
        case .name:
            let episodes = app.currentPipelineArchive?.episodes ?? []
            BatchRangePanel(
                title: "分段命名",
                summary: { "将依次给 \($0) 集的各段命名" },
                warning: { indices in
                    func text(_ list: [Int], _ tail: String) -> String {
                        guard let first = list.first else { return "" }
                        return "第 \(first + 1) 集" + (list.count > 1 ? "等 \(list.count) 集" : "") + tail
                    }
                    let valid = indices.filter { episodes.indices.contains($0) }
                    let noSplit = valid.filter { (episodes[$0].splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if !noSplit.isEmpty { return text(noSplit, "还没有分割，命名会停在那里。先做「分割」。") }
                    let inferred = valid.filter { !(episodes[$0].shotIDs ?? []).isEmpty }
                    if !inferred.isEmpty { return text(inferred, "已经推理过分镜：重新命名会改掉名字，分镜要重新推理才跟得上。") }
                    let named = valid.filter { SplitSegments.isNamed(episodes[$0].splitText ?? "") }
                    if !named.isEmpty { return text(named, "已经有名字，会被重新命名覆盖（手改的也没了）。") }
                    return nil
                },
                episodeCount: episodes.count, currentEpisode: currentEpisode,
                notePlaceholder: "比如：周承山二十年前（四十岁）的片段按「周承山四十岁时期」命名；医院的场景统一叫「江城医院·急诊室」。",
                onStart: { indices, note in app.pipelineFlow.batchName(app: app, project: key, episodeIndices: indices, note: note) },
                onClose: close)
        case .infer:
            let episodes = app.currentPipelineArchive?.episodes ?? []
            BatchRangePanel(
                title: "推理分镜",
                summary: { "将依次推理 \($0) 集" },
                warning: { indices in
                    let missing = indices.filter { episodes.indices.contains($0) && (episodes[$0].splitText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    if let first = missing.first {
                        return "第 \(first + 1) 集" + (missing.count > 1 ? "等 \(missing.count) 集" : "") + "还没有时长分割，推理会停在那里。先做「分割」。"
                    }
                    let unnamed = indices.filter { episodes.indices.contains($0) && !SplitSegments.isNamed(episodes[$0].splitText ?? "") }
                    if let first = unnamed.first {
                        return "第 \(first + 1) 集" + (unnamed.count > 1 ? "等 \(unnamed.count) 集" : "") + "还没有命名（各段的场景 / 角色 / 道具），推理会停在那里。先做「命名」。"
                    }
                    let again = indices.filter { episodes.indices.contains($0) && !(episodes[$0].shotIDs ?? []).isEmpty }
                    guard let first = again.first else { return nil }
                    return "第 \(first + 1) 集" + (again.count > 1 ? "等 \(again.count) 集" : "") + "已经推理过，会覆盖那些卡的提示词（已生成的视频保留）。"
                },
                episodeCount: episodes.count, currentEpisode: currentEpisode,
                notePlaceholder: "比如：这一集镜头再紧凑一点；对话多的段多给几个反应镜头。",
                onStart: { indices, note in app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: indices, note: note) },
                onClose: close)
        case .scene, .role, .prop:
            if let kind = step.kind { extractPanel(kind, key: key, board: board) }
        }
    }

    /// 选中各集分镜头行里这一类的名字，带「有没有卡」「哪几集出场」（提取面板的勾选区）
    private func nameChoices(_ kind: PipelineFlow.ExtractionKind, key: String, board: WorkbenchStatus.Board?, indices: [Int]) -> [ExtractNameChoice] {
        guard let board, let archive = app.currentPipelineArchive, !archive.episodes.isEmpty else { return [] }
        let selected = Set(indices).filter { archive.episodes.indices.contains($0) && board.episodes.indices.contains($0) }.sorted()
        guard !selected.isEmpty else { return [] }
        // 和真正提取同一份名单：角色名带着这一段的【阶段】（「许曼（青年）」和「许曼」是两张卡）
        let entries = PipelineFlow.extractionEntries(app: app, project: key, archive: archive, kind: kind, episodeIndices: selected)
        let missing = Set(selected.flatMap { board.episodes[$0].missingNames[kind] ?? [] })
        return entries.map { entry in
            let numbers = entry.episodes
            let label = numbers.count <= 3 ? "第\(numbers.map(String.init).joined(separator: "、"))集" : "第\(numbers.prefix(3).map(String.init).joined(separator: "、"))等\(numbers.count)集"
            return ExtractNameChoice(name: entry.name, detail: label, hasCard: !missing.contains(entry.name))
        }
    }

    private func extractPanel(_ kind: PipelineFlow.ExtractionKind, key: String, board: WorkbenchStatus.Board?) -> some View {
        BatchRangePanel(
            title: kind.buttonTitle,
            summary: { $0 == 0 ? "项目还没分集，将读整篇剧本" : "将提取 \($0) 集分镜头行里的\(kind.rawValue)" },
            warning: { indices in
                guard let archive = app.currentPipelineArchive else { return nil }
                let missing = PipelineFlow.episodesMissingStoryboard(app: app, project: key, archive: archive, episodeIndices: indices)
                guard let first = missing.first else { return nil }
                return "第 \(first + 1) 集" + (missing.count > 1 ? "等 \(missing.count) 集" : "") + "还没有推理分镜，提取不会开始。先做「分镜」。"
            },
            episodeCount: episodeCount, allowsWholeScript: true, currentEpisode: currentEpisode,
            notePlaceholder: kind == .scene ? "比如：场景只写空间和陈设，光线按白天写。"
                : (kind == .role ? "比如：服装要按剧情写出变化；年龄、身高都写具体数字。" : "比如：只提取关键道具，日常摆设不要。"),
            nameChoices: { nameChoices(kind, key: key, board: board, indices: $0) },
            nameNoun: kind.rawValue,
            onStartNames: { indices, note, names in
                app.pipelineFlow.batchExtract(app: app, project: key, kind: kind, episodeIndices: indices, note: note, names: names)
            },
            era: app.currentPipelineArchive?.eraBackground ?? "",
            onEraCommit: { app.setEraBackground($0, project: key) },
            onStart: { indices, note in app.pipelineFlow.batchExtract(app: app, project: key, kind: kind, episodeIndices: indices, note: note) },
            onClose: close)
    }
}

/// 胶囊放得下多少：按它所在的宽度（窗口宽度，开着右边抽屉要减掉抽屉）窄了去图标，
/// 不让某几步被挤成「…」（2026-10-10 优化：800 宽时有一步只剩省略号）。数是按「56/56」这样的计数量出来的，留了余量。
/// 胶囊最左边原来有「项目进度」四个字，最小窗口开抽屉、胶囊被往左推到集数栏时会被盖住，2026-10-11 用户定：去掉
enum WorkbenchCapsuleWidth {
    static let showsIcons: CGFloat = 840
}

/// 胶囊里的一步：图标 + 名字 + 「完成/总数」排成一行，下面一小条进度。完成变绿，跑着发光；点开弹出选择框。
private struct WorkbenchStepButton<Panel: View>: View {
    let title: String
    let icon: String
    let progress: WorkbenchStatus.Progress?
    let running: Bool
    @ViewBuilder let panel: () -> Panel

    @State private var show = false
    @State private var hovered = false
    @Environment(\.toolbarContainerWidth) private var containerWidth
    private var showsIcon: Bool { containerWidth == 0 || containerWidth >= WorkbenchCapsuleWidth.showsIcons }

    private var tint: Color {
        if running { return Theme.accent }
        if progress?.isComplete == true { return Theme.success }
        return Color.primary
    }

    private var fraction: Double {
        guard let progress, progress.total > 0 else { return 0 }
        return min(1, Double(progress.done) / Double(progress.total))
    }

    var body: some View {
        Button {
            DropdownPanel.shared.dismiss()
            show = true
        } label: {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    if showsIcon { Image(systemName: icon).font(.system(size: 12)).frame(width: 16) }
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let progress {
                        Text("\(progress.done)/\(progress.total)")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit()
                            .foregroundStyle(progress.isComplete || running ? tint : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(tint)
                Color.clear.frame(width: 1, height: 3)          // 给下面的进度小条留位置；宽度不抢（Color.clear 默认会撑满）
            }
            // 进度小条：灰槽 + 按完成比例填色。画在上面一行字的宽度里（别让它自己撑宽——胶囊的宽度只由字决定）
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.primary.opacity(0.1)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(tint.opacity(progress == nil || fraction == 0 ? 0 : 0.85))
                                .frame(width: proxy.size.width * fraction)
                        }
                    }
            }
            .padding(.horizontal, 10)
            // 高度和生图 / 生视频页的工具条按钮一样（42，胶囊 = 42 + 上下各 6 内边距 = 54，2026-10-10 用户：两条胶囊上下尺寸不一样）
            .frame(minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovered ? 0.07 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .pipelineActivityGlow(running)
        }
        .buttonStyle(QuietButtonStyle(hover: .none))
        .onHover { hovered = $0 }
        .dropdownPopover(isPresented: $show) { panel() }
    }
}
