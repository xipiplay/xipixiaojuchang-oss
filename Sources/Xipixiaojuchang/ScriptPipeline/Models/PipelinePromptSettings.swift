import Foundation

/// 剧本流水线可自定义提示词（2026-10-06 用户定）。
/// 各字段留空 = 使用内置默认（分集常量 / Resources/Prompts 资源 / 内置提取规则）。
struct PipelinePromptSettings: Codable, Equatable, Sendable {
    var split = ""
    var segments = ""
    var role = ""
    /// 旧的「场景与道具」合在一起的提示词（2026-10-07 起拆成 `scene` / `prop`，这个字段只为读取旧数据保留，不再用）
    var sceneProp = ""
    var scene = ""
    var prop = ""
    var storyboard = ""
    /// 分段命名（2026-10-11）：给每个 30 秒段写【场景】【角色】【道具】【本段在场】四行名字
    var naming = ""

    init(split: String = "", segments: String = "", role: String = "", sceneProp: String = "", scene: String = "", prop: String = "",
         storyboard: String = "", naming: String = "") {
        self.split = split
        self.segments = segments
        self.role = role
        self.sceneProp = sceneProp
        self.scene = scene
        self.prop = prop
        self.storyboard = storyboard
        self.naming = naming
    }

    /// 自己写解码：合成的解码器遇到缺的键会整份读失败，用户之前存的提示词就全没了（`load()` 读失败回默认）。
    /// 新加的项在老存档里没有，一律按「空 = 用内置默认」读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        split = try c.decodeIfPresent(String.self, forKey: .split) ?? ""
        segments = try c.decodeIfPresent(String.self, forKey: .segments) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        sceneProp = try c.decodeIfPresent(String.self, forKey: .sceneProp) ?? ""
        scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        prop = try c.decodeIfPresent(String.self, forKey: .prop) ?? ""
        storyboard = try c.decodeIfPresent(String.self, forKey: .storyboard) ?? ""
        naming = try c.decodeIfPresent(String.self, forKey: .naming) ?? ""
    }
}

/// 与主工程其它配置相同：UserDefaults 内 JSON 存法；读取只读，用户点保存才写入。
enum PipelinePromptSettingsStore {
    static let defaultsKey = "scriptPipelinePrompts"

    static func load(defaults: UserDefaults = .standard) -> PipelinePromptSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(PipelinePromptSettings.self, from: data) else {
            return PipelinePromptSettings()
        }
        return value
    }

    static func save(_ value: PipelinePromptSettings, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
