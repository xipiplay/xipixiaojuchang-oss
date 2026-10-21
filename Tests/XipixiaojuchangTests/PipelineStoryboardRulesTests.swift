import XCTest
@testable import Xipixiaojuchang

final class PipelineStoryboardRulesTests: XCTestCase {
    func testDoesNotUseAnotherEpisodesArrayPosition() {
        let segment = SimplePipelineSegment(text: "剧情", prompt: "提示词")
        let unrelated = ShotDraft(projectKey: "A", prompt: "其他提示词", numbering: ShotNumbering(a: 2, b: 1))
        XCTAssertNil(PipelineStoryboardRules.shot(for: segment, episode: 1, index: 0, projectKey: "A", shots: [unrelated]))
    }

    func testStableLinkAndProjectIsolation() {
        let shot = ShotDraft(projectKey: "A", prompt: "手工修改", numbering: ShotNumbering(a: 3, b: 2))
        let segment = SimplePipelineSegment(text: "剧情", prompt: "旧提示词", shotID: shot.id)
        XCTAssertEqual(PipelineStoryboardRules.shot(for: segment, episode: 3, index: 1, projectKey: "A", shots: [shot])?.id, shot.id)
        XCTAssertNil(PipelineStoryboardRules.shot(for: segment, episode: 3, index: 1, projectKey: "B", shots: [shot]))
    }

    func testBatchMismatchDoesNotChangeResults() {
        let segment = SimplePipelineSegment(text: "原剧情", prompt: "原提示词", shotID: UUID())
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "source", segments: [segment])
        XCTAssertThrowsError(try PipelineStoryboardRules.apply(["一个", "两个"], to: &work))
        XCTAssertEqual(work.segments, [segment])
        XCTAssertThrowsError(try PipelineStoryboardRules.apply([" "], to: &work))
        XCTAssertEqual(work.segments, [segment])
    }

    func testBatchKeepsPlotAndVideoLink() throws {
        let segment = SimplePipelineSegment(text: "原剧情", prompt: "旧提示词", shotID: UUID())
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "source", segments: [segment])
        try PipelineStoryboardRules.apply(["新提示词"], to: &work)
        XCTAssertEqual(work.segments[0].text, segment.text)
        XCTAssertEqual(work.segments[0].shotID, segment.shotID)
        XCTAssertEqual(work.segments[0].prompt, "新提示词")
    }
}
