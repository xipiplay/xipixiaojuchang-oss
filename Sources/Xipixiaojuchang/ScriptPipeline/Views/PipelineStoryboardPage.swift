import SwiftUI

/// 推理分镜页：提示词只读展示，编辑沿用现有分镜编辑弹窗；视频参数和提交沿用现有分镜模型。
struct PipelineStoryboardPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let archive: ProjectPipelineArchive
    let episodeIndex: Int
    var onBusyChanged: (Bool) -> Void = { _ in }

    @State private var selectedSegmentID: UUID?
    @State private var parsing = false
    @State private var editing = false
    @State private var editingShotID: UUID?
    @State private var editingSegmentID: UUID?
    /// "打开弹窗即建卡"的回滚信息：本次编辑弹窗里新建的分镜与其原始段落提示词。
    @State private var createdShotID: UUID?
    @State private var createdShotOriginalPrompt: String?
    @State private var addingPlot = false
    @State private var model = ""
    @State private var resolution: Resolution = .p720
    @State private var aspect: AspectRatio = .ratio16x9
    @State private var duration = 30
    @State private var showDuration = false
    private var running: Bool { app.pipelineFlow.active(project: app.currentProjectKey ?? "", episode: work?.id) }
    @State private var errorMessage = ""
    @State private var showError = false

    private var live: ProjectPipelineArchive { app.currentPipelineArchive.flatMap { $0.projectId == archive.projectId ? $0 : nil } ?? archive }
    private var work: SimpleEpisodeWork? { live.episodes.indices.contains(episodeIndex) ? SimplePipeline.work(in: live, index: episodeIndex) : nil }
    private var segments: [SimplePipelineSegment] { work?.segments ?? [] }
    private var selectedIndex: Int { segments.firstIndex { $0.id == selectedSegmentID } ?? 0 }
    private var selectedSegment: SimplePipelineSegment? { segments.indices.contains(selectedIndex) ? segments[selectedIndex] : nil }
    private var selectedShot: ShotDraft? {
        guard let segment = selectedSegment else { return nil }
        return PipelineStoryboardRules.shot(for: segment, episode: episodeIndex + 1, index: selectedIndex,
                                            projectKey: app.currentProjectKey ?? "", shots: app.shots)
    }
    private var prompt: String { selectedShot?.prompt ?? selectedSegment?.prompt ?? "" }
    private var currentTask: LocalTask? { selectedShot?.taskID.flatMap { app.store.task(id: $0) } }
    private var videoPath: String? { currentTask?.localVideoPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } }
    private var submitting: Bool {
        selectedShot.map { app.submittingShotIDs.contains($0.id) } == true || currentTask?.phase == .queued || currentTask?.phase == .inProgress
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text("\(segments.count) 个段落")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("批量解析") { parsing = true }
                    .buttonStyle(OutlineButtonStyle()).disabled(running)
                    .accessibilityIdentifier("pipeline-storyboard-parse")
                Button("批量推理") { infer() }
                    .buttonStyle(AccentButtonStyle()).disabled(running || segments.isEmpty || submitting)
                    .accessibilityIdentifier("pipeline-storyboard-infer")
                    .pipelineActivityGlow(running)
            }
            .pipelineHeaderLayout()
            .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
            HStack(spacing: 14) {
                segmentList.frame(width: 150)
                promptCard.frame(maxWidth: .infinity)
                previewCard.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .onChange(of: selectedSegmentID, initial: true) { _, _ in loadParameters() }
        .onChange(of: work?.id) { _, _ in selectedSegmentID = nil; loadParameters() }
        .onChange(of: app.activeModal) { old, new in
            if let id = editingShotID, old == .editVideoPrompt(shotID: id), new == nil {
                syncEditedShot(id)
                discardCreatedShotIfUnchanged(id)
            }
        }
        .onDisappear { DropdownPanel.shared.dismiss() }
        .appModal(isPresented: $parsing, width: 520, height: 340) {
            BatchShotParseView(onClose: { parsing = false }, onParse: parse, title: "批量解析")
        }
        .appModal(isPresented: $addingPlot, width: 620) {
            PipelineNewPlotEditor { text in
                guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var next = work else { return }
                let id = PipelineEditingRules.addSegment(to: &next)
                next.segments[next.segments.count - 1].text = text
                SimplePipeline.save(next, to: &latest)
                app.savePipelineArchive(latest, for: key)
                selectedSegmentID = id
                addingPlot = false
            } onClose: { addingPlot = false }
        }
        .alert("提示", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(errorMessage) }
    }

    private var segmentList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 4) {
                        Button { selectedSegmentID = segment.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("第 \(index + 1) 段").font(.callout.weight(index == selectedIndex ? .semibold : .regular))
                                Text(segment.prompt.isEmpty ? "待推理" : "提示词已生成")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                            .background(index == selectedIndex ? SolidTheme.hover(colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("pipeline-storyboard-segment-\(index + 1)")
                        Button { clearPrompt(segment.id) } label: {
                            Image(systemName: "trash").frame(width: 24, height: 32).contentShape(Rectangle())
                        }.buttonStyle(QuietButtonStyle()).disabled(running || submitting)
                            .accessibilityLabel("删除第\(index + 1)段分镜")
                            .accessibilityIdentifier("pipeline-storyboard-delete-\(index + 1)")
                        }
                    }
                    PipelineAddPlaceholder(action: addSegment)
                        .disabled(running || work == nil)
                        .accessibilityIdentifier("pipeline-storyboard-add")
                }.padding(10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectedSegment == nil ? "本段提示词" : "第 \(selectedIndex + 1) 段提示词").font(.title3.weight(.semibold))
                Spacer()
                Button("重新推理") { reinfer() }
                    .buttonStyle(OutlineButtonStyle()).disabled(running || selectedSegment == nil || submitting)
                    .accessibilityIdentifier("pipeline-storyboard-reinfer")
            }
            ScrollView {
                Text(prompt.isEmpty ? "（暂无分镜提示词）" : prompt)
                    .font(.system(size: 14)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if !running && !submitting && selectedSegment != nil { openPromptEditor() } }
            .help("单击编辑提示词")
            videoSettings
            Button { submit() } label: {
                Text("提交生成").padding(.vertical, 5.5).frame(maxWidth: .infinity)
            }.buttonStyle(AccentButtonStyle()).disabled(selectedSegment == nil || running || submitting)
                .accessibilityIdentifier("pipeline-storyboard-submit")
        }
        .padding(.horizontal, 20)
        .padding(.top, PipelinePageLayout.panelTopInset)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private var videoSettings: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconDropdown(icon: "cube", labelWidth: 70,
                             options: app.videoModelNames.map { DropdownOption(label: $0, value: $0) },
                             selection: $model, fillsRow: true, hasModels: !app.videoModelNames.isEmpty,
                             emptyHint: "请到设置里添加视频模型。")
                IconDropdown(icon: "rectangle.on.rectangle", labelWidth: 48,
                             options: Resolution.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                             selection: $resolution, fillsRow: true)
            }
            HStack(spacing: 8) {
                IconDropdown(icon: "aspectratio", labelWidth: 44,
                             options: [AspectRatio.ratio16x9, .ratio9x16, .ratio1x1, .ratio4x3, .ratio3x4]
                                .map { DropdownOption(label: $0.plainLabel, value: $0) },
                             selection: $aspect, fillsRow: true)
                Button { showDuration = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "timer").font(.caption).foregroundStyle(.secondary)
                        Text("\(duration) 秒").font(.callout)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(HoverHighlightButtonStyle())
                .dropdownPopover(isPresented: $showDuration) {
                    DurationPopoverContent(initial: duration, onLiveChange: { duration = $0 }, onCommit: { _ in })
                }
            }
        }
        .disabled(running || submitting)
    }

    private var previewCard: some View {
        VStack(spacing: 12) {
            HStack {
                if let currentTask { StatusBadge(phase: currentTask.phase) }
                else { StatusCapsule(title: submitting ? "排队中" : "待生成", color: .secondary) }
                Text("视频").font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Theme.accent.opacity(0.15), in: Capsule())
                Spacer()
                Text("共 \(selectedShot?.taskIDs.count ?? 0) 版").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(SolidTheme.inset(colorScheme))
                         if submitting { GenerationProgressView(progress: currentTask?.progressPercent ?? 0) }
                        else if let path = videoPath { VideoThumbnailView(path: path, fitsAspect: true) }
                        else { Text(currentTask == nil ? "暂无视频" : currentTask?.phase.displayName ?? "暂无视频").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                    historyVideos
                }
            }.frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Button("播放视频") { if let id = selectedShot?.id { app.previewingShotID = id } }
                    .buttonStyle(AccentButtonStyle()).disabled(videoPath == nil)
                    .accessibilityIdentifier("pipeline-storyboard-play")
                Button("在访达中显示") {
                    if let videoPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: videoPath)]) }
                }.buttonStyle(OutlineButtonStyle()).disabled(videoPath == nil)
                    .accessibilityIdentifier("pipeline-storyboard-finder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, PipelinePageLayout.panelTopInset)
        .padding(.bottom, 20)
        .frame(maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private var historyVideos: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array((selectedShot?.taskIDs ?? []).enumerated()), id: \.element) { index, taskID in
                    let task = app.store.task(id: taskID)
                    Button {
                        guard let shot = selectedShot else { return }
                        app.applyVersion(shotID: shot.id, taskID: taskID)
                        loadParameters()
                    } label: {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6).fill(SolidTheme.inset(colorScheme)).frame(width: 64, height: 64)
                            .overlay { if let path = task?.localVideoPath { VideoThumbnailView(path: path, fitsAspect: true) } }
                        // 版本号按文件名（2026-10-16 所有版本列表统一，见 `LocalTask.versionNumber(in:)`）
                        Text("第 \(task?.versionNumber(in: selectedShot?.taskIDs ?? []) ?? index + 1) 版").font(.caption2)
                    }.padding(5)
                    }.buttonStyle(QuietButtonStyle()).disabled(submitting || running)
                }
                if (selectedShot?.taskIDs ?? []).isEmpty {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6).fill(SolidTheme.inset(colorScheme)).frame(width: 64, height: 64)
                            .overlay(Text("暂无任务").font(.caption2).foregroundStyle(.tertiary))
                        Text("第 1 版").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(5)
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func infer() {
        guard let key = app.currentProjectKey else { return }
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: episodeIndex)
    }

    private func addSegment() {
        addingPlot = true
    }

    private func clearPrompt(_ id: UUID) {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var next = work,
              let index = next.segments.firstIndex(where: { $0.id == id }) else { return }
        let shot = PipelineStoryboardRules.shot(for: next.segments[index], episode: episodeIndex + 1, index: index,
                                               projectKey: key, shots: app.shots)
        if let shot { next.segments[index].shotID = shot.id; app.updateShotPrompt(shot.id, prompt: "") }
        PipelineEditingRules.clearPrompt(id, in: &next)
        SimplePipeline.save(next, to: &latest)
        app.savePipelineArchive(latest, for: key)
    }

    private func loadParameters() {
        model = selectedShot?.model ?? app.defaultVideoModel ?? app.videoModelNames.first ?? ""
        resolution = selectedShot?.resolution ?? app.defaultVideoResolution.flatMap(Resolution.init(rawValue:)) ?? .p720
        aspect = selectedShot?.aspectRatio ?? app.defaultVideoAspect.flatMap(AspectRatio.init(rawValue:)) ?? .ratio16x9
        duration = selectedShot?.duration ?? 30
    }

    private func openPromptEditor() {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work, let segment = selectedSegment else { return }
        var shot = selectedShot ?? ShotDraft(projectKey: key, model: model, prompt: prompt, duration: 30,
                                            aspectRatio: aspect, resolution: resolution,
                                            generateAudio: app.generateAudioDefault, watermark: app.watermarkDefault,
                                            numbering: ShotNumbering(a: episodeIndex + 1, b: selectedIndex + 1))
        if selectedShot == nil {
            createdShotID = shot.id
            createdShotOriginalPrompt = segment.prompt
            // 只关联已经存在的素材库图片；打开编辑器不启动生成或上传。
            for asset in next.assets where segment.assetNames.contains(asset.name) || segment.text.contains(asset.name) {
                let image = PipelineAssetImageRules.item(for: asset, projectKey: key, items: app.imageItems)
                let result = image.flatMap { value in value.results.first { $0.id == value.selectedResultID } ?? value.latestResult }
                let reference = asset.libraryItemID.flatMap { id in app.library.first { $0.id == id && $0.projectKey == key } }
                    ?? app.library.first { $0.projectKey == key && result != nil && $0.imageGenResultID == result?.id }
                if let reference, !shot.imageRefs.contains(where: { $0.libraryItemID == reference.id }) {
                    shot.imageRefs.append(MaterialRef(libraryItemID: reference.id, role: .referenceImage))
                }
            }
            app.shots.append(shot)
            app.persistShots()
            next.segments[selectedIndex].shotID = shot.id
            SimplePipeline.save(next, to: &latest)
            app.savePipelineArchive(latest, for: key)
        } else {
            createdShotID = nil
            createdShotOriginalPrompt = nil
        }
        editingShotID = shot.id
        editingSegmentID = segment.id
        DropdownPanel.shared.dismiss()
        app.activeModal = .editVideoPrompt(shotID: shot.id)
    }

    private func syncEditedShot(_ id: UUID) {
        defer { editingShotID = nil; editingSegmentID = nil; loadParameters() }
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work,
              let index = next.segments.firstIndex(where: { $0.id == editingSegmentID }),
              let shot = app.shots.first(where: { $0.id == id && $0.projectKey == key }),
              next.segments[index].prompt != shot.prompt else { return }
        next.segments[index].prompt = shot.prompt
        next.segments[index].continuityKey = ""
        SimplePipeline.save(next, to: &latest)
        app.savePipelineArchive(latest, for: key)
    }

    /// 回滚"打开弹窗即建卡"：用户没保存修改就关掉编辑弹窗时，撤掉这次新建的空分镜。
    private func discardCreatedShotIfUnchanged(_ id: UUID) {
        guard createdShotID == id, let original = createdShotOriginalPrompt else { return }
        createdShotID = nil
        createdShotOriginalPrompt = nil
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work,
              let index = next.segments.firstIndex(where: { $0.shotID == id }),
              next.segments[index].prompt == original,
              let shot = app.shots.first(where: { $0.id == id && $0.projectKey == key }),
              shot.taskID == nil, shot.taskIDs.isEmpty else { return }
        app.shots.removeAll { $0.id == id }
        app.persistShots()
        next.segments[index].shotID = nil
        SimplePipeline.save(next, to: &latest)
        app.savePipelineArchive(latest, for: key)
    }

    /// 单独重推当前段（"重新推理"）：只重跑这一段的看图与提示词。
    private func reinfer() {
        guard let key = app.currentProjectKey, selectedSegment != nil else { return }
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: episodeIndex, only: selectedIndex)
    }

    private func savePrompt(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("提示词不能为空。"); return false }
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work, selectedSegment != nil else { return false }
        let shot = selectedShot
        next.segments[selectedIndex].prompt = text
        next.segments[selectedIndex].continuityKey = ""
        if let shot { next.segments[selectedIndex].shotID = shot.id }
        SimplePipeline.save(next, to: &latest)
        app.savePipelineArchive(latest, for: key)
        if let shot { app.updateShotPrompt(shot.id, prompt: text) }
        return app.pipelineArchive(for: key) == latest
    }

    private func parse(_ values: [String]) -> Bool {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work else { return false }
        do {
            let linkedShots = next.segments.enumerated().map { index, segment in
                PipelineStoryboardRules.shot(for: segment, episode: episodeIndex + 1, index: index,
                                             projectKey: key, shots: app.shots)
            }
            try PipelineStoryboardRules.apply(values, to: &next)
            for index in next.segments.indices {
                if let shot = linkedShots[index] { next.segments[index].shotID = shot.id }
            }
            SimplePipeline.save(next, to: &latest)
            app.savePipelineArchive(latest, for: key)
            guard app.pipelineArchive(for: key) == latest else { fail("分镜保存失败，请重试。"); return false }
            for (index, segment) in next.segments.enumerated() {
                if let shot = PipelineStoryboardRules.shot(for: segment, episode: episodeIndex + 1, index: index,
                                                          projectKey: key, shots: app.shots) {
                    app.updateShotPrompt(shot.id, prompt: segment.prompt)
                }
            }
            return app.pipelineArchive(for: key) == latest
        } catch { fail(error.localizedDescription); return false }
    }

    private func submit() {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var next = work, let segment = selectedSegment else { return }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("请先填写分镜提示词。"); return }
        guard app.videoModelNames.contains(model) else { fail("请先选择可用的视频模型。"); return }
        var shot = selectedShot ?? ShotDraft(projectKey: key, prompt: prompt, duration: 30,
                                            generateAudio: app.generateAudioDefault, watermark: app.watermarkDefault,
                                            numbering: ShotNumbering(a: episodeIndex + 1, b: selectedIndex + 1))
        shot.model = model
        shot.resolution = resolution
        shot.aspectRatio = aspect
        shot.duration = duration
        let issues = ShotValidator.validate(shot)
        guard issues.isEmpty else { fail(issues.joined(separator: "\n")); return }
        // 软件自动对应当前段使用的素材，不让用户另建制作卡。
        for asset in next.assets where segment.assetNames.contains(asset.name) || segment.text.contains(asset.name) {
            var libraryID = asset.libraryItemID.flatMap { app.libraryItem($0)?.id }
            if libraryID == nil, let image = PipelineAssetImageRules.item(for: asset, projectKey: key, items: app.imageItems),
               let result = image.results.first(where: { $0.id == image.selectedResultID }) ?? image.latestResult {
                libraryID = app.library.first { $0.projectKey == key && $0.imageGenResultID == result.id }?.id
                if libraryID == nil { libraryID = app.saveImageItemToLibrary(image.id, resultID: result.id) }
            }
            if let libraryID, !shot.imageRefs.contains(where: { $0.libraryItemID == libraryID }) {
                shot.imageRefs.append(MaterialRef(libraryItemID: libraryID, role: .referenceImage))
            }
        }
        if let index = app.shots.firstIndex(where: { $0.id == shot.id }) { app.shots[index] = shot }
        else { app.shots.append(shot) }
        app.persistShots()
        next.segments[selectedIndex].shotID = shot.id
        next.segments[selectedIndex].prompt = shot.prompt
        SimplePipeline.save(next, to: &latest)
        app.savePipelineArchive(latest, for: key)
        guard app.pipelineArchive(for: key) == latest else { fail("分镜保存失败，请重试。"); return }
        app.submitShot(shot.id)
    }

    private func fail(_ message: String) { errorMessage = message; showError = true }
}
