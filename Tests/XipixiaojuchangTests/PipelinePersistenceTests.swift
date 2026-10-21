import XCTest
@testable import Xipixiaojuchang

final class PipelinePersistenceTests: XCTestCase {

    func testPipelineArchiveSaveLoadAndValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = ProjectPipelineArchive(
            projectId: UUID(),
            wholeScript: "第1集 掌柜登门\n掌柜推开木门走进厅堂。\n\n第2集 雨夜客至\n暴雨拍打窗棂。",
            loadedFileName: "测试短剧.txt",
            episodes: [
                Episode(title: "第 1 集", text: "掌柜推开木门走进厅堂。"),
                Episode(title: "第 2 集", text: "暴雨拍打窗棂。")
            ],
            dictionary: [
                DictEntry(kind: "角色", name: "齐掌柜", desc: "深灰长衫", fromEp: 1)
            ],
            works: [
                EpWork(),
                EpWork()
            ],
            rosterLocked: false,
            segmentSeconds: 30
        )

        XCTAssertNoThrow(try archive.validate())

        let fileURL = tempDir.appendingPathComponent("pipeline.json")
        let data = try JSONEncoder().encode(archive)
        try data.write(to: fileURL)

        let loadedData = try Data(contentsOf: fileURL)
        let loadedArchive = try JSONDecoder().decode(ProjectPipelineArchive.self, from: loadedData)

        XCTAssertEqual(loadedArchive.wholeScript, archive.wholeScript)
        XCTAssertEqual(loadedArchive.loadedFileName, archive.loadedFileName)
        XCTAssertEqual(loadedArchive.episodes.count, 2)
        XCTAssertEqual(loadedArchive.dictionary.first?.name, "齐掌柜")
        XCTAssertEqual(loadedArchive.segmentSeconds, 30)
    }

    func testProjectArchiveSampleJsonCompatibility() throws {
        let sampleURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/script-pipeline-sample/.verification/ui-preview/项目存档.json")
        guard FileManager.default.fileExists(atPath: sampleURL.path) else {
            return
        }

        let data = try Data(contentsOf: sampleURL)
        let archive = try JSONDecoder().decode(ProjectPipelineArchive.self, from: data)

        XCTAssertNoThrow(try archive.validate())
        XCTAssertFalse(archive.wholeScript.isEmpty)
        XCTAssertFalse(archive.dictionary.isEmpty)
        XCTAssertFalse(archive.episodes.isEmpty)
        XCTAssertEqual(archive.dictionary.first?.name, "齐掌柜")
    }

    func testScriptFileImporterLoadsPlainTextAndEncodings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // UTF-8 txt
        let utf8URL = tempDir.appendingPathComponent("utf8.txt")
        let testContent = "第1集 掌柜问话\n齐掌柜看着账本。"
        try testContent.write(to: utf8URL, atomically: true, encoding: .utf8)

        let result = try ScriptFileImporter.load(from: utf8URL)
        switch result {
        case .text(let content, let fileName):
            XCTAssertEqual(fileName, "utf8.txt")
            XCTAssertEqual(content, testContent)
        case .archive:
            XCTFail("应当解析为纯文本")
        }
    }

    func testPromptStoreLoadsBundledAndEmbeddedPrompts() {
        let promptNames = [
            "新4分镜10-2.txt",
            "提取场景+道具.txt",
            "提取场景.txt",
            "提取道具.txt",
            "提取角色.txt",
            "新30s分割.txt"
        ]

        for name in promptNames {
            let loaded = PipelinePromptStore.load(name)
            XCTAssertFalse(loaded.isEmpty, "提示词 \(name) 应当能加载且不为空")
        }

        let raw = "前置规则内容\n执行指令\n如果你理解了上述所有规则及格式要求，请回复准备就绪"
        let ready = PipelinePromptStore.apiReady(raw)
        XCTAssertTrue(ready.contains("【直接开始】"))
        XCTAssertFalse(ready.contains("如果你理解了上述所有规则"))
    }

    func testEpisodeSplitterSplitsMarkedScript() {
        let script = """
        第1集 序幕
        风雪呼啸，客栈门扉轻掩。

        第2集 破晓
        晨光透过窗棂洒在桌上。
        """

        let episodes = EpisodeSplitter.split(script)
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes[0].title.contains("第1集"))
        XCTAssertTrue(episodes[1].title.contains("第2集"))
    }

    @MainActor
    func testAppModelPipelinePersistenceIsolation() {
        let app = AppModel()
        let projA = "test-proj-A-" + UUID().uuidString
        let projB = "test-proj-B-" + UUID().uuidString

        let archiveA = ProjectPipelineArchive(
            projectId: UUID(),
            wholeScript: "项目A剧本正文",
            loadedFileName: "剧本A.txt"
        )
        let archiveB = ProjectPipelineArchive(
            projectId: UUID(),
            wholeScript: "项目B剧本正文",
            loadedFileName: "剧本B.txt"
        )

        defer {
            app.removePipelineArchive(for: projA)
            app.removePipelineArchive(for: projB)
        }

        app.savePipelineArchive(archiveA, for: projA)
        app.savePipelineArchive(archiveB, for: projB)

        let loadedA = app.pipelineArchive(for: projA)
        let loadedB = app.pipelineArchive(for: projB)

        XCTAssertEqual(loadedA?.wholeScript, "项目A剧本正文")
        XCTAssertEqual(loadedB?.wholeScript, "项目B剧本正文")

        app.removePipelineArchive(for: projA)
        XCTAssertNil(app.pipelineArchive(for: projA))
        XCTAssertNotNil(app.pipelineArchive(for: projB))
    }
}
