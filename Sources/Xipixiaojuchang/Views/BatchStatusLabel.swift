import SwiftUI

/// 批量操作（批量分割 / 提取素材）的进度和结果，放在软件右上角（标题栏那一行、项目名的右边）。
/// 跑的时候：转圈 +「批量分割 12/60」；跑完：分割显示「成功几集、失败几集」，提取显示「新建几张卡片」。
/// 跑完后点一下：没有失败、没有提醒就直接收起；有失败会弹出失败的原因，有提醒（提取素材的名字对不上等）也会弹出，里面可以清除。
struct BatchStatusLabel: View {
    @Environment(AppModel.self) private var app
    let project: String
    @State private var showFailures = false

    var body: some View {
        if let state = app.pipelineFlow.batches[project] {
            if state.finished {
                TopBarButton { handleTap(state) } label: {
                    HStack(spacing: 6) {
                        ForEach(Array(summary(state).enumerated()), id: \.offset) { _, part in
                            Text(part.text).foregroundStyle(part.failure ? Theme.danger : Color.secondary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
                .dropdownPopover(isPresented: $showFailures) {
                    BatchFailuresPanel(state: state) {
                        DropdownPanel.shared.dismiss()
                        app.pipelineFlow.clearBatch(project: project)
                    }
                }
                .accessibilityIdentifier("batch-status")
            } else {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("\(state.title) \(state.completed)/\(state.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .accessibilityIdentifier("batch-status")
            }
        }
    }

    private func handleTap(_ state: PipelineFlow.BatchState) {
        if state.failures.isEmpty, state.notes.isEmpty {
            app.pipelineFlow.clearBatch(project: project)
        } else {
            showFailures.toggle()
        }
    }

    /// 跑完后显示的几段字（红色的是失败）
    private func summary(_ state: PipelineFlow.BatchState) -> [(text: String, failure: Bool)] {
        var parts: [(String, Bool)] = []
        switch state.kind {
        case .split:
            parts.append(("成功 \(state.succeeded) 集", false))
            if !state.failures.isEmpty { parts.append(("失败 \(state.failures.count) 集", true)) }
        case .naming:
            parts.append(("分段命名：成功 \(state.succeeded) 集", false))
            if !state.failures.isEmpty { parts.append(("失败 \(state.failures.count) 集", true)) }
            if state.skipped > 0 { parts.append(("未跑 \(state.skipped) 集", false)) }
        case .infer:
            parts.append(("推理分镜：成功 \(state.succeeded) 集（\(state.created) 张卡）", false))
            if !state.failures.isEmpty { parts.append(("失败 \(state.failures.count) 集", true)) }
            if state.skipped > 0 { parts.append(("未跑 \(state.skipped) 集", false)) }
        case .extract:
            parts.append(("提取素材：新建 \(state.created) 张卡片", false))
            if !state.failures.isEmpty {
                parts.append(("失败：" + state.failures.sorted { $0.order < $1.order }.map(\.label).joined(separator: "、"), true))
            }
            if !state.notes.isEmpty { parts.append(("\(state.notes.count) 条提醒", false)) }
        }
        return parts
    }
}

/// 点右上角的结果，有失败时弹出：每一项失败的原因
struct BatchFailuresPanel: View {
    let state: PipelineFlow.BatchState
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.failures.isEmpty ? "\(state.title)：\(state.notes.count) 条提醒" : "\(state.title)：\(state.failures.count) 项没成功")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(state.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(state.failures.sorted { $0.order < $1.order }.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.label).font(.system(size: 12.5, weight: .medium))
                            Text(Formatters.errorSummary(failure.message))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("清除", action: onClear).buttonStyle(AccentButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
