import XCTest
@testable import Xipixiaojuchang

/// 存盘放到后台串行队列（2026-10-13 稳定性）：主线程不等组装和写盘；「立刻存」排在后台那些后面、等它们做完；删项目不被写回来
@MainActor
final class BackgroundSaveTests: XCTestCase {
    private func bigProject(_ app: AppModel, shots: Int = 300, images: Int = 1000) -> String {
        let key = "bg-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "后台存盘", createdAt: Date(), updatedAt: Date())
        for i in 0..<shots { app.shots.append(ShotDraft(projectKey: key, prompt: "[客厅][甲、乙][碗]\n镜头\(i)：甲推门进来，看了一眼四周。乙抬头。")) }
        for i in 0..<images { app.imageItems.append(ImageGenItem(projectKey: key, type: .character, name: "角色\(i)", prompt: "蓝色工装的中年男人，站在白色背景前。")) }
        return key
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.projectMetas[key] = nil
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
    }

    func testTheBackgroundSaveDoesNotBlockTheMainThreadAndSaveNowWaitsForIt() throws {
        let app = AppModel()
        let key = bigProject(app)
        defer { cleanup(app, key) }
        let started = Date()
        app.saveProjectsInBackground()
        let blocked = Date().timeIntervalSince(started)
        XCTAssertLessThan(blocked, 0.02, "主线程只拍快照就返回（实际 \(Int(blocked * 1000))ms）")
        XCTAssertNil(app.projectStore?.saved[key], "这时候后台多半还没写完")
        app.saveProjectsNow()                                    // 排在后台那次后面，等它做完
        XCTAssertEqual(app.projectStore?.saved[key]?.name, "后台存盘", "立刻存返回时已经落盘")
        let folder = try XCTUnwrap(app.projectStore?.folder(key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(ProjectDocument.fileName).path))
    }

    func testDeletingAProjectIsNotUndoneByAnEarlierQueuedSave() throws {
        let app = AppModel()
        let key = bigProject(app, shots: 200, images: 600)
        defer { cleanup(app, key) }
        app.saveProjectsInBackground()                           // 这一次还在后台排着 / 在做
        app.deleteProject(key: key)                              // 马上删
        app.saveProjectsNow()
        let folder = try XCTUnwrap(app.projectStore?.folder(key))
        app.projectStore?.queue.sync {}                          // 把队列里的都等完
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "删掉的项目文件夹没被之前排队的存盘写回来")
        XCTAssertNil(app.projectStore?.saved[key])
    }

    func testAnEditIsSavedAfterTheDebounceWithoutAnExplicitSave() async throws {
        let app = AppModel()
        let key = "bg-edit-" + UUID().uuidString
        app.projectMetas[key] = ProjectMeta(name: "防抖", createdAt: Date(), updatedAt: Date())
        let shot = ShotDraft(projectKey: key, prompt: "原来的")
        app.shots.append(shot)
        defer { cleanup(app, key) }
        app.saveProjectsNow()
        let i = app.shots.firstIndex { $0.id == shot.id }!
        app.shots[i].prompt = "改过的提示词"
        app.persistShots()                                       // 平常的改动：0.3s 防抖后在后台存
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if app.projectStore?.saved[key].map({ String(describing: $0).contains("改过的提示词") }) == true { break }
        }
        app.projectStore?.queue.sync {}
        let doc = try XCTUnwrap(app.projectStore?.saved[key])
        XCTAssertTrue(String(describing: doc).contains("改过的提示词"), "防抖之后落盘了")
    }
}
