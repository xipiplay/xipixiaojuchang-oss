import SwiftUI

/// 提取素材时，选中各集分镜头行里的一个名字（2026-10-10：可以只提取勾选的那几个，不用把整类都重提一遍）
struct ExtractNameChoice: Identifiable, Equatable {
    var id: String { name }
    let name: String
    /// 「第1、2集出场」
    let detail: String
    /// 选中的集里已经有这个名字的卡了
    let hasCard: Bool
}

/// 点「批量分割」「推理分镜」弹出的选择框：全部集，或者从第几集到第几集（第 1 集到第 1 集 = 只做这一集）。
/// 批量分割开始后选中的集同时跑（`PipelineFlow.batchSplit`），推理分镜一集一集串行跑（`PipelineFlow.batchInfer`）。
struct BatchRangePanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    /// 底部那句「将同时分割 N 集」，参数是选中的集数
    let summary: (Int) -> String
    /// 选中的集有问题时的提醒（红字），参数是 0 起的集序号
    let warning: (([Int]) -> String?)?
    let episodeCount: Int
    /// 底部那句话要看具体选了哪几集才能说准时给（比如「将出图 12 张」）；给了就用它，不再用 `summary`
    var rangeSummary: (([Int]) -> String)? = nil
    /// 「开始」按钮上的字（默认「开始」；花钱的步骤写成「出图 12 张」这样一眼能看到数量）
    var startTitle: (([Int]) -> String)? = nil
    /// 项目还没分集时（只有整篇剧本）也让点「开始」：用于提取素材，这时读整篇剧本、`onStart` 收到空数组
    let allowsWholeScript: Bool
    /// 给 AI 打字的框里的提示文字（见 `RerunNote`）；nil = 这一步不调文字 AI（出图 / 匹配 / 生视频），不显示这个框
    var notePlaceholder: String? = nil
    /// 提取素材用：选中的集里有哪些名字可以勾选（参数是 0 起的集序号）。没给 / 给出来是空的 = 不显示勾选区，按原来的整类提取
    var nameChoices: (([Int]) -> [ExtractNameChoice])? = nil
    /// 勾选区里这类素材的叫法（「角色」），用在按钮和底部那句话上
    var nameNoun = "素材"
    /// 勾选区显示时用它开始：参数是 0 起的集序号、补充要求、勾选的名字
    var onStartNames: (([Int], String, Set<String>) -> Void)? = nil
    /// 参数：0 起的集序号，这一次手写的补充要求（没写 = 空串）
    let onStart: ([Int], String) -> Void
    let onClose: () -> Void
    /// 提取素材用：项目的「时代背景」。给了 `onEraCommit` 才显示这一栏；关掉面板时（取消 / 开始都算）把改过的存回项目
    var era = ""
    var onEraCommit: ((String) -> Void)? = nil

    @State private var userNote = ""
    @State private var eraDraft = ""
    /// 勾选和默认相反的名字：默认勾上「还没有卡」的，已经有卡的默认不勾——想重提哪个就勾哪个
    @State private var flipped: Set<String> = []
    @State private var allEpisodes = true
    @State private var fromText = "1"
    @State private var toText: String

    /// `currentEpisode`（0 起）：给了就默认选「指定范围」、只做这一集（工作台的胶囊用，免得点一下就把全部集都跑了）
    init(title: String, summary: @escaping (Int) -> String, warning: (([Int]) -> String?)? = nil,
         episodeCount: Int, allowsWholeScript: Bool = false, currentEpisode: Int? = nil,
         rangeSummary: (([Int]) -> String)? = nil, startTitle: (([Int]) -> String)? = nil, notePlaceholder: String? = nil,
         nameChoices: (([Int]) -> [ExtractNameChoice])? = nil, nameNoun: String = "素材",
         onStartNames: (([Int], String, Set<String>) -> Void)? = nil,
         era: String = "", onEraCommit: ((String) -> Void)? = nil,
         onStart: @escaping ([Int], String) -> Void, onClose: @escaping () -> Void) {
        self.era = era
        self.onEraCommit = onEraCommit
        _eraDraft = State(initialValue: era)
        self.title = title
        self.summary = summary
        self.warning = warning
        self.episodeCount = episodeCount
        self.allowsWholeScript = allowsWholeScript
        self.rangeSummary = rangeSummary
        self.startTitle = startTitle
        self.notePlaceholder = notePlaceholder
        self.nameChoices = nameChoices
        self.nameNoun = nameNoun
        self.onStartNames = onStartNames
        self.onStart = onStart
        self.onClose = onClose
        if let currentEpisode, (0..<max(episodeCount, 0)).contains(currentEpisode) {
            _allEpisodes = State(initialValue: false)
            _fromText = State(initialValue: String(currentEpisode + 1))
            _toText = State(initialValue: String(currentEpisode + 1))
        } else {
            _toText = State(initialValue: String(max(1, episodeCount)))
        }
    }

    private var range: ClosedRange<Int>? {
        guard let from = Int(fromText.trimmingCharacters(in: .whitespaces)),
              let to = Int(toText.trimmingCharacters(in: .whitespaces)),
              from >= 1, to >= from, to <= episodeCount else { return nil }
        return from...to
    }

    private var selectedIndices: [Int] {
        allEpisodes ? Array(0..<episodeCount) : (range.map { Array(($0.lowerBound - 1)..<$0.upperBound) } ?? [])
    }

    private func isChecked(_ choice: ExtractNameChoice) -> Bool {
        choice.hasCard ? flipped.contains(choice.name) : !flipped.contains(choice.name)
    }

    private func namePicker(_ choices: [ExtractNameChoice]) -> some View {
        let checked = choices.filter(isChecked).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("提取哪些\(nameNoun)（已勾 \(checked)/\(choices.count)）")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 10) {
                    Button("只选还没有卡的") { flipped = [] }
                    Button("全选") { flipped = Set(choices.filter(\.hasCard).map(\.name)) }
                    Button("全不选") { flipped = Set(choices.filter { !$0.hasCard }.map(\.name)) }
                }
                .buttonStyle(QuietButtonStyle(hover: .fill(radius: 5)))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.accent)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        Button {
                            if flipped.contains(choice.name) { flipped.remove(choice.name) } else { flipped.insert(choice.name) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isChecked(choice) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(isChecked(choice) ? Theme.accent : Color.secondary)
                                Text(choice.name).font(.system(size: 13)).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(choice.hasCard ? "已有卡 · \(choice.detail)" : "没有卡 · \(choice.detail)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(choice.hasCard ? Color.secondary : Theme.warning)
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
            .frame(maxHeight: 150)
            .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
        }
    }

    var body: some View {
        let choices = nameChoices?(selectedIndices) ?? []
        let pickedNames = Set(choices.filter(isChecked).map(\.name))
        return VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))

            if episodeCount > 0 {
                SegmentedBar(options: [("全部集", true), ("指定范围", false)], selection: $allEpisodes)
                    .frame(height: 26)
            }

            if episodeCount > 0, !allEpisodes {
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
                if range == nil {
                    Text("集号要在 1 到 \(episodeCount) 之间，而且「到」不能小于「从」。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.danger)
                }
            }

            if !choices.isEmpty { namePicker(choices) }

            if onEraCommit != nil {
                VStack(alignment: .leading, spacing: 5) {
                    Text("时代背景（可不填；填了每次提取都带上、整个项目通用）")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    TextField("比如：民国背景 / 古代言情背景 / 现代都市背景", text: $eraDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
                        .accessibilityIdentifier("pipeline-era-background")
                }
            }

            if let notePlaceholder {
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
                            Text(notePlaceholder)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 9).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 84)
                    .background(SolidTheme.inset(colorScheme), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SolidTheme.cardStroke(colorScheme)))
                }
            }

            if let text = warning?(selectedIndices) {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(choices.isEmpty ? (rangeSummary?(selectedIndices) ?? summary(selectedIndices.count))
                     : (pickedNames.isEmpty ? "没有勾选要提取的\(nameNoun)" : "将提取 \(pickedNames.count) 个\(nameNoun)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onClose).keyboardShortcut(.cancelAction)
                Button(choices.isEmpty ? (startTitle?(selectedIndices) ?? "开始") : "提取 \(pickedNames.count) 个") {
                    onEraCommit?(eraDraft)
                    onClose()
                    if choices.isEmpty { onStart(selectedIndices, userNote) } else { onStartNames?(selectedIndices, userNote, pickedNames) }
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled((selectedIndices.isEmpty && !(allowsWholeScript && episodeCount == 0)) || (!choices.isEmpty && pickedNames.isEmpty))
            }
        }
        .padding(16)
        .frame(width: 360)
        // 关掉面板（取消 / 开始都算）：时代背景改过就存回项目。开始提取时 `onClose` 在读取之前就会调，
        // 所以开始按钮里先存一次，保证这一次的请求就带上新填的
        .onDisappear { onEraCommit?(eraDraft) }
    }
}
