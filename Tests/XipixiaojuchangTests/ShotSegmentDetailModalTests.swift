import XCTest
@testable import Xipixiaojuchang

/// 生视频页单击分镜打开段落详情（2026-10-26）：先找这条分镜在哪一集第几段，不在任何一集里就是「其他分镜」
@MainActor
final class ShotSegmentDetailModalTests: XCTestCase {
    func testFindsTheEpisodeSegmentOrFallsBackToOthers() {
        let a = UUID(), b = UUID(), c = UUID(), free = UUID()
        var archive = ProjectPipelineArchive(wholeScript: "", episodes: [])
        archive.episodes = [Episode(title: "第1集", text: "", shotIDs: [a]),
                            Episode(title: "第2集", text: "", shotIDs: [b, c])]
        XCTAssertEqual(ShotSegmentDetailModal.spot(of: c, archive: archive, board: nil), .init(episode: 1, segment: 2))
        XCTAssertEqual(ShotSegmentDetailModal.spot(of: a, archive: archive, board: nil), .init(episode: 0, segment: 1))
        XCTAssertNil(ShotSegmentDetailModal.spot(of: free, archive: archive, board: nil), "不在集里、也没有看板：找不到")

        var board = WorkbenchStatus.Board()
        board.otherShotIDs = [UUID(), free]
        XCTAssertEqual(ShotSegmentDetailModal.spot(of: free, archive: archive, board: board),
                       .init(episode: WorkbenchSegmentGrid.otherEpisode, segment: 2), "不在任何一集里：「其他分镜」里的第几个")
    }
}
