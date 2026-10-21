import XCTest
@testable import Xipixiaojuchang

/// 空项目 / 自由创作里拖 txt 进工作台：自动认是分镜还是剧本（2026-10-14 用户：软件分剧本模式和自由创作模式）
final class DroppedFileKindTests: XCTestCase {
    func testAScriptIsNotAStoryboard() {
        let script = """
        第1集
        场景：年度赛车颁奖礼·后台 夜 内
        △ 周承山攥着复检申请副本走进后台。
        周承山：[压低声音] 这份报告你看过没有？
        许曼：我只负责颁奖。
        """
        XCTAssertNil(ShotScriptParser.storyboardShots(script), "没有行首三个方括号：是剧本")
        XCTAssertEqual(ShotScriptParser.parse(script).count, 1, "（对照）原来的 parse 会把整篇当成一个分镜，所以不能拿它判断")
    }

    func testAStoryboardIsRecognizedAndThePreambleDropped() throws {
        let storyboard = """
        好的，下面是分镜：

        [颁奖礼·后台][周承山、许曼][复检申请副本]
        【角色初始站位与朝向】周承山站在画面右侧。
        中景，周承山边走边说："这份报告你看过没有？"

        [颁奖礼·颁奖台][许曼][ ]【角色初始站位与朝向】许曼站在台中央。
        近景，许曼举起奖杯。
        """
        let shots = try XCTUnwrap(ShotScriptParser.storyboardShots(storyboard))
        XCTAssertEqual(shots.count, 2)
        XCTAssertTrue(shots[0].hasPrefix("[颁奖礼·后台][周承山、许曼][复检申请副本]"), "开场白不算进分镜")
        XCTAssertTrue(shots[1].hasPrefix("[颁奖礼·颁奖台][许曼][ ]"), "头行后面同一行接着写也认")
    }
}
