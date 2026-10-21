import XCTest
@testable import Xipixiaojuchang

/// 中转失败时只带 `error.message`、`status` 不变成 failed（2026-10-14 实测：后台显示失败，软件一直「生成中 100%」）：
/// 连续报错 2 分钟判失败，中间有一次正常就重新计时；正常返回里的 `message` 之类不算
@MainActor
final class PollingUpstreamErrorTests: XCTestCase {
    private func response(_ json: String) throws -> VideoStatusResponse {
        try VideoStatusResponse(data: Data(json.utf8))
    }

    private let failing = #"{"error":{"message":"<urlopen error [Errno 110] Connection timed out>","type":"proxy_error"},"id":"task_x","progress":100,"status":"pending"}"#

    func testReadsTheUpstreamErrorMessage() throws {
        XCTAssertEqual(try response(failing).upstreamError, "<urlopen error [Errno 110] Connection timed out>")
        XCTAssertNil(try response(#"{"status":"pending","message":"success","progress":30}"#).upstreamError, "顶层 message 不算")
        XCTAssertNil(try response(#"{"status":"pending","error":{"message":""}}"#).upstreamError, "空的不算")
        XCTAssertNil(try response(#"{"status":"pending","error":null}"#).upstreamError)
    }

    func testFailsOnlyAfterTheErrorLastsTwoMinutes() throws {
        let status = try response(failing)
        let t0 = Date()
        let first = PollingManager.upstreamErrorVerdict(status, since: nil, now: t0)
        XCTAssertEqual(first.since, t0)
        XCTAssertNil(first.fail, "第一次报错先不判")
        let early = PollingManager.upstreamErrorVerdict(status, since: first.since, now: t0.addingTimeInterval(119))
        XCTAssertNil(early.fail)
        XCTAssertEqual(early.since, t0, "计时起点不变")
        let late = PollingManager.upstreamErrorVerdict(status, since: first.since, now: t0.addingTimeInterval(120))
        XCTAssertEqual(late.fail, "<urlopen error [Errno 110] Connection timed out>", "失败原因就是上游那句")
    }

    func testANormalResponseResetsTheTimer() throws {
        let normal = try response(#"{"status":"in_progress","progress":40}"#)
        let verdict = PollingManager.upstreamErrorVerdict(normal, since: Date().addingTimeInterval(-100), now: Date())
        XCTAssertNil(verdict.since)
        XCTAssertNil(verdict.fail)
    }

    func testCompletedOrFailedStatusIsLeftToTheNormalPath() throws {
        let completed = try response(#"{"status":"completed","error":{"message":"warn"},"url":"https://x.test/a.mp4"}"#)
        XCTAssertNil(PollingManager.upstreamErrorVerdict(completed, since: Date().addingTimeInterval(-600), now: Date()).fail, "已完成照常下载")
        let failed = try response(#"{"status":"failed","error":{"message":"boom"}}"#)
        XCTAssertNil(PollingManager.upstreamErrorVerdict(failed, since: nil, now: Date()).since, "本来就失败的走原来的分支")
    }
}
