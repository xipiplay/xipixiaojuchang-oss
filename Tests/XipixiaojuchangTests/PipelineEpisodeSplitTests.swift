import XCTest
@testable import Xipixiaojuchang

final class PipelineEpisodeSplitTests: XCTestCase {

    func testEpisodeSplitterStandardArabicNumerals() {
        let script = """
        第1集 序幕
        风雪交加的夜晚，客栈门扉被叩响。
        掌柜抬头看去。

        第2集 变故
        清晨微光洒进房中。
        案几上的玉佩不翼而飞。
        """

        let episodes = EpisodeSplitter.split(script)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes[0].title.contains("第1集"))
        XCTAssertTrue(episodes[0].text.contains("客栈门扉被叩响"))
        XCTAssertTrue(episodes[1].title.contains("第2集"))
        XCTAssertTrue(episodes[1].text.contains("玉佩不翼而飞"))
    }

    func testEpisodeSplitterChineseNumeralsAndChapters() {
        let script = """
        【第一章 始】
        少年背剑入城。

        【第二章 遇】
        酒肆喧嚣，一白衣女子独酌。

        【第三集 别】
        斜阳古道，两骑分道扬镳。
        """

        let episodes = EpisodeSplitter.split(script)
        XCTAssertEqual(episodes.count, 3)
        XCTAssertTrue(episodes[0].title.contains("第一章"))
        XCTAssertTrue(episodes[1].title.contains("第二章"))
        XCTAssertTrue(episodes[2].title.contains("第三集"))
    }

    func testEpisodeSplitterRequiresAtLeastTwoMatches() {
        let singleScript = """
        第1集 独角戏
        全篇只有这一场戏。
        """
        XCTAssertTrue(EpisodeSplitter.split(singleScript).isEmpty)

        let noTagScript = """
        很久很久以前，在一个遥远的王国里。
        公主和王子过上了幸福的生活。
        """
        XCTAssertTrue(EpisodeSplitter.split(noTagScript).isEmpty)
    }

    func testAISplitJSONExtractionAndParsingStandard() {
        let aiOutput = """
        好的，我已经按剧情节奏将剧本切分为两集：
        ```json
        [
          {"title": "第 1 集", "text": "这是第一集正文内容。"},
          {"title": "第 2 集", "text": "这是第二集正文内容。"}
        ]
        ```
        请查看。
        """

        let (episodes, isFallback) = PipelineAIService.parseEpisodes(from: aiOutput)
        XCTAssertFalse(isFallback)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes[0].title, "第 1 集")
        XCTAssertEqual(episodes[0].text, "这是第一集正文内容。")
        XCTAssertEqual(episodes[1].title, "第 2 集")
        XCTAssertEqual(episodes[1].text, "这是第二集正文内容。")
    }

    func testAISplitJSONExtractionFallbackOnMalformedOutput() {
        let malformed = "这是一段没有输出标准 JSON 的 AI 自由回答正文。"
        let (episodes, isFallback) = PipelineAIService.parseEpisodes(from: malformed)
        XCTAssertTrue(isFallback)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].title, "第 1 集")
        XCTAssertEqual(episodes[0].text, malformed)
    }

    func testPipelineArchiveSplitWorkflowStateTransitions() throws {
        let script = """
        第1集 启程
        踏上漫漫长路。

        第2集 归途
        夕阳西下，平安归家。
        """
        let local = EpisodeSplitter.split(script)
        XCTAssertEqual(local.count, 2)

        var archive = ProjectPipelineArchive(
            projectId: UUID(),
            wholeScript: script,
            loadedFileName: "测试剧本.txt"
        )
        XCTAssertEqual(archive.splitStage, 0)
        XCTAssertEqual(archive.episodes.count, 0)
        XCTAssertEqual(archive.works.count, 0)

        // 阶段 1：分集切出（待确认）
        archive.episodes = local
        archive.splitStage = 1
        XCTAssertEqual(archive.episodes.count, 2)
        XCTAssertEqual(archive.splitStage, 1)

        // 阶段 2：确认分集，对齐 works
        var newWorks: [EpWork] = []
        for i in archive.episodes.indices {
            newWorks.append(i < archive.works.count ? archive.works[i] : EpWork())
        }
        archive.works = newWorks
        archive.splitStage = 2

        XCTAssertEqual(archive.works.count, 2)
        XCTAssertEqual(archive.splitStage, 2)

        // 验证持久化编解码无损
        let data = try JSONEncoder().encode(archive)
        let restored = try JSONDecoder().decode(ProjectPipelineArchive.self, from: data)
        try restored.validate()

        XCTAssertEqual(restored.episodes.count, 2)
        XCTAssertEqual(restored.works.count, 2)
        XCTAssertEqual(restored.splitStage, 2)
        XCTAssertEqual(restored.episodes[0].title, local[0].title)
    }

    func testEndpointConstruction() throws {
        var config = PipelineAISettings()
        config.baseURL = "https://api.deepseek.com"
        var url = try PipelineAIService.endpoint(for: config)
        XCTAssertEqual(url.absoluteString, "https://api.deepseek.com/v1/chat/completions")

        config.baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        url = try PipelineAIService.endpoint(for: config)
        XCTAssertEqual(url.absoluteString, "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")

        config.baseURL = "https://my-gateway.internal/v1/chat/completions"
        url = try PipelineAIService.endpoint(for: config)
        XCTAssertEqual(url.absoluteString, "https://my-gateway.internal/v1/chat/completions")
    }
}
