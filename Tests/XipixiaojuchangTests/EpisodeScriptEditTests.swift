import XCTest
@testable import Xipixiaojuchang

final class EpisodeScriptEditTests: XCTestCase {
    private func archive() -> (ProjectPipelineArchive, Episode) {
        let episode = Episode(title: "第1集", text: "场景：甲 日 内\n台词一")
        return (ProjectPipelineArchive(wholeScript: "全文", episodes: [episode, Episode(title: "第2集", text: "第二集")]), episode)
    }

    func testEditingAnEpisodeChangesOnlyThatEpisode() throws {
        let (a, e) = archive()
        let updated = try XCTUnwrap(EpisodeScriptEdit.applying(title: "第1集", text: "改过的原文", episodeID: e.id, to: a))
        XCTAssertEqual(updated.episodes[0].text, "改过的原文")
        XCTAssertEqual(updated.episodes[1], a.episodes[1])
        XCTAssertEqual(updated.wholeScript, "全文")
    }

    func testTitleIsTrimmedAndNoChangeReturnsNil() throws {
        let (a, e) = archive()
        let updated = try XCTUnwrap(EpisodeScriptEdit.applying(title: "  新标题 ", text: e.text, episodeID: e.id, to: a))
        XCTAssertEqual(updated.episodes[0].title, "新标题")
        XCTAssertNil(EpisodeScriptEdit.applying(title: "第1集 ", text: e.text, episodeID: e.id, to: a), "只多了空格：不算改动")
        XCTAssertNil(EpisodeScriptEdit.applying(title: "第1集", text: e.text, episodeID: e.id, to: a))
    }

    func testUnknownEpisodeIsIgnored() {
        let (a, _) = archive()
        XCTAssertNil(EpisodeScriptEdit.applying(title: "x", text: "y", episodeID: UUID(), to: a), "这一集已经不在了（重新分集 / 清空）：不写")
    }

    func testWholeScriptCanOnlyBeEditedBeforeSplitting() throws {
        let unsplit = ProjectPipelineArchive(wholeScript: "全文", episodes: [])
        let updated = try XCTUnwrap(EpisodeScriptEdit.applying(title: "", text: "新全文", episodeID: nil, to: unsplit))
        XCTAssertEqual(updated.wholeScript, "新全文")
        let (split, _) = archive()
        XCTAssertNil(EpisodeScriptEdit.applying(title: "", text: "新全文", episodeID: nil, to: split), "分过集之后整篇不在这里改")
    }

    /// 已知后果（见 `EpisodeScriptEdit` 的说明）：分段按原文绑定，原文一改，这一集的分段就对不上了
    func testEditingTheTextHidesTheEpisodesExistingSegmentsUntilTheTextIsRestored() throws {
        var (a, e) = archive()
        var work = SimplePipeline.work(in: a, index: 0)
        work.segments = [SimplePipelineSegment(text: "台词一", assetNames: ["甲"], prompt: "提示词")]
        SimplePipeline.save(work, to: &a)
        XCTAssertEqual(SimplePipeline.work(in: a, index: 0).segments.count, 1)

        let edited = try XCTUnwrap(EpisodeScriptEdit.applying(title: "第1集", text: e.text + "\n多一句", episodeID: e.id, to: a))
        XCTAssertTrue(SimplePipeline.work(in: edited, index: 0).segments.isEmpty, "分段对不上了")
        let restored = try XCTUnwrap(EpisodeScriptEdit.applying(title: "第1集", text: e.text, episodeID: e.id, to: edited))
        XCTAssertEqual(SimplePipeline.work(in: restored, index: 0).segments.count, 1, "改回原样又对上")
    }

    // MARK: 时长分割那一份

    func testEditingTheSplitTextLeavesTheOriginalAlone() throws {
        let (a, e) = archive()
        let updated = try XCTUnwrap(EpisodeScriptEdit.applying(title: "第1集", text: "分割后的文本", episodeID: e.id, field: .split, to: a))
        XCTAssertEqual(updated.episodes[0].splitText, "分割后的文本")
        XCTAssertEqual(updated.episodes[0].text, e.text, "原文不动")
        XCTAssertEqual(SimplePipeline.work(in: updated, index: 0).sourceKey, SimplePipeline.work(in: a, index: 0).sourceKey,
                       "改的不是原文，这一集按原文绑定的分段不受影响")
    }

    func testAnEmptySplitBoxDoesNotCreateAnEmptySplitText() {
        let (a, e) = archive()
        XCTAssertNil(EpisodeScriptEdit.applying(title: "第1集", text: "", episodeID: e.id, field: .split, to: a))
    }

    func testClearingAnExistingSplitTextIsAnEditAndTheWholeScriptHasNoSplitField() throws {
        var (a, e) = archive()
        a.episodes[0].splitText = "旧的分割"
        let cleared = try XCTUnwrap(EpisodeScriptEdit.applying(title: "第1集", text: "", episodeID: e.id, field: .split, to: a))
        XCTAssertEqual(cleared.episodes[0].splitText, "")
        let unsplit = ProjectPipelineArchive(wholeScript: "全文", episodes: [])
        XCTAssertNil(EpisodeScriptEdit.applying(title: "", text: "x", episodeID: nil, field: .split, to: unsplit))
    }
}
