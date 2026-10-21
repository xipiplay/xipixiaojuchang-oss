import XCTest
@testable import Xipixiaojuchang

/// 生图卡片的命名（2026-10-08）：不撞号、提取出来直接用真名字、同名加序号、提交时不把序号改回去。
@MainActor
final class ImageCardNamingTests: XCTestCase {
    func testThePlaceholderNumberIsTheLargestExistingOnePlusOneSoDeletingNeverCollides() {
        XCTAssertEqual(ImageCardNaming.nextPlaceholderNumber(existing: []), 1)
        XCTAssertEqual(ImageCardNaming.nextPlaceholderNumber(existing: ["图片1", "图片3", "图片4", "图片5"]), 6, "删掉图片2 之后不会再发出第二个图片5")
        XCTAssertEqual(ImageCardNaming.nextPlaceholderNumber(existing: ["张三", "客厅", "图片2"]), 3, "真名字不占编号")
        XCTAssertEqual(ImageCardNaming.nextPlaceholderNumber(existing: ["图片", "图片x", "图片 3", "图片12"]), 13, "只认「图片」加纯数字")
    }

    func testManualAddingAfterDeletingGivesAFreshName() {
        let app = AppModel()
        app.currentProjectKey = "naming-" + UUID().uuidString
        for _ in 0..<5 { app.addImageItem() }
        app.removeImageItem(id: app.currentImageItems[1].id)
        app.addImageItem()
        let names = app.currentImageItems.map(\.name)
        XCTAssertEqual(names, ["图片1", "图片3", "图片4", "图片5", "图片6"])
        XCTAssertEqual(Set(names).count, names.count, "没有重名")
    }

    func testUniqueAddsASequenceNumberForDuplicates() {
        XCTAssertEqual(ImageCardNaming.unique("张三", taken: []), "张三")
        XCTAssertEqual(ImageCardNaming.unique("张三", taken: ["张三"]), "张三 2")
        XCTAssertEqual(ImageCardNaming.unique("张三", taken: ["张三", "张三 2"]), "张三 3")
        XCTAssertEqual(ImageCardNaming.baseName("张三 2"), "张三")
        XCTAssertEqual(ImageCardNaming.baseName("张三"), "张三")
        XCTAssertEqual(ImageCardNaming.baseName("张三 二"), "张三 二", "只去掉纯数字的序号")
    }

    func testParsedCardsUseTheRecognisedNamesAndFallBackToANumberedPlaceholder() {
        let parsed = ImagePromptParser.parse("""
        这个人是："张三"，三十岁。
        这个场景叫："客厅"，现代。
        这个人是："张三"，换了一身衣服。
        这个物品名称叫：，没写名字。
        """)
        XCTAssertEqual(parsed.count, 4)
        let names = ImageCardNaming.names(forParsed: parsed, existing: ["图片1", "客厅"])
        XCTAssertEqual(names, ["张三", "客厅 2", "张三 2", "图片2"], "同名（含和已有卡片重名）加序号；识别不出的叫图片N，接在已有编号后面")
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testAppendParsedCardsNamesThemAndRepeatingTheExtractionDoesNotCollide() {
        let app = AppModel()
        let key = "naming-" + UUID().uuidString
        let parsed = ImagePromptParser.parse("这个人是：\"张三\"，三十岁。\n这个场景叫：\"客厅\"，现代。")
        let first = app.appendParsedImageCards(parsed, projectKey: key)
        XCTAssertEqual(first.map(\.name), ["张三", "客厅"])
        XCTAssertEqual(first.map(\.type), [.character, .scene], "类型不受影响")
        let second = app.appendParsedImageCards(parsed, projectKey: key)
        XCTAssertEqual(second.map(\.name), ["张三 2", "客厅 2"], "再提取一遍：追加，同名加序号")
    }

    func testSubmittingKeepsTheNumberedNameButFollowsARealRename() {
        // 提取出来就叫「张三 2」，提交时从提示词里提到的还是「张三」：不改回去
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "张三 2", derived: "张三", taken: ["张三"]), "张三 2")
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "张三", derived: "张三", taken: []), "张三")
        // 手动建的「图片5」，提示词里写了「这个人是：李四」→ 改成李四；李四已经有了 → 李四 2
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "图片5", derived: "李四", taken: []), "李四")
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "图片5", derived: "李四", taken: ["李四"]), "李四 2")
        // 改了提示词换了人：跟着换
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "张三", derived: "王五", taken: []), "王五")
        // 提不出名字：不动
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "图片5", derived: nil, taken: []), "图片5")
        XCTAssertEqual(ImageCardNaming.nameAfterSubmit(current: "图片5", derived: "", taken: []), "图片5")
    }
}
