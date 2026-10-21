import Foundation

/// 映射直导建卡服务（P3：分镜卡 + 生图条目 + 素材待办）
/// 严格遵循：零 AI 调用、幂等、事务化、用户已生成/已编辑条目不静默覆盖
enum DirectPublishService {

    // MARK: - 1. 生图条目直导与更新

    struct ImagePublishResult: Sendable {
        var createdItems: [ImageGenItem] = []
        var updatedItems: [ImageGenItem] = []
        var conflicts: [String] = []
        var totalCount: Int { createdItems.count + updatedItems.count }
    }

    /// 在单集描述锁定后，尽早建/更新生图条目
    static func publishImageItems(
        projectKey: String,
        entries: [DictEntry],
        existingItems: [ImageGenItem],
        library: [LibraryItem] = []
    ) -> (allImageItems: [ImageGenItem], result: ImagePublishResult) {
        var items = existingItems
        var result = ImagePublishResult()

        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            let prompt = PipelineRules.referencePrompt(entry)
            let subjectType = ImageSubjectType.from(kind: entry.kind)

            // 变体基图引用：若基于本体条目，尝试关联本体的素材作为最初版参考图
            var baseRefs: [MaterialRef] = []
            if let baseName = entry.basedOn, !baseName.isEmpty {
                if let lib = library.first(where: { $0.projectKey == projectKey && $0.name == baseName }) {
                    baseRefs.append(MaterialRef(libraryItemID: lib.id))
                }
            }

            // 查找同名已建条目（按项目与内部全名隔离）
            if let idx = items.firstIndex(where: { $0.projectKey == projectKey && $0.name == name }) {
                let existing = items[idx]
                // 冲突保护：若用户已生成过图片（已有版本结果）或正在生成中，不静默覆盖
                if !existing.results.isEmpty || existing.status == .generating {
                    result.conflicts.append("条目「\(name)」已有生成图或生成中，保留原图不覆盖")
                    continue
                }
                // 未生成的条目支持提示词与关系更新
                items[idx].prompt = prompt
                items[idx].type = subjectType
                if items[idx].imageRefs.isEmpty && !baseRefs.isEmpty {
                    items[idx].imageRefs = baseRefs
                }
                result.updatedItems.append(items[idx])
            } else {
                // 新建条目
                let newItem = ImageGenItem(
                    projectKey: projectKey,
                    type: subjectType,
                    name: name,
                    prompt: prompt,
                    imageRefs: baseRefs,
                    status: .pending
                )
                items.append(newItem)
                result.createdItems.append(newItem)
            }
        }

        return (items, result)
    }

    // MARK: - 2. 分镜卡直导建卡

    struct ShotPublishResult: Sendable {
        var createdShots: [ShotDraft] = []
        var updatedShots: [ShotDraft] = []
        var createdLibraryCount: Int = 0
        var skippedCount: Int = 0
        var conflicts: [String] = []
    }

    /// 在每集名字校验通过后，直接建分镜卡并关联素材待办（纯 Swift 直建，零 AI 消耗）
    static func publishEpisodeShotsDirect(
        projectKey: String,
        episodeIndex: Int,
        durationSeconds: Int,
        finalShots: [String],
        boundSegments: [BoundSegment],
        dictionary: [DictEntry],
        existingShots: [ShotDraft],
        existingLibrary: [LibraryItem],
        segmentIndices: Set<Int>? = nil,
        referenceLibraryIDs: [Int: [UUID]] = [:]
    ) -> (allShots: [ShotDraft], allLibrary: [LibraryItem], result: ShotPublishResult) {
        var shots = existingShots
        var library = existingLibrary
        var result = ShotPublishResult()

        for (i, text) in finalShots.enumerated() {
            // 单段建卡仍沿用原段号；默认 nil 保持整集发布与 --run 的既有行为。
            guard segmentIndices?.contains(i) != false else { continue }
            let submitted = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !submitted.isEmpty else { continue }
            let segIndex = i + 1
            let numbering = ShotNumbering(a: episodeIndex, b: segIndex)

            // 组装本段出镜素材引用及待办
            var imageRefs: [MaterialRef] = []
            if let resolvedIDs = referenceLibraryIDs[i] {
                // 工作台已解析真实入库图片的 ID；不再为同一图创建空的同名素材。
                imageRefs = resolvedIDs.compactMap { id in
                    library.first { $0.id == id && $0.projectKey == projectKey && $0.kind == .image }
                }.map { MaterialRef(libraryItemID: $0.id) }
            } else if boundSegments.indices.contains(i) {
                let seg = boundSegments[i]
                for binding in seg.bindings where binding.usage == "出镜" {
                    let rawName = BindingRules.entry(binding, in: dictionary)?.name ?? binding.internalName
                    let libItem: LibraryItem
                    if let found = library.first(where: { $0.projectKey == projectKey && $0.name == rawName }) {
                        libItem = found
                    } else {
                        let created = LibraryItem(
                            kind: .image,
                            localPath: nil,
                            name: rawName,
                            projectKey: projectKey
                        )
                        library.append(created)
                        result.createdLibraryCount += 1
                        libItem = created
                    }
                    imageRefs.append(MaterialRef(libraryItemID: libItem.id))
                }
            }

            // 幂等查重与冲突检测
            if let existingIdx = shots.firstIndex(where: {
                $0.projectKey == projectKey &&
                $0.numbering?.a == episodeIndex &&
                $0.numbering?.b == segIndex
            }) {
                let existing = shots[existingIdx]
                // 冲突保护：若卡片已被用户提交生成任务，不静默覆盖
                if existing.taskID != nil || !existing.taskIDs.isEmpty {
                    result.conflicts.append("第 \(episodeIndex) 集第 \(segIndex) 段已有生成任务，跳过覆盖")
                    result.skippedCount += 1
                    continue
                }
                // 未提交任务时支持更新分镜文案与素材关联
                if existing.prompt == submitted && existing.imageRefs == imageRefs {
                    result.skippedCount += 1
                    continue
                }
                shots[existingIdx].prompt = submitted
                shots[existingIdx].duration = durationSeconds
                shots[existingIdx].imageRefs = imageRefs
                result.updatedShots.append(shots[existingIdx])
            } else {
                // 新建分镜卡
                let newShot = ShotDraft(
                    projectKey: projectKey,
                    prompt: submitted,
                    duration: durationSeconds,
                    imageRefs: imageRefs,
                    numbering: numbering
                )
                shots.append(newShot)
                result.createdShots.append(newShot)
            }
        }

        return (shots, library, result)
    }

    /// 在每集名字校验通过后，使用标准交付包直接建分镜卡
    static func publishEpisodeShots(
        projectKey: String,
        episodeIndex: Int,
        package: SubmissionPackage,
        existingShots: [ShotDraft],
        existingLibrary: [LibraryItem]
    ) -> (allShots: [ShotDraft], allLibrary: [LibraryItem], result: ShotPublishResult) {
        var shots = existingShots
        var library = existingLibrary
        var result = ShotPublishResult()

        for card in package.segments {
            let submitted = card.submittedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !submitted.isEmpty else { continue }

            let numbering = ShotNumbering(a: episodeIndex, b: card.segmentIndex)

            // 幂等查重：检查当前项目中是否已存在该集该段
            if let existingIdx = shots.firstIndex(where: {
                $0.projectKey == projectKey &&
                $0.numbering?.a == episodeIndex &&
                $0.numbering?.b == card.segmentIndex
            }) {
                let existing = shots[existingIdx]
                // 冲突保护：若卡片已被用户提交生成任务，不静默覆盖
                if existing.taskID != nil || !existing.taskIDs.isEmpty {
                    result.conflicts.append("第 \(episodeIndex) 集第 \(card.segmentIndex) 段已有生成任务，跳过覆盖")
                    result.skippedCount += 1
                    continue
                }
                // 若内容未变，视为已存在
                if existing.prompt == submitted {
                    result.skippedCount += 1
                    continue
                }
            }

            // 组装素材引用与待办条目
            var imageRefs: [MaterialRef] = []
            for ref in card.bindings where ref.usageType == "出镜" && ref.assetState != "无需图" {
                let name = ref.internalNameSnapshot
                // 检索素材库是否已有该条目
                let libItem: LibraryItem
                if let found = library.first(where: { $0.projectKey == projectKey && $0.name == name }) {
                    libItem = found
                } else {
                    let created = LibraryItem(
                        kind: .image,
                        localPath: nil,
                        name: name,
                        projectKey: projectKey
                    )
                    library.append(created)
                    result.createdLibraryCount += 1
                    libItem = created
                }
                imageRefs.append(MaterialRef(libraryItemID: libItem.id))
            }

            // 新建分镜卡
            let newShot = ShotDraft(
                projectKey: projectKey,
                prompt: submitted,
                duration: card.durationSeconds,
                imageRefs: imageRefs,
                numbering: numbering
            )
            shots.append(newShot)
            result.createdShots.append(newShot)
        }

        return (shots, library, result)
    }

    // MARK: - 3. 从文件直导建卡（零 AI 解析）

    static func importFromPackageFiles(
        packageURL: URL,
        projectKey: String,
        existingShots: [ShotDraft],
        existingLibrary: [LibraryItem]
    ) throws -> (allShots: [ShotDraft], allLibrary: [LibraryItem], result: ShotPublishResult) {
        let data = try Data(contentsOf: packageURL)
        let package = try JSONDecoder().decode(SubmissionPackage.self, from: data)

        return publishEpisodeShots(
            projectKey: projectKey,
            episodeIndex: package.episodeIndex,
            package: package,
            existingShots: existingShots,
            existingLibrary: existingLibrary
        )
    }
}

// MARK: - ImageSubjectType 辅助映射

extension ImageSubjectType {
    static func from(kind: String) -> ImageSubjectType? {
        switch kind {
        case "角色": return .character
        case "场景": return .scene
        case "道具": return .prop
        default: return nil
        }
    }
}
