import XCTest
@testable import Xipixiaojuchang

/// 用真实数据的**副本**预演迁移（不启动 App、不碰正式数据）。平时跳过；手动跑：
///
///     MIGRATE_SOURCE=<1.x 数据副本目录> MIGRATE_METAS=<projectMetas.json> \
///     MIGRATE_CACHE=<旧缓存目录，只读> MIGRATE_OUT=<空的输出目录> \
///     swift test --filter LegacyMigrationPreviewTests
///
/// 输出：`<OUT>/项目/<ID>/…`、`<OUT>/备份/`、`<OUT>/迁移报告.md`、`<OUT>/迁移报告.json`。
final class LegacyMigrationPreviewTests: XCTestCase {
    /// 用现有 2.0 项目文件的**副本**检查：启动还原（含任务记录）→ 存盘，项目文件一个字都不变。
    ///
    ///     MIGRATE_LIVE_ROOT=<只含各项目 project.json 的副本根目录> swift test --filter LegacyMigrationPreviewTests
    @MainActor
    func testCurrentProjectsAreStableAcrossLoadAndSave() throws {
        guard let path = ProcessInfo.processInfo.environment["MIGRATE_LIVE_ROOT"] else {
            throw XCTSkip("未设置 MIGRATE_LIVE_ROOT")
        }
        let store = ProjectStore(root: URL(fileURLWithPath: path, isDirectory: true))
        let docs = store.loadAll()
        XCTAssertTrue(store.unreadable.isEmpty, "\(store.unreadable)")
        var snapshot = LegacyProjection.snapshot(from: docs, projectsRoot: store.root)
        snapshot.tasks = LegacyProjection.tasks(from: docs, projectsRoot: store.root)
        let previous = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var options = MigrationOptions.live(root: store.root, previous: previous)
        options.targetExists = { _, _ in false }
        let plan = LegacyMigrationPlanner.plan(snapshot, options: options) { FileManager.default.fileExists(atPath: $0) }
        XCTAssertEqual(plan.copies.count, 0)
        XCTAssertEqual(plan.projects.count, docs.count)
        for doc in plan.projects where doc != previous[doc.id] {
            XCTFail("项目 \(doc.name)（\(doc.id)）存一遍就变了")
            try ProjectDocument.encode(doc).write(to: store.root.appendingPathComponent("\(doc.id)/resaved.json"))
        }
    }

    func testPreviewOnDataCopy() throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["MIGRATE_SOURCE"], let out = env["MIGRATE_OUT"] else {
            throw XCTSkip("未设置 MIGRATE_SOURCE / MIGRATE_OUT")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let outURL = URL(fileURLWithPath: out)
        let metas = try env["MIGRATE_METAS"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }

        try LegacyMigrator.backup(appSupport: sourceURL, metasData: metas, to: outURL.appendingPathComponent("备份"))
        let snapshot = try LegacyMigrator.loadSnapshot(appSupport: sourceURL, metasData: metas)
        var plan = LegacyMigrationPlanner.plan(snapshot) { FileManager.default.fileExists(atPath: $0) }
        let projectsRoot = outURL.appendingPathComponent("项目", isDirectory: true)
        if let cache = env["MIGRATE_CACHE"] {
            plan.report.unreferencedFiles = LegacyMigrator.unreferencedFiles(
                cacheRoot: URL(fileURLWithPath: cache), skipping: projectsRoot, snapshot: snapshot)
        }
        let failures = try LegacyMigrator.execute(plan, projectsRoot: projectsRoot)
        try LegacyMigrator.renderReport(plan.report, copyFailures: failures)
            .write(to: outURL.appendingPathComponent("迁移报告.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(plan.report).write(to: outURL.appendingPathComponent("迁移报告.json"))

        // 写出去的每个 project.json 都能原样读回
        for doc in plan.projects {
            let data = try Data(contentsOf: projectsRoot.appendingPathComponent("\(doc.id)/\(ProjectDocument.fileName)"))
            XCTAssertEqual(try ProjectDocument.decode(data), doc)
        }
        XCTAssertEqual(failures, [])

        // 适配层来回一圈（启动还原成旧数组 → 存盘）不改任何项目、不拷任何文件
        var back = LegacyProjection.snapshot(from: plan.projects, projectsRoot: projectsRoot)
        back.tasks = LegacyProjection.tasks(from: plan.projects, projectsRoot: projectsRoot)   // 同 AppModel.loadProjects
        let previous = Dictionary(plan.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let resaved = LegacyMigrationPlanner.plan(back, options: .live(root: projectsRoot, previous: previous)) {
            FileManager.default.fileExists(atPath: $0)
        }
        XCTAssertEqual(resaved.copies.count, 0)
        XCTAssertEqual(resaved.projects.count, plan.projects.count)
        let drift = outURL.appendingPathComponent("回环不一致", isDirectory: true)
        for doc in resaved.projects where doc != previous[doc.id] {
            XCTFail("项目 \(doc.name)（\(doc.id)）来回一圈后变了，见 \(drift.path)")
            try FileManager.default.createDirectory(at: drift, withIntermediateDirectories: true)
            try ProjectDocument.encode(doc).write(to: drift.appendingPathComponent("\(doc.id).json"))
        }
        if !resaved.copies.isEmpty {
            try encoder.encode(resaved.copies.map { "\($0.source) → \($0.projectID)/\($0.relativePath)" })
                .write(to: outURL.appendingPathComponent("回环多出的拷贝.json"))
        }
    }
}
