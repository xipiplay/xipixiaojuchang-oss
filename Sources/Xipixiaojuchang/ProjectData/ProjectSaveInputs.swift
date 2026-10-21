import Foundation

/// 一个项目存盘时要用到的全部输入（2026-10-12 稳定性：存盘只重新组装改过的项目）。
/// 和上次存盘时的一份比，不一样 = 这个项目改过。凡是会影响这个项目 `project.json` 的东西都要在这里：
/// 元信息、分镜、生图卡、它自己的素材库条目、它名下的视频任务、剧本存档，以及它**引用到的别的项目的素材**
/// （跨项目引用会作为副本写进本项目，那条素材变了本项目也要重写）。漏了哪一样，那一样改了就不会存——加新数据时记得补进来
struct ProjectSaveInputs: Equatable {
    var meta: ProjectMeta?
    var shots: [ShotDraft] = []
    var imageItems: [ImageGenItem] = []
    var library: [LibraryItem] = []
    var tasks: [LocalTask] = []
    var pipeline: ProjectPipelineArchive?
    /// 引用到的、不属于本项目的素材库条目（按 ID 排序）
    var foreignLibrary: [LibraryItem] = []

    /// 按项目分组。项目的范围和存盘时组装的一样：有元信息 / 分镜 / 剧本 / 生图卡 / 素材的 key 都算
    static func group(_ s: LegacySnapshot) -> [String: ProjectSaveInputs] {
        var result: [String: ProjectSaveInputs] = [:]
        for (key, meta) in s.metas { result[key, default: .init()].meta = meta }
        for shot in s.shots where !shot.projectKey.isEmpty { result[shot.projectKey, default: .init()].shots.append(shot) }
        for item in s.imageItems where !item.projectKey.isEmpty { result[item.projectKey, default: .init()].imageItems.append(item) }
        for item in s.library { if let key = item.projectKey, !key.isEmpty { result[key, default: .init()].library.append(item) } }
        for (key, archive) in s.pipelines { result[key, default: .init()].pipeline = archive }

        // 视频任务归**按分镜顺序第一个引用它**的项目（和 `LegacyMigrationPlanner.plan` 的 taskOwner 同一条规则）
        let tasksByID = Dictionary(s.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var taskOwner: [String: String] = [:]
        for shot in s.shots {
            for id in shot.taskIDs + [shot.taskID].compactMap({ $0 }) where taskOwner[id] == nil { taskOwner[id] = shot.projectKey }
        }
        let libraryByID = Dictionary(s.library.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, var inputs) in result {
            for shot in inputs.shots {
                for id in shot.taskIDs + [shot.taskID].compactMap({ $0 }) where taskOwner[id] == key {
                    if let task = tasksByID[id], !inputs.tasks.contains(where: { $0.id == id }) { inputs.tasks.append(task) }
                }
            }
            var referenced = Set<UUID>()
            for shot in inputs.shots { for ref in shot.imageRefs + shot.videoRefs + shot.audioRefs { referenced.insert(ref.libraryItemID) } }
            for item in inputs.imageItems { for ref in item.imageRefs { referenced.insert(ref.libraryItemID) } }
            for work in inputs.pipeline?.simpleWorks ?? [] { for asset in work.assets { if let id = asset.libraryItemID { referenced.insert(id) } } }
            inputs.foreignLibrary = referenced.compactMap { libraryByID[$0] }.filter { $0.projectKey != key }.sorted { $0.id.uuidString < $1.id.uuidString }
            result[key] = inputs
        }
        return result
    }
}
