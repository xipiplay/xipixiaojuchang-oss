import AppKit
import Foundation

// MARK: - 项目文件夹的读写（2.0）
//
// `<根目录>/<项目ID>/project.json` + images/ videos/ imports/。
// - 读：启动时读全部 project.json（P1 仍整体加载；「只加载当前项目」在后面的批次做）。
// - 写：只写和上次存的不一样的项目；读不出来的项目文件夹永不覆盖。
// - 删项目：整个文件夹移到废纸篓。
// - 1.x 数据：第一次启动 2.0 时一次性迁移（先备份，旧文件一律不改不删）。

/// 2026-10-13 起存盘在后台串行队列上做（`queue`，见 `AppModel.saveProjectsInBackground`）：
/// 组装、编码、写文件都不占主线程。**所有会写盘 / 删项目的操作都排在这条队列上**，先后顺序就是排队的顺序——
/// 删项目也走它，否则更早排队的一次存盘可能在删除之后才执行、把刚删的项目文件夹写回来。
/// 主线程还会读 `saved` / `unreadable`：都加锁
final class ProjectStore: @unchecked Sendable {
    static let rootDefaultsKey = "projectsRootPath"

    let root: URL
    /// 存盘用的串行队列
    let queue = DispatchQueue(label: "io.github.xipiplay.xipixiaojuchang.projectsave", qos: .utility)
    private let lock = NSLock()
    private var _saved: [String: ProjectDocument] = [:]
    private var _unreadable: [String: String] = [:]
    private var _lastBuiltKeys: Set<String> = []
    /// 每个项目上次存盘时的输入（只在 `queue` 上读写；见 `saveChanged`）。启动后第一次存盘时是空的 → 全部组装一遍
    private var savedInputs: [String: ProjectSaveInputs] = [:]

    /// 上次读到 / 存下的文档（比较用，也给换算沿用 ID）
    var saved: [String: ProjectDocument] { lock.withLock { _saved } }
    /// 读失败的项目文件夹（不覆盖、不删除）
    var unreadable: [String: String] { lock.withLock { _unreadable } }
    /// 上一次存盘重新组装了哪些项目（测试 / 排查用）
    var lastBuiltKeys: Set<String> { lock.withLock { _lastBuiltKeys } }

    init(root: URL) {
        self.root = root
    }

    /// 只重新组装**改过的**项目再存（2026-10-12 稳定性；原来每次把全部项目都组装一遍）：
    /// 把每个项目自己的输入和上次存盘时比（见 `ProjectSaveInputs`），不靠各处记得「标脏」，哪里改了都漏不掉。
    /// 在 `queue` 上调用。返回值同 `save`
    func saveChanged(_ snapshot: LegacySnapshot) -> [String: String] {
        let inputs = ProjectSaveInputs.group(snapshot)
        let changed = Set(inputs.keys.filter { savedInputs[$0] != inputs[$0] })
        savedInputs = savedInputs.filter { inputs[$0.key] != nil }       // 删掉的项目不留
        guard !changed.isEmpty else { return [:] }
        let moved = save(snapshot, only: changed)
        for key in changed { savedInputs[key] = inputs[key] }
        return moved
    }

    /// 已迁移过：返回记下的根目录；没迁移过：nil
    nonisolated static var recordedRoot: URL? {
        UserDefaults.standard.string(forKey: rootDefaultsKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func loadAll() -> [ProjectDocument] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var docs: [ProjectDocument] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            let file = folder(name).appendingPathComponent(ProjectDocument.fileName)
            guard fm.fileExists(atPath: file.path) else { continue }
            do {
                let doc = try ProjectDocument.decode(Data(contentsOf: file))
                docs.append(doc)
                lock.withLock { _saved[doc.id] = doc }
            } catch {
                lock.withLock { _unreadable[name] = error.localizedDescription }
                AppLog.write("project", "读取项目 \(name) 失败（不会覆盖）：\(error.localizedDescription)")
            }
        }
        return docs
    }

    /// 旧页面的数组 → 项目文档 → 写盘。返回搬进项目文件夹的外部文件（旧绝对路径 → 新绝对路径），
    /// 调用方据此把内存里的路径改过来。
    /// `only`：只组装这几个项目（别的项目这次没改，不用重算；查找表照旧用全量，跨项目引用的素材照样找得到）。nil = 全部
    @discardableResult
    func save(_ snapshot: LegacySnapshot, only: Set<String>? = nil) -> [String: String] {
        let fm = FileManager.default
        var options = MigrationOptions.live(root: root, previous: saved)
        options.onlyKeys = only
        let plan = LegacyMigrationPlanner.plan(snapshot, options: options) { fm.fileExists(atPath: $0) }
        lock.withLock { _lastBuiltKeys = Set(plan.projects.map(\.id)) }
        var relocated: [String: String] = [:]
        var failed: [String: [String: String]] = [:]   // 项目 → 相对路径 → 源路径
        for copy in plan.copies {
            let target = folder(copy.projectID).appendingPathComponent(copy.relativePath)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: copy.source), to: target)
                relocated[copy.source] = target.path
            } catch {
                failed[copy.projectID, default: [:]][copy.relativePath] = copy.source
                AppLog.write("project", "拷贝 \(copy.source) 进项目 \(copy.projectID) 失败：\(error.localizedDescription)")
            }
        }
        let (savedNow, unreadableNow) = lock.withLock { (_saved, _unreadable) }
        for var doc in plan.projects where unreadableNow[doc.id] == nil {
            if let map = failed[doc.id] { doc.mapFiles { map[$0] ?? $0 } }
            guard savedNow[doc.id] != doc else { continue }
            write(doc)
        }
        return relocated
    }

    func write(_ doc: ProjectDocument) {
        let dir = folder(doc.id)
        do {
            for sub in [ProjectDocument.imagesFolder, ProjectDocument.videosFolder, ProjectDocument.importsFolder] {
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
            try ProjectDocument.encode(doc).write(to: dir.appendingPathComponent(ProjectDocument.fileName), options: .atomic)
            lock.withLock { _saved[doc.id] = doc }
        } catch {
            AppLog.write("project", "保存项目 \(doc.id) 失败：\(error.localizedDescription)")
        }
    }

    /// 删项目：整个文件夹进废纸篓（访达里可恢复）
    func trashProject(_ id: String) {
        guard !id.isEmpty, !id.contains("/") else { return }
        let dir = folder(id)
        lock.withLock { _saved[id] = nil }
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        } catch {
            AppLog.write("project", "项目 \(id) 移到废纸篓失败：\(error.localizedDescription)")
        }
    }

    // MARK: 1.x → 2.0 一次性迁移

    struct MigrationOutcome {
        var report: MigrationReport
        var reportFile: URL
    }

    /// 迁到 `<缓存目录>/项目/`。先写到临时文件夹，全部成功再改名，中途失败不留半成品。
    static func migrateLegacyData(cacheRoot: URL) throws -> MigrationOutcome {
        let fm = FileManager.default
        let stamp = Self.stamp()
        let root = cacheRoot.appendingPathComponent("项目", isDirectory: true)
        let staging = cacheRoot.appendingPathComponent("项目.迁移中-\(stamp)", isDirectory: true)
        let metasData = UserDefaults.standard.data(forKey: "projectMetas")

        try LegacyMigrator.backup(appSupport: FileLocations.appSupport, metasData: metasData,
                                  to: FileLocations.appSupport.appendingPathComponent("backups/pre-2.0-\(stamp)"))
        let snapshot = try LegacyMigrator.loadSnapshot(appSupport: FileLocations.appSupport, metasData: metasData)
        var options = MigrationOptions()
        options.fromVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.x"
        var plan = LegacyMigrationPlanner.plan(snapshot, options: options) { fm.fileExists(atPath: $0) }
        plan.report.unreferencedFiles = LegacyMigrator.unreferencedFiles(cacheRoot: cacheRoot, skipping: root,
                                                                         snapshot: snapshot)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let failures = try LegacyMigrator.execute(plan, projectsRoot: staging)
        if fm.fileExists(atPath: root.path) {
            try fm.moveItem(at: root, to: cacheRoot.appendingPathComponent("项目.旧-\(stamp)", isDirectory: true))
        }
        try fm.moveItem(at: staging, to: root)

        let reportFile = root.appendingPathComponent("迁移报告-\(stamp).md")
        try LegacyMigrator.renderReport(plan.report, copyFailures: failures)
            .write(to: reportFile, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(root.path, forKey: rootDefaultsKey)
        AppLog.write("project", "1.x → 2.0 迁移完成：\(plan.projects.count) 个项目，报告 \(reportFile.path)")
        return MigrationOutcome(report: plan.report, reportFile: reportFile)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

extension ProjectDocument {
    /// 改写所有文件字段（拷贝失败时把相对路径换回源绝对路径）
    mutating func mapFiles(_ transform: (String) -> String) {
        for s in settings.indices {
            for v in settings[s].versions.indices {
                settings[s].versions[v].file = settings[s].versions[v].file.map(transform)
            }
            if var legacy = settings[s].legacy {
                for e in legacy.libraryEntries.indices {
                    legacy.libraryEntries[e].file = legacy.libraryEntries[e].file.map(transform)
                }
                settings[s].legacy = legacy
            }
        }
        for e in episodes.indices {
            for g in episodes[e].segments.indices {
                for v in episodes[e].segments[g].videos.indices {
                    episodes[e].segments[g].videos[v].file = episodes[e].segments[g].videos[v].file.map(transform)
                }
            }
        }
    }
}
