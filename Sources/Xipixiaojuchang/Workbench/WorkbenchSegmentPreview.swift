import SwiftUI
import AVFoundation

/// 二级页面右上「本段预览」（2026-10-15 用户给的新布局）：在页面里直接播这一段的当前版本，不用再弹大预览。
/// 打开时停在第一帧不自动播（翻段时不突然出声）；播放条和大预览同一个（`VideoControlBar`）。
/// 全屏按钮 = 打开大预览（大窗口播放，能切版本、能再全屏）；关掉回到这里（2026-10-15 用户：单独写的全屏窗口试过，还是换回大预览）
/// 当前版本失败 / 生成中 / 下载中 / 待生成 / 还没生成：画面位置写状态（失败带原因），去「历史版本」能切回前面的。
struct SegmentInlinePlayer: View {
    @Environment(AppModel.self) private var app
    let shotID: UUID

    @State private var player: AVPlayer?
    @State private var loadedPath: String?

    private var shot: ShotDraft? { app.shots.first { $0.id == shotID } }
    private var task: LocalTask? { shot?.taskID.flatMap { app.store.task(id: $0) } }
    private var videoPath: String? {
        guard let path = task?.localVideoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82))
            if let player, let videoPath {
                // 先垫首帧封面：播放器图层在解出第一帧之前是透明的，原来会露出黑底黑几帧
                //（2026-10-26 用户录屏：弹窗出来了预览还黑着，内容不同步）。画面同样按比例内缩，出帧后正好盖住它
                VideoThumbnailView(path: videoPath, fitsAspect: true, showsSpinner: false)
                AVPlayerContainer(player: player)
                    // 鼠标移到画面上才出播放条（同大预览）
                    .hoverRevealControls {
                        VideoControlBar(player: player, onToggleFullscreen: openBigPreview, isFullscreen: false)
                    }
            } else {
                placeholder
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { load() }
        .onChange(of: videoPath) { _, _ in load() }
        .onDisappear { player?.pause() }
        .accessibilityIdentifier("workbench-segment-player")
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            if shot?.showsPendingVersion == true {
                Text("待生成").foregroundStyle(.white.opacity(0.7))
                Text("重新推理出来的提示词还没生成视频").font(.caption).foregroundStyle(.white.opacity(0.45))
            } else if let task {
                switch task.phase {
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(Theme.danger)
                    Text("这一版生成失败").foregroundStyle(.white.opacity(0.75))
                    if let raw = task.errorMessage, !raw.isEmpty {
                        Text(Formatters.errorSummary(raw)).font(.caption).foregroundStyle(.white.opacity(0.5))
                            .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 24).help(raw)
                    }
                    Text("改好左边的提示词再点「提交生成」，或在「历史版本」里切回前面的版本").font(.caption).foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                case .completed:
                    if task.errorMessage != nil {
                        Text("视频下载失败").foregroundStyle(.white.opacity(0.7))
                    } else {
                        ProgressView().controlSize(.small)
                        Text("正在下载视频").foregroundStyle(.white.opacity(0.7))
                    }
                default:
                    TaskInProgressView(task: task)
                }
            } else {
                Image(systemName: "film").font(.title3).foregroundStyle(.white.opacity(0.35))
                Text("还没有生成视频").foregroundStyle(.white.opacity(0.55))
            }
        }
        .font(.system(size: 13))
    }

    /// 载入当前版本，停在第一帧。换版本时同一个播放器换片源（同大预览：换绑新播放器有时只剩声音、画面空白）
    private func load() {
        guard let path = videoPath else {
            player?.pause()
            loadedPath = nil
            return
        }
        guard path != loadedPath else { return }
        loadedPath = path
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        if let player {
            player.pause()
            player.replaceCurrentItem(with: item)
            player.seek(to: .zero)
        } else {
            player = AVPlayer(playerItem: item)
        }
    }

    private func openBigPreview() {
        player?.pause()
        ThumbVideoPlayback.shared.stop()
        app.previewingShotID = shotID
    }
}

/// 二级页面右上「历史版本」按钮点开的面板（2026-10-15 用户给的图）：最新的在最上面；每行 缩略图 + 「版本 N」（最新的带「最新」）+ 参数，
/// 右边当前那一版写「当前预览」并描边；点别的哪一行（整行都能点，2026-10-15 用户：不要「预览」按钮）= 设为当前版本
///（提示词和参数一起换回，同大预览的版本列），上面「本段预览」跟着换。
/// 失败的写原因、点不了；生成中 / 下载中的点得了（同版本列）；重新推理出来的「待生成」排最上面
struct SegmentVersionPanel: View {
    @Environment(AppModel.self) private var app
    let shotID: UUID
    let onClose: () -> Void

    private struct Row: Identifiable {
        let id: String
        let number: Int?
        let path: String?
        let detail: String
        let note: String?
        let selectable: Bool
        /// 失败的版本（2026-10-16 用户：点不了）：和别的版本一样能设为当前版本（左边是它的提示词、右边预览写失败原因）；行上也写失败原因
        var failure: String? = nil
    }

    private var shot: ShotDraft? { app.shots.first { $0.id == shotID } }

    private func rows(_ shot: ShotDraft) -> [Row] {
        var rows: [Row] = shot.taskIDs.enumerated().compactMap { offset, id in
            guard let task = app.store.task(id: id) else { return nil }
            let number = task.versionNumber(in: shot.taskIDs)
            let detail = [task.resolution?.displayName, task.aspectRatio.plainLabel, "\(task.duration) 秒"].compactMap { $0 }.joined(separator: " · ")
            if let path = task.localVideoPath, FileManager.default.fileExists(atPath: path) {
                return Row(id: id, number: number, path: path, detail: detail, note: nil, selectable: true)
            }
            switch task.phase {
            case .failed:
                let reason = task.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Row(id: id, number: number, path: nil, detail: detail, note: "失败", selectable: true,
                           failure: (reason?.isEmpty == false ? reason : nil) ?? "没有返回失败原因")
            case .completed: return Row(id: id, number: number, path: nil, detail: detail,
                                        note: task.errorMessage == nil ? "下载中" : "下载失败", selectable: task.errorMessage == nil)
            default: return Row(id: id, number: number, path: nil, detail: detail, note: "生成中", selectable: true)
            }
        }
        rows.reverse()
        if shot.hasPendingVersion {
            rows.insert(Row(id: ShotVersionColumn.pendingID, number: nil, path: nil, detail: "重新推理出来的提示词，还没生成视频",
                            note: nil, selectable: true), at: 0)
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史版本").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .help("关闭")
            }
            if let shot {
                let current = shot.showsPendingVersion ? ShotVersionColumn.pendingID : shot.taskID
                let latest = shot.taskIDs.last
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows(shot)) { row in
                            rowView(row, isCurrent: row.id == current, isLatest: row.id == latest)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 420)
            }
        }
        .padding(14)
        .frame(width: 400)
    }

    private func rowView(_ row: Row, isCurrent: Bool, isLatest: Bool) -> some View {
        Button { if row.selectable, !isCurrent { choose(row.id) } } label: { rowContent(row, isCurrent: isCurrent, isLatest: isLatest) }
            .buttonStyle(QuietButtonStyle(hover: row.selectable && !isCurrent ? .fill(radius: 10) : .none))
            .disabled(!row.selectable && !isCurrent)
            .help(isCurrent ? "当前版本"
                  : row.failure != nil ? "设为当前版本（提示词和参数换回这一版，改好再提交；预览显示失败原因）"
                  : (row.selectable ? "设为当前版本（提示词和参数换回这一版）" : (row.note ?? "")))
    }

    private func rowContent(_ row: Row, isCurrent: Bool, isLatest: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                if let path = row.path {
                    VideoThumbnailView(path: path)
                } else {
                    Image(systemName: "film").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.primary.opacity(0.06))
                }
            }
            .frame(width: 72, height: 40.5)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.number.map { "版本 \($0)" } ?? "待生成").font(.system(size: 13.5, weight: .semibold))
                    if isLatest {
                        Text("最新").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    }
                    if let note = row.note {
                        Text(note).font(.system(size: 11)).foregroundStyle(note == "失败" || note == "下载失败" ? Theme.danger : Color.secondary)
                    }
                }
                Text(row.detail).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let failure = row.failure {
                    Text(failure).font(.system(size: 11)).foregroundStyle(Theme.danger)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("segment-version-failure")
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Text("当前预览").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(isCurrent ? 0.07 : 0.04)))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(isCurrent ? Theme.accent : .clear, lineWidth: 1.5)
        }
        .opacity(row.selectable || isCurrent ? 1 : 0.6)
    }

    private func choose(_ id: String) {
        if id == ShotVersionColumn.pendingID {
            app.applyPendingVersion(shotID: shotID)
        } else {
            app.applyVersion(shotID: shotID, taskID: id)
        }
        app.timelineDisplayTaskID = nil
    }
}
