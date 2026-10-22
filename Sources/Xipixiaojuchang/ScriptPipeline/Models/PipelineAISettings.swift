import Foundation

struct PipelineAISettings: Codable, Equatable, Sendable {
    var baseURL = "https://api.deepseek.com"
    var apiKey = ""
    var model = "deepseek-flash"
    /// 外部智能体接力（2026-10-07）：开着时，文字类 AI 请求不调上面的 API，改成放进收件目录，由外部智能体回答；
    /// 软件也开始接收命令文件（见 `AgentBridge`）。⚠️ 必须可选：旧的已保存配置里没有这个键。
    var agentMode: Bool?
    /// 思考强度（2026-10-11）：留空 = 不发这个参数，用模型自己的默认；填了就随请求发 `reasoning_effort`。
    /// 起因：NVIDIA 上的 GLM-5.3 默认思考到最深（`max`），一集分割要想五分钟以上，被服务商网关在约 300 秒处断开（HTTP 504）。
    /// 常见取值 `low` / `medium` / `high` / `max`，各家支持的不一样，按服务商文档填。⚠️ 必须可选：旧的已保存配置里没有这个键。
    var reasoningEffort: String?
    /// 流式接收（2026-10-11）：nil / true = 边生成边收（任务抽屉里能实时看到思考和输出，也不容易被网关因为等太久断开）；
    /// false = 等整份回答写完再收（个别中转站不支持流式时关掉）。⚠️ 必须可选：旧的已保存配置里没有这个键。
    var streaming: Bool?
    var usesStreaming: Bool { streaming != false }
    /// 同时请求数（2026-10-12 用户要的，设置里每张服务商卡片一个）：批量分割同时跑几集；提取素材每一类同时发几个请求（最多 3）。
    /// nil = 默认 5。起因：NVIDIA 免费接口 5 个一起发也回了一串 429。⚠️ 必须可选：旧的已保存配置里没有这个键
    var concurrency: Int?
    static let concurrencyRange = 1...10
    static let defaultConcurrency = 5
    var requestConcurrency: Int { min(max(concurrency ?? Self.defaultConcurrency, Self.concurrencyRange.lowerBound), Self.concurrencyRange.upperBound) }

    var usesAgent: Bool { agentMode == true }

    func validated() throws -> Self {
        var result = self
        result.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort = reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        result.reasoningEffort = effort.isEmpty ? nil : effort
        // 接力模式不用 API：地址 / 模型 / Key 原样保留（关掉接力后还在），不要求填
        if usesAgent { return result }
        let url = URL(string: result.baseURL)
        guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw PipelineSettingsError.invalid("接口地址需为完整的 http/https 地址，不能含账号、查询参数或片段。")
        }
        guard !result.model.isEmpty else { throw PipelineSettingsError.invalid("请填写模型名称。") }
        guard !result.apiKey.isEmpty else { throw PipelineSettingsError.invalid("请填写 API Key。") }
        return result
    }
}

enum PipelineSettingsError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

/// 与主工程渠道采用相同的 UserDefaults JSON 存法。加载只读，用户保存才写入。
@MainActor
enum PipelineAISettingsStore {
    static let defaultsKey = "scriptPipelineAI"
    static let legacyKey = "pipelinePreviewAI"

    struct Loaded {
        var config: PipelineAISettings
        var inherited: Bool = false
        var error: String?
    }

    /// 2026-10-23 去掉了读早期样例程序 `~/Library/Preferences/ScriptPipelineSample.plist` 的兜底：
    /// 那是别的程序留下的文件（里面带密钥），开源版第一次打开会把它读进来
    static func load(defaults: UserDefaults = .standard) -> Loaded {
        // 设置页存过「服务商列表」（2026-10-11）：以它里面当前使用的那个为准；没存过才走下面的老路径（老的单份配置 / 旧版）
        if let data = defaults.data(forKey: PipelineProviderStore.defaultsKey) {
            guard let book = try? JSONDecoder().decode(PipelineProviderBook.self, from: data) else {
                return Loaded(config: PipelineAISettings(), error: "已保存的服务商列表无法读取，原配置未被覆盖；请检查后重新保存。")
            }
            return Loaded(config: book.resolved)
        }
        if let data = defaults.data(forKey: defaultsKey) {
            guard let config = try? JSONDecoder().decode(PipelineAISettings.self, from: data) else {
                return Loaded(config: PipelineAISettings(), error: "已保存的流水线配置无法读取，原配置未被覆盖；请检查后重新保存。")
            }
            return Loaded(config: config)
        }
        if let data = defaults.data(forKey: legacyKey),
           let config = try? JSONDecoder().decode(PipelineAISettings.self, from: data) {
            return Loaded(config: config, inherited: true)
        }
        return Loaded(config: PipelineAISettings())
    }

    @discardableResult
    static func save(_ config: PipelineAISettings, defaults: UserDefaults = .standard) throws -> PipelineAISettings {
        let checked = try config.validated()
        let data = try JSONEncoder().encode(checked)
        defaults.set(data, forKey: defaultsKey)
        return checked
    }
}
