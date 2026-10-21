import SwiftUI

/// 设置 → 剧本流水线（2026-10-11 改版）：文字服务商是一排卡片，和「服务渠道」一样可新增 / 删除 / 展开编辑；
/// 模型从服务商的模型列表里「获取」后选，思考强度从下拉里选，都不手输。同一时间用其中一个（卡片上有「设为当前使用」）。
/// 提示词不在这里了，在设置里单独一页「提示词」。
struct PipelineProvidersEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var book: PipelineProviderBook
    var loadError: String?
    /// 列表变了：外面负责存盘、刷新接力
    var onPersist: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "外部智能体接力") {
                SettingsRow("让外部智能体回答") {
                    Toggle("", isOn: Binding(get: { book.agentMode == true }, set: { book.agentMode = $0 ? true : nil; onPersist() }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("外部智能体接力")
                        .accessibilityIdentifier("pipeline-settings-agent")
                }
                if book.agentMode == true {
                    SettingsDivider()
                    SettingsRow("收件目录") {
                        Button("在访达中显示") { NSWorkspace.shared.open(AgentBridge.shared.root) }
                            .accessibilityIdentifier("pipeline-settings-agent-reveal")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                if let loadError { SettingsNote(text: loadError, tone: .bad) }
                if book.providers.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "server.rack").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("还没有文字服务商").font(.system(size: 14, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .background(RoundedRectangle(cornerRadius: SettingsStyle.cardRadius)
                        .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                } else {
                    ForEach(book.providers) { provider in
                        ProviderCard(provider: provider,
                                     isActive: book.active?.id == provider.id,
                                     onSave: { save($0) },
                                     onActivate: { book.activeID = provider.id; onPersist() },
                                     onDelete: { remove(provider.id) })
                    }
                }
            }
            // 接力开着时不调任何服务商：卡片灰掉、不让改（和以前一样）
            .opacity(book.agentMode == true ? 0.5 : 1)
            .disabled(book.agentMode == true)
        }
    }

    private func save(_ provider: PipelineProvider) {
        guard let index = book.providers.firstIndex(where: { $0.id == provider.id }) else { return }
        book.providers[index] = provider
        onPersist()
    }

    private func remove(_ id: UUID) {
        let wasActive = book.active?.id == id
        book.providers.removeAll { $0.id == id }
        if wasActive { book.activeID = book.providers.first?.id }
        onPersist()
    }
}

// MARK: 一张服务商卡片

private struct ProviderCard: View {
    @Environment(AppModel.self) private var app
    let provider: PipelineProvider
    let isActive: Bool
    let onSave: (PipelineProvider) -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var draft: PipelineProvider
    @State private var isExpanded: Bool
    @State private var errors: [Field: String] = [:]
    @State private var fetching = false
    @State private var fetchError: String?
    @State private var showModelPicker = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testOK = false
    @State private var showDeleteConfirm = false
    @State private var showSaved = false
    @State private var savedTask: Task<Void, Never>?

    private enum Field: Hashable { case name, baseURL, apiKey }

    init(provider: PipelineProvider, isActive: Bool, onSave: @escaping (PipelineProvider) -> Void,
         onActivate: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.provider = provider
        self.isActive = isActive
        self.onSave = onSave
        self.onActivate = onActivate
        self.onDelete = onDelete
        _draft = State(initialValue: provider)
        // 新建的（地址或 Key 还空着）默认展开，直接引导填写
        _isExpanded = State(initialValue: provider.baseURL.isEmpty || provider.apiKey.isEmpty)
    }

    private var isDirty: Bool { draft != provider }
    private var hasModels: Bool { !(draft.fetchedModels ?? []).isEmpty }

    var body: some View {
        SettingsCard(highlighted: isExpanded) {
            summaryRow
                .padding(.horizontal, SettingsStyle.rowHorizontal)
                .padding(.vertical, 12)
            if isExpanded {
                SettingsDivider()
                editor.transition(.opacity)
            }
        }
        .onDisappear { savedTask?.cancel() }
        .alert("删除服务商", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除「\(provider.name.isEmpty ? "未命名服务商" : provider.name)」？此操作不可撤销。")
        }
    }

    // MARK: 摘要行

    private func pill(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(accent ? Theme.accent : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(accent ? Theme.accent.opacity(0.14) : Color.primary.opacity(0.07)))
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isExpanded)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(draft.name.isEmpty ? "未命名服务商" : draft.name).font(.system(size: 14, weight: .medium))
                        if isDirty { Text("未保存").font(.system(size: 11)).foregroundStyle(Theme.warning) }
                    }
                    Text(draft.baseURL.isEmpty ? "未填地址" : draft.baseURL)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if isActive { pill("当前使用", accent: true) }
                if !draft.model.isEmpty { pill(draft.model) }
                if let effort = draft.reasoningEffort, !effort.isEmpty {
                    pill("思考 \(ReasoningEffortOption.label(for: effort))\(ReasoningEffortOption.warning(forModel: draft.model, value: effort) == nil ? "" : " ⚠︎")")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .hoverHighlight(radius: 8)
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }
            .help(isExpanded ? "点此收起" : "点此展开编辑")

            Button { showDeleteConfirm = true } label: {
                Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(Theme.danger.opacity(0.85))
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(QuietButtonStyle())
            .help("删除服务商")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 展开编辑

    private func fieldRow(_ title: LocalizedStringKey, prompt: String, text: Binding<String>, field: Field, secure: Bool = false) -> some View {
        SettingsRow(title) {
            VStack(alignment: .trailing, spacing: 3) {
                Group {
                    if secure { SecureField(prompt, text: text) } else { TextField(prompt, text: text) }
                }
                .onSubmit { save() }
                .settingsField(width: 320)
                if let message = errors[field] { Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            fieldRow("服务商名", prompt: "如 NVIDIA", text: $draft.name, field: .name)
            SettingsDivider()
            fieldRow("API 地址", prompt: "如 https://integrate.api.nvidia.com/v1", text: $draft.baseURL, field: .baseURL)
            SettingsDivider()
            fieldRow("API Key", prompt: "API Key", text: $draft.apiKey, field: .apiKey, secure: true)
            SettingsDivider()
            modelRow
            SettingsDivider()
            effortRow
            SettingsDivider()
            SettingsRow("流式接收") {
                Toggle("", isOn: Binding(get: { draft.streaming != false }, set: { draft.streaming = $0 ? nil : false }))
                    .labelsHidden().toggleStyle(.switch)
                    .help("边生成边接收：任务抽屉里能实时看到思考和输出，数据一直在流也不容易被服务商的网关因为等太久断开（504）。个别中转站不支持流式，测试连接报错时关掉试试")
                    .accessibilityLabel("流水线流式接收")
            }
            SettingsDivider()
            concurrencyRow
            SettingsDivider()
            actions
        }
    }

    /// 同时请求数：批量分割同时跑几集、提取素材每类同时几个请求（最多 3）。服务商回 429（请求太多）就调低
    private var concurrencyRow: some View {
        let value = draft.concurrency ?? PipelineAISettings.defaultConcurrency
        let range = PipelineAISettings.concurrencyRange
        return SettingsRow("同时请求数") {
            HStack(spacing: 0) {
                Button { draft.concurrency = max(value - 1, range.lowerBound) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(value <= range.lowerBound)
                .accessibilityIdentifier("pipeline-provider-concurrency-minus")
                Text("\(value)").font(.system(size: 13).monospacedDigit()).frame(width: 32)
                    .accessibilityIdentifier("pipeline-provider-concurrency")
                Button { draft.concurrency = min(value + 1, range.upperBound) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(value >= range.upperBound)
                .accessibilityIdentifier("pipeline-provider-concurrency-plus")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .help("批量分割同时跑几集；提取素材每一类同时发几个请求（最多 3）。服务商报 HTTP 429（请求太多）就调低，NVIDIA 免费接口建议 2～3。命名、推理分镜本来就一集接一集跑，不受影响")
        }
    }

    /// 模型：「获取模型」向服务商要列表，点下拉里搜索、选一个。没有模型接口的中转站才需要手输（获取失败时出现）
    private var modelRow: some View {
        SettingsRow("模型") {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 8) {
                    Button { openModelPicker() } label: {
                        HStack(spacing: 6) {
                            Text(draft.model.isEmpty ? (hasModels ? "选择模型" : "请先获取模型") : draft.model)
                                .font(.system(size: 13))
                                .foregroundStyle(draft.model.isEmpty ? Color.secondary : Color.primary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .frame(width: 214)
                        .background(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).fill(Color.primary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QuietButtonStyle(hover: .none))
                    .dropdownPopover(isPresented: $showModelPicker) {
                        ModelPickerList(models: draft.fetchedModels ?? [], selected: draft.model) { chosen in
                            draft.model = chosen
                            showModelPicker = false
                            DropdownPanel.shared.dismiss()
                        }
                    }
                    .accessibilityIdentifier("provider-model-picker")

                    Button { Task { await fetchModels(thenOpen: false) } } label: {
                        HStack(spacing: 5) {
                            if fetching { ProgressView().controlSize(.mini) }
                            Text(fetching ? "获取中…" : (hasModels ? "重新获取" : "获取模型"))
                        }
                    }
                    .disabled(fetching)
                    .accessibilityIdentifier("provider-fetch-models")
                }
                if let fetchError {
                    Text(fetchError).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                        .frame(maxWidth: 320, alignment: .trailing).multilineTextAlignment(.trailing)
                    // 获取不到（没有模型接口的中转站）：给个手输的备用
                    TextField("手动输入模型名", text: $draft.model).settingsField(width: 320)
                }
            }
        }
    }

    private var effortRow: some View {
        VStack(spacing: 0) {
            effortPicker
            // 选了模型不认的档位：不报错但悄悄当默认用（用户选了「中」还是想了十万多字），在这里明说
            if let warning = ReasoningEffortOption.warning(forModel: draft.model, value: draft.reasoningEffort) {
                Text(warning)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.warning)
                    .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                    .padding(.horizontal, SettingsStyle.rowHorizontal).padding(.bottom, 10)
                    .accessibilityIdentifier("provider-effort-warning")
            }
        }
    }

    private var effortPicker: some View {
        SettingsRow("思考强度") {
            IconDropdown(
                icon: "brain",
                labelWidth: 0,
                options: ReasoningEffortOption.options(forModel: draft.model, including: draft.reasoningEffort).map { DropdownOption(label: $0.label, value: $0.value) },
                selection: Binding(get: { draft.reasoningEffort ?? "" }, set: { draft.reasoningEffort = $0.isEmpty ? nil : $0 }),
                fillsRow: true,
                verticalPadding: 4
            )
            .padding(.leading, 9).padding(.trailing, 24)
            .frame(width: 168)
            .background(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: SettingsStyle.fieldRadius).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.trailing, 9).allowsHitTesting(false)
            }
            .help("随请求发 reasoning_effort。思考型模型默认很深、很慢，选「低」能快很多；选了模型不认的档位，测试连接会报错")
            .accessibilityIdentifier("provider-effort")
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { save() } label: { Label("保存", systemImage: "checkmark") }
                    .buttonStyle(AccentButtonStyle())
                Button(testing ? "测试中…" : "测试连接") { Task { await test() } }
                    .disabled(testing)
                    .accessibilityIdentifier("provider-test")
                // 连接成功的提示就跟在「测试连接」右边（2026-10-12 用户：不用多占一行）；失败的原因可能很长，还是放在下面一行
                if let testMessage, testOK || testing {
                    Label(testMessage, systemImage: testing ? "hourglass" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(testing ? Color.secondary : Theme.success)
                        .lineLimit(1)
                        .help(testMessage)
                        .accessibilityIdentifier("provider-test-result")
                }
                if !isActive {
                    Button("设为当前使用") { activate() }
                        .help("以后所有文字步骤（分割、推理分镜、提取素材）都用这一个")
                }
                if showSaved {
                    Label("已保存", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.success).transition(.opacity)
                } else if !errors.isEmpty {
                    Label("还有 \(errors.count) 项没填对，见红字", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.warning)
                }
                Spacer()
            }
            if let testMessage, !testOK, !testing {
                SettingsNote(text: testMessage, tone: .bad)
            }
        }
        .padding(.horizontal, SettingsStyle.rowHorizontal)
        .padding(.vertical, 12)
    }

    // MARK: 动作

    private func cleaned() -> PipelineProvider {
        var value = draft
        value.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        value.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private func validate(_ value: PipelineProvider) -> [Field: String] {
        var issues: [Field: String] = [:]
        if value.name.isEmpty { issues[.name] = "服务商名不能为空" }
        if value.apiKey.isEmpty { issues[.apiKey] = "Key 不能为空" }
        if let url = URL(string: value.baseURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil {
            // 地址 OK
        } else {
            issues[.baseURL] = "接口地址需为完整的 http/https 地址，不能含账号、查询参数或片段"
        }
        return issues
    }

    @discardableResult
    private func save() -> Bool {
        let value = cleaned()
        errors = validate(value)
        guard errors.isEmpty else { return false }
        draft = value
        if value != provider { onSave(value) }
        savedTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showSaved = true }
        savedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showSaved = false }
        }
        return true
    }

    private func activate() {
        guard save() || !isDirty else { return }          // 有没保存的改动先存；存不了（红字）就不切
        onActivate()
    }

    private func openModelPicker() {
        if hasModels { showModelPicker = true; return }
        Task { await fetchModels(thenOpen: true) }
    }

    private func fetchModels(thenOpen: Bool) async {
        let value = cleaned()
        let issues = validate(value).filter { $0.key != .name }
        guard issues.isEmpty else { errors = issues; fetchError = "先把 API 地址和 Key 填好，再获取模型。"; return }
        fetching = true
        fetchError = nil
        defer { fetching = false }
        do {
            let names = try await ModelListService.fetch(baseURL: value.baseURL, apiKey: value.apiKey)
            draft.fetchedModels = names
            if thenOpen { showModelPicker = true }
        } catch {
            fetchError = "获取模型失败：\(error.localizedDescription)。没有模型接口的服务商，可以在下面手动输入模型名。"
        }
    }

    private func test() async {
        let value = cleaned()
        let issues = validate(value)
        guard issues.isEmpty else { errors = issues; testOK = false; testMessage = "先把名字、地址、Key 填好。"; return }
        guard !value.model.isEmpty else { testOK = false; testMessage = "先获取模型并选一个。"; return }
        testing = true
        testMessage = "正在测试…"
        let result = await ConnectionProbe.ai(config: value.settings())
        testing = false
        testOK = result.ok
        testMessage = result.message
        if isActive, value == provider {       // 测的就是正在用的那个（已保存的这份）：左栏 AI 图标跟着亮 / 变红，左栏还在跑的那次作废
            app.reportAIProbe(result)
        }
    }
}

// MARK: 模型下拉（可搜索）

/// 获取到的模型列表：上面一个搜索框，下面一排可点的名字。几十个模型也能找
private struct ModelPickerList: View {
    let models: [String]
    let selected: String
    let onPick: (String) -> Void
    @State private var query = ""

    private var shown: [String] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return words.isEmpty ? models : models.filter { name in words.allSatisfy { name.lowercased().contains($0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索模型（\(models.count) 个）", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { name in
                        Button { onPick(name) } label: {
                            HStack(spacing: 6) {
                                Text(name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if name == selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    if shown.isEmpty {
                        Text("没有匹配的模型").font(.system(size: 12)).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            .frame(height: min(300, CGFloat(max(shown.count, 1)) * 30 + 8))
        }
        .padding(10)
        .frame(width: 340)
    }
}
