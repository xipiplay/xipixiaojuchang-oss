import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：工作台右上角三个标签叫「原文 / 分割 / 分镜」；流程顺着走：添加剧本后在原文，
/// 分割之后跳到分割，推理分镜之后才是分镜。
final class WorkbenchPaneFlowTests: XCTestCase {
    private func episode(split: Bool = false, shots: Bool = false) -> Episode {
        var e = Episode(title: "集", text: "原文", splitText: split ? "--- 00:00 - 00:30\n台词" : nil)
        e.shotIDs = shots ? [UUID()] : nil
        return e
    }

    func testTheThreeTabsAreCalledOriginalSplitAndStoryboard() {
        XCTAssertEqual(PipelinePage.ScriptPane.allCases.map(\.rawValue), ["原文", "分割", "分镜"])
    }

    func testEachEpisodeOpensOnTheStepItHasReached() {
        XCTAssertEqual(PipelinePage.autoPane(for: nil), .original)
        XCTAssertEqual(PipelinePage.autoPane(for: episode()), .original, "刚添加的剧本：原文")
        XCTAssertEqual(PipelinePage.autoPane(for: episode(split: true)), .split, "分割过：分割")
        XCTAssertEqual(PipelinePage.autoPane(for: episode(split: true, shots: true)), .segments, "推理过分镜：分镜")
    }

    func testAFinishedBatchJumpsToItsOwnPageOnlyWhenThisEpisodeHasTheResult() {
        XCTAssertEqual(PipelinePage.paneAfterBatch(.split, episode: episode(split: true)), .split, "分割跑完 → 分割（不是分镜）")
        XCTAssertNil(PipelinePage.paneAfterBatch(.split, episode: episode()), "这一集这次没分割成：不跳")
        XCTAssertEqual(PipelinePage.paneAfterBatch(.infer, episode: episode(split: true, shots: true)), .segments, "推理分镜跑完 → 分镜")
        XCTAssertNil(PipelinePage.paneAfterBatch(.infer, episode: episode(split: true)), "这一集没推理出分镜：不跳")
        XCTAssertNil(PipelinePage.paneAfterBatch(.extract, episode: episode(split: true, shots: true)), "提取素材不跳")
    }
}
