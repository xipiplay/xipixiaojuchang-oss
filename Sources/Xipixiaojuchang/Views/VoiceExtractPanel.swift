import SwiftUI

/// 生图页工具条「提取音色」弹出的选择框（2026-10-26）：本项目所有角色卡一张一行，默认勾上还没写文本音色的；
/// 已经有的标「已有」、默认不勾，勾上才覆盖。开始后在后台跑（`PipelineFlow.batchExtractVoices`），结果在右上角。
struct VoiceExtractPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 直接传进来：弹出框是另一个窗口里的 NSHostingView，拿不到外面的环境
    let app: AppModel
    let project: String
    let onClose: () -> Void

    @State private var userNote = ""
    /// 勾选和默认相反的卡：默认勾上「还没有音色」的
    @State private var flipped: Set<UUID> = []

    private var cards: [ImageGenItem] {
        app.imageItems.filter { $0.projectKey == project && $0.type == .character
            && ImageCardNaming.placeholderNumber(of: $0.name) == nil && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func hasVoice(_ card: ImageGenItem) -> Bool { CardVoice.normalizedText(card.voiceText) != nil }

    private func isChecked(_ card: ImageGenItem) -> Bool {
        hasVoice(card) ? flipped.contains(card.id) : !flipped.contains(card.id)
    }

    private func detail(_ card: ImageGenItem) -> String {
        var parts = [hasVoice(card) ? "已有音色" : "还没有音色"]
        if card.voiceAudioID != nil, CardVoice.mode(of: card) == .audio { parts.append("用的是音频") }
        return parts.joined(separator: " · ")
    }

    private var busy: Bool {
        if let running = app.pipelineFlow.batches[project], !running.finished { return true }
        return app.pipelineFlow.active(project: project, slot: "extract-voice")
    }

    var body: some View {
        let all = cards
        let picked = all.filter(isChecked)
        return VStack(alignment: .leading, spacing: 14) {
            Text("提取音色").font(.system(size: 15, weight: .semibold))
            Text("读角色形象和出场原文，给勾选的角色卡写文本音色描述。只写文本，不动绑的音频；卡上选的是音频的照旧用音频。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if all.isEmpty {
                Text("这个项目还没有角色卡。先在工作台做「角色」提取。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                picker(all, checked: picked.count)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("给 AI 的补充要求（可不填，只对这一次生效）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $userNote)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                    if userNote.isEmpty {
                        Text("比如：方言角色写清口音；反派声音更低沉。")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 64)
                .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
            }

            if busy {
                Text("这个项目还有批量任务在跑，等它结束再提取音色。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }

            HStack {
                Text(picked.isEmpty ? "没有勾选角色" : "将给 \(picked.count) 张卡写音色")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("提取 \(picked.count) 个") {
                    let ids = picked.map(\.id)
                    let note = userNote
                    onClose()
                    app.pipelineFlow.batchExtractVoices(app: app, project: project, cardIDs: ids, note: note)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || busy)
                .accessibilityIdentifier("voice-extract-start")
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func picker(_ all: [ImageGenItem], checked: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("给哪些角色写（已勾 \(checked)/\(all.count)）")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    Button("只选还没有的") { flipped = [] }
                    Button("全选") { flipped = Set(all.filter(hasVoice).map(\.id)) }
                    Button("全不选") { flipped = Set(all.filter { !hasVoice($0) }.map(\.id)) }
                }
                .buttonStyle(QuietButtonStyle(hover: .fill(radius: 5)))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(all) { card in
                        Button {
                            if flipped.contains(card.id) { flipped.remove(card.id) } else { flipped.insert(card.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isChecked(card) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isChecked(card) ? Theme.accent : Color.secondary)
                                Text(card.displayName).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(detail(card))
                                    .font(.system(size: 11))
                                    .foregroundStyle(hasVoice(card) ? Color.secondary : Theme.warning)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 240)
            .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        }
    }
}
