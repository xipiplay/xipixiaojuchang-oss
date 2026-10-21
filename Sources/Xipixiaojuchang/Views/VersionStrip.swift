import SwiftUI

/// 大图 / 视频大预览右边那一列历史版本（2026-10-14 用户：「点历史版本改成和生图、生视频右侧详情的历史版本同样功能」，
/// 因为以后要把生视频并进工作台，换版本主要在大预览里做）。
/// **单独一条，贴在预览弹窗外面右边**（用户：「大图是大图，历史版本是历史版本」，放进弹窗里把大图挤小了）；第一版就显示。
///
/// - 点一下 = 右栏历史版本同一个动作：设为当前版本，那一版的提示词和参数一起搬回卡片（调用方传 `onSelect`）；
///   不分「正在看」和「当前」——描边的就是当前版本。
/// - 顺序和右栏一样：旧的在上、新的在下；打开时滚到当前那一版。
/// - 没有图 / 视频的版本（生成中、失败）也列出来，标上状态；失败的点不了，生成中的点得了
///   （2026-10-15 用户：点了别的版本再关掉弹窗，就看不到还有一版在生成了——得能点回来，大预览左边显示生成进度）。
/// - 不绑键盘：点一下会改掉卡片上的提示词和参数，键盘太容易误触。
struct VersionStrip<ID: Hashable>: View {
    struct Entry: Identifiable {
        let id: ID
        /// 「第 N 版」的 N
        let number: Int
        /// 缩略图；nil = 没有图 / 视频（用 `note` 说明）
        let thumbnail: AnyView?
        /// 「生成中」「失败」之类；有图的版本是 nil
        var note: String? = nil
        /// 没有图也能点（生成中 / 下载中）；false = 有图才能点
        var selectableWithoutThumbnail = false
        /// 版本名换成别的字（「待生成」）；nil = 「第 N 版」
        var label: String? = nil
        /// 悬停时的说明（失败原因）
        var detail: String? = nil

        var selectable: Bool { thumbnail != nil || selectableWithoutThumbnail }
    }

    let entries: [Entry]
    let current: ID?
    let onSelect: (ID) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(entries) { entry in
                        row(entry)
                            .id(entry.id)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard let current else { return }
                DispatchQueue.main.async { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .frame(width: VersionStripLayout.width)
    }

    private func row(_ entry: Entry) -> some View {
        let selected = entry.id == current
        let usable = entry.selectable
        return Button {
            if !selected { onSelect(entry.id) }
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let thumbnail = entry.thumbnail {
                        thumbnail
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.insetFill)
                            .overlay {
                                Text(entry.note ?? "暂无")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 120, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(entry.label ?? "第 \(entry.number) 版")
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 10).fill(
                selected ? Theme.accent.opacity(0.14) : Color.secondary.opacity(0.06)
            ))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(QuietButtonStyle())
        // 当前那一版不变灰（还在下载 / 失败也要看得出是它）；点它本来就什么都不做
        .disabled(!usable && !selected)
        .help(entry.detail.map { "失败：\($0)" } ?? (usable ? (selected ? "当前版本" : "设为当前版本（提示词和参数换回这一版）") : (entry.note ?? "这一版没有可看的内容")))
    }
}

enum VersionStripLayout {
    /// 版本列的宽度
    static let width: CGFloat = 150
    /// 和预览弹窗之间的空隙
    static let gap: CGFloat = 12
}

/// 生图大图右边那一条：这张卡的所有版本（成功的图 + 失败的那几次，2026-10-16 和生视频统一：最新的在上、失败的也能点）。
/// 点图 = 生图右栏「历史版本」（`applyImageResult`），大图跟着换；点失败的 = 换回那一次的提示词和参数，大图写失败原因
struct ImageVersionColumn: View {
    @Environment(AppModel.self) private var app
    let itemID: UUID

    var body: some View {
        if let item = app.imageItems.first(where: { $0.id == itemID }), !item.versionEntries.isEmpty {
            VersionStrip(
                entries: item.versionEntries.reversed().map { entry in
                    if let failure = entry.failure {
                        return VersionStrip.Entry(id: entry.id, number: entry.number, thumbnail: nil, note: "失败",
                                                  selectableWithoutThumbnail: true, detail: failure.error)
                    }
                    let result = entry.result
                    return VersionStrip.Entry(id: entry.id, number: entry.number,
                                              thumbnail: result?.localPath.map { AnyView(AsyncThumbImage(path: $0)) },
                                              note: result?.localPath == nil ? "没有图" : nil)
                },
                // 大图现在显示的那一版（和 `ImagePreviewSheet.selectedResult` 同一个口径）；在看失败的那一版就是它
                current: item.viewingFailureID
                    ?? item.results.first(where: { $0.id == app.previewingImageResultID })?.id ?? item.latestResult?.id,
                onSelect: { id in
                    if item.failures.contains(where: { $0.id == id }) {
                        app.applyImageFailure(itemID, failureID: id)
                    } else {
                        app.applyImageResult(itemID, resultID: id)
                        app.previewingImageResultID = id
                    }
                })
        }
    }
}

/// 视频大预览右边那一条：这张分镜卡的每一次生成。点一下 = 生视频右栏「历史版本」（`applyVersion`），左边改播那一版
struct ShotVersionColumn: View {
    @Environment(AppModel.self) private var app
    let shotID: UUID

    var body: some View {
        if let shot = app.shots.first(where: { $0.id == shotID }), !shot.taskIDs.isEmpty {
            VersionStrip(entries: entries(shot), current: shot.showsPendingVersion ? Self.pendingID : shot.taskID) { taskID in
                if taskID == Self.pendingID {
                    app.applyPendingVersion(shotID: shotID)
                } else {
                    app.applyVersion(shotID: shotID, taskID: taskID)
                }
                app.timelineDisplayTaskID = nil
            }
        }
    }

    /// 「待生成」那一格的 ID（不是任务号）
    static let pendingID = "pending-version"

    /// 和工作台二级页面「历史版本」同一套（2026-10-16 用户：工作台和生视频侧对不上）：最新的在上、「待生成」最上面；
    /// 版本号按文件名；没有本地视频的写状态；生成中 / 下载中 / 失败的都点得了（失败的：左边写失败原因，提示词换回那一版改了再交）
    private func entries(_ shot: ShotDraft) -> [VersionStrip<String>.Entry] {
        let versions = shot.taskIDs.compactMap { id -> VersionStrip<String>.Entry? in
            guard let task = app.store.task(id: id) else { return nil }
            let number = task.versionNumber(in: shot.taskIDs)
            if let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) {
                return .init(id: id, number: number, thumbnail: AnyView(VideoThumbnailView(path: path)))
            }
            let note: String
            switch task.phase {
            case .failed: note = "失败"
            case .completed: note = task.errorMessage == nil ? "下载中" : "下载失败"
            default: note = "生成中"
            }
            return .init(id: id, number: number, thumbnail: nil, note: note, selectableWithoutThumbnail: note != "下载失败",
                         detail: task.phase == .failed ? task.errorMessage : nil)
        }
        let pending: [VersionStrip<String>.Entry] = shot.hasPendingVersion
            // 重新推理出来、还没生成的那一版（2026-10-15 用户）：排最上面，点了就是当前版本
            ? [.init(id: Self.pendingID, number: 0, thumbnail: nil, note: "还没生成视频", selectableWithoutThumbnail: true, label: "待生成")]
            : []
        return pending + versions.reversed()
    }
}
