import XCTest
@testable import Xipixiaojuchang

/// 批量入库预检没过时的「跳过已入库」（2026-10-09）：只差「已入库过」的，去掉它们、剩下的全能存才给这个按钮；
/// 别的问题（无类型 / 没结果 / 文件缺失）仍然是全有全无，得先处理。
@MainActor
final class BatchSaveSkipTests: XCTestCase {
    private var app: AppModel!
    private var key: String!
    private var file: URL!

    override func setUp() async throws {
        app = AppModel()
        key = "batch-save-" + UUID().uuidString
        file = FileManager.default.temporaryDirectory.appendingPathComponent("batch-save-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: file)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
    }

    /// 一张成功出过图的卡（结果的文件真实存在）。`saved`：当前显示的这一版已经入库
    @discardableResult
    private func addCard(_ name: String, saved: Bool = false, type: ImageSubjectType? = .character,
                         status: ImageGenStatus = .success, hasFile: Bool = true) -> ImageGenItem {
        var item = ImageGenItem(projectKey: key, type: type, name: name, prompt: "p")
        let result = ImageGenResult(localPath: hasFile ? file.path : "/不存在/\(name).png", createdAt: Date())
        item.results = [result]
        item.status = status
        app.imageItems.append(item)
        if saved {
            var lib = LibraryItem(kind: .image, localPath: nil, name: "角色-\(name)", projectKey: key)
            lib.imageGenResultID = result.id
            app.library.append(lib)
        }
        return item
    }

    func testSomeSavedAndTheRestFineCanBeSkippedInTheirOriginalOrder() {
        let a = addCard("甲"), b = addCard("乙", saved: true), c = addCard("丙"), d = addCard("丁", saved: true)
        let ids = [a, b, c, d].map(\.id)
        let issues = app.batchSaveLibraryIssues(for: ids)
        XCTAssertEqual(issues.alreadySaved, 2)
        XCTAssertEqual(issues.noType + issues.noResult + issues.missingFile, 0)
        XCTAssertEqual(app.batchSaveIDsSkippingSaved(ids), [a.id, c.id], "跳过已入库的，剩下的按原顺序")
    }

    func testNothingToSkipOrNothingLeftGivesNoButton() {
        let a = addCard("甲"), b = addCard("乙")
        XCTAssertTrue(app.batchSaveLibraryIssues(for: [a.id, b.id]).isEmpty)
        XCTAssertNil(app.batchSaveIDsSkippingSaved([a.id, b.id]), "没有已入库的：预检本来就过了，用不着")
        let x = addCard("丙", saved: true), y = addCard("丁", saved: true)
        XCTAssertNil(app.batchSaveIDsSkippingSaved([x.id, y.id]), "全都已入库：没有要保存的")
    }

    func testOtherProblemsStillBlockEvenIfSavedOnesAreSkipped() {
        let saved = addCard("甲", saved: true)
        let untyped = addCard("乙", type: nil)
        let generating = addCard("丙", status: .generating)
        let missing = addCard("丁", hasFile: false)
        for bad in [untyped, generating, missing] {
            XCTAssertNil(app.batchSaveIDsSkippingSaved([saved.id, bad.id]), "\(bad.name)：别的问题全有全无的规矩不变，先处理")
        }
        // 好的 + 已入库的 + 有问题的：一并算有问题
        let fine = addCard("戊")
        XCTAssertNil(app.batchSaveIDsSkippingSaved([fine.id, saved.id, untyped.id]))
    }

    func testOnlyTheDisplayedVersionCountsAsSaved() {
        // 两个结果，第 1 版入过库；当前显示（选中）第 1 版 = 已入库，显示第 2 版 = 还没入库
        var item = addCard("甲", saved: true)
        let second = ImageGenResult(localPath: file.path, createdAt: Date())
        let i = app.imageItems.firstIndex { $0.id == item.id }!
        app.imageItems[i].results.append(second)
        app.imageItems[i].selectedResultID = item.results[0].id
        item = app.imageItems[i]
        XCTAssertEqual(app.batchSaveVerdict(item), .alreadySaved)
        app.imageItems[i].selectedResultID = second.id
        XCTAssertEqual(app.batchSaveVerdict(app.imageItems[i]), .ok, "显示的是没入库的那一版：要存")
        app.imageItems[i].selectedResultID = nil                                      // 没选 = 跟随最新（第 2 版）
        XCTAssertEqual(app.batchSaveVerdict(app.imageItems[i]), .ok)
    }

    func testAGeneratingCardWithAnOldSavedResultIsNoResultNotAlreadySaved() {
        let card = addCard("甲", saved: true, status: .generating)
        XCTAssertEqual(app.batchSaveVerdict(card), .noResult, "和原来的预检一样：没成功就是没结果，先于「已入库」判断")
        XCTAssertEqual(app.batchSaveLibraryIssues(for: [card.id]).noResult, 1)
    }

    func testTheVerdictsMatchTheCountsOfThePrecheck() {
        let ids = [addCard("a"), addCard("b", saved: true), addCard("c", type: nil), addCard("d", status: .failed), addCard("e", hasFile: false)].map(\.id)
        let issues = app.batchSaveLibraryIssues(for: ids)
        XCTAssertEqual([issues.noType, issues.noResult, issues.alreadySaved, issues.missingFile], [1, 1, 1, 1])
        XCTAssertEqual(issues.summary, "1 张没有类型（纯生图），不能入库 —— 请先给它们选类型；1 张还没有生成结果；1 张当前显示的那一版已经入库过；1 张的本地文件缺失")
    }
}
