import XCTest
@testable import Xipixiaojuchang

/// 2026-10-23：任务抽屉的「重试」原来不弹付费确认、提交失败的占位还会先被删掉（失败版本消失）。
/// 现在先确认、再按和详情页一样的口径检查，检查不过就说原因，不交、也不动历史。
@MainActor
final class JobRetryTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "job-retry-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
    }

    func testVideoRetryIsBlockedWhenTheShotsModelIsNotConfigured() {
        var shot = ShotDraft(projectKey: key, prompt: "[客厅][周承山][ ]\n正文")
        shot.model = "不存在的模型-\(UUID().uuidString)"
        app.shots.append(shot)
        XCTAssertNotNil(JobRetry.videoBlocker(shotID: shot.id, app: app))
    }

    func testVideoRetryOnAMissingShotSaysSo() {
        XCTAssertEqual(JobRetry.videoBlocker(shotID: UUID(), app: app), "这条分镜已经不在了。")
    }

    func testImageRetryIsBlockedForAnEmptyPromptOrUnknownModel() {
        var empty = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "  ")
        empty.status = .failed
        var stale = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "红衣少女")
        stale.model = "不存在的图片模型-\(UUID().uuidString)"
        app.imageItems.append(contentsOf: [empty, stale])
        XCTAssertNotNil(JobRetry.imageBlocker(itemID: empty.id, app: app))
        XCTAssertNotNil(JobRetry.imageBlocker(itemID: stale.id, app: app))
        XCTAssertEqual(JobRetry.imageBlocker(itemID: UUID(), app: app), "这张卡片已经不在了。")
    }

    /// 重试不再先删「提交失败」的占位：失败那一版留在历史里，重试是新的一版
    func testRetryAfterASubmitFailureKeepsTheFailedVersion() throws {
        let shot = ShotDraft(projectKey: key, prompt: "[客厅][周承山][ ]\n正文")
        app.shots.append(shot)
        app.submitShot(shot.id)                      // 没配模型 → 立刻一次提交失败（不走网络）
        let first = try XCTUnwrap(app.shots.first { $0.id == shot.id }?.taskIDs.first)
        XCTAssertTrue(first.hasPrefix("pending-") || first.hasPrefix("failed-"))
        app.submitShot(shot.id)                      // 抽屉「重试」确认后走的就是这一步
        let after = try XCTUnwrap(app.shots.first { $0.id == shot.id })
        XCTAssertEqual(after.taskIDs.count, 2)
        XCTAssertEqual(after.taskIDs.first, first, "失败的那一版还在")
        XCTAssertNotNil(app.store.task(id: first))
        for id in after.taskIDs { app.store.remove(id: id) }
    }
}
