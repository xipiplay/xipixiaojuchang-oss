import XCTest
@testable import Xipixiaojuchang

/// 任务中心（2026-10-06 P2）：不限同时数量（用户定：渠道不限并发）、重启后的处理、抽屉保留多久。
@MainActor
final class JobCenterTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func center() -> JobCenter {
        JobCenter(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json"))
    }

    private func record(_ id: String, _ kind: JobRecord.Kind, _ state: JobRecord.State, at offset: Double = 0) -> JobRecord {
        JobRecord(id: id, kind: kind, projectKey: "P", title: "t", state: state,
                  createdAt: t0.addingTimeInterval(offset), updatedAt: t0.addingTimeInterval(offset))
    }

    // MARK: 重启

    func testRestartMarksRunningAIInterruptedAndRequeuesUnsubmittedVideo() {
        let after = JobCenter.afterRestart([
            record("a", .ai, .running), record("b", .ai, .completed),
            record("v1", .video, .running), record("v2", .video, .waiting), record("v3", .video, .failed),
        ], now: t0)
        XCTAssertEqual(after.map(\.state), [.interrupted, .completed, .waiting, .waiting, .failed])
        XCTAssertNotNil(after[0].note)
    }

    // MARK: 保留

    func testRetentionKeepsActiveAndOnlyRecentFinished() {
        let old = record("old", .ai, .completed, at: -8 * 86400)
        let recent = record("recent", .ai, .failed, at: -86400)
        let waiting = record("w", .video, .waiting, at: -30 * 86400)
        XCTAssertEqual(Set(JobCenter.retained([old, recent, waiting], now: t0).map(\.id)), ["recent", "w"])
    }

    func testRetentionCapsFinishedAt200() {
        let many = (0..<250).map { record("r\($0)", .ai, .completed, at: Double(-$0)) }
        let kept = JobCenter.retained(many, now: t0)
        XCTAssertEqual(kept.count, JobCenter.keepCount)
        XCTAssertTrue(kept.contains { $0.id == "r0" }, "留最新的")
        XCTAssertFalse(kept.contains { $0.id == "r249" })
    }

    // MARK: 视频（不限同时数量）

    func testVideosSubmitImmediatelyWithoutLimit() {
        let c = center()
        var started: [String] = []
        c.startVideo = { id, _ in started.append(id) }
        for i in 1...5 { c.enqueueVideo(placeholderID: "p\(i)", shotID: UUID(), projectKey: "P", channel: "ch") }
        XCTAssertEqual(started, ["p1", "p2", "p3", "p4", "p5"])
        c.pumpVideos()
        XCTAssertEqual(started.count, 5, "提交中的不会重复提交")
    }

    func testSubmissionResultUpdatesRecord() {
        let c = center()
        c.startVideo = { _, _ in }
        c.enqueueVideo(placeholderID: "ok", shotID: UUID(), projectKey: "P", channel: "ch")
        c.enqueueVideo(placeholderID: "bad", shotID: UUID(), projectKey: "P", channel: "ch")
        c.videoSubmitFinished(placeholderID: "ok", error: nil)
        c.videoSubmitFinished(placeholderID: "bad", error: "Key 不对")
        XCTAssertNil(c.records.first { $0.id == "ok" }, "提交成功的占位记录删掉（任务已在视频版本里）")
        XCTAssertEqual(c.records.first { $0.id == "bad" }?.state, .failed)
        XCTAssertEqual(c.records.first { $0.id == "bad" }?.note, "Key 不对")
    }

    func testUnsubmittedVideoIsResubmittedAfterRestart() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json")
        let c = JobCenter(fileURL: url)
        c.startVideo = { _, _ in }
        c.enqueueVideo(placeholderID: "p1", shotID: UUID(), projectKey: "P", channel: "ch")
        c.flush()   // 提交途中退出
        let reloaded = JobCenter(fileURL: url)
        reloaded.load()
        var started: [String] = []
        reloaded.startVideo = { id, _ in started.append(id) }
        reloaded.pumpVideos()
        XCTAssertEqual(started, ["p1"])
    }

    // MARK: 生图（不限同时数量）

    func testImagesAllStartImmediately() async {
        let c = center()
        var gates: [UUID: CheckedContinuation<Void, Never>] = [:]
        var started: [UUID] = []
        c.runImage = { id in
            started.append(id)
            await withCheckedContinuation { gates[id] = $0 }
        }
        let ids = (0..<5).map { _ in UUID() }
        ids.forEach(c.enqueueImage)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(Set(started), Set(ids))
        XCTAssertEqual(c.imageRunning, Set(ids))
        ids.forEach { gates[$0]?.resume() }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(c.imageRunning.isEmpty)
    }

    // MARK: 剧本 AI 记录 + 落盘

    func testAIRecordsPersistAndReloadAsInterrupted() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString).json")
        let c = JobCenter(fileURL: url)
        let done = c.aiStarted(projectKey: "P", episodeID: nil, title: "剧本分集")
        c.aiFinished(done, state: .completed, note: nil)
        _ = c.aiStarted(projectKey: "P", episodeID: UUID(), title: "推理分镜")
        c.flush()

        let reloaded = JobCenter(fileURL: url)
        reloaded.load()
        XCTAssertEqual(reloaded.records.map(\.state), [.completed, .interrupted])
    }

    // MARK: 生图状态

    func testQueuedImageStatusIsBusyAndRoundTrips() throws {
        XCTAssertTrue(ImageGenStatus.queued.isBusy)
        XCTAssertFalse(ImageGenStatus.failed.isBusy)
        let data = try JSONEncoder().encode([ImageGenStatus.queued])
        XCTAssertEqual(try JSONDecoder().decode([ImageGenStatus].self, from: data), [.queued])
    }
}
