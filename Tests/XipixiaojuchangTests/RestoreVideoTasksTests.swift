import XCTest
@testable import Xipixiaojuchang

/// 2026-10-18：启动恢复视频任务（jobs.json → 任务列表）时，**已经随项目文件载入过的失败占位不再重复建一条**。
///
/// 背景：失败占位有两条存放路径——既存进 project.json 的视频版本里（失败也占一版），
/// 又留在 jobs.json（任务抽屉显示失败原因用）。原来恢复时不查重 → 重启一次抽屉里就多一行，
/// 而且查 id / 存盘都是「第一条优先」，后建的会顶掉原来那条。
@MainActor
final class RestoreVideoTasksTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        app = AppModel()
        app.currentProjectKey = "restore-" + UUID().uuidString
        app.jobCenter.startVideo = { _, _ in }   // 挡住真实提交（这个测试只关心列表里几条）
    }

    override func tearDown() async throws {
        app.currentProjectKey = nil
        app = nil
    }

    /// 造一条失败的视频记录：先进排队再判失败（走真实的任务中心路径）
    private func makeFailedRecord(placeholder: String, shotID: UUID) {
        app.jobCenter.enqueueVideo(placeholderID: placeholder, shotID: shotID,
                                   projectKey: app.currentProjectKey ?? "", channel: "测试渠道")
        app.jobCenter.videoSubmitFinished(placeholderID: placeholder, error: "请求失败（HTTP 503）")
    }

    func testFailedPlaceholderAlreadyLoadedIsNotDuplicated() {
        let shotID = app.addShot()
        let placeholder = "pending-" + UUID().uuidString
        // 模拟：失败占位随项目文件载入（store 里已有这条，taskIDs 也记了）
        app.store.add(LocalTask(id: placeholder, model: "m", prompt: "p", duration: 5, phase: .failed,
                                createdAt: Date(), updatedAt: Date(), errorMessage: "请求失败（HTTP 503）"))
        let i = app.shots.firstIndex { $0.id == shotID }!
        app.shots[i].taskIDs.append(placeholder)
        app.shots[i].taskID = placeholder
        makeFailedRecord(placeholder: placeholder, shotID: shotID)

        app.restoreVideoTasksFromJobs()

        XCTAssertEqual(app.store.tasks.filter { $0.id == placeholder }.count, 1, "同一个 id 只留一条")
    }

    func testRecordWithoutLoadedTaskIsStillRestored() {
        let shotID = app.addShot()
        let placeholder = "pending-" + UUID().uuidString
        makeFailedRecord(placeholder: placeholder, shotID: shotID)

        app.restoreVideoTasksFromJobs()

        let restored = app.store.tasks.filter { $0.id == placeholder }
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.phase, .failed)
        XCTAssertEqual(restored.first?.errorMessage, "请求失败（HTTP 503）", "失败原因要带到列表里")
    }

    func testRecordForMissingShotIsRemoved() {
        let placeholder = "pending-" + UUID().uuidString
        makeFailedRecord(placeholder: placeholder, shotID: UUID())

        app.restoreVideoTasksFromJobs()

        XCTAssertTrue(app.store.tasks.allSatisfy { $0.id != placeholder }, "分镜没了就不建任务")
        XCTAssertFalse(app.jobCenter.records.contains { $0.id == placeholder }, "记录也要撤掉")
    }
}
