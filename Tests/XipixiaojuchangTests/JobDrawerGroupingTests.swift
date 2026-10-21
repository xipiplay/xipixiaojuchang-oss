import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：批量分割 56 集，任务抽屉里是 56 条「时长分割 完成」刷屏 → 做完的同类折成一行。
final class JobDrawerGroupingTests: XCTestCase {
    private func ai(_ i: Int, title: String = "时长分割", state: JobRecord.State = .completed, project: String = "P") -> JobDrawerView.Entry {
        let t = Date(timeIntervalSince1970: 1_000_000 - Double(i))
        return .ai(JobRecord(id: "r\(i)", kind: .ai, projectKey: project, title: title, state: state, createdAt: t, updatedAt: t))
    }

    private func shape(_ rows: [JobDrawerView.DrawerRow]) -> String {
        rows.map { row in
            switch row {
            case .entry: "单"
            case .group(let g): "组\(g.records.count)"
            }
        }.joined(separator: " ")
    }

    func testAFinishedBatchCollapsesIntoOneRow() {
        let rows = JobDrawerView.rows((0..<56).map { ai($0) })
        XCTAssertEqual(shape(rows), "组56")
    }

    func testTwoFinishedTasksStayAsTheyAre() {
        XCTAssertEqual(shape(JobDrawerView.rows([ai(0), ai(1)])), "单 单")
    }

    func testRunningAndFailedTasksAreNeverFolded() {
        let list = [ai(0, state: .running), ai(1), ai(2), ai(3), ai(4, state: .failed), ai(5), ai(6)]
        XCTAssertEqual(shape(JobDrawerView.rows(list)), "单 组3 单 单 单", "进行中、失败的单独留着；被失败隔开后只剩两条，也不折")
    }

    func testDifferentStepsOrProjectsAreNotMixed() {
        let list = [ai(0), ai(1), ai(2), ai(3, title: "推理分镜"), ai(4, title: "推理分镜"), ai(5, title: "推理分镜"), ai(6, project: "Q"), ai(7, project: "Q")]
        XCTAssertEqual(shape(JobDrawerView.rows(list)), "组3 组3 单 单")
    }
}
