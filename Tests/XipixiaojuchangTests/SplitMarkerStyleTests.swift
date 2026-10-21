import XCTest
@testable import Xipixiaojuchang

/// 时间标号的两种写法（2026-10-11）：段末 `--- 00:00 - 00:30`（旧）、段首 `=== [00:00-00:30] ===`（新，分割提示词 v2 用的）。
/// 夹具是 v2 提示词里自己的格式示范。
final class SplitMarkerStyleTests: XCTestCase {
    /// v2 分割提示词里的「格式示范」（标号在段首、每段都有【本段在场】）
    private let v2 = """
    === [00:00-00:30] ===
    【场景】：蕴古斋前柜 日 内
    【角色】：齐掌柜、沈砚、宋文清、老孙
    【道具】：货账、藤箱
    【本段在场】：齐掌柜、沈砚、宋文清、老孙
    [齐掌柜]（坐在太师椅上，指腹点住账页）：头一天就迟到一刻钟。你就住后院，走两步路。
    [沈砚]（边把藤箱放到脚边边抬眼）：门板沉，下了半天。
    △ 齐掌柜撑扶手起身，货账拍在桌上
    [齐掌柜]（压着火）：你跟我讲讲，这是什么？
    [沈砚]：货账。

    === [00:30-01:00] ===
    【本段在场】：齐掌柜、沈砚、宋文清、老孙（中途进场，拿着账本）
    [宋文清]（手掌向外一摊，侧身对着齐掌柜）：我看他这路数不对，连学徒都不如。
    [老孙]（抬手往下轻压）：文清，少说两句。
    △ 齐掌柜站直，抬手压住货账
    [齐掌柜]：下回再出这种东西，我直接退回东家。
    """

    private let tail = "场景：客厅 日 内\n张三：你来了。\n--- 00:00 - 00:30\n李四：等一下。\n--- 00:30 - 01:00"

    func testBothMarkerWritingsAreRecognisedAndOtherLinesAreNot() {
        for line in ["=== [00:00-00:30] ===", "=== [00:30-01:00] ===", "=== 00:30 - 01:00 ===", "--- [00:00-00:30] ---",
                     "--- 00:00 - 00:30", "---[00:00 - 00:30]", "  ==  [1:05-1:35]  ==  "] {
            XCTAssertTrue(StoryboardInference.isTimeMarker(line), line)
        }
        for line in ["=== 标题 ===", "---", "===", "我们 00:00-00:30 见", "时间 00:00 - 00:30", "- 00:00 - 00:30", "= [00:00-00:30]", ""] {
            XCTAssertFalse(StoryboardInference.isTimeMarker(line), line)
        }
    }

    func testTheStyleIsHeadWhenMarkersOpenASegmentAndTailWhenTheyCloseOne() {
        XCTAssertEqual(StoryboardInference.markerStyle(of: v2), .head)
        XCTAssertEqual(StoryboardInference.markerStyle(of: tail), .tail)
        XCTAssertEqual(StoryboardInference.markerStyle(of: "--- 00:00 - 00:30\n张三：你来了。\n--- 00:30 - 01:00\n李四：等一下。"), .head,
                       "第一个标号前面没有正文：标号在段首")
        XCTAssertEqual(StoryboardInference.markerStyle(of: "以下是分割结果：\n=== [00:00-00:30] ===\n张三：你来了。"), .head, "= 写的标号 = 段首，前面有前言也一样")
        XCTAssertNil(StoryboardInference.markerStyle(of: "只有正文，没有标号"))
    }

    func testTheSegmentCountWorksForBothAndSkipsPrefacesAndEndWords() {
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: v2), 2)
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: v2 + "\n\n**结束。**"), 2, "收尾词不算一段")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: "以下是分割结果：\n" + v2), 2, "前言不算一段")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: "=== [00:00-00:30] ===\n=== [00:30-01:00] ===\n张三：你来了。"), 1, "空段不算")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: tail), 2, "旧写法不变")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: tail + "\n结束。"), 2)
        XCTAssertNil(StoryboardInference.expectedBlockCount(in: "没有标号"))
    }

    func testHeadStyleTextIsCutIntoSegmentsWithTheirOwnTimesAndPresentCharacters() {
        let segments = SplitSegments.parse(v2)
        XCTAssertEqual(segments.map(\.number), [1, 2])
        XCTAssertEqual(segments[0].timeRange, "00:00–00:30")
        XCTAssertEqual(segments[1].timeRange, "00:30–01:00")
        XCTAssertEqual(segments[0].scene, "蕴古斋前柜")
        XCTAssertEqual(segments[1].scene, "蕴古斋前柜", "后一段没写场景：沿用")
        XCTAssertEqual(segments[0].roles, ["齐掌柜", "沈砚", "宋文清", "老孙"])
        XCTAssertEqual(segments[1].roles, ["齐掌柜", "沈砚", "宋文清", "老孙"], "括号里的备注（含逗号）不进名字")
        XCTAssertFalse(segments.contains { $0.roles.contains("本段在场") }, "「本段在场」不是角色名")
        XCTAssertEqual(segments[0].props, ["货账", "藤箱"])
        XCTAssertFalse(segments[0].text.contains("==="), "标号行不算段的文字")
        XCTAssertTrue(segments[0].text.hasPrefix("【场景】") && segments[0].text.contains("[沈砚]：货账。"))
        XCTAssertTrue(segments[1].text.contains("下回再出这种东西"))
        XCTAssertFalse(segments[0].text.contains("宋文清（") || segments[0].text.contains("老孙（抬手"), "第二段的话不串进第一段")
    }

    func testPresentListOverridesTheSceneWideRosterAndTailStyleIsUnchanged() {
        let narrower = "=== [00:00-00:30] ===\n【场景】：客厅\n【角色】：张三、李四、王五\n【本段在场】：张三\n[张三]：你来了。\n=== [00:30-01:00] ===\n【本段在场】：李四、王五\n[李四]：等一下。"
        XCTAssertEqual(SplitSegments.parse(narrower).map(\.roles), [["张三"], ["李四", "王五"]], "本段在场 = 画面里实际在的人")
        let old = SplitSegments.parse(tail)
        XCTAssertEqual(old.count, 2)
        XCTAssertEqual(old[0].timeRange, "00:00–00:30")
        XCTAssertEqual(old[0].roles, ["张三"], "旧写法：台词前的说话人")
        XCTAssertEqual(old[1].scene, "客厅")
    }

    func testEditingOneSegmentKeepsTheMarkersAndRefusesMarkersInTheNewText() throws {
        let edited = try XCTUnwrap(SplitSegments.replacing(segment: 2, in: v2, with: "[宋文清]：改过的台词。"))
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: edited), 2)
        XCTAssertTrue(edited.contains("=== [00:30-01:00] ===\n[宋文清]：改过的台词。"), edited)
        XCTAssertTrue(edited.contains("[沈砚]：货账。"), "别的段原样")
        XCTAssertNil(SplitSegments.replacing(segment: 2, in: v2, with: "好的\n=== [00:30-01:00] ===\n又一段"), "新文字里不许带标号（会拆出多一段）")
        XCTAssertNil(SplitSegments.replacing(segment: 2, in: v2, with: "好的\n--- 00:30 - 01:00\n又一段"))
    }

    func testTheRequestExplainsWhereTheMarkersSitForWhicheverWritingIsUsed() {
        let head = StoryboardInference.scriptSection(v2)
        XCTAssertTrue(head.contains("一共 2 段") && head.contains("写在它下面那一段的开头") && head.contains("不是上一段的结尾"), head)
        XCTAssertFalse(head.contains("写在它上面那一段的末尾"), "两种写法的说明不能混")
        let old = StoryboardInference.scriptSection(tail)
        XCTAssertTrue(old.contains("写在它上面那一段的末尾") && !old.contains("写在它下面那一段的开头"), old)
        XCTAssertEqual(StoryboardInference.scriptSection("没有标号"), "【本集剧本（按它输出分镜）】\n没有标号")
    }

    func testReInferringOneSegmentSendsItInTheSameWritingAndKeepsTheSceneInfo() throws {
        let second = try XCTUnwrap(SplitSegments.parse(v2).last)
        let head = SplitSegments.standaloneText(for: second, style: .head)
        XCTAssertTrue(head.hasPrefix("=== [00:30-01:00] ===\n【场景】：蕴古斋前柜\n【角色】：齐掌柜、沈砚、宋文清、老孙\n【道具】：货账、藤箱\n"), head)
        XCTAssertTrue(head.contains("[宋文清]（手掌向外一摊"), head)
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: head), 1, "发出去的这一段正好是 1 段")
        let first = try XCTUnwrap(SplitSegments.parse(v2).first)
        XCTAssertEqual(SplitSegments.standaloneText(for: first, style: .head).components(separatedBy: "【场景】").count, 2, "本来就写了的不重复补")

        let oldSecond = try XCTUnwrap(SplitSegments.parse(tail).last)
        let oldText = SplitSegments.standaloneText(for: oldSecond, style: .tail)
        XCTAssertTrue(oldText.hasSuffix("\n--- 00:30 - 01:00"), oldText)
        XCTAssertTrue(oldText.hasPrefix("【场景】：客厅\n"), "旧写法的后几段也补上场景")
        XCTAssertEqual(StoryboardInference.expectedBlockCount(in: oldText), 1)
    }

    // MARK: 整条推理分镜

    private func block(_ tag: String) -> String {
        "[蕴古斋前柜][齐掌柜、沈砚][货账]\n【角色初始站位与朝向】\(tag)齐掌柜站在柜后。\n中景，齐掌柜拍账。\n必须按照镜头描述和角色台词生成。电影写实风格，无字幕，无音乐，角色说中文。"
    }

    @MainActor
    func testInferringAnEpisodeWrittenWithHeadMarkersChecksTheBlockCountAgain() async throws {
        let app = AppModel()
        let key = "head-style-" + UUID().uuidString
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: [Episode(title: "第1集", text: "原文", splitText: v2)]), for: key)
        defer { app.removePipelineArchive(for: key); app.shots.removeAll { $0.projectKey == key } }

        let two = [block("一"), block("二")].joined(separator: "\n\n")
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: { _, user in
            XCTAssertTrue(user.contains("一共 2 段") && user.contains("写在它下面那一段的开头"), "发给 AI 的说明按段首写法讲：\(user.prefix(200))")
            return two
        })
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertEqual(app.shots.filter { $0.projectKey == key }.count, 2, "2 段 2 块：建 2 张卡")

        // 块数对不上要拦住（v2 写法下这个核对之前是失效的：数不出段数）
        let other = "head-style-bad-" + UUID().uuidString
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "原文", episodes: [Episode(title: "第1集", text: "原文", splitText: v2)]), for: other)
        defer { app.removePipelineArchive(for: other); app.shots.removeAll { $0.projectKey == other } }
        let three = [block("一"), block("二"), block("三")].joined(separator: "\n\n")
        app.pipelineFlow.batchInfer(app: app, project: other, episodeIndices: [0], chat: { _, _ in three })
        await app.pipelineFlow.waitForAll(project: other)
        XCTAssertTrue(app.shots.filter { $0.projectKey == other }.isEmpty, "3 块比 2 段多：一张卡也不建")
        let failure = app.pipelineFlow.batches[other]?.failures.first?.message ?? ""
        XCTAssertTrue(failure.contains("多了 1 块"), failure)
    }
}
