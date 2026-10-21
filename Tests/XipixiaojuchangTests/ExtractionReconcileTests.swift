import XCTest
@testable import Xipixiaojuchang

/// 提取对账（2026-10-17；方案见仓库根 `方案-提取对账.md`）：沿用 / 新建 / 变化 / 待确认 + 幂等 + 重提更新。
@MainActor
final class ExtractionReconcileTests: XCTestCase {
    private let key = "reconcile"
    private var app: AppModel!

    override func setUp() async throws {
        app = AppModel()
        app.currentProjectKey = key
    }
    override func tearDown() async throws {
        app.imageItems.removeAll { $0.projectKey == key }
        app.currentProjectKey = nil
        app = nil
    }

    // MARK: 造数据

    @discardableResult
    private func card(_ name: String, from: Int? = nil, stage: String? = nil, prompt: String = "这个人是：\"X\"，灰西装。") -> ImageGenItem {
        var item = ImageGenItem(projectKey: key, type: .character, name: name, prompt: prompt)
        item.fromEpisode = from
        item.stage = stage
        app.imageItems.append(item)
        return item
    }
    /// 一块角色输出（`change` = 变化版格式，带「修改内容」行）
    private func block(_ name: String, from: Int? = nil, stage: String? = nil, change: Bool = false) -> ImagePromptParser.Parsed {
        var lines = ["这个人是：\"\(name)\"，现代背景。"]
        if let stage { lines.append("阶段：\(stage)") }
        if let from { lines.append("起始集：\(from)") }
        if change {
            lines.append("修改内容：上衣换成白色赛车服。")
            lines.append("保持不变：面部五官、发型。")
        } else {
            lines.append("描述：三十岁，灰西装。")
        }
        return ImagePromptParser.Parsed(type: .character, name: name, prompt: lines.joined(separator: "\n"),
                                        fromEpisode: from, stage: stage)
    }
    private func apply(_ pairs: [(card: ImagePromptParser.Parsed, reference: String?)], reused: [String] = [],
                       mode: ExtractionReconcile.Mode = .batch, listed: Set<String> = ["张三", "李四", "周承山"]) -> ExtractionReconcile.Outcome {
        ExtractionReconcile.apply(pairs: pairs, reused: reused, mode: mode, kind: .role,
                                  listedNames: listed, project: key, app: app)
    }
    private func cards(_ name: String? = nil) -> [ImageGenItem] {
        app.imageItems.filter { $0.projectKey == key && (name == nil || $0.name == name) }
    }

    // MARK: 沿用行

    func testReusedLinesAreRecognizedInQuotesListsAndBullets() {
        let raw = """
        沿用：张三
        沿用："李四"
        - 沿用：沈砚、许曼
        这个人是："王五"，三十岁。
        """
        XCTAssertEqual(ExtractionReconcile.reusedNames(in: raw), ["张三", "李四", "沈砚", "许曼"])
    }

    // MARK: 四分类

    func testUnknownNamesAreCreatedAndReusedNamesAreLeftAlone() {
        card("张三")
        let outcome = apply([(block("李四"), nil)], reused: ["张三"])
        XCTAssertEqual(outcome.created, 1)
        XCTAssertEqual(cards("李四").count, 1)
        XCTAssertEqual(cards("张三").count, 1, "沿用不建卡")
        XCTAssertTrue(outcome.notes.contains { $0.contains("新建 1 个") && $0.contains("沿用 1 个") }, "\(outcome.notes)")
    }

    func testTheSameSlotIsNeverCreatedTwice() {
        card("张三")
        let outcome = apply([(block("张三"), nil)])
        XCTAssertEqual(outcome.created, 0, "同一个版本槽已经有了：不重复建")
        XCTAssertEqual(cards("张三").count, 1)
        XCTAssertTrue(outcome.notes.contains { $0.contains("没有重复建") }, "\(outcome.notes)")
    }

    func testAPlainBlockWithANewStartIsPendingAndNotCreated() {
        card("张三", from: 1)
        let outcome = apply([(block("张三", from: 5), nil)])
        XCTAssertEqual(outcome.created, 0)
        XCTAssertEqual(cards("张三").count, 1)
        XCTAssertTrue(outcome.notes.contains { $0.contains("待确认") && $0.contains("修改内容") }, "\(outcome.notes)")
    }

    func testAChangeBlockCreatesAndLinksToItsBase() {
        let base = card("张三", from: 1)
        let outcome = apply([(block("张三", from: 5, change: true), nil)])
        XCTAssertEqual(outcome.created, 1)
        let variant = try! XCTUnwrap(cards("张三").first { $0.fromEpisode == 5 })
        XCTAssertEqual(variant.referenceCardID, base.id, "变化版认最近的一版基础版")
    }

    func testAChangeBlockWithoutABaseIsPending() {
        let outcome = apply([(block("周承山", from: 5, change: true), nil)])
        XCTAssertEqual(outcome.created, 0, "变化版找不到基础版：不建，进待确认")
        XCTAssertTrue(outcome.notes.contains { $0.contains("待确认") && $0.contains("基础版") }, "\(outcome.notes)")
    }

    /// 点名重提：同一个版本槽返回时更新原卡的描述，图 / 生成历史不动
    func testRefreshUpdatesTheSameSlotInsteadOfCreating() {
        let existing = card("张三", prompt: "这个人是：\"张三\"，老描述。")
        app.imageItems[app.imageItems.firstIndex { $0.id == existing.id }!].results =
            [ImageGenResult(localPath: nil, createdAt: Date())]
        let outcome = apply([(block("张三"), nil)], mode: .refresh)
        XCTAssertEqual(outcome.created, 0)
        XCTAssertEqual(outcome.updated, 1)
        let updated = try! XCTUnwrap(cards("张三").first)
        XCTAssertTrue(updated.prompt.contains("描述：三十岁，灰西装。"), updated.prompt)
        XCTAssertEqual(updated.results.count, 1, "生成历史保留")
    }

    func testRefreshWithoutASameSlotCardFallsBackToTheNormalRules() {
        card("张三", from: 1)
        let outcome = apply([(block("李四"), nil)], mode: .refresh)
        XCTAssertEqual(outcome.created, 1, "没见过的名字：照常新建")
        XCTAssertEqual(outcome.updated, 0)
    }

    /// 同一个版本槽万一有多张卡（历史 / 迁移数据）：重提时全都更新，别只改第一张（2026-10-18）
    func testRefreshUpdatesEveryCardInTheSameSlot() {
        card("张三", from: 2, prompt: "这个人是：\"张三\"，老描述甲。")
        card("张三", from: 2, prompt: "这个人是：\"张三\"，老描述乙。")
        let outcome = apply([(block("张三", from: 2), nil)], mode: .refresh)
        XCTAssertEqual(outcome.updated, 2, "两张都该更新")
        for item in cards("张三") {
            XCTAssertTrue(item.prompt.contains("描述：三十岁，灰西装。"), item.prompt)
        }
    }

    // MARK: 幂等

    func testRunningTheSameBatchTwiceCreatesNothingTheSecondTime() {
        let pairs: [(card: ImagePromptParser.Parsed, reference: String?)] = [(block("张三"), nil), (block("李四"), nil)]
        XCTAssertEqual(apply(pairs).created, 2)
        XCTAssertEqual(apply(pairs).created, 0, "同一批再跑一遍：零新卡")
        XCTAssertEqual(cards().count, 2)
    }
}
