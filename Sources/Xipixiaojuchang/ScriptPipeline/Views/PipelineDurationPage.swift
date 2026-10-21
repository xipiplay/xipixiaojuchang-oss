import SwiftUI

/// 时长分割页：只处理当前集的剧情段落。
/// 页面卡片位置与剧本分集页一致；素材和分镜在后续页面处理。
struct PipelineDurationPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme

    let archive: ProjectPipelineArchive
    let episodeIndex: Int
    var onBusyChanged: (Bool) -> Void = { _ in }

    @State private var selectedSegmentID: UUID?
    @State private var editing = false
    @State private var adding = false
    @State private var draftText = ""
    private var running: Bool {
        app.pipelineFlow.active(project: app.currentProjectKey ?? "", episode: episode?.id)
    }
    @State private var showError = false
    @State private var errorMessage = ""

    private var liveArchive: ProjectPipelineArchive {
        app.currentPipelineArchive.flatMap { $0.projectId == archive.projectId ? $0 : nil } ?? archive
    }

    private var episode: Episode? {
        liveArchive.episodes.indices.contains(episodeIndex) ? liveArchive.episodes[episodeIndex] : nil
    }

    private var work: SimpleEpisodeWork? {
        guard episode != nil else { return nil }
        return SimplePipeline.work(in: liveArchive, index: episodeIndex)
    }

    private var segments: [SimplePipelineSegment] { work?.segments ?? [] }
    private var selectedIndex: Int { segments.firstIndex { $0.id == selectedSegmentID } ?? 0 }
    private var selectedSegment: SimplePipelineSegment? {
        segments.indices.contains(selectedIndex) ? segments[selectedIndex] : nil
    }

    var body: some View {
        HStack(spacing: 14) {
            segmentList.frame(width: 180)
            plotCard
        }
        .padding(20)
        .onChange(of: episode?.id) { _, _ in
            selectedSegmentID = nil
            editing = false
        }
        .onDisappear { DropdownPanel.shared.dismiss() }
        .appModal(isPresented: $adding, width: 620) {
            PipelineNewPlotEditor(onSave: { text in
                guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var next = work else { return }
                selectedSegmentID = PipelineEditingRules.addSegment(to: &next)
                next.segments[next.segments.count - 1].text = text
                SimplePipeline.save(next, to: &latest)
                app.savePipelineArchive(latest, for: key)
                adding = false
            }, onClose: { adding = false })
        }
        .alert("提示", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage) }
    }

    private var segmentList: some View {
        VStack(spacing: 0) {
            Text("\(segments.count) 个段落")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
            Divider().opacity(0.2)
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 4) {
                        Button { selectedSegmentID = segment.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(index + 1) 段")
                                    .font(.callout.weight(index == selectedIndex ? .semibold : .regular))
                                Text("\(archive.segmentSeconds) 秒").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(index == selectedIndex ? SolidTheme.hover(colorScheme) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(editing)
                        .accessibilityIdentifier("pipeline-duration-segment-\(index + 1)")
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                        Button { remove(segment.id) } label: {
                            Image(systemName: "trash").frame(width: 24, height: 32).contentShape(Rectangle())
                        }.buttonStyle(QuietButtonStyle()).disabled(running || editing)
                            .accessibilityLabel("删除第\(index + 1)段")
                            .accessibilityIdentifier("pipeline-duration-delete-\(index + 1)")
                        }
                    }
                    PipelineAddPlaceholder(action: add)
                        .disabled(running || editing || work == nil)
                        .accessibilityIdentifier("pipeline-duration-add")
                }
                .padding(10)
            }
            .frame(maxHeight: .infinity)
        }
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        .accessibilityIdentifier("pipeline-duration-list")
    }

    private var plotCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(selectedSegment == nil ? "本段剧情" : "第 \(selectedIndex + 1) 段剧情")
                    .font(.title3.weight(.semibold))
                Spacer()
                if editing {
                    Button("取消") { editing = false }.buttonStyle(OutlineButtonStyle())
                        .accessibilityIdentifier("pipeline-duration-edit-cancel")
                    Button("保存") { savePlot() }.buttonStyle(AccentButtonStyle())
                        .accessibilityIdentifier("pipeline-duration-edit-save")
                } else {
                    Button("编辑剧情") {
                        draftText = selectedSegment?.text ?? ""
                        editing = true
                    }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(selectedSegment == nil || running)
                    .accessibilityIdentifier("pipeline-duration-edit")
                    Button("重新生成") { regenerate() }
                        .buttonStyle(AccentButtonStyle())
                        .disabled(episode == nil || running)
                        .pipelineActivityGlow(running)
                        .accessibilityIdentifier("pipeline-duration-regenerate")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider().opacity(0.2)

            Group {
                if running && selectedSegment == nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在分割剧情…").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if editing {
                    TextEditor(text: $draftText)
                        .font(.system(size: 14)).lineSpacing(5)
                        .textEditorStyle(.plain)
                        .padding(16)
                        .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                        .padding(20)
                        .accessibilityIdentifier("pipeline-duration-text-editor")
                } else if let segment = selectedSegment {
                    ScrollView {
                        Text(segment.text)
                            .font(.system(size: 14)).lineSpacing(6)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .accessibilityIdentifier("pipeline-duration-text")
                    }
                } else {
                    Text(episode == nil ? "请先完成剧本分集" : "尚未生成段落")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        .accessibilityIdentifier("pipeline-duration-card")
    }

    private func savePlot() {
        guard let key = app.currentProjectKey, var updated = app.currentPipelineArchive,
              updated.projectId == archive.projectId, var work,
              let segment = selectedSegment else { return }
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("剧情不能为空。"); return
        }
        guard segment.text != draftText, let index = work.segments.firstIndex(where: { $0.id == segment.id }) else {
            editing = false; return
        }
        work.segments[index].text = draftText
        for i in work.segments.indices where i >= index { work.segments[i].continuityKey = "" }
        SimplePipeline.save(work, to: &updated)
        app.savePipelineArchive(updated, for: key)
        guard app.pipelineArchive(for: key) == updated else { fail("剧情保存失败，请重试。"); return }
        editing = false
    }

    private func regenerate() {
        guard let key = app.currentProjectKey else { return }
        app.pipelineFlow.splitDuration(app: app, project: key, episodeIndex: episodeIndex)
    }

    private func add() {
        adding = true
    }

    private func remove(_ id: UUID) {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var work else { return }
        for index in work.segments.indices {
            if let shot = PipelineStoryboardRules.shot(for: work.segments[index], episode: episodeIndex + 1,
                                                      index: index, projectKey: key, shots: app.shots) {
                work.segments[index].shotID = shot.id
            }
        }
        PipelineEditingRules.removeSegment(id, from: &work)
        SimplePipeline.save(work, to: &latest)
        app.savePipelineArchive(latest, for: key)
        selectedSegmentID = work.segments.first?.id
    }

    private func fail(_ message: String) {
        errorMessage = message
        showError = true
    }
}
