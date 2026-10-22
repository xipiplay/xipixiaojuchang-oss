import SwiftUI

/// 任务抽屉（2026-10-06 P2）：视频、生图、剧本 AI 一个列表。
///
/// - 范围：只显示当前项目的任务（2026-10-07 用户定：去掉「全部项目」切换——点别的项目的任务行定位不到，
///   角标也只数当前项目，别的项目的任务在这里没有可做的事；素材库、生图、分镜也都是按项目隔离）。
/// - 保留：进行中的全显示；结束的只显示最近 7 天、最多 200 条（结果一直在项目里，不受影响）。
/// - 行：视频 / 生图沿用原来的 `TaskRow` / `ImageTaskRow`（错误原文、悬停、点击定位都不变），
///   下面加一行操作（不再等待 / 继续等待 / 停止 / 重试）。
struct JobDrawerView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("jobDrawerKind") private var kindRaw = Kind.all.rawValue

    enum Kind: String, CaseIterable {
        case all, video, image, ai
        var title: String {
            switch self {
            case .all: "全部类型"
            case .video: "视频"
            case .image: "生图"
            case .ai: "剧本 AI"
            }
        }
    }

    enum Entry: Identifiable {
        case video(LocalTask)
        case image(ImageGenItem)
        case ai(JobRecord)

        var id: String {
            switch self {
            case .video(let t): "v-\(t.id)"
            case .image(let i): "i-\(i.id.uuidString)"
            case .ai(let r): r.id
            }
        }
        var date: Date {
            switch self {
            case .video(let t): t.createdAt
            case .image(let i): i.submittedAt ?? .distantPast
            case .ai(let r): r.createdAt
            }
        }
        var projectKey: String {
            switch self {
            case .video(let t): t.groupKey
            case .image(let i): i.projectKey
            case .ai(let r): r.projectKey
            }
        }
        var isActive: Bool {
            switch self {
            case .video(let t): t.phase == .queued || t.phase == .inProgress || t.phase == .paused
            case .image(let i): i.status.isBusy
            case .ai(let r): r.state.isActive
            }
        }
    }

    /// 抽屉里的一行：一条任务，或者「一批做完的同类剧本 AI 任务」折成的一行
    /// （2026-10-10 用户：批量分割 56 集，抽屉里就是 56 条「时长分割 完成」刷屏）
    enum DrawerRow: Identifiable {
        case entry(Entry)
        case group(AIGroup)

        var id: String {
            switch self {
            case .entry(let e): e.id
            case .group(let g): g.id
            }
        }
    }

    struct AIGroup {
        var records: [JobRecord]
        var id: String { "group-" + (records.first?.id ?? "") }
        var title: String { records.first?.title ?? "" }
        var date: Date { records.map(\.createdAt).max() ?? .distantPast }
    }

    /// 连续的、同一个项目同一个步骤、**已经完成**的剧本 AI 任务，凑够 `groupMinimum` 条就折成一行。
    /// 进行中的、失败的、已停止的都不折：要能停、能看失败原因。
    nonisolated static let groupMinimum = 3

    static func rows(_ list: [Entry]) -> [DrawerRow] {
        var rows: [DrawerRow] = []
        var run: [JobRecord] = []
        func flush() {
            if run.count >= groupMinimum { rows.append(.group(AIGroup(records: run))) }
            else { rows += run.map { .entry(.ai($0)) } }
            run = []
        }
        for entry in list {
            if case .ai(let record) = entry, record.state == .completed,
               run.isEmpty || (run[0].projectKey == record.projectKey && run[0].title == record.title) {
                run.append(record)
            } else {
                flush()
                if case .ai(let record) = entry, record.state == .completed { run = [record] }
                else { rows.append(.entry(entry)) }
            }
        }
        flush()
        return rows
    }

    /// 先排出来的条数（见列表那里的说明）；换筛选时回到第一页
    static let pageSize = 30
    @State private var shownLimit = pageSize

    /// 展开了的批量（折叠 / 展开只在这次打开抽屉期间记着）
    @State private var expandedGroups: Set<String> = []

    private var kind: Kind { Kind(rawValue: kindRaw) ?? .all }
    /// 没进项目（抽屉只能在项目里打开，正常不会出现）才显示全部，并带项目名
    private var showsAll: Bool { app.currentProjectKey == nil }

    private var entries: [Entry] {
        let project = showsAll ? nil : app.currentProjectKey
        let filter = app.taskFilter
        var list: [Entry] = []
        if kind == .all || kind == .video {
            list += app.store.tasks
                .filter { (project == nil || $0.groupKey == project) && filter.matches($0) }
                .map(Entry.video)
        }
        if kind == .all || kind == .image {
            list += app.imageItems
                .filter { $0.submittedAt != nil && (project == nil || $0.projectKey == project) && filter.matches($0) }
                .map(Entry.image)
        }
        if kind == .all || kind == .ai {
            list += app.jobCenter.records
                .filter { $0.kind == .ai && (project == nil || $0.projectKey == project) && filter.matches($0) }
                .filter { !JobCenter.hidesBatchDriver($0, among: app.jobCenter.records) }
                .map(Entry.ai)
        }
        return Self.retained(list, now: Date())
    }

    /// 进行中的全留；结束的只留最近 7 天，最多 200 条；新的在上
    static func retained(_ list: [Entry], now: Date) -> [Entry] {
        let cutoff = now.addingTimeInterval(-JobCenter.keepDays * 86400)
        let active = list.filter(\.isActive)
        let finished = list.filter { !$0.isActive && $0.date >= cutoff }
            .sorted(by: newerFirst)
            .prefix(JobCenter.keepCount)
        return (active + finished).sorted(by: newerFirst)
    }

    /// 新的在上；时间一样时按 id 排，顺序每次都一样。
    /// ⚠️ 不能只比时间：任务时间存到秒，一批提交的常常同一秒（用户项目里 290 个视频有 51 个撞秒），
    /// 排序对相等的不保证先后，抽屉每次轮询重排时它们互换位置，懒加载列表跟着挪，会空出一大块、某一行时有时无（2026-10-14 用户录屏）
    static func newerFirst(_ a: Entry, _ b: Entry) -> Bool {
        a.date != b.date ? a.date > b.date : a.id > b.id
    }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 6) {
            SegmentedBar(options: TaskFilter.allCases.map { ($0.displayName, $0) }, selection: $app.taskFilter)
                .frame(height: 24)
            HStack {
                IconDropdown(icon: "line.3.horizontal.decrease", labelWidth: 72,
                             options: Kind.allCases.map { DropdownOption(label: $0.title, value: $0.rawValue) },
                             selection: $kindRaw)
                Spacer()
                Text("近 7 天")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            let list = entries
            if list.isEmpty {
                Spacer()
                Text("暂无任务").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    // 不用懒加载：行有高有矮（失败的多两行错误 + 重试按钮），LazyVStack 滑动时估高对不上，
                    // 列表中间会空出一大块、某一行时有时无（2026-10-14 用户两次录屏）。一次全排出来又太慢（220 条开抽屉 380 ms），
                    // 系统 List 更慢（500 多 ms）——所以先排最新的 `pageSize` 条，底下「显示更早的」再加
                    let allRows = Self.rows(list)
                    let drawerRows = Array(allRows.prefix(shownLimit))
                    VStack(spacing: 2) {
                        ForEach(Array(drawerRows.enumerated()), id: \.element.id) { index, drawerRow in
                            switch drawerRow {
                            case .entry(let entry):
                                VStack(alignment: .leading, spacing: 2) {
                                    if showsAll {
                                        Text(app.projectName(for: entry.projectKey))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .padding(.leading, 6)
                                    }
                                    row(entry)
                                    JobActions(entry: entry)
                                }
                            case .group(let group):
                                AIGroupRow(group: group, expanded: expandedGroups.contains(group.id)) {
                                    if !expandedGroups.insert(group.id).inserted { expandedGroups.remove(group.id) }
                                }
                                if expandedGroups.contains(group.id) {
                                    ForEach(group.records) { record in
                                        VStack(alignment: .leading, spacing: 2) {
                                            row(.ai(record))
                                        }
                                        .padding(.leading, 10)
                                    }
                                }
                            }
                            if index < drawerRows.count - 1 { Divider() }
                        }
                        if allRows.count > drawerRows.count {
                            Button("显示更早的 \(min(Self.pageSize, allRows.count - drawerRows.count)) 条（还有 \(allRows.count - drawerRows.count) 条）") {
                                shownLimit += Self.pageSize
                            }
                            .buttonStyle(OutlineButtonStyle())
                            .controlSize(.small)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("job-drawer-more")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: app.taskFilter) { _, _ in shownLimit = Self.pageSize }
        .onChange(of: kindRaw) { _, _ in shownLimit = Self.pageSize }
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .video(let task): TaskRow(task: task)
        case .image(let item): ImageTaskRow(item: item)
        case .ai(let record): AIJobRow(record: record)
        }
    }
}

/// 一批做完的同类剧本 AI 任务折成的一行：「时长分割 · 完成 56 集」，点一下展开看每一集
private struct AIGroupRow: View {
    @Environment(AppModel.self) private var app
    let group: JobDrawerView.AIGroup
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        Text(group.title).font(.callout.weight(.medium))
                        StatusCapsule(title: "完成 \(group.records.count)", color: Theme.success)
                        Spacer()
                    }
                    Text("剧本 AI · 共 \(group.records.count) 个 · \(group.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("job-group-\(group.title)")
            if let first = group.records.first, first.projectKey == app.currentProjectKey, app.isInWorkspace {
                Button("去剧本页") { app.openScriptPage() }
                    .buttonStyle(OutlineButtonStyle())
                    .controlSize(.mini)
                    .padding(.leading, 16)
            }
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 剧本 AI 任务行：步骤 + 集 + 状态 + 说明
private struct AIJobRow: View {
    @Environment(AppModel.self) private var app
    let record: JobRecord

    private var episodeLabel: String {
        guard let id = record.episodeID else { return "整部剧本" }
        return app.pipelineArchive(for: record.projectKey)?.episodes.first { $0.id == id }?.title ?? "已删除的集"
    }

    private var status: (String, Color) {
        switch record.state {
        case .waiting: ("排队中", Theme.warning)
        case .running: ("进行中", Theme.accent)
        case .completed: ("完成", Theme.success)
        case .failed: ("失败", Theme.danger)
        case .stopped: ("已停止", .gray)
        case .interrupted: ("已中断", Theme.warning)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.title).font(.callout.weight(.medium))
                StatusCapsule(title: status.0, color: status.1)
                if record.state == .running { ProgressView().controlSize(.mini) }
                Spacer()
            }
            Text("剧本 AI · \(episodeLabel) · \(record.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let note = record.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(record.state == .failed ? Theme.danger : .secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            // 软件直接调接口、流式接收时的实时进度（外部智能体接力、没开流式的没有）
            if record.state.isActive { AIStreamSection(recordID: record.id) }
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 剧本 AI 任务那一行下面的实时进度（2026-10-11 流式接收）：一句话说现在在想还是在写、写了多少字、用了多久；
/// 「看过程」展开后能看思考的内容和已经写出来的部分，一边生成一边往下长。任务结束这一块就消失，只留结果
private struct AIStreamSection: View {
    @Environment(AppModel.self) private var app
    let recordID: String
    @State private var expanded = false

    var body: some View {
        if let summary = app.jobCenter.streamSummary(for: recordID) {
            VStack(alignment: .leading, spacing: 4) {
                AIStreamStatus(summary: summary, expanded: expanded) { expanded.toggle() }
                if expanded { AIStreamText(progress: summary.latest, several: summary.requests > 1) }
            }
            .padding(.top, 2)
        }
    }
}

/// 进行中任务下面的两行小字（2026-10-11 用户指出任务列表会「跳」：「看过程」按钮和数字在同一行，数字一长就被挤成两行，整行变高）。
/// 现在：第一行「现在在干什么 · 已用时」+ 按钮，这一行的字再长也不会折行；第二行放字数，单路时只占一行（放不下就截尾），
/// 几路同时进行时固定占两行——所以行高不再随数字变，列表不会跳
struct AIStreamStatus: View {
    let summary: JobCenter.AIStreamSummary
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        let several = summary.requests > 1
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 每秒刷新一次「已用时」，别的字不用跟着重画
                TimelineView(.periodic(from: summary.startedAt, by: 1)) { context in
                    Text("\(summary.headline) · 已用 \(Self.elapsed(context.date.timeIntervalSince(summary.startedAt)))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(expanded ? "收起" : "看过程", action: onToggle)
                    .buttonStyle(OutlineButtonStyle())
                    .controlSize(.mini)
                    .fixedSize()
                    .help("看思考的内容和已经写出来的部分（只留最近的一段）")
            }
            Text(summary.detail)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(several ? 2 : 1, reservesSpace: several)
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total) 秒" : "\(total / 60) 分 \(total % 60) 秒"
    }
}

/// 「看过程」展开的内容：思考和输出各一块，固定高度、自己滚，新内容来了贴着底部
struct AIStreamText: View {
    let progress: AIStreamProgress
    /// 一个任务里同时有好几个请求时，这里只显示最近有动静的那一个
    let several: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if several { Text("同时有好几个请求，下面是最近有动静的一个").font(.caption2).foregroundStyle(.tertiary) }
            block("思考", progress.reasoningTail, total: progress.reasoningChars)
            block("输出", progress.contentTail, total: progress.contentChars)
            if progress.reasoningChars == 0, progress.contentChars == 0 {
                Text("还没有收到内容").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func plain(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .textSelection(.enabled)
    }

    /// 抽屉里一行大约 20 个汉字、框高 130 大约放 8 行：不超过这个量就不用滚动
    static func fitsWithoutScrolling(_ text: String) -> Bool {
        text.count <= 120 && text.filter { $0 == "\n" }.count <= 6
    }

    @ViewBuilder
    private func block(_ title: String, _ text: String, total: Int) -> some View {
        if total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \(total) 字" + (total > text.count ? "（只显示最近 \(text.count) 字）" : ""))
                    .font(.caption2).foregroundStyle(.secondary)
                Group {
                    if Self.fitsWithoutScrolling(text) {
                        // 内容少：直接显示，别撑出一个大空框
                        plain(text)
                    } else {
                        ScrollView { plain(text) }
                            .defaultScrollAnchor(.bottom)          // 新内容来了贴着底部，一直看到最新的
                            .frame(height: 130)
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// 每条任务下面的操作
private struct JobActions: View {
    @Environment(AppModel.self) private var app
    let entry: JobDrawerView.Entry
    /// 等用户确认的付费操作（重试会花钱：先弹确认，2026-10-23）
    @State private var pendingConfirm: Action?
    @State private var infoMessage: String?

    var body: some View {
        let buttons = actions
        if !buttons.isEmpty {
            HStack(spacing: 6) {
                ForEach(buttons, id: \.title) { action in
                    Button(action.title) {
                        if action.confirm != nil { pendingConfirm = action } else { action.run() }
                    }
                        .buttonStyle(OutlineButtonStyle())
                        .controlSize(.mini)
                        .help(action.help)
                }
                Spacer()
            }
            .padding(.leading, 6)
            .padding(.bottom, 4)
            .alert(pendingConfirm?.confirm?.title ?? "", isPresented: Binding(
                get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } })) {
                Button("取消", role: .cancel) {}
                Button(pendingConfirm?.title ?? "确定") { pendingConfirm?.run() }
            } message: {
                Text(pendingConfirm?.confirm?.message ?? "")
            }
            .alert("提示", isPresented: Binding(get: { infoMessage != nil }, set: { if !$0 { infoMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(infoMessage ?? "")
            }
        }
    }

    private struct Action {
        var title: String
        var help: String
        /// 非 nil = 点了先弹这个确认框，确认后才 `run`
        var confirm: (title: String, message: String)? = nil
        var run: () -> Void
    }

    private var actions: [Action] {
        switch entry {
        case .video(let task):
            let placeholder = task.id.hasPrefix("pending-")
            if !placeholder, task.phase == .queued || task.phase == .inProgress {
                return [Action(title: "不再等待",
                               help: "平台没有取消接口：只是不再查它的结果，服务端可能照样生成、照样扣费。之后可以点「继续等待」") {
                    app.stopWaitingVideo(taskID: task.id)
                }]
            }
            if task.phase == .paused {
                return [Action(title: "继续等待", help: "重新开始查这条视频的结果") {
                    app.resumeWaitingVideo(taskID: task.id)
                }]
            }
            if task.phase == .failed, let shot = app.shotForTask(task) {
                // 失败的这一版留在历史里，重试是新的一版（version-history-rule）；原来提交失败的占位会先被删掉
                return [Action(title: "重试", help: "按分镜现在的提示词和参数重新提交",
                               confirm: ("重试这条视频？", "会按分镜现在的提示词和参数重新提交 1 个视频，产生费用。失败的这一版留在历史里。")) {
                    if let blocker = JobRetry.videoBlocker(shotID: shot.id, app: app) { infoMessage = blocker; return }
                    app.submitShot(shot.id)
                }]
            }
            return []
        case .image(let item):
            if item.status.isBusy {
                return [Action(title: "停止", help: "取消请求。中转站可能已经在生成，仍可能扣费") {
                    app.stopImageGeneration(item.id)
                }]
            }
            if item.status == .failed {
                return [Action(title: "重试", help: "按卡片现在的提示词和参数重新生成",
                               confirm: ("重试这张图？", "会按卡片现在的提示词和参数重新生成 1 张图，产生费用。失败的这一版留在历史里。")) {
                    if let blocker = JobRetry.imageBlocker(itemID: item.id, app: app) { infoMessage = blocker; return }
                    app.requestImageGeneration(item.id)
                }]
            }
            return []
        case .ai(let record):
            var list: [Action] = []
            if record.state.isActive {
                list.append(Action(title: "停止", help: "停下这一步；已完成的结果保留") {
                    app.pipelineFlow.cancel(project: record.projectKey, episode: record.episodeID, slot: record.slot)
                })
            }
            if record.projectKey == app.currentProjectKey, app.isInWorkspace {
                list.append(Action(title: "去剧本页", help: "打开这个项目的剧本页") { app.openScriptPage() })
            }
            return list
        }
    }
}

/// 任务抽屉「重试」提交前的检查（2026-10-23）：和段落详情页 / 生图卡的提交前检查同一口径，
/// 返回 nil = 可以交；否则是要告诉用户的原因（不偷偷跳过、也不当成一次失败记进历史）
@MainActor
enum JobRetry {
    static func videoBlocker(shotID: UUID, app: AppModel) -> String? {
        guard let shot = app.shots.first(where: { $0.id == shotID }) else { return "这条分镜已经不在了。" }
        let issues = ShotValidator.validate(shot)
        if !issues.isEmpty { return issues.joined(separator: "；") + "。" }
        if !WorkbenchBatch.videoModelConfigured(shot, app: app) {
            return "这条分镜选的模型「\(shot.model)」已经不在配置里，先换一个模型再重试。"
        }
        return nil
    }

    static func imageBlocker(itemID: UUID, app: AppModel) -> String? {
        guard let item = app.imageItems.first(where: { $0.id == itemID }) else { return "这张卡片已经不在了。" }
        if app.imageModelNames.isEmpty { return "还没有可用的图片模型，请先到设置里添加渠道与图片模型。" }
        if let m = item.model, !m.isEmpty, !app.imageModelNames.contains(m) {
            return "这张卡片选的模型「\(m)」已经不在配置里，先换一个模型再重试。"
        }
        if item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "这张卡片还没有提示词。" }
        return nil
    }
}
