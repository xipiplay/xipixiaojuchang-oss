import XCTest
@testable import Xipixiaojuchang

/// 一集的时长分割按时间标号切成一段一段，并估每段用到的素材（2026-10-09 工作台第 2 步）。
final class SplitSegmentsTests: XCTestCase {
    private let sample = """
    场景：蕴古斋前柜 日 内
    【角色】：齐掌柜、沈砚
    【道具】：货账
    △ 齐掌柜坐在太师椅上，右手压住货账
    齐掌柜：头一天就迟到一刻钟。
    --- 00:00 - 00:30
    △ 沈砚抬眼
    沈砚：门板沉，下了半天。
    宋文清：我来晚了。
    --- 00:30 - 01:00
    场景：后院 夜 外
    △ 月光落在井沿
    --- 01:00 - 01:30
    **结束。**
    """

    func testSegmentsAreCutAtTheTimeMarkersAndTheMarkerBelongsToTheSegmentAboveIt() {
        let segments = SplitSegments.parse(sample)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.number), [1, 2, 3])
        XCTAssertEqual(segments.map(\.timeRange), ["00:00–00:30", "00:30–01:00", "01:00–01:30"])
        XCTAssertTrue(segments[0].text.hasPrefix("场景：蕴古斋前柜 日 内"))
        XCTAssertTrue(segments[0].text.hasSuffix("头一天就迟到一刻钟。"))
        XCTAssertFalse(segments[0].text.contains("---"), "时间标号行不进段落文字")
        XCTAssertTrue(segments[1].text.hasPrefix("△ 沈砚抬眼"))
    }

    func testTheCountMatchesWhatInferenceExpects() {
        XCTAssertEqual(SplitSegments.parse(sample).count, StoryboardInference.expectedBlockCount(in: sample))
        let trailing = "甲\n--- 00:00 - 00:30\n乙，最后一个标号后面还有字"
        XCTAssertEqual(SplitSegments.parse(trailing).count, StoryboardInference.expectedBlockCount(in: trailing))
        XCTAssertEqual(SplitSegments.parse(trailing).last?.timeRange, nil, "最后没有标号的一段没有时间")
    }

    func testEndMarksAndBlankPiecesAreNotSegments() {
        XCTAssertEqual(SplitSegments.parse("甲\n--- 00:00 - 00:30\n\n--- 00:30 - 01:00\n（完）").count, 1)
        XCTAssertEqual(SplitSegments.parse("").count, 0)
        XCTAssertEqual(SplitSegments.parse("没有任何标号的一整段文字").count, 1)
    }

    func testRolesPropsAndSceneAreEstimatedFromTheListedLinesAndTheSpeakers() {
        let segments = SplitSegments.parse(sample)
        XCTAssertEqual(segments[0].scene, "蕴古斋前柜", "「日 内」去掉，只留地点")
        XCTAssertEqual(segments[0].roles, ["齐掌柜", "沈砚"])
        XCTAssertEqual(segments[0].props, ["货账"])
        // 第 2 段没有列角色：沿用同一场景里列过的，再加这一段的说话人（宋文清）
        XCTAssertEqual(segments[1].scene, "蕴古斋前柜")
        XCTAssertEqual(segments[1].roles, ["齐掌柜", "沈砚", "宋文清"])
        XCTAssertEqual(segments[1].props, ["货账"])
        // 第 3 段换了场景：角色、道具重新算（这一段没有列、也没有人说话）
        XCTAssertEqual(segments[2].scene, "后院")
        XCTAssertEqual(segments[2].roles, [])
        XCTAssertEqual(segments[2].props, [])
    }

    func testSpeakersAreOnlyForThatSegmentAndReservedWordsAreNotNames() {
        let text = """
        场景：客厅
        【角色】：甲
        甲：你好
        --- 00:00 - 00:30
        旁白：夜深了
        乙（OS）：外面有人
        画面：一盏灯
        --- 00:30 - 01:00
        △ 安静
        --- 01:00 - 01:30
        """
        let segments = SplitSegments.parse(text)
        XCTAssertEqual(segments[0].roles, ["甲"])
        XCTAssertEqual(segments[1].roles, ["甲", "乙"], "括号备注去掉；旁白、画面这类不是人")
        XCTAssertEqual(segments[2].roles, ["甲"], "上一段的说话人不往后传")
    }

    func testBothHalfAndFullWidthColonsAndBracketedLabelsAreRecognised() {
        let text = "【场景】：老城区助餐点门口 黄昏 外\n【角色】: 林知夏、母亲\n【道具】：饭盒、 台面\n--- 00:00 - 00:30"
        let segment = SplitSegments.parse(text)[0]
        XCTAssertEqual(segment.scene, "老城区助餐点门口")
        XCTAssertEqual(segment.roles, ["林知夏", "母亲"])
        XCTAssertEqual(segment.props, ["饭盒", "台面"])
    }

    func testTheFormatWithBracketedSpeakersAndActionNotesIsRecognised() {
        let text = """
        【场景】：盛景中心楼下 日 外
        【角色】：程砚、房东大妈、房东群
        【道具】：轿车、引擎盖
        △ 盛景中心写字楼前停着一辆黑色轿车，乌泱泱的房东围堵在车前，房东大妈双手拍打着引擎盖，神情激动
        [房东大妈]（拍着引擎盖嚎啕大哭）：老板你不能走啊！
        [房东大妈]（眼泪鼻涕横流）：我那三套房的房贷还指着你们公司呢！
        △ 程砚坐在车内透过车窗冷眼看着车外的房东们，神色冷淡
        --- 00:00 - 00:30
        [房东二叔]：让我们进去！
        [房东群]（齐声）：还钱！
        --- 00:30 - 01:00
        """
        let segments = SplitSegments.parse(text)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].scene, "盛景中心楼下")
        XCTAssertEqual(segments[0].roles, ["程砚", "房东大妈", "房东群"], "已经列出的角色，说话人不重复")
        XCTAssertEqual(segments[0].props, ["轿车", "引擎盖"])
        // 第 2 段没有列角色：沿用同一场景列过的，再加这一段新出现的说话人（房东二叔）
        XCTAssertEqual(segments[1].roles, ["程砚", "房东大妈", "房东群", "房东二叔"])
        XCTAssertEqual(segments[1].props, ["轿车", "引擎盖"])
    }

    // MARK: 改一段写回整集

    func testReplacingOneSegmentLeavesTheOthersAndTheMarkersAlone() throws {
        let original = sample
        let updated = try XCTUnwrap(SplitSegments.replacing(segment: 2, in: original, with: "△ 沈砚低头\n沈砚：门板沉。"))
        let segments = SplitSegments.parse(updated)
        XCTAssertEqual(segments.count, 3, "段数不变")
        XCTAssertEqual(segments[1].text, "△ 沈砚低头\n沈砚：门板沉。")
        XCTAssertEqual(segments[0].text, SplitSegments.parse(original)[0].text)
        XCTAssertEqual(segments[2].text, SplitSegments.parse(original)[2].text)
        XCTAssertEqual(segments.map(\.timeRange), ["00:00–00:30", "00:30–01:00", "01:00–01:30"], "时间标号一个没动")
        XCTAssertTrue(updated.hasSuffix("**结束。**"), "收尾词还在")
    }

    func testReplacingTheLastUnmarkedSegmentKeepsTheEndMark() throws {
        let text = "甲\n--- 00:00 - 00:30\n乙\n乙二\n（完）"
        let updated = try XCTUnwrap(SplitSegments.replacing(segment: 2, in: text, with: "丙"))
        XCTAssertEqual(updated, "甲\n--- 00:00 - 00:30\n丙\n（完）")
    }

    func testReplacingRefusesTimeMarkersAndUnknownSegments() {
        XCTAssertNil(SplitSegments.replacing(segment: 1, in: sample, with: "新的\n--- 00:10 - 00:20\n又一段"), "会把一段拆成两段")
        XCTAssertNil(SplitSegments.replacing(segment: 9, in: sample, with: "x"))
    }

    func testEditedTextRoundTripsExactly() throws {
        let segment = SplitSegments.parse(sample)[0]
        XCTAssertEqual(SplitSegments.replacing(segment: 1, in: sample, with: segment.text), sample, "没改动就一字不差")
    }
}
