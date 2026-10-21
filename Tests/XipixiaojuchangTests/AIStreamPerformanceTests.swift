import XCTest
@testable import Xipixiaojuchang

/// 流式接收的开销（2026-10-11）：10 路同时思考时，每路每秒几十个数据块，每个块都不能再去数整段「尾巴」有多少字
final class AIStreamPerformanceTests: XCTestCase {
    private func line(_ piece: String) -> String {
        "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"\(piece)\"}}]}"
    }

    func testFeedingALongThinkingStreamStaysCheap() throws {
        var accumulator = AIStreamAccumulator()
        let piece = "这一段先看看场景里谁在说话，再分清楚"
        let chunk = line(piece)
        let start = Date()
        // 约 20 万字的思考：一个块 18 个字 ≈ 1.1 万个块
        for _ in 0..<11_000 { try accumulator.feed(line: chunk) }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertEqual(accumulator.progress.reasoningChars, 11_000 * piece.count)
        XCTAssertLessThan(seconds, 1.0, "收 20 万字思考花了 \(seconds) 秒：每个块的开销跟尾巴长度挂钩了")
    }

    func testTheTailKeepsTheLatestTextAndTheRightCount() throws {
        var accumulator = AIStreamAccumulator()
        for index in 0..<3000 { try accumulator.feed(line: line("第\(index)段思考。")) }
        let progress = accumulator.progress
        XCTAssertTrue(progress.reasoningTail.hasSuffix("第2999段思考。"))
        XCTAssertLessThanOrEqual(progress.reasoningTail.count, AIStreamProgress.tailLimit)
        XCTAssertGreaterThan(progress.reasoningTail.count, AIStreamProgress.tailLimit - 50, "尾巴要尽量留满上限")
    }
}
