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

/// 生图右栏的「用到它的分段」+ 素材库状态。点分段直接跳到工作台那一段。
/// 独立子视图：自己读分镜 / 分集存档，右栏其余部分不跟着它重算。
struct CardUsageSection: View {
    @Environment(AppModel.self) private var app
    let card: ImageGenItem
    /// 现在显示的那一版的结果 ID（素材库里按它判断「已入库」）
    let resultID: UUID?

    var body: some View {
        let entries = card.type == nil ? [] : CardUsage.entries(for: card, cards: app.currentImageItems, shots: app.currentShots,
                                                                  archive: app.currentPipelineArchive,
                                                                  attachedCardID: { kind, name, shot in
                                                                      WorkbenchVersions.attachedCardID(kind: kind, name: name, shot: shot,
                                                                                                       cards: app.currentImageItems, app: app)
                                                                  }) { app.numbering(of: $0).title }
        let inLibrary = resultID.map { id in app.library.contains { $0.imageGenResultID == id } }
        if card.type != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("用到它的分段").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(entries) { entry in
                        Button { app.workbenchOpenSegment(episodeIndex: entry.episodeIndex, segment: entry.segment) } label: {
                            Text(entry.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.accent.opacity(0.12)))
                                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.75))
                        }
                        .buttonStyle(QuietButtonStyle(hover: .capsule))
                        .help("跳到工作台的这一段")
                    }
                    if entries.isEmpty {
                        Text("还没有分段用到这张卡").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    if let inLibrary {
                        Text(inLibrary ? "素材库：已入库" : "素材库：未入库")
                            .font(.system(size: 11.5))
                            .foregroundStyle(inLibrary ? Theme.success : Color.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
                    }
                }
            }
        }
    }
}

/// 生图页右栏「版本」：这张卡的阶段（四十岁 / 少年；空 = 主时间线）和起始集（空 = 全程）（2026-10-14 名字与形态分离）。
/// 名字只放基础名，这两样存在卡上、不进提示词；匹配和「更换版本」按它们选卡。只有场景 / 角色 / 道具卡有
struct CardVersionSection: View {
    @Environment(AppModel.self) private var app
    let card: ImageGenItem
    @State private var stage = ""
    @State private var episode = ""
    @FocusState private var focused: Field?
    private enum Field { case stage, episode }

    var body: some View {
        if card.type != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("版本").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    field("阶段", placeholder: "主时间线", text: $stage, which: .stage, width: 130)
                    field("起始集", placeholder: "全程", text: $episode, which: .episode, width: 70)
                    Spacer(minLength: 0)
                }
            }
            .onAppear(perform: load)
            .onChange(of: card.id) { _, _ in load() }
            .onChange(of: card.stage) { _, _ in if focused == nil { load() } }
            .onChange(of: card.fromEpisode) { _, _ in if focused == nil { load() } }
            .onChange(of: focused) { old, new in if old != nil, new != old { save() } }
        }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>, which: Field, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: width)
                .focused($focused, equals: which)
                .onSubmit(save)
        }
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
