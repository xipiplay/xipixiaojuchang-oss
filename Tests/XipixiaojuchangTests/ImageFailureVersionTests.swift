import XCTest
@testable import Xipixiaojuchang

/// 生图侧和生视频统一（2026-10-16 用户）：失败的生图也留成一个版本（按时间和成功的一起编号），能点进去换回那一次的提示词和参数
@MainActor
final class ImageFailureVersionTests: XCTestCase {
    func testVersionsAreNumberedInTimeOrderIncludingFailures() {
        var item = ImageGenItem(name: "甲", prompt: "p")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        item.results = [ImageGenResult(localPath: "/a.png", createdAt: t0), ImageGenResult(localPath: "/c.png", createdAt: t0.addingTimeInterval(20))]
        item.failures = [ImageGenFailure(createdAt: t0.addingTimeInterval(10), error: "503")]
        let entries = item.versionEntries
        XCTAssertEqual(entries.map(\.number), [1, 2, 3])
        XCTAssertNotNil(entries[1].failure, "中间那次失败是第 2 版")
        XCTAssertEqual(item.versionNumber(of: item.results[1].id), 3, "失败之后成功的那张是第 3 版")
    }

    func testFailureIsRecordedAndCanBeOpened() {
        let app = AppModel()
        var item = ImageGenItem(projectKey: "img-fail-\(UUID().uuidString)", name: "甲", prompt: "第一次的提示词", model: "m1")
        item.results = [ImageGenResult(localPath: "/a.png", createdAt: Date(timeIntervalSince1970: 1_800_000_000), prompt: "成功那张的提示词", model: "m0")]
        app.imageItems.append(item)
        let idx = app.imageItems.count - 1
        defer { app.imageItems.remove(at: idx) }

        app.recordImageFailure(at: idx, "HTTP 503")
        XCTAssertEqual(app.imageItems[idx].status, .failed)
        XCTAssertEqual(app.imageItems[idx].failures.count, 1)
        XCTAssertEqual(app.imageItems[idx].failures[0].prompt, "第一次的提示词", "记下当时的提示词")
        XCTAssertEqual(app.imageItems[idx].versionEntries.count, 2, "失败也是一版")

        app.imageItems[idx].prompt = "后来改过的"
        let failureID = app.imageItems[idx].failures[0].id
        app.applyImageFailure(item.id, failureID: failureID)
        XCTAssertEqual(app.imageItems[idx].prompt, "第一次的提示词", "点失败的那一版：换回那一次的提示词")
        XCTAssertEqual(app.imageItems[idx].viewingFailure?.error, "HTTP 503", "预览写失败原因")

        app.applyImageResult(item.id, resultID: app.imageItems[idx].results[0].id)
        XCTAssertNil(app.imageItems[idx].viewingFailureID, "点回成功的图：不再看失败")
        XCTAssertEqual(app.imageItems[idx].prompt, "成功那张的提示词")
    }

    func testRegeneratingKeepsEarlierFailures() {
        let app = AppModel()
        let item = ImageGenItem(projectKey: "img-keep-\(UUID().uuidString)", name: "甲", prompt: "p")
        app.imageItems.append(item)
        let idx = app.imageItems.count - 1
        defer { app.imageItems.remove(at: idx) }
        app.recordImageFailure(at: idx, "第一次失败")
        app.recordImageFailure(at: idx, "第二次失败")
        XCTAssertEqual(app.imageItems[idx].failures.map(\.error), ["第一次失败", "第二次失败"], "再失败也不会把前一次删掉")
    }
}
