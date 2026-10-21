import XCTest
@testable import Xipixiaojuchang

/// 提取素材的回复解析（2026-10-07）：AI 偶尔漏写一项，只跳过那一项，不让整次提取作废。
final class SimplePipelineParseAssetsTests: XCTestCase {
    func testWellFormedReplyParsesAsBefore() throws {
        let raw = #"{"assets":[{"kind":"场景","name":"客栈","description":"木头客栈"},{"kind":"角色","name":"甲","description":"红衣少女"}]}"#
        let assets = try SimplePipeline.parseAssets(raw)
        XCTAssertEqual(assets.map(\.name), ["客栈", "甲"])
        XCTAssertEqual(assets.map(\.kind), ["场景", "角色"])
    }

    func testAnIncompleteItemIsSkippedAndTheRestKept() throws {
        let raw = #"{"assets":[{"kind":"场景","name":"客栈","description":"木头客栈"},{"kind":"角色","name":"乙","description":"  "},{"kind":"道具","name":"","description":"x"},{"kind":"其他","name":"丙","description":"y"},{"kind":"角色","name":"甲","description":"红衣少女"}]}"#
        let assets = try SimplePipeline.parseAssets(raw)
        XCTAssertEqual(assets.map(\.name), ["客栈", "甲"], "描述为空 / 名称为空 / 类型认不出的三项跳过")
    }

    func testMissingFieldsCountAsIncompleteInsteadOfBreakingTheWholeReply() throws {
        let raw = #"{"assets":[{"kind":"场景","name":"客栈"},{"kind":"角色","name":"甲","description":"红衣少女"}]}"#
        XCTAssertEqual(try SimplePipeline.parseAssets(raw).map(\.name), ["甲"])
    }

    func testNearSynonymKindsAreNormalized() throws {
        let raw = #"{"assets":[{"kind":"地点","name":"客栈","description":"a"},{"kind":"人物","name":"甲","description":"b"},{"kind":"物品","name":"碗","description":"c"}]}"#
        let assets = try SimplePipeline.parseAssets(raw)
        XCTAssertEqual(assets.map(\.kind), ["场景", "角色", "道具"])
    }

    func testFailsOnlyWhenNothingUsableIsLeft() {
        let raw = #"{"assets":[{"kind":"角色","name":"乙","description":""},{"kind":"其他","name":"丙","description":"y"}]}"#
        XCTAssertThrowsError(try SimplePipeline.parseAssets(raw)) { error in
            XCTAssertTrue(error.localizedDescription.contains("素材类型、名称或描述为空"), error.localizedDescription)
        }
    }

    func testAnEmptyAssetsArrayIsStillAnEmptyResultAndNotJSONIsStillAnError() throws {
        XCTAssertEqual(try SimplePipeline.parseAssets(#"{"assets":[]}"#), [])
        XCTAssertThrowsError(try SimplePipeline.parseAssets("抱歉，我无法完成"))
    }

    func testDuplicateNamesOfTheSameKindAreMergedAfterNormalizing() throws {
        let raw = #"{"assets":[{"kind":"场景","name":"客栈","description":"a"},{"kind":"地点","name":"客栈","description":"b"}]}"#
        XCTAssertEqual(try SimplePipeline.parseAssets(raw).count, 1)
    }
}
