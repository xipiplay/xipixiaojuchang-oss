import Foundation

/// 提取对账（2026-10-17；方案见仓库根 `方案-提取对账.md`）：提取结果在建卡之前先和项目里**已有的全部素材**对一遍——
///
/// - **沿用**：名字（+ 阶段）已有卡、本次没有变化 → 不建卡（AI 按要求只回一行「沿用：名字」）；
/// - **新建**：这个名字项目里没有过 → 照常建卡；
/// - **变化**：输出的是变化版（带「修改内容：」的块）且找得到基础版 → 建卡 + 关联基础版；
/// - **待确认**：已有卡却给了新起始集的完整版（没写「修改内容」）、或变化版找不到基础版
///   → **不建卡**，写进对账报告等人处理。
///
/// 同一条铁律：起始集不同、描述措辞不同都不算"变化"；重复执行同一批 = 幂等（同一个版本槽不重复建）。
@MainActor
enum ExtractionReconcile {
    /// `batch`：批量提取；`refresh`：用户在提取面板勾了具体名字重提——同一个版本槽返回时**更新原卡的描述**（不建新卡）
    enum Mode { case batch, refresh }

    struct Outcome: Equatable {
        /// 建卡数（新建 + 变化）
        var created = 0
        /// 重提更新的卡数
        var updated = 0
        var notes: [String] = []
    }

    // MARK: 沿用行

    nonisolated(unsafe) private static let reusedLine = try! NSRegularExpression(pattern: #"^\s*[-*•·]?\s*沿用\s*[：:]\s*(.+?)\s*$"#)

    /// 从回复原文里扫「沿用：名字」行（`ImagePromptParser` 只认完整块，认不到这一行）。
    /// 一行可以写一个名字，也可以顿号逗号分开写几个。
    static func reusedNames(in raw: String) -> [String] {
        var result: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = reusedLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let value = ns.substring(with: m.range(at: 1))
            for part in value.components(separatedBy: CharacterSet(charactersIn: "、，,")) {
                let name = part.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’「」『』"))
                if !name.isEmpty { result.append(name) }
            }
        }
        return result
    }

    // MARK: 对账

    /// 一块输出是不是变化版：正文里有「修改内容：」那一行（三种提示词的变化版格式都带它）
    static func isChangeBlock(_ prompt: String) -> Bool {
        prompt.components(separatedBy: "\n").contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("修改内容")
        }
    }

    /// 变化版的基础版找不找得到（和 `ReferenceLinks.base(for:)` 一个口径，但对着还没建卡的输出先判）：
    /// 写了「参考：X」→ 项目里有 X；没写 → 同名同阶段更早的版本，或（新阶段）同名主时间线那张。
    static func baseExists(for parsed: ImagePromptParser.Parsed, reference: String?, kind: PipelineFlow.ExtractionKind,
                           existingAll: [ImageGenItem]) -> Bool {
        let pool = existingAll.filter { $0.type == kind.subjectType }
        let base = parsed.name, stage = CardVersion.normalizedStage(parsed.stage), episode = parsed.fromEpisode ?? 0
        if let reference {
            let target = AssetVersionName.baseName(reference)
            return pool.contains { $0.baseName == target }
        }
        if episode > 0, pool.contains(where: { $0.baseName == base && $0.hasStage(stage) && $0.versionEpisode < episode }) { return true }
        if stage != nil, pool.contains(where: { $0.baseName == base && $0.hasStage(nil) }) { return true }
        return false
    }

    /// 对账并落地。`pairs`：解析出来的完整块 + 块里「参考：X」的名字（`ReferenceLinks.splitReferenceLine` 拆好的）。
    /// `reused`：回复里「沿用：」行的名字。`listedNames`：这次名单里的逻辑名（核对沿用行用）。
    @discardableResult
    static func apply(pairs: [(card: ImagePromptParser.Parsed, reference: String?)],
                      reused: [String], mode: Mode, kind: PipelineFlow.ExtractionKind,
                      listedNames: Set<String>, project: String, app: AppModel) -> Outcome {
        var outcome = Outcome()
        let existingAll = app.imageItems.filter { $0.projectKey == project }
        var toCreate: [(card: ImagePromptParser.Parsed, reference: String?)] = []
        var updates: [(id: UUID, parsed: ImagePromptParser.Parsed, reference: String?)] = []
        var pending: [String] = []
        var skipped: [String] = []
        var newCount = 0, changeCount = 0
        /// 同一批里前面已经决定要建的卡：基础版和变化版常常在一条回复里一起回来，找基础版时也要算上它们
        var provisional: [ImageGenItem] = []
        var provisionalSlots: Set<String> = []
        func pairSlot(_ parsed: ImagePromptParser.Parsed) -> String {
            "\(parsed.name)|\(CardVersion.normalizedStage(parsed.stage) ?? "")|\(parsed.fromEpisode ?? 0)"
        }
        func provisionalItem(_ parsed: ImagePromptParser.Parsed) -> ImageGenItem {
            var item = ImageGenItem(projectKey: project, type: parsed.type, name: parsed.name, prompt: parsed.prompt)
            item.fromEpisode = parsed.fromEpisode
            item.stage = parsed.stage
            return item
        }

        for pair in pairs {
            // 「起始集：」「阶段：」行读成字段再判（和 `appendParsedImageCards` 同一口径）
            let stripped = CardVersion.takeVersionLines(pair.card)
            let base = stripped.name
            let stage = CardVersion.normalizedStage(stripped.stage)
            let slot = "\(stripped.fromEpisode ?? 0)|\(stage ?? "")"
            let siblings = existingAll.filter { $0.type == kind.subjectType && $0.baseName == base && $0.hasStage(stage) }
            let sameSlot = siblings.first { CardVersion.slot($0) == slot }

            if mode == .refresh, sameSlot != nil {
                // 同一个版本槽万一有多张卡（正常对账不会产出、历史/迁移数据可能有）：全都更新，别只改第一张（2026-10-18）
                for sibling in siblings where CardVersion.slot(sibling) == slot {
                    updates.append((sibling.id, stripped, pair.reference))
                }
                continue
            }
            if let sameSlot {
                // 同一个版本槽已经有了：不重复建（就是这个规则让重复提取幂等）
                skipped.append("「\(base)\(stage.map { "（\($0)）" } ?? "")」\(sameSlot.versionNote.map { "（\($0)）" } ?? "")已经有了，没有重复建")
                continue
            }
            if provisionalSlots.contains(pairSlot(stripped)) {
                skipped.append("「\(base)\(stage.map { "（\($0)）" } ?? "")」这次回复里回了两遍，只算一遍")
                continue
            }
            if isChangeBlock(stripped.prompt) {
                if baseExists(for: stripped, reference: pair.reference, kind: kind, existingAll: existingAll + provisional) {
                    toCreate.append(pair)
                    provisional.append(provisionalItem(stripped))
                    provisionalSlots.insert(pairSlot(stripped))
                    changeCount += 1
                } else {
                    pending.append("「\(base)」是变化版但没找到基础版（项目里没有它的原版）——没有建卡；确认是全新素材的话按基础版重提")
                }
                continue
            }
            if siblings.isEmpty, !provisional.contains(where: { $0.type == kind.subjectType && $0.baseName == base && $0.hasStage(stage) }) {
                toCreate.append(pair)
                provisional.append(provisionalItem(stripped))
                provisionalSlots.insert(pairSlot(stripped))
                newCount += 1
            } else {
                let known = siblings.isEmpty
                    ? (provisional.first { $0.type == kind.subjectType && $0.baseName == base && $0.hasStage(stage) }.map { $0.versionNote ?? "基础版" } ?? "基础版")
                    : siblings.map { $0.versionNote ?? "基础版" }.joined(separator: "、")
                pending.append("「\(base)\(stage.map { "（\($0)）" } ?? "")」已经有卡（\(known)），这次又给了\(stripped.fromEpisode.map { "第\($0)集起" } ?? "新")的完整描述但没写「修改内容」——没有建新卡；确实要新形态就按变化版重提，否则就沿用旧版")
            }
        }

        if !toCreate.isEmpty {
            let created = app.appendParsedImageCards(toCreate.map(\.card), projectKey: project)
            outcome.created = created.count
            let links = ReferenceLinks.assign(cards: created, referenceNames: toCreate.map(\.reference),
                                              items: app.imageItems.filter { $0.projectKey == project })
            app.linkReferenceCards(links.links)
            outcome.notes += links.notes
        }
        for update in updates {
            app.applyReconciledUpdate(cardID: update.id, parsed: update.parsed)
            outcome.updated += 1
            if let reference = update.reference, let card = app.imageItems.first(where: { $0.id == update.id }) {
                let links = ReferenceLinks.assign(cards: [card], referenceNames: [reference],
                                                  items: app.imageItems.filter { $0.projectKey == project })
                app.linkReferenceCards(links.links)
                outcome.notes += links.notes
            }
        }

        // 汇总
        if newCount + changeCount + outcome.updated + reused.count > 0 {
            var line = "对账：新建 \(newCount) 个、变化 \(changeCount) 个、沿用 \(reused.count) 个"
            if outcome.updated > 0 { line += "、更新 \(outcome.updated) 个" }
            outcome.notes.append(line + (pending.isEmpty ? "" : "、待确认 \(pending.count) 个"))
        }
        if !pending.isEmpty { outcome.notes.append("待确认（没有建卡）：\n" + pending.map { "· " + $0 }.joined(separator: "\n")) }
        if !skipped.isEmpty { outcome.notes.append("没有重复建：" + skipped.joined(separator: "；")) }
        // 核对沿用行：只比基础名（沿用行多半只写「周承山」，名单里可能是「周承山（四十岁）」）
        let listed = Set(listedNames.map { StageName.split($0).name })
        let unknown = reused.filter { !listed.contains(StageName.split($0).name) }
        if !unknown.isEmpty { outcome.notes.append("「沿用」行里的名字不在这次名单里：\(unknown.prefix(5).joined(separator: "、"))") }
        return outcome
    }
}
