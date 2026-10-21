import Foundation

/// 直接改分镜头行 `[场景][角色][道具]` 里的名字（2026-10-09 工作台「本段素材」的加 / 删）。
///
/// 一段分镜有哪些素材，**只认头行**——「本段素材」每一行、提取用的名字清单、应用素材往头行名字前插「图N」，读的都是它。
/// 所以「本段素材」里加、删名字，就是改头行本身，不另存一份清单（另存会和头行对不上）。
/// 只动提示词的第一行里对应那一组方括号，别的字原样不动；别的项上已有的「图N」标记也原样留着。
enum HeadLineEdit {
    typealias Kind = PipelineFlow.ExtractionKind

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    nonisolated(unsafe) private static let bracketRegex = try! NSRegularExpression(pattern: #"\[([^\[\]\n]*)\]"#)
    private static let separators: Set<Character> = ["、", "，", ",", "；", ";"]
    private static let forbidden = CharacterSet(charactersIn: "[]【】、，,；;\n")

    private static func groupIndex(_ kind: Kind) -> Int {
        switch kind {
        case .scene: 0
        case .role: 1
        case .prop: 2
        }
    }

    /// 头行（第一个非空行）和三组方括号里内容的范围（相对这一行）。第一行不是头行 → nil
    private static func locate(_ prompt: String) -> (lines: [String], lineIndex: Int, groups: [NSRange])? {
        let lines = prompt.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), StoryboardInference.isHeader(lines[i]) else { return nil }
        let ns = lines[i] as NSString
        let groups = bracketRegex.matches(in: lines[i], range: NSRange(location: 0, length: ns.length)).prefix(3).map { $0.range(at: 1) }
        return groups.count == 3 ? (lines, i, Array(groups)) : nil
    }

    private struct Item {
        var text: String
        /// 这一项后面跟的分隔符（最后一项没有）
        var separator: String
    }

    private static func items(of content: String) -> [Item] {
        var result: [Item] = []
        var current = ""
        for ch in content {
            if separators.contains(ch) { result.append(Item(text: current, separator: String(ch))); current = "" } else { current.append(ch) }
        }
        result.append(Item(text: current, separator: ""))
        return result
    }

    private static func content(of items: [Item]) -> String { items.map { $0.text + $0.separator }.joined() }

    private static func replacing(group index: Int, with newContent: String, in found: (lines: [String], lineIndex: Int, groups: [NSRange])) -> String {
        var lines = found.lines
        lines[found.lineIndex] = (lines[found.lineIndex] as NSString).replacingCharacters(in: found.groups[index], with: newContent)
        return lines.joined(separator: "\n")
    }

    /// 头行里现有的所有名字（三组合起来，用来查重）
    private static func existingNames(_ found: (lines: [String], lineIndex: Int, groups: [NSRange])) -> Set<String> {
        let line = found.lines[found.lineIndex] as NSString
        var result = Set<String>()
        for (index, range) in found.groups.enumerated() {
            for item in items(of: line.substring(with: range)) {
                let name = StoryboardNames.cleanName(item.text, isScene: index == 0)
                if !name.isEmpty { result.insert(name) }
            }
        }
        return result
    }

    /// 在 `kind` 那一组方括号的末尾加一个名字
    static func adding(_ name: String, kind: Kind, to prompt: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure("名字不能是空的。") }
        guard trimmed.unicodeScalars.allSatisfy({ !forbidden.contains($0) }), trimmed.count <= 30 else {
            throw Failure("名字里不能有方括号、顿号、逗号这类符号，也不要太长（30 字以内）。")
        }
        guard let found = locate(prompt) else { throw Failure("这一段的提示词第一行不是「[场景][角色][道具]」的格式，没法在这里加。可以点提示词框去改。") }
        guard !existingNames(found).contains(StoryboardNames.cleanName(trimmed, isScene: kind == .scene)) else {
            throw Failure("「\(trimmed)」已经在这一段的头行里了。")
        }
        let index = groupIndex(kind)
        let old = (found.lines[found.lineIndex] as NSString).substring(with: found.groups[index])
        let base = old.trimmingCharacters(in: .whitespaces)
        let joined = base.isEmpty ? trimmed : (base.last.map(separators.contains) == true ? base + trimmed : base + "、" + trimmed)
        return replacing(group: index, with: joined, in: found)
    }

    /// 从头行里删掉这个名字（在哪一组都行）。名字前面的「图N」标记跟着这一项一起去掉；别的项不动
    static func removing(_ name: String, from prompt: String) throws -> String {
        guard let found = locate(prompt) else { throw Failure("这一段的提示词第一行不是「[场景][角色][道具]」的格式，没法在这里删。可以点提示词框去改。") }
        let line = found.lines[found.lineIndex] as NSString
        for (index, range) in found.groups.enumerated() {
            var list = items(of: line.substring(with: range))
            guard let k = list.firstIndex(where: { StoryboardNames.cleanName($0.text, isScene: index == 0) == name }) else { continue }
            list.remove(at: k)
            if k == list.count, k > 0 { list[k - 1].separator = "" }          // 删的是最后一项：前一项后面的分隔符也不要了
            let rest = content(of: list)
            return replacing(group: index, with: rest.trimmingCharacters(in: .whitespaces).isEmpty ? "" : rest, in: found)
        }
        throw Failure("头行里找不到「\(name)」。")
    }
}

/// 「本段素材」里加 / 删素材名：改这一段分镜提示词的头行，删的时候一并去掉它挂着的参考图（并把后面的「图N」重新编号）
@MainActor
enum WorkbenchMaterialEdit {
    typealias Kind = PipelineFlow.ExtractionKind

    static func add(name: String, kind: Kind, shotID: UUID, app: AppModel) throws {
        guard let index = app.shots.firstIndex(where: { $0.id == shotID }) else { throw HeadLineEdit.Failure("这一段的分镜卡已经不在了。") }
        app.shots[index].prompt = try HeadLineEdit.adding(name, kind: kind, to: app.shots[index].prompt)
        app.touchProject(app.shots[index].projectKey)
        app.persistShots()
    }

    static func remove(name: String, shotID: UUID, app: AppModel) throws {
        guard let first = app.shots.first(where: { $0.id == shotID }) else { throw HeadLineEdit.Failure("这一段的分镜卡已经不在了。") }
        // 逻辑名「周承山（四十岁）」：头行里写的是基础名「周承山」（阶段在分割文本的【阶段】行里）；头行里本来就写着带括号的就删它
        let headName = (try? HeadLineEdit.removing(name, from: first.prompt)) != nil ? name : StageName.split(name).name
        // 先确认头行里改得动，再动参考图——改不动就什么都不变
        _ = try HeadLineEdit.removing(headName, from: first.prompt)
        // 这个名字挂着的参考图：一个一个去掉（每去一个，提示词里的「图N」跟着清掉、后面的编号前移）
        // （名字一模一样的、和只差重名序号的都算它的，见 `ownedRefIndices`）
        while let shot = app.shots.first(where: { $0.id == shotID }),
              let index = WorkbenchVersions.ownedRefIndices(name: name, shot: shot, app: app).first {
            app.removeShotMaterial(shotID: shotID, refID: shot.imageRefs[index].id)
        }
        guard let index = app.shots.firstIndex(where: { $0.id == shotID }) else { return }
        app.shots[index].prompt = try HeadLineEdit.removing(headName, from: app.shots[index].prompt)
        app.touchProject(app.shots[index].projectKey)
        app.persistShots()
    }
}
