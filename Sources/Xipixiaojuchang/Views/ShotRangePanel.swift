import SwiftUI

/// 生视频页「按范围选」的小框（2026-10-27）：哪几集 + 最多几个 + 跳过已完成 / 正在生成的，点「选中」把这些分镜勾上。
/// 只是选；提交照旧点底栏的「批量提交」（先设参数、再确认）。没分集的项目（自由创作）只有后两项
struct ShotRangePanel: View {
    let episodeCount: Int
    /// 按这些条件会选中几个（底部那句话、按钮上的数）
    let count: (ShotRangeSelection.Options) -> Int
    let onPick: (ShotRangeSelection.Options) -> Void
    let onClose: () -> Void

    @State private var allEpisodes = true
    @State private var fromText = "1"
    @State private var toText: String
    @State private var limitText = ""
    @State private var skipsBusyOrDone = true

    init(episodeCount: Int, count: @escaping (ShotRangeSelection.Options) -> Int,
         onPick: @escaping (ShotRangeSelection.Options) -> Void, onClose: @escaping () -> Void) {
        self.episodeCount = episodeCount
        self.count = count
        self.onPick = onPick
        self.onClose = onClose
        _toText = State(initialValue: String(max(1, episodeCount)))
    }

    private var range: ClosedRange<Int>? {
        guard let from = Int(fromText.trimmingCharacters(in: .whitespaces)),
              let to = Int(toText.trimmingCharacters(in: .whitespaces)),
              from >= 1, to >= from, to <= episodeCount else { return nil }
        return from...to
    }

    private var rangeInvalid: Bool { episodeCount > 0 && !allEpisodes && range == nil }

    /// 空 = 不限；填了不是正整数也算填错
    private var limit: Int?? {
        let text = limitText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .some(nil) }
        guard let n = Int(text), n > 0 else { return nil }
        return .some(n)
    }

    private var options: ShotRangeSelection.Options? {
        guard !rangeInvalid, let limit else { return nil }
        return .init(episodes: episodeCount > 0 && !allEpisodes ? range : nil, limit: limit, skipsBusyOrDone: skipsBusyOrDone)
    }

    var body: some View {
        let picked = options.map(count) ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            Text("按范围选").font(.system(size: 15, weight: .semibold))

            if episodeCount > 0 {
                SegmentedBar(options: [("全部集", true), ("指定范围", false)], selection: $allEpisodes)
                    .frame(height: 26)
                if !allEpisodes {
                    HStack(spacing: 8) {
                        Text("从第")
                        TextField("1", text: $fromText).frame(width: 52).multilineTextAlignment(.center)
                        Text("集  到第")
                        TextField("\(episodeCount)", text: $toText).frame(width: 52).multilineTextAlignment(.center)
                        Text("集")
                        Spacer()
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    if rangeInvalid {
                        Text("集号要在 1 到 \(episodeCount) 之间，而且「到」不能小于「从」。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("最多选")
                TextField("不限", text: $limitText).frame(width: 64).multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("shot-range-limit")
                Text("个（按页面上的先后）")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 13))
            if limit == nil {
                Text("「最多选」要填正整数，空着就是不限。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }

            SelectBox(title: "跳过已完成、排队中和正在生成的", isChecked: skipsBusyOrDone) { skipsBusyOrDone.toggle() }

            Text("在当前看得见的分镜里选（状态筛选、搜索都算）。选好后点底栏的「批量提交」：先设参数，再确认。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(options == nil ? "条件没填对" : (picked == 0 ? "没有符合条件的分镜" : "将选中 \(picked) 个"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button("选中 \(picked) 个") {
                    guard let options else { return }
                    onClose()
                    onPick(options)
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(options == nil || picked == 0)
                .accessibilityIdentifier("shot-range-pick")
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
