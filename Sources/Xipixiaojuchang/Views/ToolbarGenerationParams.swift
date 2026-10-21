import SwiftUI

// MARK: - 底部工具条里的「当前卡」生成参数 + 提交生成（2026-10-08 用户定：从右栏底部搬进工具条）
//
// 原来钉在右栏底部的那一块（生视频：模型 / 分辨率 / 比例 / 时长；生图：模型 / 类型 / 比例 / 质量；加「提交生成」）
// 现在放在页面底部的工具条里，作用对象仍然是**右栏正在看的那一张卡**。选中多张卡时工具条整条换成批量按钮（本来就有
// 批量设置参数 / 批量提交），这里不显示。右栏因此只剩历史版本 + 提示词。

extension AppModel {
    /// 右栏正在看的分镜（点的那张；没点过 / 已删就退回第一张）
    var inspectedShot: ShotDraft? {
        currentShots.first(where: { $0.id == timelineShotID }) ?? currentShots.first
    }

    /// 右栏正在看的图片条目（点的那张；没点过 / 已删就退回第一张）
    var inspectedImageItem: ImageGenItem? {
        if let id = inspectedImageItemID, let selected = currentImageItems.first(where: { $0.id == id }) {
            return selected
        }
        return currentImageItems.first
    }
}

/// 提交前的检查（右栏原来的提交按钮和工具条里的提交按钮是同一套规则）
@MainActor
enum ShotSubmitRules {
    static func isModelConfigured(_ shot: ShotDraft, app: AppModel) -> Bool {
        !app.videoModelNames.isEmpty && app.videoModelNames.contains(shot.model)
    }

    /// 还不满足提交条件的原因（空 = 可以提交）
    static func issues(_ shot: ShotDraft, app: AppModel) -> [String] {
        var issues = ShotValidator.validate(shot)
        if !isModelConfigured(shot, app: app), !issues.contains(where: { $0.contains("模型") }) {
            issues.append(app.videoModelNames.isEmpty
                          ? "还没有可用的视频模型，请先到设置里添加渠道与模型"
                          : "请先选择模型")
        }
        return issues
    }

    /// 这条分镜**正在提交 / 生成**（只看它自己的当前任务，不是全局锁；`submittingShotIDs` 是点提交到拿到任务 ID 之间的瞬态）
    static func isSubmitting(_ shot: ShotDraft, app: AppModel) -> Bool {
        if app.submittingShotIDs.contains(shot.id) { return true }
        guard let id = shot.taskID, let task = app.store.task(id: id) else { return false }
        return task.phase == .queued || task.phase == .inProgress
    }
}

/// 工具条里放参数的那一段。**独立子视图**：自己读条目列表，工具条所在的页壳不读（页壳每次重算会连累两个面板，见 `WorkspacePanelColumn` 的说明）。
struct ToolbarGenerationParams: View {
    @Environment(AppModel.self) private var app
    @Environment(\.toolbarContainerWidth) private var containerWidth

    /// 工具条所在宽度小于它就用紧凑档（别让胶囊撑出所在区域）。
    /// 实测（含胶囊内边距和两侧留白）：两页同宽，常规档 706，紧凑档 628。
    /// 工具条在整个内容区居中，最小窗口 1160 时内容区宽 1108，远大于这个值，所以平时都是常规档；只有窗口被压得很窄才会走紧凑档。
    static let compactBelow: CGFloat = 720

    var body: some View {
        let compact = containerWidth > 0 && containerWidth < Self.compactBelow
        if app.workspaceMode == .video {
            if let shot = app.inspectedShot {
                VideoToolbarParams(shot: app.shotBinding(shot.id), compact: compact)
            }
        } else if let item = app.inspectedImageItem {
            ImageToolbarParams(item: item, compact: compact)
        }
    }
}

// MARK: 共用的小零件

/// 工具条里四个参数位置的宽度（生视频 / 生图**共用**：两页的工具条一样宽，2026-10-08 用户要求）。
/// 每个位置 = 固定宽度的图标槽 + 4 + 固定宽度的文字槽，所以无论里面是什么参数、图标是哪个，总宽都一样。
private enum ParamSlot {
    static let icon: CGFloat = 16
    static func model(_ compact: Bool) -> CGFloat { compact ? 70 : 104 }
    static func second(_ compact: Bool) -> CGFloat { compact ? 40 : 48 }     // 生视频：分辨率；生图：类型
    static func third(_ compact: Bool) -> CGFloat { compact ? 38 : 44 }      // 比例（两页都是）
    static func fourth(_ compact: Bool) -> CGFloat { compact ? 38 : 44 }     // 生视频：时长；生图：质量
}

/// 工具条里的竖分割线（导入 / 新增 | 参数 | 提交生成）。
/// 不再显示「属于哪张卡」的名字（2026-10-08 用户定：提交的肯定是当前选中的；长名字还会把工具条撑长）
private struct ParamsDivider: View {
    var body: some View {
        Capsule().fill(Theme.hairline).frame(width: 1, height: 20)
    }
}

// MARK: 生视频

private struct VideoToolbarParams: View {
    @Environment(AppModel.self) private var app
    @Binding var shot: ShotDraft
    let compact: Bool
    @State private var showSubmitHint = false

    /// 在抽屉里临时看着别的版本时（与右栏原来的规则一致）：参数显示那一版的、**只读**，别让人以为能改
    private var viewingOlder: LocalTask? {
        guard let id = app.timelineDisplayTaskID, shot.taskIDs.contains(id), id != shot.taskID else { return nil }
        return app.store.task(id: id)
    }

    var body: some View {
        let issues = ShotSubmitRules.issues(shot, app: app)
        HStack(spacing: compact ? 6 : 10) {
            ParamsDivider()
            if let d = viewingOlder {
                HStack(spacing: 10) {
                    Label(d.model.isEmpty ? "未选模型" : d.model, systemImage: "cube")
                    Label(d.resolution?.displayName ?? "—", systemImage: "rectangle.on.rectangle")
                    Label(d.aspectRatio.plainLabel, systemImage: "aspectratio")
                    Label("\(d.duration) 秒", systemImage: "timer")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                VideoParamControls(shot: $shot, compact: compact)
            }
            ParamsDivider()
            Button {
                if issues.isEmpty { app.submitShot(shot.id) } else { showSubmitHint = true }
            } label: {
                Text("提交生成").lineLimit(1).fixedSize()
            }
            .buttonStyle(AccentButtonStyle())
            // 生成中禁用（灰、防连点）：按这条分镜自己的当前任务算，换到别的分镜就按那个分镜重新判定
            .disabled(ShotSubmitRules.isSubmitting(shot, app: app))
            .help(issues.isEmpty ? "提交生成" : "还不满足提交条件（点看原因）")
            .dropdownPopover(isPresented: $showSubmitHint) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill").font(.caption)
                    }
                }
                .padding(12)
            }
        }
    }

}

/// 生视频的四个参数：模型 / 分辨率 / 比例 / 时长。工具条和「编辑提示词」弹窗共用这一份（2026-10-10）
struct VideoParamControls: View {
    @Environment(AppModel.self) private var app
    @Binding var shot: ShotDraft
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            IconDropdown(
                icon: "cube", labelWidth: ParamSlot.model(compact), iconWidth: ParamSlot.icon,
                options: app.videoModelNames.map { DropdownOption(label: $0, value: $0) },
                selection: $shot.model,
                hasModels: !app.videoModelNames.isEmpty,
                emptyHint: "还没有可用的视频模型。请到「设置 → 模型渠道」添加渠道与视频模型。"
            )
            IconDropdown(
                icon: "rectangle.on.rectangle", labelWidth: ParamSlot.second(compact), iconWidth: ParamSlot.icon,
                options: Resolution.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                selection: $shot.resolution
            )
            IconDropdown(
                icon: "aspectratio", labelWidth: ParamSlot.third(compact), iconWidth: ParamSlot.icon,
                options: aspectOptions, selection: $shot.aspectRatio
            )
            ShotDurationChip(shot: $shot, labelWidth: ParamSlot.fourth(compact))
        }
    }

    /// 只列真正的比例档；旧数据的值补进列表，别显示成空白（同右栏原来的口径）
    private var aspectOptions: [DropdownOption<AspectRatio>] {
        var values: [AspectRatio] = [.ratio16x9, .ratio9x16, .ratio1x1, .ratio4x3, .ratio3x4]
        if !values.contains(shot.aspectRatio) { values.append(shot.aspectRatio) }
        return values.map { DropdownOption(label: $0.plainLabel, value: $0) }
    }
}

/// 时长按钮：点开滑块，拖动期间只改按钮上的数字，松手 / 关闭才写回（同右栏原来的 `durationButton`）
private struct ShotDurationChip: View {
    @Binding var shot: ShotDraft
    let labelWidth: CGFloat
    @State private var showPopover = false
    @State private var draft: Int?

    var body: some View {
        Button {
            draft = shot.duration
            showPopover = true
        } label: {
            // 结构和 `IconDropdown` 一样（图标槽 + 4 + 文字槽），宽度才和旁边几个下拉对得齐
            HStack(spacing: 4) {
                Image(systemName: "timer").font(.caption).foregroundStyle(.secondary).frame(width: ParamSlot.icon)
                Text("\(draft ?? shot.duration) 秒")
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: labelWidth, alignment: .center)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverHighlightButtonStyle())
        .dropdownPopover(isPresented: $showPopover, onClose: { commit() }) {
            // 草稿由弹窗内容自己持有（浮层渲染在根视图的 overlay 里，拿不到这里 @State 的变化通知）
            DurationPopoverContent(
                initial: draft ?? shot.duration,
                onLiveChange: { draft = $0 },
                onCommit: { _ in commit() }
            )
        }
    }

    private func commit() {
        if let d = draft, d != shot.duration { shot.duration = d }
        draft = nil
    }
}

// MARK: 生图

private struct ImageToolbarParams: View {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    let compact: Bool
    @State private var submitHint: String?

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            ParamsDivider()
            ImageParamControls(item: item, compact: compact)
            ParamsDivider()
            Button {
                submit()
            } label: {
                Text("提交生成").lineLimit(1).fixedSize()
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(item.status.isBusy)
        }
        .alert("无法生成", isPresented: Binding(get: { submitHint != nil }, set: { if !$0 { submitHint = nil } })) {
            Button("好", role: .cancel) { submitHint = nil }
        } message: {
            Text(submitHint ?? "")
        }
    }

    /// 与右栏原来的提交按钮同一套检查，同一个动作（重新生成后自动回到最新结果）
    private func submit() {
        guard !app.imageModelNames.isEmpty else {
            submitHint = "请先到设置里添加图片模型"
            return
        }
        if let model = item.model, !model.isEmpty, !app.imageModelNames.contains(model) {
            submitHint = "请先重新选择当前可用的图片模型"
            return
        }
        guard !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            submitHint = "请先填写提示词"
            return
        }
        submitHint = nil
        app.applyImageResult(item.id, resultID: nil)
        app.requestImageGeneration(item.id)
    }
}

/// 生图的四个参数：模型 / 类型 / 比例 / 质量。工具条和「编辑提示词」弹窗共用这一份（2026-10-10）
struct ImageParamControls: View {
    @Environment(AppModel.self) private var app
    let item: ImageGenItem
    let compact: Bool

    private var modelBinding: Binding<String> {
        Binding(
            get: { item.model.flatMap { $0.isEmpty ? nil : $0 } ?? app.imageModelNames.first ?? "" },
            set: { app.updateImageItemModel(item.id, model: $0) }
        )
    }
    private var typeBinding: Binding<ImageSubjectType?> {
        Binding(get: { item.type }, set: { app.updateImageItemType(item.id, type: $0) })
    }
    private var aspectBinding: Binding<ImageAspect> {
        Binding(get: { item.aspectRatio }, set: { app.updateImageItemAspect(item.id, aspect: $0) })
    }
    private var qualityBinding: Binding<ImageQuality> {
        Binding(get: { item.quality }, set: { app.updateImageItemQuality(item.id, quality: $0) })
    }

    private let typeOptions: [DropdownOption<ImageSubjectType?>] = [
        DropdownOption(label: "默认", value: nil),
        DropdownOption(label: "角色", value: .character),
        DropdownOption(label: "场景", value: .scene),
        DropdownOption(label: "道具", value: .prop),
    ]

    var body: some View {
        HStack(spacing: compact ? 6 : 10) {
            IconDropdown(
                icon: "cube", labelWidth: ParamSlot.model(compact), iconWidth: ParamSlot.icon,
                options: app.imageModelNames.map { DropdownOption(label: $0, value: $0) },
                selection: modelBinding,
                hasModels: !app.imageModelNames.isEmpty,
                emptyHint: "还没有可用的图片模型，请到设置里添加模型。"
            )
            IconDropdown(icon: "tag", labelWidth: ParamSlot.second(compact), iconWidth: ParamSlot.icon,
                         options: typeOptions, selection: typeBinding)
            IconDropdown(
                icon: "aspectratio", labelWidth: ParamSlot.third(compact), iconWidth: ParamSlot.icon,
                options: ImageAspect.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                selection: aspectBinding
            )
            IconDropdown(
                icon: "sparkles", labelWidth: ParamSlot.fourth(compact), iconWidth: ParamSlot.icon,
                options: ImageQuality.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                selection: qualityBinding
            )
        }
    }
}
