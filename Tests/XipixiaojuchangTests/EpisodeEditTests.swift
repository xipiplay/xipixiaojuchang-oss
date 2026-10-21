import XCTest
@testable import Xipixiaojuchang

/// 2026-10-15 用户：工作台集列表「添加集」——末尾加空集；只能删最后一个还没分割、没有分镜卡的
final class EpisodeEditTests: XCTestCase {
    private func archive(_ count: Int) -> ProjectPipelineArchive {
        ProjectPipelineArchive(wholeScript: "全文", episodes: (1...count).map { Episode(title: "第\($0)集", text: "正文\($0)") })
    }

    func testAppendsAnEmptyEpisodeAtTheEnd() throws {
        let (next, index) = EpisodeEdit.appending(to: archive(56))
        XCTAssertEqual(index, 56)
        XCTAssertEqual(next.episodes.count, 57)
        XCTAssertEqual(next.episodes[56].title, "第57集")
        XCTAssertEqual(next.episodes[56].text, "")
        XCTAssertEqual(next.wholeScript, "全文", "不写回整份剧本")
        XCTAssertNoThrow(try next.validate())
    }

    func testOnlyTheLastUnsplitEpisodeCanBeDeleted() throws {
        var a = EpisodeEdit.appending(to: archive(3)).archive
        XCTAssertFalse(EpisodeEdit.canDelete(2, in: a), "中间的集不能删（后面会改号）")
        XCTAssertTrue(EpisodeEdit.canDelete(3, in: a))
        a.epIndex = 3
        let back = try XCTUnwrap(EpisodeEdit.deleting(3, from: a))
        XCTAssertEqual(back.episodes.count, 3)
        XCTAssertEqual(back.epIndex, 2)
        XCTAssertNoThrow(try back.validate())

        a.episodes[3].splitText = "=== [00:00-00:30] ===\n内容"
        XCTAssertFalse(EpisodeEdit.canDelete(3, in: a), "分割过的不能删")
        a.episodes[3].splitText = nil
        a.episodes[3].shotIDs = [UUID()]
        XCTAssertFalse(EpisodeEdit.canDelete(3, in: a), "有分镜卡的不能删")
        XCTAssertFalse(EpisodeEdit.canDelete(0, in: archive(1)), "只剩一集不删")
    }
}
