import XCTest
@testable import Xipixiaojuchang

final class PipelineRosterTests: XCTestCase {

    func testMakeBatchesThresholdSplitting() {
        // 创建 4 集，每集 6,000 字，总共 24,000 字。阈值 18,000 字下应分成 2 批 (3集 + 1集)
        let longText = String(repeating: "剧本正文片段。", count: 800) // ~5600 字符
        let episodes = [
            Episode(title: "第 1 集", text: longText),
            Episode(title: "第 2 集", text: longText),
            Episode(title: "第 3 集", text: longText),
            Episode(title: "第 4 集", text: longText)
        ]

        let batches = PipelineAIService.makeBatches(episodes: episodes, maxChars: 12000)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0], [0, 1])
        XCTAssertEqual(batches[1], [2, 3])
    }

    func testFirstEpisodeCalculation() {
        // 批次范围为第 3 到第 5 集
        let batch = 3...5

        // 情况 1: 首次发现，AI 汇报出场集号在范围内
        XCTAssertEqual(PipelineAIService.firstEpisode(existing: nil, reported: 4, batch: batch), 4)

        // 情况 2: 首次发现，AI 报告集号超出边界，截断在批次范围内
        XCTAssertEqual(PipelineAIService.firstEpisode(existing: nil, reported: 1, batch: batch), 3)
        XCTAssertEqual(PipelineAIService.firstEpisode(existing: nil, reported: 8, batch: batch), 5)

        // 情况 3: 已在更早集出现（如第 1 集），后来批次报告第 4 集，应保留更早的第 1 集
        XCTAssertEqual(PipelineAIService.firstEpisode(existing: 1, reported: 4, batch: batch), 1)

        // 情况 4: 之前记录为第 5 集，后来本批报告在第 3 集更早出场，修正为第 3 集
        XCTAssertEqual(PipelineAIService.firstEpisode(existing: 5, reported: 3, batch: batch), 3)
    }

    func testRosterContextFormatting() {
        let dictionary = [
            DictEntry(kind: "角色", name: "沈砚", desc: "", fromEp: 1),
            DictEntry(kind: "角色", name: "苏绾", desc: "", fromEp: 1),
            DictEntry(kind: "场景", name: "堂屋", desc: "", fromEp: 1),
            DictEntry(kind: "道具", name: "茶盏", desc: "", fromEp: 2)
        ]

        let context = PipelineAIService.rosterContext(for: dictionary)
        XCTAssertTrue(context.contains("- 角色：沈砚、苏绾"))
        XCTAssertTrue(context.contains("- 场景：堂屋"))
        XCTAssertTrue(context.contains("- 道具：茶盏"))

        let emptyContext = PipelineAIService.rosterContext(for: [])
        XCTAssertEqual(emptyContext, "（空）")
    }

    func testMergeRosterFromRawJSON() {
        var dict: [DictEntry] = [
            DictEntry(kind: "角色", name: "沈砚", desc: "", fromEp: 2)
        ]

        let aiResponse = """
        从文本中发现以下素材：
        ```json
        [
          {"kind": "角色", "name": "沈砚", "firstEp": 1},
          {"kind": "角色", "name": "苏绾", "firstEp": 1},
          {"kind": "场景", "name": "正堂", "firstEp": 1},
          {"kind": "道具", "name": "古剑", "firstEp": 2},
          {"kind": "未知类型", "name": "无效项", "firstEp": 1}
        ]
        ```
        """

        let ok = PipelineAIService.mergeRoster(raw: aiResponse, existing: &dict, defaultFirstEp: 1, lastEp: 2)
        XCTAssertTrue(ok)

        // 沈砚的首次出场集号应从 2 修正为 1
        let shen = dict.first { $0.name == "沈砚" }
        XCTAssertNotNil(shen)
        XCTAssertEqual(shen?.fromEp, 1)

        // 成功加入新条目
        XCTAssertTrue(dict.contains { $0.name == "苏绾" && $0.kind == "角色" })
        XCTAssertTrue(dict.contains { $0.name == "正堂" && $0.kind == "场景" })
        XCTAssertTrue(dict.contains { $0.name == "古剑" && $0.kind == "道具" })

        // 过滤非合规类型
        XCTAssertFalse(dict.contains { $0.name == "无效项" })
    }

    func testArchiveRosterLockingAndPersistence() throws {
        var archive = ProjectPipelineArchive(
            projectId: UUID(),
            wholeScript: "全剧正文...",
            loadedFileName: "短剧.txt",
            episodes: [
                Episode(title: "第 1 集", text: "正文1"),
                Episode(title: "第 2 集", text: "正文2")
            ],
            dictionary: [
                DictEntry(kind: "角色", name: "主角", desc: "", fromEp: 1),
                DictEntry(kind: "场景", name: "客栈", desc: "", fromEp: 1)
            ],
            rosterLocked: false,
            rosterBatchDone: 1,
            rosterBatchTotal: 1
        )

        XCTAssertFalse(archive.rosterLocked)
        XCTAssertEqual(archive.dictionary.count, 2)

        // 锁定清单
        archive.rosterLocked = true

        let data = try JSONEncoder().encode(archive)
        let loaded = try JSONDecoder().decode(ProjectPipelineArchive.self, from: data)
        try loaded.validate()

        XCTAssertTrue(loaded.rosterLocked)
        XCTAssertEqual(loaded.dictionary.count, 2)
        XCTAssertEqual(loaded.dictionary[0].name, "主角")
        XCTAssertEqual(loaded.dictionary[1].name, "客栈")
    }
}
