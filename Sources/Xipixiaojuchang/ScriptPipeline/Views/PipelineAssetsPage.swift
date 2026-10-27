import SwiftUI

struct PipelineAssetsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let archive: ProjectPipelineArchive
    let episodeIndex: Int
    var onBusyChanged: (Bool) -> Void = { _ in }

    @State private var kind = "角色"
    @State private var selectedID: UUID?
    @State private var draftName = ""
    @State private var draftDescription = ""
    @State private var model = ""
    @State private var type: ImageSubjectType? = .character
    @State private var aspect: ImageAspect = .ratio16x9
    @State private var quality: ImageQuality = .k2
    private var running: Bool {
        app.pipelineFlow.active(project: app.currentProjectKey ?? "", episode: work?.id)
    }
    @State private var parsing = false
    @State private var editingPrompt = false
    @State private var addingAsset = false
    @State private var errorMessage = ""
    @State private var showError = false

    private var live: ProjectPipelineArchive {
        app.currentPipelineArchive.flatMap { $0.projectId == archive.projectId ? $0 : nil } ?? archive
    }
    private var work: SimpleEpisodeWork? {
        guard live.episodes.indices.contains(episodeIndex) else { return nil }
        return SimplePipeline.work(in: live, index: episodeIndex)
    }
    private var filtered: [SimplePipelineAsset] { work?.assets.filter { $0.kind == kind } ?? [] }
    private var selected: SimplePipelineAsset? { filtered.first { $0.id == selectedID } ?? filtered.first }
    private var item: ImageGenItem? {
        guard let selected, let key = app.currentProjectKey else { return nil }
        return PipelineAssetImageRules.item(for: selected, projectKey: key, items: app.imageItems)
    }
    private var result: ImageGenResult? {
        guard let item else { return nil }
        return item.results.first { $0.id == item.selectedResultID } ?? item.latestResult
    }
    private var imagePath: String? {
        if let path = result?.localPath { return path }
        if let id = selected?.libraryItemID { return app.libraryItem(id)?.existingLocalImageURL?.path }
        return nil
    }
    private var generating: Bool { item?.status.isBusy == true }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ForEach(["场景", "角色", "道具"], id: \.self) { category in
                    Button {
                        kind = category
                        selectedID = nil
                    } label: {
                        Text(category)
                            .font(.callout.weight(category == kind ? .semibold : .regular))
                            .frame(width: 70, height: PipelinePageLayout.headerContentHeight)
                            .background(category == kind ? SolidTheme.hover(colorScheme) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(editingPrompt)
                    .accessibilityIdentifier("pipeline-assets-kind-\(category)")
                }
                Spacer()
                Button("批量解析") { parsing = true }
                    .buttonStyle(OutlineButtonStyle()).disabled(running || editingPrompt)
                    .accessibilityIdentifier("pipeline-assets-parse")
                Button("批量提取") { extract() }
                    .buttonStyle(AccentButtonStyle()).disabled(work == nil || running || editingPrompt || generating)
                    .accessibilityIdentifier("pipeline-assets-extract")
                    .pipelineActivityGlow(running)
            }
            .pipelineHeaderLayout()
            .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
            HStack(spacing: 14) {
                assetList.frame(width: 150)
                if let selected {
                    descriptionCard(selected).frame(maxWidth: .infinity)
                    previewCard(selected).frame(maxWidth: .infinity)
                } else {
                    Text(running ? "正在提取素材…" : "暂无\(kind)")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .onChange(of: selected?.id, initial: true) { _, _ in loadDraft() }
        .onChange(of: running) { _, active in if !active { loadDraft() } }
        .onChange(of: live.episodes.indices.contains(episodeIndex) ? live.episodes[episodeIndex].id : nil) { _, _ in
            selectedID = nil
            loadDraft()
        }
        .onDisappear { DropdownPanel.shared.dismiss() }
        .appModal(isPresented: $addingAsset, width: 620) {
            PipelineNewAssetEditor(kind: kind, onSave: { name, prompt in
                guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var next = work else { return }
                let value = SimplePipelineAsset(kind: kind, name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: prompt)
                next.assets.append(value)
                SimplePipeline.save(next, to: &latest)
                app.savePipelineArchive(latest, for: key)
                selectedID = value.id
                loadDraft()
                addingAsset = false
            }, onClose: { addingAsset = false })
        }
        .appModal(isPresented: $parsing, width: 520, height: 340) {
            BatchImageParseView(onClose: { parsing = false }, onParse: parse)
        }
        .appModal(isPresented: $editingPrompt, width: 620) {
            if let selected {
                EditImagePromptSheet(
                    item: item ?? ImageGenItem(type: ImageSubjectType.from(kind: selected.kind), name: selected.name,
                                               prompt: selected.description),
                    onClose: { editingPrompt = false; loadDraft() },
                    onSave: { prompt in
                        draftDescription = prompt
                        return saveDraftDescription()
                    },
                    showsMaterialSection: item != nil
                )
            }
        }
        .alert("提示", isPresented: $showError) { Button("好", role: .cancel) {} } message: { Text(errorMessage) }
    }

    private var assetList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filtered) { asset in
                    HStack(spacing: 4) {
                    Button {
                        selectedID = asset.id
                        loadDraft()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(asset.name).font(.callout).lineLimit(2)
                            Text(status(for: asset)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(selected?.id == asset.id ? SolidTheme.hover(colorScheme) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(editingPrompt)
                    .accessibilityIdentifier("pipeline-asset-\(asset.id)")
                    Button { removeAsset(asset.id) } label: {
                        Image(systemName: "trash").frame(width: 24, height: 32).contentShape(Rectangle())
                    }.buttonStyle(QuietButtonStyle()).disabled(running || editingPrompt || generating)
                        .accessibilityLabel("删除\(asset.name)")
                    }
                }
                PipelineAddPlaceholder(action: addAsset)
                    .disabled(work == nil || running || editingPrompt)
                    .accessibilityIdentifier("pipeline-assets-add")
            }.padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private func descriptionCard(_ asset: SimplePipelineAsset) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(asset.name).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer()
                Button("重新提取") { reextract() }
                    .buttonStyle(OutlineButtonStyle()).disabled(selected == nil || generating || running)
                    .accessibilityIdentifier("pipeline-assets-reextract")
            }
            ScrollView {
                Text(draftDescription)
                    .font(.system(size: 14)).lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .accessibilityIdentifier("pipeline-assets-description")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { if !generating && !running { editingPrompt = true } }
            .help("单击编辑提示词")
            imageParameters
                .disabled(generating || running)
            Button {
                guard !app.imageModelNames.isEmpty, app.imageModelNames.contains(model) else {
                    fail("请先选择可用的图片模型。"); return
                }
                guard let id = saveDraft(createImageItem: true) else { return }
                app.requestImageGeneration(id)
            } label: {
                Text("提交生成").padding(.vertical, 5.5).frame(maxWidth: .infinity)
            }
            .buttonStyle(AccentButtonStyle()).disabled(generating || running)
            .accessibilityIdentifier("pipeline-assets-submit")
        }
        .padding(.horizontal, 20)
        .padding(.top, PipelinePageLayout.panelTopInset)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private var imageParameters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconDropdown(icon: "cube", labelWidth: 70,
                             options: app.imageModelNames.map { DropdownOption(label: $0, value: $0) },
                             selection: $model, fillsRow: true, hasModels: !app.imageModelNames.isEmpty,
                             emptyHint: "请到设置里添加图片模型。")
                IconDropdown(icon: "tag", labelWidth: 42,
                             options: [DropdownOption<ImageSubjectType?>(label: "默认", value: nil),
                                       .init(label: "角色", value: .character), .init(label: "场景", value: .scene),
                                       .init(label: "道具", value: .prop)], selection: $type, fillsRow: true)
            }
            HStack(spacing: 8) {
                IconDropdown(icon: "aspectratio", labelWidth: 40,
                             options: ImageAspect.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                             selection: $aspect, fillsRow: true)
                IconDropdown(icon: "sparkles", labelWidth: 40,
                             options: ImageQuality.allCases.map { DropdownOption(label: $0.displayName, value: $0) },
                             selection: $quality, fillsRow: true)
            }
        }
    }

    private func previewCard(_ asset: SimplePipelineAsset) -> some View {
        VStack(spacing: 12) {
            HStack {
                StatusCapsule(title: previewStatus.title, color: previewStatus.color)
                Text((item?.type ?? ImageSubjectType.from(kind: asset.kind))?.displayName ?? "默认")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                Spacer()
                Text("共 \(item?.results.count ?? 0) 版").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(SolidTheme.inset(colorScheme))
                        if item?.status == .generating {
                            GenerationProgressView(progress: 0)
                        } else if item?.status == .downloading {
                            Text("正在下载图片").font(.caption).foregroundStyle(.secondary)
                        } else if item?.status == .failed {
                            VStack(spacing: 6) {
                                Image(systemName: "xmark.circle").font(.title2).foregroundStyle(Theme.danger)
                                Text("生成失败").font(.caption)
                                if let message = item?.errorMessage {
                                    Text(Formatters.errorSummary(message)).font(.caption2)
                                        .foregroundStyle(Theme.danger).lineLimit(3).help(message)
                                }
                            }.padding(12)
                        } else if let imagePath {
                            AsyncFullImage(path: imagePath, wheelZooms: false, cornerRadius: 14).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "photo")
                                Text("暂无图片").font(.caption)
                            }.foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("pipeline-assets-preview")
                    historyVersions
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                Button("保存到素材库") { saveImage() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(result == nil || item?.type == nil || generating || app.isImageResultSaved(result?.id))
                    .accessibilityIdentifier("pipeline-assets-library")
                Button("在访达中显示") {
                    guard let imagePath else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: imagePath)])
                }
                .buttonStyle(OutlineButtonStyle())
                .disabled(imagePath == nil || !FileManager.default.fileExists(atPath: imagePath ?? ""))
                .accessibilityIdentifier("pipeline-assets-finder")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, PipelinePageLayout.panelTopInset)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SolidTheme.card(colorScheme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SolidTheme.cardStroke(colorScheme)))
    }

    private var previewStatus: (title: String, color: Color) {
        switch item?.status {
        case .queued: ("排队中", Theme.warning)
        case .generating: ("生成中", Theme.accent)
        case .downloading: ("下载中", Theme.accent)
        case .failed: ("失败", Theme.danger)
        case .success: ("已完成", Theme.success)
        default: (imagePath == nil ? "待生成" : "已完成", imagePath == nil ? .secondary : Theme.success)
        }
    }

    private var historyVersions: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if let item, !item.versionEntries.isEmpty {
                    // 最新的在前，失败的那几次也是一版（2026-10-16 和生视频、生图页统一）
                    ForEach(item.versionEntries.reversed()) { entry in
                        let picked = item.viewingFailureID.map { $0 == entry.id } ?? (entry.result != nil && result?.id == entry.id)
                        Button {
                            if let failure = entry.failure {
                                app.applyImageFailure(item.id, failureID: failure.id)
                            } else {
                                app.applyImageResult(item.id, resultID: entry.id)
                            }
                            loadDraft()
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let version = entry.result {
                                        AsyncThumbImage(path: version.localPath, contentMode: .fit)
                                    } else {
                                        Image(systemName: "xmark.circle").foregroundStyle(Theme.danger)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 6))
                                HStack(spacing: 3) {
                                    Text("第 \(entry.number) 版")
                                    if entry.failure != nil { Text("失败").foregroundStyle(Theme.danger) }
                                }
                                .font(.caption2)
                            }
                            .padding(5)
                            .background(picked ? SolidTheme.hover(colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(picked ? Theme.accent : .clear))
                        }
                        .buttonStyle(QuietButtonStyle()).disabled(generating || editingPrompt)
                        .help(entry.failure.map { "失败：\($0.error)（点一下换回这一次的提示词和参数）" } ?? "")
                    }
                } else {
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 6).fill(SolidTheme.inset(colorScheme))
                            .frame(width: 64, height: 64)
                            .overlay(Text("暂无任务").font(.caption2).foregroundStyle(.tertiary))
                        Text("第 1 版").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(5)
                }
            }
        }.scrollIndicators(.hidden)
    }

    private func loadDraft() {
        guard let selected else { draftName = ""; draftDescription = ""; return }
        draftName = selected.name
        draftDescription = item?.prompt ?? selected.description
        model = item?.model ?? app.defaultImageModel ?? app.imageModelNames.first ?? ""
        type = item?.type ?? ImageSubjectType.from(kind: selected.kind)
        aspect = item?.aspectRatio ?? app.defaultImageAspect.flatMap(ImageAspect.init(rawValue:)) ?? .ratio16x9
        quality = item?.quality ?? app.defaultImageQuality.flatMap(ImageQuality.init(rawValue:)) ?? .k2
    }

    @discardableResult
    private func saveDraft(createImageItem: Bool = false) -> UUID? {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, let selected, var work,
              let index = work.assets.firstIndex(where: { $0.id == selected.id }) else { return nil }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("素材名称和描述不能为空。"); return nil
        }
        let existing = item
        let oldName = selected.name
        work.assets[index].name = name
        work.assets[index].description = draftDescription
        // 改名才需要手动失效引用它的段落（并同步段内绑定名）；描述/图片变化由“按段输入键”在推理时精确失效。
        if name != oldName {
            for i in work.segments.indices {
                guard work.segments[i].assetNames.contains(oldName) || work.segments[i].text.contains(oldName) else { continue }
                work.segments[i].continuityKey = ""
                work.segments[i].assetNames = work.segments[i].assetNames.map { $0 == oldName ? name : $0 }
            }
        }
        if let existing { work.assets[index].imageItemID = existing.id }
        if createImageItem || existing != nil {
            work.assets[index].imageItemID = app.savePipelineAssetImage(work.assets[index], model: model,
                                                                      aspect: aspect, quality: quality, type: type)
        }
        SimplePipeline.save(work, to: &latest)
        app.savePipelineArchive(latest, for: key)
        guard app.pipelineArchive(for: key) == latest else { fail("保存失败，请重试。"); return nil }
        return work.assets[index].imageItemID
    }

    private func saveDraftDescription() -> Bool {
        guard !draftDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("提示词不能为空。"); return false
        }
        _ = saveDraft()
        return selected?.description == draftDescription
    }

    private func saveImage() {
        guard let item, let result, let key = app.currentProjectKey,
              item.projectKey == key, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId,
              let id = app.saveImageItemToLibrary(item.id, resultID: result.id),
              let selected, var work, let index = work.assets.firstIndex(where: { $0.id == selected.id }) else { return }
        work.assets[index].libraryItemID = id
        SimplePipeline.save(work, to: &latest)
        app.savePipelineArchive(latest, for: key)
    }

    private func status(for asset: SimplePipelineAsset) -> String {
        guard let key = app.currentProjectKey,
              let item = PipelineAssetImageRules.item(for: asset, projectKey: key, items: app.imageItems) else {
            return asset.libraryItemID == nil ? "暂无图片" : "已有图片"
        }
        switch item.status {
        case .queued: return "排队中"
        case .generating: return "生成中"
        case .downloading: return "下载中"
        case .failed: return "生成失败"
        default: return item.results.isEmpty ? "暂无图片" : "已有图片"
        }
    }

    private func parse(_ text: String) -> Bool {
        let values = ImagePromptParser.parse(text)
        guard !values.isEmpty else { fail("没有识别到场景、角色或道具描述。"); return false }
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive,
              latest.projectId == archive.projectId, var work else { return false }
        PipelineAssetImageRules.appendParsed(values, to: &work)
        SimplePipeline.save(work, to: &latest)
        app.savePipelineArchive(latest, for: key)
        return app.pipelineArchive(for: key) == latest
    }

    private func extract() {
        guard let key = app.currentProjectKey else { return }
        app.pipelineFlow.extract(app: app, project: key, episodeIndex: episodeIndex)
    }

    private func reextract() {
        guard let key = app.currentProjectKey, let selected else { return }
        app.pipelineFlow.reextractAsset(app: app, project: key, episodeIndex: episodeIndex, assetID: selected.id)
    }

    private func addAsset() {
        addingAsset = true
    }

    private func removeAsset(_ id: UUID) {
        guard let key = app.currentProjectKey, var latest = app.currentPipelineArchive, var work,
              let removed = work.assets.first(where: { $0.id == id }) else { return }
        work.assets.removeAll { $0.id == id }
        // 段落里残留的被删名字一并清掉（2026-10-06）：避免 JSON 里留旧名、匹配时悄悄少素材。
        for i in work.segments.indices {
            work.segments[i].assetNames.removeAll { $0 == removed.name }
        }
        SimplePipeline.save(work, to: &latest)
        app.savePipelineArchive(latest, for: key)
        selectedID = nil
        loadDraft()
    }

    private func fail(_ message: String) { errorMessage = message; showError = true }
}
