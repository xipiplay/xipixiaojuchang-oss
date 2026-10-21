import Foundation

// MARK: - 1.x → 2.0 迁移执行（读旧文件、写新文件；旧文件一律不改不删）

enum LegacyMigrator {
    enum MigrationError: LocalizedError {
        case decode(String, Error)
        case projectFolderExists(String)

        var errorDescription: String? {
            switch self {
            case .decode(let file, let error): "读取 \(file) 失败：\(error.localizedDescription)"
            case .projectFolderExists(let path): "项目文件夹已存在，不覆盖：\(path)"
            }
        }
    }

    static let legacyFiles = ["shots.json", "imageItems.json", "library.json", "tasks.json"]

    /// 用旧类型解码 1.x 数据。文件不存在算空；**解码失败直接报错**，不当空数据继续（旧版曾因此丢过分镜）。
    /// `metasData` = UserDefaults 里 `projectMetas` 的原始 JSON。
    /// 日期格式跟 1.x 各自的写法一致：分镜 / 素材库 / 任务是 ISO 8601，其余是默认格式。
    static func loadSnapshot(appSupport: URL, metasData: Data?) throws -> LegacySnapshot {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        func load<T: Decodable>(_ name: String, as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
            let url = appSupport.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            do { return try decoder.decode(T.self, from: data) } catch { throw MigrationError.decode(name, error) }
        }
        var s = LegacySnapshot()
        if let metasData {
            do { s.metas = try JSONDecoder().decode([String: ProjectMeta].self, from: metasData) }
            catch { throw MigrationError.decode("projectMetas", error) }
        }
        s.shots = try load("shots.json", as: [ShotDraft].self, decoder: iso) ?? []
        s.imageItems = try load("imageItems.json", as: [ImageGenItem].self) ?? []
        s.library = try load("library.json", as: [LibraryItem].self, decoder: iso) ?? []
        s.tasks = try load("tasks.json", as: [LocalTask].self, decoder: iso) ?? []
        let pipelines = appSupport.appendingPathComponent("ScriptPipelines", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: pipelines.path)) ?? []
        for file in files.sorted() where file.hasSuffix(".json") {
            let key = String(file.dropLast(5))
            s.pipelines[key] = try load("ScriptPipelines/\(file)", as: ProjectPipelineArchive.self)
        }
        return s
    }

    /// 迁移前备份：4 个 JSON + 剧本存档目录 + 项目元数据
    static func backup(appSupport: URL, metasData: Data?, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in legacyFiles {
            let src = appSupport.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dir.appendingPathComponent(name)) }
        }
        let pipelines = appSupport.appendingPathComponent("ScriptPipelines", isDirectory: true)
        if fm.fileExists(atPath: pipelines.path) {
            try fm.copyItem(at: pipelines, to: dir.appendingPathComponent("ScriptPipelines", isDirectory: true))
        }
        if let metasData { try metasData.write(to: dir.appendingPathComponent("projectMetas.json")) }
    }

    /// 建项目文件夹、拷文件（同一磁盘上是 APFS 克隆，不额外占空间）、写 project.json。
    /// 返回拷贝失败的条目（不中断，写进报告）。
    @discardableResult
    static func execute(_ plan: MigrationPlan, projectsRoot: URL) throws -> [String] {
        let fm = FileManager.default
        for doc in plan.projects {
            let folder = projectsRoot.appendingPathComponent(doc.id, isDirectory: true)
            if fm.fileExists(atPath: folder.path) { throw MigrationError.projectFolderExists(folder.path) }
        }
        var failures: [String] = []
        for doc in plan.projects {
            let folder = projectsRoot.appendingPathComponent(doc.id, isDirectory: true)
            for sub in [ProjectDocument.imagesFolder, ProjectDocument.videosFolder, ProjectDocument.importsFolder] {
                try fm.createDirectory(at: folder.appendingPathComponent(sub, isDirectory: true),
                                       withIntermediateDirectories: true)
            }
        }
        for copy in plan.copies {
            let target = projectsRoot.appendingPathComponent(copy.projectID, isDirectory: true)
                .appendingPathComponent(copy.relativePath)
            do { try fm.copyItem(at: URL(fileURLWithPath: copy.source), to: target) }
            catch { failures.append("\(copy.source) → \(copy.projectID)/\(copy.relativePath)：\(error.localizedDescription)") }
        }
        for doc in plan.projects {
            let url = projectsRoot.appendingPathComponent(doc.id, isDirectory: true)
                .appendingPathComponent(ProjectDocument.fileName)
            try ProjectDocument.encode(doc).write(to: url, options: .atomic)
        }
        return failures
    }

    /// 旧缓存目录里没有任何记录引用的文件（跳过新项目根目录和隐藏文件）
    static func unreferencedFiles(cacheRoot: URL, skipping projectsRoot: URL, snapshot: LegacySnapshot) -> [String] {
        var referenced = Set<String>()
        for item in snapshot.imageItems { for r in item.results { if let p = r.localPath { referenced.insert(p) } } }
        for item in snapshot.library { if let p = item.localPath { referenced.insert(p) } }
        for task in snapshot.tasks { if let p = task.localVideoPath { referenced.insert(p) } }
        let skip = projectsRoot.standardizedFileURL.path + "/"
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(skip) { enumerator?.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if !referenced.contains(url.path) && !referenced.contains(path) { result.append(url.path) }
        }
        return result.sorted()
    }

    // MARK: 报告

    static func renderReport(_ r: MigrationReport, copyFailures: [String] = []) -> String {
        var out = "# 2.0 迁移报告\n\n"
        let rows = r.projects
        let total = { (f: (MigrationReport.ProjectRow) -> Int) in rows.reduce(0) { $0 + f($1) } }
        out += "迁移 \(rows.count) 个项目：剧本集 \(total(\.episodes))、剧本段 \(total(\.segments))、自由集段 \(total(\.freeSegments))、"
        out += "设定 \(total { $0.settingsByKind.values.reduce(0, +) })、图片 / 文件版本 \(total(\.mediaVersions))、视频版本 \(total(\.videoVersions))。\n\n"
        if !r.excluded.isEmpty { out += "- 不迁移：\(r.excluded.joined(separator: "、"))\n" }
        if !r.orphanKeys.isEmpty { out += "- 并进「迁移-未归属图片」的旧 key：\(r.orphanKeys.count) 个\n" }
        out += "- 不属于任何分镜卡的视频任务（不迁移）：\(r.unownedTasks)\n"
        out += "- 旧缓存目录里没有记录引用的文件（留在原处）：\(r.unreferencedFiles.count)\n"
        out += "- 拷贝失败：\(copyFailures.count)\n\n"

        out += "## 各项目\n\n"
        out += "| 项目 | 原名 | 集 | 段 | 自由集段 | 角色 | 场景 | 道具 | 其他 | 导入 | 版本 | 视频 | 待确认 | 未解析名 | 丢失文件 | 跳过任务 |\n"
        out += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for p in rows {
            let k = { (n: String) in p.settingsByKind[n] ?? 0 }
            out += "| \(p.name) | \(p.previousName ?? "") | \(p.episodes) | \(p.segments) | \(p.freeSegments) | "
            out += "\(k("角色")) | \(k("场景")) | \(k("道具")) | \(k("其他")) | \(k("导入")) | \(p.mediaVersions) | \(p.videoVersions) | "
            out += "\(p.needsReview.count) | \(p.unresolvedNames.count) | \(p.missingFiles.count) | \(p.skippedUnfinishedTasks) |\n"
        }

        let issues = rows.filter {
            !$0.needsReview.isEmpty || !$0.unresolvedNames.isEmpty || !$0.missingFiles.isEmpty
                || $0.missingTaskIDs > 0 || $0.danglingReferences > 0 || $0.crossProjectReferences > 0
        }
        if !issues.isEmpty {
            out += "\n## 需要看的地方\n"
            for p in issues {
                out += "\n### \(p.name)（\(p.id)）\n\n"
                if !p.needsReview.isEmpty { out += "- 待确认设定（同名不同描述，已合并）：\(p.needsReview.joined(separator: "、"))\n" }
                if !p.unresolvedNames.isEmpty { out += "- 段里对不上设定的名字：\(p.unresolvedNames.joined(separator: "、"))\n" }
                if p.danglingReferences > 0 { out += "- 分镜卡引用了已删除的素材：\(p.danglingReferences) 处（已去掉）\n" }
                if p.crossProjectReferences > 0 { out += "- 分镜卡引用了别的项目的素材：\(p.crossProjectReferences) 处（已在本项目建一份）\n" }
                if p.missingTaskIDs > 0 { out += "- 分镜卡记着、但任务记录已不在的视频：\(p.missingTaskIDs) 个\n" }
                if !p.missingFiles.isEmpty {
                    out += "- 丢失的文件 \(p.missingFiles.count) 个：\n"
                    for f in p.missingFiles { out += "  - `\(f)`\n" }
                }
            }
        }
        if !r.unreferencedFiles.isEmpty {
            out += "\n## 旧缓存目录里没有记录引用的文件\n\n"
            for f in r.unreferencedFiles { out += "- `\(f)`\n" }
        }
        if !copyFailures.isEmpty {
            out += "\n## 拷贝失败\n\n"
            for f in copyFailures { out += "- \(f)\n" }
        }
        return out
    }
}
