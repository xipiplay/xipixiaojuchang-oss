import XCTest
@testable import Xipixiaojuchang

final class PipelineAssetImageRulesTests: XCTestCase {
    func testImageLookupRequiresProjectAndType() {
        let asset = SimplePipelineAsset(kind: "角色", name: "长安", description: "围裙")
        let wrongProject = ImageGenItem(projectKey: "B", type: .character, name: "长安", prompt: "")
        let wrongType = ImageGenItem(projectKey: "A", type: .scene, name: "长安", prompt: "")
        let correct = ImageGenItem(projectKey: "A", type: .character, name: "长安", prompt: "")
        XCTAssertEqual(PipelineAssetImageRules.item(for: asset, projectKey: "A", items: [wrongProject, wrongType, correct])?.id, correct.id)
        XCTAssertNil(PipelineAssetImageRules.item(for: asset, projectKey: "C", items: [correct]))
    }

    func testLinkedImageSurvivesRename() {
        let item = ImageGenItem(projectKey: "A", type: .character, name: "旧名字", prompt: "")
        let asset = SimplePipelineAsset(kind: "角色", name: "新名字", description: "", imageItemID: item.id)
        XCTAssertEqual(PipelineAssetImageRules.item(for: asset, projectKey: "A", items: [item])?.id, item.id)
        XCTAssertNil(PipelineAssetImageRules.item(for: asset, projectKey: "B", items: [item]))
    }

    func testExtractionKeepsImagesAndExistingSegmentResults() {
        let old = SimplePipelineAsset(kind: "角色", name: "长安", description: "旧服装", imageItemID: UUID(), libraryItemID: UUID())
        let segment = SimplePipelineSegment(text: "剧情", prompt: "已生成分镜", shotID: UUID())
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "source", assets: [old], segments: [segment])
        PipelineAssetImageRules.merge([SimplePipelineAsset(kind: "角色", name: "长安", description: "新服装")], into: &work)
        XCTAssertEqual(work.assets[0].id, old.id)
        XCTAssertEqual(work.assets[0].imageItemID, old.imageItemID)
        XCTAssertEqual(work.assets[0].libraryItemID, old.libraryItemID)
        XCTAssertEqual(work.assets[0].description, "新服装")
        XCTAssertEqual(work.segments, [segment])
    }

    func testBatchParseAvoidsExactDuplicatesAndKeepsSegments() {
        let parsed = ImagePromptParser.parse("这个人是：长安，穿围裙。\n这个场景叫：厨房，白墙。")
        let segment = SimplePipelineSegment(text: "剧情")
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "source", segments: [segment])
        PipelineAssetImageRules.appendParsed(parsed, to: &work)
        PipelineAssetImageRules.appendParsed(parsed, to: &work)
        XCTAssertEqual(work.assets.count, 2)
        XCTAssertEqual(work.assets.map(\.kind), ["角色", "场景"])
        XCTAssertTrue(work.assetsExtracted)
        XCTAssertEqual(work.segments, [segment])
    }
}
