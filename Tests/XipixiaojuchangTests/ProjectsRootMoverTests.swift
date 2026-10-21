import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：设置的缓存页只有「打开」，没法更换项目文件夹。
final class ProjectsRootMoverTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("root-mover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// 在 `root` 下建一个项目文件夹：project.json + videos/a.mp4
    @discardableResult
    private func makeProject(_ id: String, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("videos"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent(ProjectDocument.fileName))
        try Data("video".utf8).write(to: folder.appendingPathComponent("videos/a.mp4"))
        return folder
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testMovesEveryProjectFolderAndLeavesOtherThingsAlone() throws {
        let old = base.appendingPathComponent("old"), new = base.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try makeProject("A", in: old)
        try makeProject("B", in: old)
        try Data("x".utf8).write(to: old.appendingPathComponent("notes.txt"))               // 不是项目：不动
        try FileManager.default.createDirectory(at: old.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)

        var seen: [[Int]] = []
        let count = try ProjectsRootMover.move(from: old, to: new, progress: { seen.append([$0, $1]) })

        XCTAssertEqual(count, 2)
        XCTAssertEqual(seen, [[0, 2], [1, 2], [2, 2]], "每搬完一个报一次进度")
        XCTAssertTrue(exists(new.appendingPathComponent("A/videos/a.mp4")))
        XCTAssertTrue(exists(new.appendingPathComponent("B/\(ProjectDocument.fileName)")))
        XCTAssertFalse(exists(old.appendingPathComponent("A")))
        XCTAssertTrue(exists(old.appendingPathComponent("notes.txt")), "不是项目的东西原地不动")
        XCTAssertTrue(exists(old.appendingPathComponent("空文件夹")))
        XCTAssertEqual(ProjectsRootMover.projectFolders(in: new).map(\.lastPathComponent), ["A", "B"])
    }

    func testMovingThereAndBackBringsEveryProjectBackUnchanged() throws {
        let first = base.appendingPathComponent("first"), second = base.appendingPathComponent("second")
        try makeProject("A", in: first)
        try makeProject("B", in: first)
        try Data("改过的".utf8).write(to: first.appendingPathComponent("A/videos/b.mp4"))

        try ProjectsRootMover.validate(old: first, new: second)
        XCTAssertEqual(try ProjectsRootMover.move(from: first, to: second), 2)
        XCTAssertTrue(ProjectsRootMover.projectFolders(in: first).isEmpty, "搬走之后原位置没有项目")

        try ProjectsRootMover.validate(old: second, new: first)                           // 换回来：原位置还在、能用
        XCTAssertEqual(try ProjectsRootMover.move(from: second, to: first), 2)
        XCTAssertEqual(ProjectsRootMover.projectFolders(in: first).map(\.lastPathComponent), ["A", "B"])
        XCTAssertEqual(try String(contentsOf: first.appendingPathComponent("A/videos/b.mp4"), encoding: .utf8), "改过的", "里面的文件原样回来")
        XCTAssertTrue(ProjectsRootMover.projectFolders(in: second).isEmpty)
    }

    func testRefusesAPlaceThatIsTheSameOrInsideTheOldOne() throws {
        let old = base.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectsRootMover.validate(old: old, new: old))
        XCTAssertThrowsError(try ProjectsRootMover.validate(old: old, new: old.appendingPathComponent("里面")))
        XCTAssertNoThrow(try ProjectsRootMover.validate(old: old, new: base.appendingPathComponent("别处")))
        XCTAssertTrue(exists(base.appendingPathComponent("别处")), "能用的位置顺手建出来")
    }

    func testAClashingProjectStopsEverythingBeforeAnythingMoves() throws {
        let old = base.appendingPathComponent("old"), new = base.appendingPathComponent("new")
        try makeProject("A", in: old)
        try makeProject("B", in: old)
        try makeProject("B", in: new)                                                      // 新位置里已经有 B

        XCTAssertThrowsError(try ProjectsRootMover.move(from: old, to: new)) { error in
            XCTAssertTrue(error.localizedDescription.contains("B"), "\(error)")
        }
        XCTAssertTrue(exists(old.appendingPathComponent("A")), "一个都没动")
        XCTAssertFalse(exists(new.appendingPathComponent("A")))
    }

    func testAFailureHalfwayPutsEverythingBack() throws {
        let old = base.appendingPathComponent("old"), new = base.appendingPathComponent("new")
        try makeProject("A", in: old)
        try makeProject("B", in: old)
        try makeProject("C", in: old)
        struct Boom: Error {}
        var calls = 0
        let mover: (URL, URL) throws -> Void = { from, to in
            calls += 1
            if calls == 3 { throw Boom() }                                                // 搬第三个（C）时失败；之后的搬回也要能走
            try FileManager.default.moveItem(at: from, to: to)
        }

        XCTAssertThrowsError(try ProjectsRootMover.move(from: old, to: new, moveItem: mover)) { error in
            XCTAssertTrue(error.localizedDescription.contains("C"))
            XCTAssertTrue(error.localizedDescription.contains("恢复原样"))
        }
        for id in ["A", "B", "C"] {
            XCTAssertTrue(exists(old.appendingPathComponent("\(id)/videos/a.mp4")), "\(id) 回到原处")
            XCTAssertFalse(exists(new.appendingPathComponent(id)), "新位置不留 \(id)")
        }
    }
}

/// 更换项目文件夹前的检查：有任务在跑就不让换；这里的用例都在动手之前就被拦下，不会碰任何项目文件
@MainActor
final class ChangeProjectsRootGuardTests: XCTestCase {
    func testBusyWorkIsDescribedAndBlocksTheChange() async throws {
        let app = AppModel()
        XCTAssertNil(app.busyWorkSummary(), "什么都没在跑")

        let now = Date()
        let taskID = "busy-\(UUID().uuidString)"
        app.store.add(LocalTask(id: taskID, model: "m", prompt: "p", duration: 5, phase: .inProgress, createdAt: now, updatedAt: now))
        defer { app.store.remove(id: taskID) }
        XCTAssertEqual(app.busyWorkSummary(), "1 个视频")

        let target = FileManager.default.temporaryDirectory.appendingPathComponent("never-used-\(UUID().uuidString)")
        do {
            try await app.changeProjectsRoot(to: target, moveExisting: true)
            XCTFail("有任务在跑，应该被拦下")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("还有任务在跑"), "\(error)")
        }
        XCTAssertFalse(app.projectSavesSuspended, "被拦下的时候不能把存盘关掉")
        XCTAssertNil(app.projectsRootChange)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "也没有去新位置建文件夹")
    }
}
