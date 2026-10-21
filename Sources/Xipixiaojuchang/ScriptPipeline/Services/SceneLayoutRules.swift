import Foundation

/// 场景空间布局与看图约束纯规则
enum LayoutRules {
    static let visionSystem = """
    只根据所提供的场景基图提取可见空间布局。左右始终指这张基图的画面左右；前景/后景指离相机近/远。
    输出 JSON {"layout":"...","uncertainties":"..."}。
    layout 用分行短句描述：门窗的画面方位，柜台/桌椅/固定陈设方位，前后空间及通道，能看见的主要入射光方向。
    不编造不可见门窗、房间、精确尺寸、方位坐标；不能确定的放 uncertainties，不能当确定事实。
    不评价美术，不加角色或动作，不推断图片之外的故事。布局描述可直接用于分镜空间约束。
    """

    static func root(_ entry: DictEntry, dictionary: [DictEntry]) -> DictEntry? {
        guard entry.kind == "场景" else { return nil }
        var current = entry, visited = Set<UUID>()
        while let base = current.basedOn, !base.isEmpty {
            guard visited.insert(current.id).inserted,
                  let parent = dictionary.first(where: { $0.kind == "场景" && $0.name == base }) else { return nil }
            current = parent
        }
        return current
    }

    static func effective(_ entry: DictEntry, dictionary: [DictEntry]) -> String {
        guard let root = root(entry, dictionary: dictionary) else { return "" }
        var lines: [String] = []
        if let layout = root.sceneLayout, layout.reviewed, !layout.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("基场景 \(root.name)（以基图画面左右为准）：\n" + layout.text)
        }
        // 子场景继承父级布局，并附加本子区的局部结构
        var current = entry, visited = Set<UUID>(), children: [DictEntry] = []
        while current.id != root.id && visited.insert(current.id).inserted {
            if current.relation == "子场景" { children.append(current) }
            guard let base = current.basedOn,
                  let parent = dictionary.first(where: { $0.kind == "场景" && $0.name == base }) else { break }
            current = parent
        }
        for child in children.reversed() {
            if let local = child.sceneLayout, local.reviewed {
                let relative = local.relativePosition.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = local.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !relative.isEmpty || !text.isEmpty {
                    lines.append("子区 \(child.name)：" + (relative.isEmpty ? "" : "相对位置：" + relative + "\n") + text)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 截取完整的陈述句，避免把“右侧”截断成有歧义的碎片
    static func limited(_ text: String, characters: Int) -> String {
        guard characters > 0, text.count > characters else { return text }
        var result = ""
        for fact in text.replacingOccurrences(of: "。", with: "。\n").components(separatedBy: .newlines) {
            if fact.isEmpty { continue }
            let next = result.isEmpty ? fact : result + "\n" + fact
            if next.count > characters { break }
            result = next
        }
        return result
    }

    static func injection(_ segment: BoundSegment, dictionary: [DictEntry], characterLimit: Int) -> String {
        var seen = Set<UUID>(), parts: [String] = []
        for binding in segment.bindings where binding.kind == "场景" && binding.usage == "出镜" {
            guard binding.approved, let entry = BindingRules.entry(binding, in: dictionary),
                  seen.insert(entry.id).inserted else { continue }
            let text = limited(effective(entry, dictionary: dictionary), characters: characterLimit)
            if !text.isEmpty { parts.append("本段场景 \(entry.name)｜\(binding.scope)\n" + text) }
        }
        return parts.isEmpty ? "" : "【场景布局】\n" + parts.joined(separator: "\n\n")
    }

    static func parseVision(_ raw: String) throws -> SceneLayoutData {
        struct Response: Decodable { var layout: String; var uncertainties: String? }
        let jsonStr = PipelineAIService.extractJSON(raw)
        guard let data = jsonStr.data(using: .utf8),
              let value = try? JSONDecoder().decode(Response.self, from: data),
              !value.layout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PipelineAIError.invalidResult("看图回复缺少可用 layout；已有布局保留，可人工填写")
        }
        return SceneLayoutData(
            text: value.layout.trimmingCharacters(in: .whitespacesAndNewlines),
            relativePosition: "",
            reviewed: false,
            source: "看图提取",
            imagePath: nil,
            imageRevision: nil,
            rawReply: raw,
            uncertainties: value.uncertainties ?? "",
            lastError: ""
        )
    }

    /// 保留版本批准与段落 ID；仅使场景结构变化的下游分镜失效
    static func update(_ id: UUID, value: SceneLayoutData, dictionary: inout [DictEntry], works: inout [EpWork]) throws {
        guard let index = dictionary.firstIndex(where: { $0.id == id && $0.kind == "场景" }),
              dictionary[index].basedOn == nil || dictionary[index].relation == "子场景" else {
            throw PipelineAIError.invalidResult("布局只存根场景或子场景，变体请编辑继承来源")
        }
        guard dictionary[index].sceneLayout != value else { return }
        dictionary[index].sceneLayout = value
        for i in works.indices {
            let affected = works[i].boundSegments.contains { segment in
                segment.bindings.contains { binding in
                    guard binding.kind == "场景", let entry = BindingRules.entry(binding, in: dictionary) else { return false }
                    if entry.id == id || root(entry, dictionary: dictionary)?.id == id { return true }
                    var current = entry, seen = Set<UUID>()
                    while let base = current.basedOn, seen.insert(current.id).inserted {
                        guard let parent = dictionary.first(where: { $0.kind == "场景" && $0.name == base }) else { break }
                        if parent.id == id { return true }; current = parent
                    }
                    return false
                }
            }
            if affected { PipelineRules.invalidate(&works[i], from: 2) }
        }
    }
}
