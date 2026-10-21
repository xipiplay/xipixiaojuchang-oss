import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：从分段跳到生图页之后，老得从第一层重新进工作台——加「返回」，并且回来时接着回到那一段。
@MainActor
final class WorkbenchBackNavigationTests: XCTestCase {
    func testJumpingFromASegmentRemembersItAndGoingBackToTheWorkbenchClearsIt() {
        let app = AppModel()
        let key = "back-nav-" + UUID().uuidString
        app.currentProjectKey = key
        app.isInWorkspace = true
        defer { app.isInWorkspace = false; app.currentProjectKey = nil }
        let origin = AppModel.WorkbenchLocation(projectKey: key, episodeIndex: 2, segment: 4)

        // 2026-10-15 起只剩跳生图页（生视频页没有入口了）
        app.workbenchOpenImageCard(UUID(), from: origin)
        XCTAssertEqual(app.workbenchJumpBack, origin)
        XCTAssertEqual(app.workspaceMode, .image)
        XCTAssertEqual(app.projectPage, .production)

        app.openScriptPage()                                             // 不管点的是「返回」还是左边的工作台图标
        XCTAssertNil(app.workbenchJumpBack)
        XCTAssertEqual(app.projectPage, .script)
    }

    func testOpeningACardWithoutSayingWhereFromHasNoBackButton() {
        let app = AppModel()
        app.currentProjectKey = "x-" + UUID().uuidString
        app.isInWorkspace = true
        defer { app.isInWorkspace = false; app.currentProjectKey = nil }
        app.workbenchOpenImageCard(UUID(), from: .init(projectKey: app.currentProjectKey!, episodeIndex: 0, segment: 1))
        app.workbenchOpenImageCard(UUID())
        XCTAssertNil(app.workbenchJumpBack, "别处（不是分段详情）打开卡片，不显示返回")
    }

    func testSuggestionsCarryTheFirstImageThatWasDrawnForThemSoTheListCanShowThumbnails() {
        let key = "sug-thumb-" + UUID().uuidString
        func card(_ name: String, path: String?) -> ImageGenItem {
            var item = ImageGenItem(projectKey: key, type: .character, name: name, prompt: "p")
            if let path { item.results = [ImageGenResult(localPath: path, createdAt: Date())]; item.status = .success }
            return item
        }
        let list = WorkbenchVersions.suggestions(cards: [card("第1集的周承山", path: nil), card("第24集的周承山", path: "/tmp/a.png"),
                                                          card("周承山 2", path: "/tmp/b.png"), card("沈砚", path: nil)])
        XCTAssertEqual(list.first { $0.name == "周承山" }?.imagePath, "/tmp/a.png", "同名的几个版本里，第一张出过图的")
        XCTAssertEqual(list.first { $0.name == "周承山 2" }?.imagePath, "/tmp/b.png")
        XCTAssertNil(list.first { $0.name == "沈砚" }?.imagePath, "没出过图 = 没缩略图，列表里显示图标")
    }

    /// 一张卡重新生成过好几次：缩略图是这张卡现在显示的那一张（选了哪版就是哪版，没选就是最新的），不是第一次生成的
    func testTheThumbnailIsTheImageTheCardShowsNowNotTheFirstOneItEverMade() {
        let key = "sug-current-" + UUID().uuidString
        var card = ImageGenItem(projectKey: key, type: .character, name: "周承山", prompt: "p")
        card.results = ["/tmp/v1.png", "/tmp/v2.png", "/tmp/v3.png"].map { ImageGenResult(localPath: $0, createdAt: Date()) }
        card.status = .success
        XCTAssertEqual(WorkbenchVersions.suggestions(cards: [card]).first?.imagePath, "/tmp/v3.png", "没挑过 = 最新一版")
        card.selectedResultID = card.results[1].id
        XCTAssertEqual(WorkbenchVersions.suggestions(cards: [card]).first?.imagePath, "/tmp/v2.png", "生图页里选了哪一版，这里就是哪一版")
    }
}

/// 2026-10-10 用户：分段详情里点素材的缩略图要看大图（不再是直接跳去生图页）
@MainActor
final class WorkbenchPreviewImageCardTests: XCTestCase {
    func testPreviewOpensTheVersionTheCardIsShowingAndStaysOnThisPage() {
        let app = AppModel()
        app.projectPage = .script
        let first = ImageGenResult(localPath: "/tmp/a.png", createdAt: Date(timeIntervalSince1970: 1))
        let second = ImageGenResult(localPath: "/tmp/b.png", createdAt: Date(timeIntervalSince1970: 2))
        var card = ImageGenItem(projectKey: "preview-" + UUID().uuidString, type: .character, name: "程砚", prompt: "p")
        card.results = [first, second]
        card.selectedResultID = first.id
        app.imageItems.append(card)
        defer { app.imageItems.removeAll { $0.id == card.id }; app.previewingImageItemID = nil; app.previewingImageResultID = nil }

        app.workbenchPreviewImageCard(card.id)
        XCTAssertEqual(app.previewingImageItemID, card.id)
        XCTAssertEqual(app.previewingImageResultID, first.id, "看的是卡片现在显示的那一版，不是最新的")
        XCTAssertEqual(app.projectPage, .script, "只盖一层大图，不换页")
    }

    func testPreviewDoesNothingWithoutAnImageOrWithoutTheCard() {
        let app = AppModel()
        var card = ImageGenItem(projectKey: "preview-" + UUID().uuidString, type: .prop, name: "怀表", prompt: "p")
        card.results = [ImageGenResult(localPath: nil, createdAt: Date())]
        app.imageItems.append(card)
        defer { app.imageItems.removeAll { $0.id == card.id } }

        app.workbenchPreviewImageCard(card.id)
        XCTAssertNil(app.previewingImageItemID, "这一版没有图：不打开")
        app.workbenchPreviewImageCard(UUID())
        XCTAssertNil(app.previewingImageItemID, "没有这张卡：不打开")
    }
}
