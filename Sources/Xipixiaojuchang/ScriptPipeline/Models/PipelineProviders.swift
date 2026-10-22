import Foundation

/// 剧本流水线的文字服务商（2026-10-11）：和「服务渠道」一样是一排可新增 / 删除 / 展开编辑的卡片，不再是单独一份配置。
/// 每张卡片：名字、API 地址、API Key、选中的模型（从服务商的 `/v1/models` 里「获取」后选，不手输）、思考强度（下拉选）、流式接收开关。
/// 同一时间用其中一个（`PipelineProviderBook.activeID`）；各处读配置仍然读 `PipelineAISettingsStore.load().config`，
/// 那里会把当前使用的服务商 + 「外部智能体接力」开关合成原来那份 `PipelineAISettings`，所以调用方一行都不用改。
struct PipelineProvider: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var baseURL = ""
    var apiKey = ""
    var model = ""
    /// nil = 不发（用模型自己的默认）
    var reasoningEffort: String?
    /// nil / true = 流式接收；false = 关
    var streaming: Bool?
    /// 同时请求数（见 `PipelineAISettings.concurrency`）；nil = 默认 5
    var concurrency: Int?
    /// 上一次「获取模型」拿到的列表（存下来，下次打开直接选，不用再等一次）
    var fetchedModels: [String]?

    /// 合成各处在用的单份配置（不带接力开关）
    func settings(agentMode: Bool? = nil) -> PipelineAISettings {
        PipelineAISettings(baseURL: baseURL, apiKey: apiKey, model: model, agentMode: agentMode,
                           reasoningEffort: reasoningEffort, streaming: streaming, concurrency: concurrency)
    }
}

struct PipelineProviderBook: Codable, Equatable, Sendable {
    var providers: [PipelineProvider] = []
    var activeID: UUID?
    /// 外部智能体接力（见 `PipelineAISettings.agentMode`）：和服务商无关，开着就不调任何服务商
    var agentMode: Bool?

    /// 当前使用的服务商：`activeID` 指的那个；指向的已被删掉 / 没记过，就用第一个
    var active: PipelineProvider? { providers.first { $0.id == activeID } ?? providers.first }

    /// 各处在用的单份配置。一个服务商都没有 = 什么都没配（地址、Key、模型都是空，校验时会明说缺什么）
    var resolved: PipelineAISettings {
        guard let active else { return PipelineAISettings(baseURL: "", apiKey: "", model: "", agentMode: agentMode) }
        return active.settings(agentMode: agentMode)
    }
}

/// 思考强度的选项（下拉，不手输）。服务商的模型列表里**不带**「这个模型支持哪几档」，所以这里是常见的几档；
/// 选了模型不认的档位，「测试连接」会直接报错
enum ReasoningEffortOption {
    static let standard: [(label: String, value: String)] = [
        ("默认（不发）", ""), ("低", "low"), ("中", "medium"), ("高", "high"), ("最高", "max"),
    ]

    /// GLM 系列（NVIDIA 文档：`reasoning_effort` 只认 low / high / max，默认 max）。**没有「中」**：
    /// 服务商对不认的值不报错、当成没写，按默认的「最高」想——用户选了「中」还是想了十万多字（2026-10-11）
    static let glm: [(label: String, value: String)] = [("默认（不发）", ""), ("低", "low"), ("高", "high"), ("最高", "max")]

    /// 这个模型能用的档位。认得的模型家族用它文档里列的；不认识的给常见几档
    static func levels(forModel model: String) -> [(label: String, value: String)] {
        model.lowercased().contains("glm") ? glm : standard
    }

    /// 下拉里要列的：这个模型能用的几档，加上这个服务商里已经存着的别的值（比如以前手输 / 选过的 `medium`、`xhigh`），
    /// 免得打开设置就把它丢了，也让人看得出它不在这个模型认的档位里
    static func options(forModel model: String = "", including current: String?) -> [(label: String, value: String)] {
        let base = levels(forModel: model)
        let trimmed = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !base.contains(where: { $0.value == trimmed }) else { return base }
        return base + [("\(trimmed)（这个模型不认）", trimmed)]
    }

    /// 选了的档位不在这个模型认的几档里：给人看的提醒（服务商多半不报错，只是悄悄当默认用）。没问题就是 nil
    static func warning(forModel model: String, value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !levels(forModel: model).contains(where: { $0.value == trimmed }) else { return nil }
        let accepted = levels(forModel: model).filter { !$0.value.isEmpty }.map(\.label).joined(separator: " / ")
        return "这个模型只认 \(accepted)。「\(trimmed)」它不会报错，但会当成没选、按默认的「最高」想——选一个它认的。"
    }

    static func label(for value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (standard + glm).first { $0.value == trimmed }?.label ?? (trimmed.isEmpty ? "默认（不发）" : "\(trimmed)（自定义）")
    }
}

/// 服务商列表的存取。key 和单份配置（`scriptPipelineAI`）分开：列表一旦存过，`PipelineAISettingsStore.load()` 就以它为准
@MainActor
enum PipelineProviderStore {
    static let defaultsKey = "scriptPipelineProviders"

    /// 设置页用：存过列表就读列表；没存过就把现有的单份配置（老的、旧版的）变成第一张卡片，不用重填
    static func load(defaults: UserDefaults = .standard)
        -> (book: PipelineProviderBook, error: String?) {
        if let data = defaults.data(forKey: defaultsKey) {
            guard let book = try? JSONDecoder().decode(PipelineProviderBook.self, from: data) else {
                return (PipelineProviderBook(), "已保存的服务商列表无法读取，原配置未被覆盖；请检查后重新保存。")
            }
            return (book, nil)
        }
        let loaded = PipelineAISettingsStore.load(defaults: defaults)
        if let error = loaded.error { return (PipelineProviderBook(), error) }
        return (migrated(from: loaded.config), nil)
    }

    /// 单份配置 → 只有一张卡片的列表。什么都没填过（地址、Key 都空）的不算，列表保持空
    static func migrated(from config: PipelineAISettings) -> PipelineProviderBook {
        var book = PipelineProviderBook(agentMode: config.agentMode)
        let touched = !config.apiKey.trimmingCharacters(in: .whitespaces).isEmpty
        guard touched else { return book }
        let host = URL(string: config.baseURL)?.host ?? ""
        let provider = PipelineProvider(name: host.isEmpty ? "默认" : host, baseURL: config.baseURL, apiKey: config.apiKey,
                                        model: config.model, reasoningEffort: config.reasoningEffort, streaming: config.streaming)
        book.providers = [provider]
        book.activeID = provider.id
        return book
    }

    static func save(_ book: PipelineProviderBook, defaults: UserDefaults = .standard) throws {
        let data = try JSONEncoder().encode(book)
        defaults.set(data, forKey: defaultsKey)
        // 同步一份单份配置（老读取方 / 回退到旧版时还能用）；当前服务商还没配全就不动它，留着上一份好的
        _ = try? PipelineAISettingsStore.save(book.resolved, defaults: defaults)
    }
}
