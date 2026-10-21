import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：分镜 1-3-1 软件显示已完成、但没有视频，服务商后台也是已完成。
/// 原因：任务先被标成「已完成」再开始下载，下载到一半软件退出（装新版本）就停在「已完成、没文件、也没记失败」——
/// 启动时没人再管它。现在这种任务启动时接着下。
@MainActor
final class DownloadRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func task(phase: TaskPhase = .completed, local: String? = nil, url: String? = "https://x/content",
                      error: String? = nil, ageHours: Double) -> LocalTask {
        let t = now.addingTimeInterval(-ageHours * 3600)
        var task = LocalTask(id: "task_x", model: "m", prompt: "p", duration: 10, phase: phase, createdAt: t, updatedAt: t)
        task.localVideoPath = local
        task.resultURL = url
        task.errorMessage = error
        return task
    }

    func testACompletedTaskWithNoFileAndNoRecordedFailureIsDownloadedAgainRightAway() {
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(ageHours: 11), now: now), .retryLoop(immediate: true))
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(url: nil, ageHours: 11), now: now), .recoverURL,
                       "没存直链：先查一次状态补回来")
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(ageHours: 24 * 8), now: now), .none, "放了超过 7 天的不管")
    }

    func testTasksThatAreFineAreLeftAlone() {
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(local: "/a/1-3-1.mp4", ageHours: 1), now: now), .none, "已经有视频")
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(phase: .inProgress, ageHours: 1), now: now), .none, "还在生成：别的流程管")
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(phase: .failed, error: "上游失败", ageHours: 1), now: now), .none)
    }

    func testTasksThatRecordedADownloadFailureKeepTheirOldWindows() {
        let failure = "视频已生成，但下载转存失败：超时"
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(error: failure, ageHours: 0.5), now: now), .retryLoop(immediate: false))
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(error: failure, ageHours: 3), now: now), .none, "直链 2 小时有效期过了")
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(url: nil, error: failure, ageHours: 5), now: now), .recoverURL)
        XCTAssertEqual(PollingManager.downloadRecovery(for: task(url: nil, error: failure, ageHours: 30), now: now), .none)
    }
}
