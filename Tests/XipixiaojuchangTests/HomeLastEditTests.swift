import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 主页大图：「上次编辑：第 3 集 · 待出图」——上次停在哪一集、这一集现在到哪一步。
final class HomeLastEditTests: XCTestCase {
    func testTextNamesTheEpisodeAndItsStage() {
        XCTAssertEqual(HomeContinueProject.lastEditText(episodeCount: 56, episodeIndex: 2, stageTitle: "待出图"), "第 3 集 · 待出图")
        XCTAssertEqual(HomeContinueProject.lastEditText(episodeCount: 56, episodeIndex: 0, stageTitle: nil), "第 1 集")
    }

    func testAnOutOfRangeEpisodeFallsBackToTheFirstAndNoEpisodesMeansNoLine() {
        XCTAssertEqual(HomeContinueProject.lastEditText(episodeCount: 3, episodeIndex: 9, stageTitle: "待分割"), "第 1 集 · 待分割")
        XCTAssertEqual(HomeContinueProject.lastEditText(episodeCount: 3, episodeIndex: -1, stageTitle: "待分割"), "第 1 集 · 待分割")
        XCTAssertNil(HomeContinueProject.lastEditText(episodeCount: 0, episodeIndex: 0, stageTitle: "待分割"))
    }
}
