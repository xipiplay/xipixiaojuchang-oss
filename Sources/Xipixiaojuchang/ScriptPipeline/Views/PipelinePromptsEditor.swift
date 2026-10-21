import SwiftUI

/// 剧本流水线提示词规则编辑（设置 → 提示词，独立的一页）。
/// 字段显示"当前生效"的文本：与内置默认一致 = 跟随默认；改动后点保存写入覆盖。
///
/// 2026-10-09 改成**左边选一条、右边一个大编辑框**：原来是 6 个固定 150 高的文本框竖着排在一个能滚动的页面里，
/// 页面和框里都能滚，鼠标几乎总停在某个框上，滚轮滚的是框、滚到头才轮到页面（嵌套滚动），长提示词在 150 高里也很难改。
/// 现在这个子页面铺满设置弹窗的高度、页面本身不滚，只有右边那一个编辑框能滚。
struct PipelinePromptsEditor: View {
    @Binding var draft: PipelinePromptSettings
    var dirty: Bool
    var message: String?
    var isError: Bool
    /// 从别的页点进来时才有「返回」；提示词是独立的一页（2026-10-11）就没有
    var onBack: (() -> Void)?
    var onSave: () -> Void
    @State private var selected: Item
    @State private var focused = false
    /// 有文本文件正拖在编辑框上
    @State private var dropTargeted = false
    /// 拖入的结果提示（几秒后自己消失）
    @State private var dropHint: (text: String, isError: Bool)?

    init(draft: Binding<PipelinePromptSettings>, dirty: Bool, message: String?, isError: Bool,
         onBack: (() -> Void)? = nil, onSave: @escaping () -> Void) {
        _draft = draft
        self.dirty = dirty
        self.message = message
        self.isError = isError
        self.onBack = onBack
        self.onSave = onSave
        // 默认选中第一条改过的（没有就第一条）
        _selected = State(initialValue: Item.allCases.first { $0.isModified(in: draft.wrappedValue) } ?? .split)
    }

    /// 七条提示词（顺序就是流程顺序）
    enum Item: String, CaseIterable, Identifiable {
        case split, segments, naming, role, scene, prop, storyboard
        var id: String { rawValue }

        var title: String {
            switch self {
            case .split: "分集"
            case .segments: "分割（时长）"
            case .naming: "分段命名"
            case .role: "提取角色"
            case .scene: "提取场景"
            case .prop: "提取道具"
            case .storyboard: "推理分镜"
            }
        }

        /// 这条提示词用在哪一步（一句话）
        var usage: String {
            switch self {
            case .split: "导入剧本后由 AI 分集时用。剧本里有「第N集」标题时软件直接在本地按标题切，用不到它；没有标题才会用。"
            case .segments: "时长分割：读一集的原文，按 30 秒切成段落，结果存为这一集的「时长分割」。只管切，名字交给「分段命名」。"
            case .naming: "分段命名：读一集的分段（和前面各集已有的名字），给每段写【场景】【角色】【道具】【本段在场】四行，写在这一段文字的最上面；推理分镜按它们出头行。"
            case .role: "角色提取：名字取自分镜头行，去原文里找描述，在生图页建卡片（先推理分镜）。"
            case .scene: "场景提取：名字取自分镜头行，去用到它的分镜里找描述，在生图页建卡片（先推理分镜）。"
            case .prop: "道具提取：名字取自分镜头行，去原文里找描述，在生图页建卡片（先推理分镜）。"
            case .storyboard: "推理分镜：读一集的时长分割，每个 30 秒段推理成一条分镜提示词，建成分镜卡。"
            }
        }

        var fallback: String {
            switch self {
            case .split: PipelinePromptStore.splitPromptDefault
            case .segments: PipelinePromptStore.segmentDefault
            case .naming: PipelinePromptStore.namingDefault
            case .role: PipelinePromptStore.roleDefault
            case .scene: PipelinePromptStore.sceneDefault
            case .prop: PipelinePromptStore.propDefault
            case .storyboard: PipelinePromptStore.shotsDefault
            }
        }

        var keyPath: WritableKeyPath<PipelinePromptSettings, String> {
            switch self {
            case .split: \.split
            case .segments: \.segments
            case .naming: \.naming
            case .role: \.role
            case .scene: \.scene
            case .prop: \.prop
            case .storyboard: \.storyboard
            }
        }

        /// 和内置默认不一样（前后空白不算）
        func isModified(in settings: PipelinePromptSettings) -> Bool {
            settings[keyPath: keyPath].trimmingCharacters(in: .whitespacesAndNewlines)
                != fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static var defaultSettings: PipelinePromptSettings {
        PipelinePromptSettings(split: PipelinePromptStore.splitPromptDefault,
                               segments: PipelinePromptStore.segmentDefault,
                               role: PipelinePromptStore.roleDefault,
                               scene: PipelinePromptStore.sceneDefault,
                               prop: PipelinePromptStore.propDefault,
                               storyboard: PipelinePromptStore.shotsDefault,
                               naming: PipelinePromptStore.namingDefault)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let onBack {
                    Button { onBack() } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("prompts-back")
                }
                if onBack != nil { Text("提示词规则").font(.system(size: 15, weight: .semibold)) }     // 独立一页时页头已经写了「提示词」
                Spacer()
                Button("全部恢复默认") { draft = Self.defaultSettings }
                    .accessibilityIdentifier("prompts-reset-all")
                Button("保存", action: onSave)
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!dirty)
            }
            if let message {
                SettingsNote(text: message, tone: isError ? .bad : .secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                list
                editor
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 左：六条提示词

    private var list: some View {
        VStack(spacing: 3) {
            ForEach(Item.allCases) { item in
                Button { selected = item } label: {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13, weight: selected == item ? .semibold : .regular))
                            .foregroundStyle(selected == item ? Color.primary : Color.secondary)
                        Spacer(minLength: 0)
                        if item.isModified(in: draft) {
                            Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                .help("和内置默认不一样")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected == item ? 0.10 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("prompts-item-\(item.title)")
            }
            Spacer(minLength: 0)
        }
        .frame(width: 138)
    }

    // MARK: 拖入 TXT

    private func handleDrop(_ result: Result<(name: String, count: Int), PromptTextDropError>) {
        switch result {
        case .success(let file):
            dropHint = ("已载入「\(file.name)」（\(file.count) 字），还没保存；不对可以按 ⌘Z 撤销。", false)
        case .failure(let error):
            dropHint = (error.message, true)
        }
        let shown = dropHint?.text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if dropHint?.text == shown { dropHint = nil }
        }
    }

    // MARK: 右：一个大编辑框

    private var editor: some View {
        let item = selected
        let text = Binding(get: { draft[keyPath: item.keyPath] }, set: { draft[keyPath: item.keyPath] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                Text("\(text.wrappedValue.count) 字")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("恢复默认") { text.wrappedValue = item.fallback }
                    .buttonStyle(QuietButtonStyle(hover: .fill(radius: 6)))
                    .font(.system(size: 12))
                    .disabled(!item.isModified(in: draft))
                    .accessibilityIdentifier("prompts-reset-\(item.title)")
            }
            Text(item.usage)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 只有这一个文本框能滚。换一条就重建它（光标 / 撤销记录 / 滚动位置都从头来）。可以把 TXT 文件拖进来（整条换成文件内容，⌘Z 撤销）
            PromptTextEditor(text: text,
                             onFocusChange: { focused = $0 },
                             onDropTargetChange: { dropTargeted = $0 },
                             onDropResult: handleDrop)
                .id(item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius).fill(Color.primary.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius).strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay {
                    if dropTargeted {
                        Text("松开，用这个文件替换「\(item.title)」的全部内容")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(Theme.accent.opacity(0.18)))
                            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius))
                .inputChrome(focused: focused || dropTargeted, radius: SettingsStyle.cardRadius)
            // 拖入 TXT 后的结果提示（成功 / 失败）；平时不放「可以拖文件进来」这类说明
            if let hint = dropHint {
                HStack(spacing: 6) {
                    Image(systemName: hint.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(hint.isError ? Theme.warning : Theme.success)
                    Text(hint.text).foregroundStyle(hint.isError ? Theme.warning : Color.secondary)
                }
                .font(.system(size: 11.5))
                .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
