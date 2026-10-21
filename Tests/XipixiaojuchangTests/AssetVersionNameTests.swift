import XCTest
@testable import Xipixiaojuchang

/// 素材名里的「第N集的」版本前缀：拆名字、按集号选版本、匹配素材时用基础名（2026-10-09）
final class AssetVersionNameTests: XCTestCase {
    func testParsesArabicChineseAndFullwidthNumbers() {
        XCTAssertEqual(AssetVersionName.parse("第1集的沈惊澜"), .init(episode: 1, base: "沈惊澜"))
        XCTAssertEqual(AssetVersionName.parse("第12集的老城区客厅"), .init(episode: 12, base: "老城区客厅"))
        XCTAssertEqual(AssetVersionName.parse("第一集的沈惊澜"), .init(episode: 1, base: "沈惊澜"))
        XCTAssertEqual(AssetVersionName.parse("第十二集的怀表"), .init(episode: 12, base: "怀表"))
        XCTAssertEqual(AssetVersionName.parse("第二十集的怀表"), .init(episode: 20, base: "怀表"))
        XCTAssertEqual(AssetVersionName.parse("第一百零五集的怀表"), .init(episode: 105, base: "怀表"))
        XCTAssertEqual(AssetVersionName.parse("第８集的沈惊澜"), .init(episode: 8, base: "沈惊澜"))
        XCTAssertEqual(AssetVersionName.parse("  第 8 集 的 沈惊澜  "), .init(episode: 8, base: "沈惊澜"), "空白不影响")
        XCTAssertEqual(AssetVersionName.parse("第3集的第二套婚服"), .init(episode: 3, base: "第二套婚服"), "只拆最前面那一段前缀")
    }

    func testNamesWithoutThePrefixAreLeftAlone() {
        for name in ["沈惊澜", "图片 7", "第一集团的老板", "第集的沈惊澜", "第0集的沈惊澜", "第3集沈惊澜", "第3集的", "角色-沈惊澜"] {
            XCTAssertNil(AssetVersionName.parse(name), name)
            XCTAssertEqual(AssetVersionName.baseName(name), name)
        }
        XCTAssertEqual(AssetVersionName.baseName("第8集的沈惊澜"), "沈惊澜")
    }

    func testPickTakesTheLatestVersionNotAfterTheEpisode() {
        let versions = [1, 8, 20]
        XCTAssertEqual(AssetVersionName.pick(versions: versions, episode: 1), 0)
        XCTAssertEqual(AssetVersionName.pick(versions: versions, episode: 7), 0)
        XCTAssertEqual(AssetVersionName.pick(versions: versions, episode: 8), 1, "第 8 集起生效，第 8 集本身就用它")
        XCTAssertEqual(AssetVersionName.pick(versions: versions, episode: 19), 1)
        XCTAssertEqual(AssetVersionName.pick(versions: versions, episode: 60), 2)
        XCTAssertEqual(AssetVersionName.pick(versions: [20, 1, 8], episode: 9), 2, "和顺序无关")
    }

    func testNoVersionIsPickedWhenAllOfThemStartAfterTheEpisode() {
        // 2026-10-09 用户实测：第 2 集的分镜被挂上了第 24 集才出现的变化版
        XCTAssertNil(AssetVersionName.pick(versions: [24, 30, 45], episode: 2), "比所有版本都早：不匹配，不去猜更晚的变化版")
        XCTAssertNil(AssetVersionName.pick(versions: [5, 9], episode: 4))
        XCTAssertEqual(AssetVersionName.pick(versions: [24, 30, 45], episode: 24), 0, "第 24 集起生效，第 24 集本身就用它")
        XCTAssertEqual(AssetVersionName.pick(versions: [24, 30, 45], episode: 29), 0)
        XCTAssertEqual(AssetVersionName.pick(versions: [24, 30, 45], episode: 44), 1)
    }

    func testNoEpisodeMeansTheEarliestVersion() {
        XCTAssertEqual(AssetVersionName.pick(versions: [9, 5], episode: nil), 1, "不知道是第几集：取最早的基础形象")
        XCTAssertNil(AssetVersionName.pick(versions: [], episode: 3))
    }

    func testUnprefixedVersionsCountAsAlwaysValidAndTiesKeepLibraryOrder() {
        XCTAssertEqual(AssetVersionName.pick(versions: [0, 8], episode: 3), 0, "没有前缀 = 全程有效（集号 0）")
        XCTAssertEqual(AssetVersionName.pick(versions: [0, 8], episode: 9), 1)
        XCTAssertEqual(AssetVersionName.pick(versions: [0, 0, 0], episode: 5), 0, "同集号取靠前的（同一张卡入库过好几次）")
        XCTAssertEqual(AssetVersionName.pick(versions: [4, 4], episode: 9), 0)
    }
}
