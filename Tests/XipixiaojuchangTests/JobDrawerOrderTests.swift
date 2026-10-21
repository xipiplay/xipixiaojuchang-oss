import XCTest
@testable import Xipixiaojuchang

/// 任务抽屉的顺序要每次都一样（2026-10-14 用户录屏：抽屉里空出一大块、某一行时有时无）：
/// 一批提交的视频常常同一秒，只按时间排时它们的先后不固定，每次轮询重排都可能互换
final class JobDrawerOrderTests: XCTestCase {
    func testSameSecondTasksKeepAFixedOrder() {
        let now = Date()
        let t = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 60)
        let tasks = (0..<12).map { i in
            JobDrawerView.Entry.video(LocalTask(id: "task-\(i)", model: "m", prompt: "p", duration: 30, phase: .completed,
                                                createdAt: i < 8 ? t : t.addingTimeInterval(Double(i)), updatedAt: t))
        }
        let first = JobDrawerView.retained(tasks, now: now).map(\.id)
        for _ in 0..<20 {
            XCTAssertEqual(JobDrawerView.retained(tasks.shuffled(), now: now).map(\.id), first, "输入顺序怎么变，排出来都一样")
        }
        XCTAssertEqual(Array(first.prefix(4)), ["v-task-11", "v-task-10", "v-task-9", "v-task-8"], "新的在上")
    }
}
