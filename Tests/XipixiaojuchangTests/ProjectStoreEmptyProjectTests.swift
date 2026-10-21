import XCTest
@testable import Xipixiaojuchang

/// 新建的空项目（只有名字、没有任何内容）也要落盘并能在下次启动读回来：
/// 项目靠 `<根目录>/<项目ID>/project.json` 被读取，文件夹是 ID 命名的（不是项目名）。
@MainActor
final class ProjectStoreEmptyProjectTests: XCTestCase {
    func testABrandNewEmptyProjectGetsItsFolderAndProjectJSONAndIsReadBackOnRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xipi-empty-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = UUID().uuidString
        let created = Date()
        let snapshot = LegacySnapshot(metas: [key: ProjectMeta(name: "全新的空项目", createdAt: created, updatedAt: created)])

        ProjectStore(root: root).save(snapshot)

        // 文件夹按 ID 命名，里面有 project.json 和三个子文件夹
        let folder = root.appendingPathComponent(key)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))
        for sub in ["images", "videos", "imports"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(sub).path), sub)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("全新的空项目").path),
                       "2.0 起文件夹用项目 ID 命名，不是项目名")

        // 「重启」：新开一个 ProjectStore 读这个根目录，项目还在、名字对
        let reloaded = ProjectStore(root: root).loadAll()
        XCTAssertEqual(reloaded.map(\.id), [key])
        XCTAssertEqual(reloaded.first?.name, "全新的空项目")
    }
}
