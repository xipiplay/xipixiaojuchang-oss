import SwiftUI
import AppKit

/// 右栏任务列表：当前项目的任务，平铺显示状态/进度（不分组），支持按名称/提交顺序 + 升降序
/// 任务抽屉的状态筛选（视频 / 生图 / 剧本 AI 共用，2026-10-06 P2 统一任务抽屉）
enum TaskFilter: String, CaseIterable, Identifiable {
    case all, active, completed, failed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: "全部"
        case .active: "进行中"
        case .completed: "已完成"
        case .failed: "失败"
        }
    }
    func matches(_ task: LocalTask) -> Bool {
        switch self {
        case .all: true
        case .active: task.phase == .queued || task.phase == .inProgress || task.phase == .paused
        case .completed: task.phase == .completed
        case .failed: task.phase == .failed
        }
    }
    func matches(_ item: ImageGenItem) -> Bool {
        switch self {
        case .all: true
        case .active: item.status.isBusy
        case .completed: item.status == .success
        case .failed: item.status == .failed
        }
    }
    func matches(_ record: JobRecord) -> Bool {
        switch self {
        case .all: true
        case .active: record.state.isActive
        case .completed: record.state == .completed
        case .failed: record.state == .failed || record.state == .stopped || record.state == .interrupted
        }
    }
}

/// 失败原因原文浮层（视频 / 生图任务行共用）：可选中、可一键复制 —— **报给服务商时要贴原文**
///（摘要是给人一眼看的，原文才是证据）。
///
/// ⚠️ 这里是**静态内容**（字符串是参数传进来的），不受 `DropdownPopoverModifier`
/// 那个「AnyView 快照不跟随外部状态」的影响（见 `开发笔记.md` 第六节）。
struct TaskErrorDetail: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("失败原因").font(.headline)
                Spacer()
                Button("复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(raw, forType: .string)
                }
                .buttonStyle(OutlineButtonStyle())
                .controlSize(.small)
            }
            Text(raw)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                // 撑到内容需要的高度（不截断）—— 服务商原文常有 300~400 字符
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(width: 420)
    }
}

/// 右栏任务行：分镜序号 + 状态徽章 + 进度条 + 参数摘要 + 删除
struct TaskRow: View {
    @Environment(AppModel.self) private var app
    let task: LocalTask
    /// 失败原因详情浮层（点摘要打开）
    @State private var showErrorDetail = false

    /// 该任务对应的分镜 —— **两级回退**：
    ///
    /// ① `shot.taskIDs` 里能找到 → 权威（提交成功过的任务都会写回那里）
    /// ② **用 `task.fileName` 反查** —— 失败的任务、以及提交过程中的占位任务
    ///    **都不在 `taskIDs` 里**（`submitShot` 只在提交成功时写回）。没有这一级的话：
    ///    行首缺「分镜X 第N版」、徽章挤到最左边、点它还不会滚到对应分镜
    ///    （用户 2026-09-23 报「徽章的位置都不对」，提交后/生成中/失败三种状态都中招）。
    private var shot: ShotDraft? {
        if let linked = app.shots.first(where: { $0.taskIDs.contains(task.id) }) { return linked }
        guard let name = task.fileName, !name.isEmpty,
              let prefix = Self.prefixFromFileName(name) else { return nil }
        // 只在这条任务自己的项目里找：每个项目都有「1-1」，不限项目会对到别的项目的分镜上
        return app.shots.first { $0.projectKey == task.groupKey && app.numbering(of: $0).filePrefix == prefix }
    }

    /// 从任务文件名反推分镜的编号前缀。
    ///
    /// `task.fileName` 由 `shotFileName` 生成，形状是 **`段号-段内序号-版本号`**（如 `1-4-3`）；
    /// 而分镜的 `numbering.filePrefix` 只有**前两段**（`1-4`）—— 所以要去掉最后一段才能对上。
    private static func prefixFromFileName(_ name: String) -> String? {
        let parts = name.split(separator: "-")
        guard parts.count >= 3 else { return nil }   // 至少 A-B-V 三段
        return parts.dropLast().joined(separator: "-")
    }

    /// 该任务对应分镜的**编号**（「分镜1-1」那套 —— 与文件名前两段一致，能对上）
    private var shotNumbering: ShotNumbering? {
        shot.map { app.numbering(of: $0) }
    }

    /// 该任务的版本号（第几版）：按文件名，和历史版本、预览左上角同一个口径（2026-10-16 用户：任务列表和历史版本对不上；
    /// 原来按它在 `taskIDs` 里排第几个数，删过 / 跳过号的分镜就对不上）。提交中的占位任务也有文件名，一样显示；
    /// 既没文件名、也不在分镜上的老任务 → nil（行首只显示「分镜1-4」）
    private var versionIndex: Int? {
        if task.fileName?.isEmpty == false { return task.versionNumber(in: shot?.taskIDs ?? []) }
        guard let shot, shot.taskIDs.contains(task.id) else { return nil }
        return task.versionNumber(in: shot.taskIDs)
    }

    /// 参数摘要：模型 + 分辨率 + 画幅 + 时长（统一走 LocalTask.modeSummary）
    private var summary: String {
        "\(task.modeSummary) · \(task.aspectRatio.plainLabel) · \(task.duration) 秒"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // ⚠️ **文字 + 徽章要往里缩 6pt**（2026-09-13 用户实测）：悬停高亮的背景是外层
                // `VStack` + 垂直 padding 的范围，而内容原来紧贴它的左缘 —— **圆角（10）会把首字"切"出来**
                //（用户原话："'分'和'官'这两个开头的字样稍微有点露出高亮区域了"）。
                // ⚠️ 缩进的是**这一组内容**、不是整行 —— 删除按钮要靠右边缘定位，必须**保持不动**（用户明确要求）。
                HStack(spacing: 6) {
                    if let numbering = shotNumbering {
                        Text(versionIndex.map { "\(numbering.title) 第\($0)版" } ?? numbering.title)
                            .font(.caption.weight(.medium))
                    }
                    StatusBadge(phase: task.phase).equatable()
                }
                .padding(.leading, 6)
                Spacer()
                Button {
                    app.deleteTask(id: task.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                // ⚠️ **右内边距**（2026-09-13 用户要求）：行的高亮背景是外层 `VStack` 的范围，
                // 而删除按钮原来**紧贴它的右缘** —— 它自己的悬停高亮（会外扩 8×4）于是**溢出到行高亮之外**，
                // 两个高亮看着"重叠/错位"（用户实测）。留 8pt 让它和高亮边缘分开。
                .padding(.trailing, 8)
            }
            if task.phase == .queued || task.phase == .inProgress {
                HStack(spacing: 6) {
                    if task.progressPercent == nil {
                        // 平台无百分比进度，显示「排队中（第N位）/生成中」
                        if task.phase == .queued {
                            if let pos = task.queuePosition, pos > 0 {
                                Text("排队中 · 第 \(pos) 位")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("排队中")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView().controlSize(.small)
                            Text("生成中")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView(value: task.progressPercent ?? 0, total: 100)
                        Text("\(Int((task.progressPercent ?? 0).rounded()))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // ⚠️ **这 6pt 缩进不能漏**（2026-09-23 用户报「排队中的字样没有对齐」）：
                // 首行（编号 + 徽章）和参数摘要都有这个缩进，漏了的话整块**偏左 6pt** ——
                // 视觉上「排队中 / 生成中 / 进度百分比」会比上下两行探出去一截。
                // 三种状态**共用这一个 HStack**，所以一处修就全好了。
                // 同首行的理由：悬停高亮是外层 VStack 的范围、圆角 10 会把首字"切"出来。
                .padding(.leading, 6)
            }
            // 失败原因摘要：**点它看完整原文**（服务商返回的 JSON 常有几百字符，列表里放不下）
            // ⚠️ 必须是 Button —— 整行有 `onTapGesture`（滚到对应分镜），子视图的 Button 会先消费
            // 点击、不会连带触发（同删除按钮，2026-09-13 已实测确认过，别为此加额外防护）
            if task.phase == .failed, let raw = task.errorMessage, !raw.isEmpty {
                Button {
                    showErrorDetail = true
                } label: {
                    Text(Formatters.errorSummary(raw))
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 同首行：往里缩 6pt（别让首字被高亮框圆角"切"出来）
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .help("点击查看完整错误原文")
                .dropdownPopover(isPresented: $showErrorDetail) {
                    TaskErrorDetail(raw: raw)
                }
            }
            // 这里原来在「非进行中」时显示 `Formatters.taskDate`（几月几号几点），已按用户要求删掉
            Text(summary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                // 同首行：往里缩 6pt，别让首字被高亮框的圆角"切"出来（用户实测的是"官"字）
                .padding(.leading, 6)
        }
        .padding(.vertical, 4)
        // ⚠️ 没有悬停高亮（2026-10-08 用户定：去掉）。原来的悬停高亮带 0.15 秒动画，鼠标在任务列表里一划，
        // 抽屉那层毛玻璃就跟着重采样，旁边的底部胶囊右侧会闪；去掉后鼠标划过抽屉不再触发任何动画。
        .contentShape(Rectangle())
        .onTapGesture {
            // 点击任务 → 中间列滚动到对应分镜
            //（失败 / 提交中的任务现在也能滚了 —— 见 `shot` 的两级回退）
            // ⚠️ 删除按钮不会连带触发这里：**子视图的手势优先于父视图**，Button 会先消费点击 ——
            //  用户 2026-09-13 实测确认过"点删除不会切分镜"，别为此加额外防护
            if let shot {
                app.scrollToShotID = shot.id
            }
        }
    }
}


/// 生图任务行：类型徽章 + 名字 + 状态 + **删除** + **参数摘要**，点击定位到中栏卡片。
///
/// ⚠️ 结构**对齐分镜侧的 `TaskRow`**（2026-09-13 用户要求"视频任务列表有的、生图也要有"）：
/// 原来整行是一个 `Button`，**改成 `VStack` + 行内删除按钮 + `onTapGesture`** ——
/// 因为 `Button` 里放不下 `Button`（删除按钮会被外层吃掉）。
/// 悬停高亮、左缩进、删除按钮的右内边距，全部与分镜侧同一套数值。
struct ImageTaskRow: View {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    /// 失败原因原文浮层（点摘要打开；与视频侧 `TaskRow` 同一套）
    @State private var showErrorDetail = false

    /// 参数摘要里的模型名（口径同详情面板/卡片：`item.model` 空 = 配置里第一个图片模型）
    private var displayedModel: String {
        item.model.flatMap { $0.isEmpty ? nil : $0 } ?? app.imageModelNames.first ?? "未选模型"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // 类型徽章 + 名字：一起往里缩 6pt（同分镜侧 —— 免得首字被行高亮的圆角"切"出来）
                HStack(spacing: 6) {
                    if let type = item.type {
                        Text(type.displayName)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.15)))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(item.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 🎨 2026-09-27 用户定：状态徽章跟视频侧同款、挪到左边（名字后面）。
                    // 原来在右边是一行纯文字（`statusLabel`），跟生视频侧不一致。
                    statusBadge
                    if item.status.isBusy {
                        // 生图接口没有百分比进度，转圈是唯一的"活着"信号（同旧版，只是跟着挪到左边）
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.leading, 6)
                Spacer()
                // 🗑 删除卡片（**走统一确认弹窗**）。
                // ⚠️ 2026-09-27 修：这里原来是**直接** `removeImageItem` —— 用户实测"删任务把卡片也删了"。
                // 事实：生图没有独立的任务对象，这行**就是卡片本身**（列表由条目组出来），所以这个位置
                // 只能删卡片；但直接删太突然。现在和"卡片上的垃圾桶 / 网格批量删除"**同一套确认弹窗**
                //（`activeModal = .confirmDeleteImage`），先给用户看清楚要删什么。
                Button {
                    AppLog.write("imageGenButton", "任务列表请求删除确认 name=\(item.name)")
                    app.activeModal = .confirmDeleteImage(itemID: item.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .padding(.trailing, 8)
            }
            // 失败原因摘要（与视频侧同款：点开看完整原文）——2026-09-27 用户要求补齐。
            // ⚠️ 必须是 Button：整行有 `onTapGesture`（滚到对应卡片），子视图的 Button 会先消费点击
            //（同删除按钮，视频侧同款写法）。
            if item.status == .failed, let raw = item.errorMessage, !raw.isEmpty {
                Button {
                    showErrorDetail = true
                } label: {
                    Text(Formatters.errorSummary(raw))
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 同首行：往里缩 6pt（别让首字被高亮框圆角"切"出来）
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .help("点击查看完整错误原文")
                .dropdownPopover(isPresented: $showErrorDetail) {
                    TaskErrorDetail(raw: raw)
                }
            }
            // 参数摘要（与分镜侧那一行同位置）：**模型 + 画幅 + 分辨率档位**。
            // 模型口径与详情面板/卡片一致：没选过 → 显示配置里第一个图片模型的真名
            //（2026-09-27 用户："生图任务列表的参数行少了模型"）。
            // ⚠️ 缩进要**跟着"第一行内容"走**（2026-09-13 用户实测："参数有点靠左"）：
            // 有类型徽章时，第一行的可见内容（徽章的**文字**）从 `6 + 5`（胶囊内边距）处开始，
            // 参数如果只缩 6 就会比它靠左 5pt、看着没对齐；没有徽章时第一行从 6 开始，参数也该是 6。
            Text("\(displayedModel) · \(item.aspectRatio.displayName) · \(item.quality.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, item.type == nil ? 6 : 11)
        }
        // ⚠️ **与分镜侧 `TaskRow` 同一套数值**（2026-09-23 统一，用户报"两边不一致"）：
        // `.vertical, 4`，且**横向内边距交给容器**（`ImageTaskRow(...).padding(.horizontal, 8)`）。
        // 原来横向写在**这一层、且在 `.background` 之前** —— 后果有两个：
        //   ① 悬停高亮把横向 8pt 也包了进去 → 比视频侧宽 16pt（贴到容器边缘）；
        //   ② 行高比视频侧多 4pt（`.vertical, 6`）。
        .padding(.vertical, 4)
        // ⚠️ 没有悬停高亮（2026-10-08 用户定：去掉）。原来的悬停高亮带 0.15 秒动画，鼠标在任务列表里一划，
        // 抽屉那层毛玻璃就跟着重采样，旁边的底部胶囊右侧会闪；去掉后鼠标划过抽屉不再触发任何动画。
        .contentShape(Rectangle())
        // ⚠️ 用 `onTapGesture` 而不是包一层 Button —— 否则里面的删除按钮会被吃掉（同分镜侧）
        .onTapGesture { app.scrollToImageItemID = item.id }
    }

    /// 状态胶囊（与视频侧 `StatusBadge` 同一套外观，走 `StatusCapsule`）——文案/配色用生图自己的口径。
    /// 2026-09-27 用户定：原来在右边是一行纯文字（`statusLabel`），跟生视频侧不一致 →
    /// 挪到左边（名字后）、改胶囊。
    private var statusBadge: some View {
        StatusCapsule(title: statusTitle, color: statusColor)
    }

    private var statusTitle: String {
        switch item.status {
        case .pending: "待生成"
        case .queued: "排队中"
        case .generating: "生成中"
        case .downloading: "下载中"
        case .success: item.results.count > 1 ? "共 \(item.results.count) 版" : "已完成"
        case .failed: "失败"
        }
    }

    /// 配色对齐视频侧语义：待生成 = 排队（赭）/ 生成中·下载中 = 进行中（主色）/ 完成鼠尾草绿 / 失败砖红
    private var statusColor: Color {
        switch item.status {
        case .pending, .queued: Theme.warning
        case .generating, .downloading: Theme.accent
        case .success: Theme.success
        case .failed: Theme.danger
        }
    }
}
