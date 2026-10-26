import SwiftUI

/// 生图 / 生视频右栏里共用的小零件（2026-10-10：右栏提示词下面原来整片空白，把已有的信息摆进去）。

/// 预览框的宽高比：横图按它自己的比例，方形和竖图用方框（竖图在方框里等比留边，不把右栏撑得老长）
enum InspectorPreview {
    static func ratio(_ aspect: ImageAspect) -> CGFloat {
        switch aspect {
        case .ratio16x9: 16.0 / 9.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio1x1, .ratio9x16, .ratio3x4: 1
        }
    }

    static func ratio(_ aspect: AspectRatio) -> CGFloat {
        switch aspect {
        case .ratio16x9, .adaptive, .horizontal: 16.0 / 9.0
        case .ratio4x3: 4.0 / 3.0
        case .ratio1x1, .ratio9x16, .ratio3x4, .vertical: 1
        }
    }
}

/// 一排参数小标签（模型 · 比例 · 质量 · 生成时间）
struct InspectorChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
            }
        }
    }
}

extension CardUsageSummary {
    /// 用到这张卡的分段（没类型的卡没有）
    @MainActor
    static func entries(_ card: ImageGenItem, app: AppModel) -> [CardUsage.Entry] {
        guard card.type != nil else { return [] }
        // 卡片和素材库各取一次（2026-10-26 用户：弹窗开得慢）：原来每查一段都重新筛一遍本项目的卡、在整个素材库里从头找，
        // 主角那种用到上百段的卡一次要算半秒
        let cards = app.currentImageItems
        let index = Dictionary(app.library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let library = { (id: UUID) in index[id] }
        return CardUsage.entries(for: card, cards: cards, shots: app.currentShots,
                                 archive: app.currentPipelineArchive,
                                 attachedCardID: { kind, name, shot in
                                     WorkbenchVersions.attachedCardID(kind: kind, name: name, shot: shot,
                                                                      cards: cards, app: app, library: library)
                                 }) { app.numbering(of: $0).title }
    }
}

/// 生图编辑弹窗右栏的「用到它的分段」（2026-10-26：右边详情要去掉，信息并进弹窗）：
/// 一行汇总「用到 126 段 · 第 1～24 集」，点「查看」按集分组列出来；点段号跳到工作台那一段，`onJump` 让弹窗关掉。
/// 素材库状态挪到了弹窗里图片右上角
struct CardUsageSummary: View {
    @Environment(AppModel.self) private var app
    let card: ImageGenItem
    var onJump: () -> Void = {}
    @State private var showAll = false
    /// 算好的分段（nil = 还没算）。**不在 body 里算**：弹窗里切音色、打字都会刷新 body，每次都扫整个项目就卡了（2026-10-26 用户）。
    /// 打开 / 换卡时算一次，点「查看」时再算一次（拿最新的）
    @State private var entries: [CardUsage.Entry]?

    var body: some View {
        let entries = entries ?? []
        if card.type != nil {
            // 一律一行（2026-10-26 用户：别排成两行标签，有「查看」就够了）：「用到 6 段 · 第 1～16 集　查看」
            HStack(spacing: 8) {
                if entries.isEmpty {
                    Text("还没有分段用到这张卡").foregroundStyle(.tertiary)
                } else {
                    let episodes = entries.map(\.episodeIndex)
                    let first = (episodes.min() ?? 0) + 1, last = (episodes.max() ?? 0) + 1
                    Text("用到 \(entries.count) 段 · " + (first == last ? "第 \(first) 集" : "第 \(first)～\(last) 集"))
                        .foregroundStyle(.secondary)
                    Button("查看") { self.entries = Self.entries(card, app: app); showAll = true }
                        .buttonStyle(QuietButtonStyle(hover: .capsule))
                        .foregroundStyle(Theme.accent)
                        .dropdownPopover(isPresented: $showAll) { allList(entries) }
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .lineLimit(1)
            .opacity(self.entries == nil ? 0 : 1)
            // 弹窗先出来，下一拍再算（打开不等它）
            .task(id: card.id) { self.entries = Self.entries(card, app: app) }
        }
    }

    /// 按集分组：一集一行「第 3 集　1 2 3 4 5」，点段号跳过去
    private func allList(_ entries: [CardUsage.Entry]) -> some View {
        let groups = Dictionary(grouping: entries, by: \.episodeIndex).sorted { $0.key < $1.key }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(groups, id: \.key) { episode, items in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("第 \(episode + 1) 集").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        FlowLayout(spacing: 4, lineSpacing: 4) {
                            ForEach(items.sorted { $0.segment < $1.segment }) { entry in
                                segmentChip("\(entry.segment)") { jump(entry) }
                                    .help(entry.title)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340)
        .frame(maxHeight: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func segmentChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.75))
        }
        .buttonStyle(QuietButtonStyle(hover: .capsule))
        .help("跳到工作台的这一段")
    }

    private func jump(_ entry: CardUsage.Entry) {
        showAll = false
        onJump()
        app.workbenchOpenSegment(episodeIndex: entry.episodeIndex, segment: entry.segment)
    }
}

/// 生图编辑弹窗标题行里的「阶段 / 起始集」两格（2026-10-26：右边详情要去掉，并进弹窗；原来生图页右栏「版本」那两格，同一套存法）
struct CardVersionFields: View {
    @Environment(AppModel.self) private var app
    let card: ImageGenItem
    @State private var stage = ""
    @State private var episode = ""
    @FocusState private var focused: Field?
    private enum Field { case stage, episode }

    var body: some View {
        HStack(spacing: 6) {
            Text("阶段").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("主时间线", text: $stage)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 110)
                .focused($focused, equals: .stage).onSubmit(save)
            Text("起始集").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 4)
            TextField("全程", text: $episode)
                .textFieldStyle(.roundedBorder).font(.system(size: 12)).frame(width: 52)
                .focused($focused, equals: .episode).onSubmit(save)
        }
        .help("阶段：同一个人 / 地方 / 物品的另一个形态（四十岁、少年），空 = 主时间线；起始集：这一版从第几集起用，空 = 全程")
        .onAppear(perform: load)
        .onChange(of: card.id) { _, _ in load() }
        .onChange(of: card.stage) { _, _ in if focused == nil { load() } }
        .onChange(of: card.fromEpisode) { _, _ in if focused == nil { load() } }
        .onChange(of: focused) { old, new in if old != nil, new != old { save() } }
        .onDisappear { if focused != nil { save() } }
    }

    private func load() {
        stage = card.stage ?? ""
        episode = card.fromEpisode.map(String.init) ?? ""
    }

    private func save() {
        let number = AssetVersionName.number(episode.trimmingCharacters(in: .whitespaces))
        app.updateImageItemVersion(card.id, stage: stage, fromEpisode: number)
        load()
    }
}
