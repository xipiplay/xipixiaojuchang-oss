import XCTest
@testable import Xipixiaojuchang

final class ImageGenItemPersistenceTests: XCTestCase {
    func testSelectedHistoryResultSurvivesCodableRoundTrip() throws {
        let older = ImageGenResult(localPath: "/tmp/older.png")
        let reference = MaterialRef(libraryItemID: UUID(), role: .referenceImage)
        let latest = ImageGenResult(
            localPath: "/tmp/latest.png",
            prompt: "latest prompt",
            model: "image-model",
            type: .character,
            aspectRatio: .ratio16x9,
            quality: .k2,
            imageRefs: [reference]
        )
        var item = ImageGenItem(name: "角色", prompt: "portrait", status: .success)
        item.results = [older, latest]
        item.selectedResultID = older.id

        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ImageGenItem.self, from: data)

        XCTAssertEqual(decoded.selectedResultID, older.id)
        XCTAssertEqual(decoded.results.last?.id, latest.id)
        XCTAssertEqual(decoded.results.last?.prompt, "latest prompt")
        XCTAssertEqual(decoded.results.last?.imageRefs, [reference])
    }

    func testOlderDataWithoutSelectedResultDefaultsToLatestBehavior() throws {
        let result = ImageGenResult(localPath: "/tmp/latest.png")
        var item = ImageGenItem(name: "角色", prompt: "portrait", status: .success)
        item.results = [result]
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "selectedResultID")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ImageGenItem.self, from: oldData)

        XCTAssertNil(decoded.selectedResultID)
        XCTAssertEqual(decoded.latestResult?.id, result.id)
    }
}
