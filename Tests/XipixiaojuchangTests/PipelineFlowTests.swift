import XCTest
@testable import Xipixiaojuchang

private actor FlowRecorder {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
    func count() -> Int { values.count }
}

private actor FlowGate {
    private var continuation: CheckedContinuation<String, Never>?
    var started = false
    func reply() async -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}

@MainActor
final class PipelineFlowTests: XCTestCase {
    private func fixture(_ app: AppModel, texts: [String]) -> (String, Episode, ProjectPipelineArchive) {
        let key = "flow-test-" + UUID().uuidString
        let episode = Episode(title: "第1集", text: "未分割的旧原文")
        let work = SimpleEpisodeWork(id: episode.id, sourceKey: SimplePipeline.key(episode.text),
                                     segments: texts.map { SimplePipelineSegment(text: $0) })
        let archive = ProjectPipelineArchive(wholeScript: episode.text, episodes: [episode], simpleWorks: [work])
        app.savePipelineArchive(archive, for: key)
        return (key, episode, archive)
    }

    /// 2026-10-09 改：剧本里有「第 N 集」标题就在本地按标题切，不调用 AI（原来是一律交给 AI——贵、慢，还会丢掉标题行）
    func testMarkedScriptIsSplitLocallyWithoutAskingAI() async throws {
        let app = AppModel(), recorder = FlowRecorder()
        let key = "flow-test-" + UUID().uuidString
        defer { app.removePipelineArchive(for: key) }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "第1集\n场景：客厅 日 内\n原文一\n\n第2集\n场景：厨房 夜 内\n原文二"), for: key)
        app.pipelineFlow.splitScript(app: app, project: key, chat: { _, user in
            await recorder.add(user)
            return #"[{"title":"AI第一集","text":"AI分集内容"}]"#
        })
        await app.pipelineFlow.waitForJob(project: key, episode: nil)
        let count = await recorder.count()
        XCTAssertEqual(count, 0, "有标题就不该请求 AI")
        let archive = try XCTUnwrap(app.pipelineArchive(for: key))
        XCTAssertEqual(archive.episodes.map(\.title), ["第1集", "第2集"])
        XCTAssertEqual(archive.episodes[0].text, "第1集\n场景：客厅 日 内\n原文一", "标题行原样留在每集正文开头，集号随正文走")
        XCTAssertEqual(archive.episodes[1].text, "第2集\n场景：厨房 夜 内\n原文二")
        XCTAssertEqual(archive.works.count, 2)
        XCTAssertEqual(archive.splitStage, 2)
        XCTAssertFalse(app.pipelineFlow.active(project: key, episode: nil))
        XCTAssertNotEqual(app.pipelineFlow.jobs[PipelineFlow.key(key, nil)]?.failed, true, "本地分集不该失败")
    }

    func testScriptWithoutEpisodeHeadingsStillGoesThroughAI() async throws {
        let app = AppModel(), recorder = FlowRecorder()
        let key = "flow-test-" + UUID().uuidString
        defer { app.removePipelineArchive(for: key) }
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "没有集标题的剧本\n一段\n又一段"), for: key)
        app.pipelineFlow.splitScript(app: app, project: key, chat: { _, user in
            await recorder.add(user)
            return #"[{"title":"AI第一集","text":"AI分集内容"}]"#
        })
        await app.pipelineFlow.waitForJob(project: key, episode: nil)
        let count = await recorder.count()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(app.pipelineArchive(for: key)?.episodes.map(\.title), ["AI第一集"])
        XCTAssertFalse(app.pipelineFlow.active(project: key, episode: nil))
    }

    func testExtractionReadsEditedSegmentsInsteadOfWholeEpisode() async throws {
        let app = AppModel(), recorder = FlowRecorder()
        let (key, episode, _) = fixture(app, texts: ["新增的剧情段落", "已经修改的第二段"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.extract(app: app, project: key, episodeIndex: 0, chat: { _, user in
            XCTAssertTrue(user.contains("新增的剧情段落"))
            XCTAssertTrue(user.contains("已经修改的第二段"))
            XCTAssertFalse(user.contains("未分割的旧原文"))
            await recorder.add(user)
            return #"{"assets":[{"kind":"场景","name":"厨房","description":"木桌"}]}"#
        })
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        XCTAssertEqual(app.pipelineArchive(for: key)?.simpleWorks[0].assets.first?.name, "厨房")
        XCTAssertEqual(app.pipelineArchive(for: key)?.simpleWorks[0].segments.count, 2)
    }

    func testContinuationLooksAtNewScenesAndUsesPreviousEnding() async throws {
        let app = AppModel(), lookRecorder = FlowRecorder(), chatRecorder = FlowRecorder()
        let (key, episode, initial) = fixture(app, texts: ["场景：厨房\n甲入门", "场景：厨房\n甲走到桌边", "场景：院子\n乙走出", "场景：厨房\n甲回来"])
        defer { app.removePipelineArchive(for: key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scene-" + UUID().uuidString)
        try Data("mock image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = initial
        var work = archive.simpleWorks[0]
        let imageA = ImageGenItem(projectKey: key, type: .scene, name: "厨房", prompt: "")
        let imageB = ImageGenItem(projectKey: key, type: .scene, name: "院子", prompt: "")
        var a = imageA, b = imageB
        a.results = [ImageGenResult(localPath: file.path)]; b.results = [ImageGenResult(localPath: file.path)]
        app.imageItems.append(contentsOf: [a, b])
        defer { app.imageItems.removeAll { $0.id == a.id || $0.id == b.id } }
        work.assets = [SimplePipelineAsset(kind: "场景", name: "厨房", description: "木桌", imageItemID: a.id),
                       SimplePipelineAsset(kind: "场景", name: "院子", description: "院门", imageItemID: b.id)]
        archive.simpleWorks = [work]
        app.savePipelineArchive(archive, for: key)
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: 0, chat: { _, user in
            if user.contains("甲走到桌边") { XCTAssertTrue(user.contains("甲站在门右侧")) }
            await chatRecorder.add(user)
            return #"{"prompt":"完整30秒提示词","endPositions":"甲站在门右侧"}"#
        }, vision: { _, context in
            await lookRecorder.add(context)
            return "看图：甲在门左侧"
        })
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        let lookCount = await lookRecorder.count(), chatCount = await chatRecorder.count()
        XCTAssertEqual(lookCount, 3) // A起点、B起点、返回A，连续A只继承
        XCTAssertEqual(chatCount, 4)
        let result = try XCTUnwrap(app.pipelineArchive(for: key)?.simpleWorks[0])
        XCTAssertEqual(result.segments[1].initialPositions, result.segments[0].endPositions)
        XCTAssertEqual(result.segments[3].initialPositions, "看图：甲在门左侧")
        XCTAssertTrue(result.segments.allSatisfy { !$0.continuityKey.isEmpty })
    }

    func testMissingImageKeepsCompletedResultsAndResumes() async throws {
        let app = AppModel(), recorder = FlowRecorder()
        let (key, episode, initial) = fixture(app, texts: ["场景：厨房\n甲坐下", "场景：院子\n乙站起"])
        defer { app.removePipelineArchive(for: key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scene-" + UUID().uuidString)
        try Data("mock image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var a = ImageGenItem(projectKey: key, type: .scene, name: "厨房", prompt: "")
        var b = ImageGenItem(projectKey: key, type: .scene, name: "院子", prompt: "")
        a.results = [ImageGenResult(localPath: file.path)]
        app.imageItems.append(contentsOf: [a, b])
        defer { app.imageItems.removeAll { $0.id == a.id || $0.id == b.id } }
        var archive = initial
        archive.simpleWorks[0].assets = [SimplePipelineAsset(kind: "场景", name: "厨房", description: "木桌", imageItemID: a.id),
                                         SimplePipelineAsset(kind: "场景", name: "院子", description: "院门", imageItemID: b.id)]
        app.savePipelineArchive(archive, for: key)
        let chat: SimplePipeline.Chat = { _, user in
            await recorder.add(user)
            return #"{"prompt":"分镜","endPositions":"角色位于画面左边"}"#
        }
        let vision: PipelineContinuity.Vision = { _, _ in "看图站位" }
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: 0, chat: chat, vision: vision)
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        XCTAssertFalse(app.pipelineFlow.active(project: key, episode: episode.id))
        XCTAssertTrue(app.pipelineFlow.jobs[PipelineFlow.key(key, episode.id)]?.note.contains("缺少场景") == true)
        XCTAssertFalse(app.pipelineArchive(for: key)!.simpleWorks[0].segments[0].prompt.isEmpty)
        XCTAssertTrue(app.pipelineArchive(for: key)!.simpleWorks[0].segments[1].prompt.isEmpty)
        b.results = [ImageGenResult(localPath: file.path)]
        app.imageItems[app.imageItems.firstIndex(where: { $0.id == b.id })!] = b
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: 0, chat: chat, vision: vision)
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        let calls = await recorder.count()
        XCTAssertEqual(calls, 2) // 第一段没有重复调用
        XCTAssertTrue(app.pipelineArchive(for: key)!.simpleWorks[0].promptsComplete)
    }

    func testRemovingPromptKeepsPlotAndVideoLink() {
        let segment = SimplePipelineSegment(text: "剧情", prompt: "分镜", shotID: UUID())
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "source", segments: [segment])
        PipelineEditingRules.clearPrompt(segment.id, in: &work)
        XCTAssertEqual(work.segments[0].text, "剧情")
        XCTAssertEqual(work.segments[0].shotID, segment.shotID)
        XCTAssertTrue(work.segments[0].prompt.isEmpty)
        let newID = PipelineEditingRules.addSegment(to: &work)
        XCTAssertEqual(work.segments.count, 2)
        PipelineEditingRules.removeSegment(newID, from: &work)
        XCTAssertEqual(work.segments.count, 1)
    }

    func testStoppedRequestCannotOverwriteNewerResultsAndNavigationIsIndependent() async throws {
        let app = AppModel(), gate = FlowGate()
        let (key, episode, archive) = fixture(app, texts: ["当前剧情"])
        defer { app.removePipelineArchive(for: key) }
        app.pipelineFlow.extract(app: app, project: key, episodeIndex: 0, chat: { _, _ in await gate.reply() })
        while await !gate.started { await Task.yield() }
        XCTAssertTrue(app.pipelineFlow.active(project: key, episode: episode.id))
        XCTAssertTrue(app.pipelineFlow.glowing(.assets, project: key))
        XCTAssertFalse(app.pipelineFlow.active(project: "another-project", episode: episode.id))
        app.pipelineFlow.cancel(project: key, episode: episode.id)
        app.pipelineFlow.extract(app: app, project: key, episodeIndex: 0, chat: { _, _ in
            #"{"assets":[{"kind":"场景","name":"新回复","description":"新内容"}]}"#
        })
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        await gate.release(#"{"assets":[{"kind":"场景","name":"迟到的回复","description":"旧内容"}]}"#)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(app.pipelineArchive(for: key)?.simpleWorks[0].assets.first?.name, "新回复")
        XCTAssertEqual(app.pipelineArchive(for: key)?.episodes, archive.episodes)
        XCTAssertFalse(app.pipelineFlow.active(project: key, episode: episode.id))
    }

    func testOldSegmentsDecodeWithoutContinuityFields() throws {
        let id = UUID()
        let json = "{\"id\":\"\(id)\",\"text\":\"旧剧情\",\"prompt\":\"旧分镜\"}"
        let segment = try JSONDecoder().decode(SimplePipelineSegment.self, from: Data(json.utf8))
        XCTAssertEqual(segment.id, id)
        XCTAssertEqual(segment.prompt, "旧分镜")
        XCTAssertEqual(segment.initialPositions, "")
        XCTAssertEqual(segment.endPositions, "")
        XCTAssertEqual(segment.continuityKey, "")
    }

    func testSceneSequenceUsesPlotOrderNotNameLength() throws {
        let assets = [SimplePipelineAsset(kind: "场景", name: "厨房", description: ""),
                      SimplePipelineAsset(kind: "场景", name: "特别长的院子名字", description: "")]
        let segment = SimplePipelineSegment(text: "场景：厨房\n甲离开。\n场景：特别长的院子名字\n甲到达。")
        XCTAssertEqual(try PipelineContinuity.sceneSequence(for: segment, assets: assets).map(\.name), ["厨房", "特别长的院子名字"])
    }

    func testInputKeyOnlyCoversUsedAssets() {
        let segment = SimplePipelineSegment(text: "厨房里，甲做饭", assetNames: ["甲"])
        let used = SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣")
        var unused = SimplePipelineAsset(kind: "道具", name: "钥匙", description: "铜钥匙")
        let before = PipelineContinuity.inputKey(segment: segment, assets: [used, unused], previous: nil)
        unused.description = "银钥匙"
        let afterUnusedChanged = PipelineContinuity.inputKey(segment: segment, assets: [used, unused], previous: nil)
        XCTAssertEqual(before, afterUnusedChanged, "其它素材变化不应让本段失效")
        var usedChanged = used
        usedChanged.description = "蓝衣"
        let afterUsedChanged = PipelineContinuity.inputKey(segment: segment, assets: [usedChanged, unused], previous: nil)
        XCTAssertNotEqual(before, afterUsedChanged, "本段用到的素材变化应让本段失效")
    }

    func testReinferOnlyRunsSelectedSegment() async throws {
        let app = AppModel(), chatRecorder = FlowRecorder(), lookRecorder = FlowRecorder()
        let (key, episode, initial) = fixture(app, texts: ["场景：厨房\n甲入门", "场景：厨房\n甲走到桌边"])
        defer { app.removePipelineArchive(for: key) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scene-" + UUID().uuidString)
        try Data("mock image".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var archive = initial
        var work = archive.simpleWorks[0]
        var image = ImageGenItem(projectKey: key, type: .scene, name: "厨房", prompt: "")
        image.results = [ImageGenResult(localPath: file.path)]
        app.imageItems.append(image)
        defer { app.imageItems.removeAll { $0.id == image.id } }
        work.assets = [SimplePipelineAsset(kind: "场景", name: "厨房", description: "木桌", imageItemID: image.id)]
        archive.simpleWorks = [work]
        app.savePipelineArchive(archive, for: key)
        let chat: SimplePipeline.Chat = { _, _ in
            await chatRecorder.add("chat")
            return #"{"prompt":"完整提示词","endPositions":"段末站位"}"#
        }
        let vision: PipelineContinuity.Vision = { _, _ in
            await lookRecorder.add("look")
            return "看图站位"
        }
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: 0, chat: chat, vision: vision)
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        let batchChats = await chatRecorder.count(), batchLooks = await lookRecorder.count()
        XCTAssertEqual(batchChats, 2)
        XCTAssertEqual(batchLooks, 1) // 第一段看图；第二段同场景继承
        // 单独重推第 2 段：只跑这一段；首场景承接上一段末站位，不再看图。
        app.pipelineFlow.infer(app: app, project: key, episodeIndex: 0, only: 1, chat: chat, vision: vision)
        await app.pipelineFlow.waitForJob(project: key, episode: episode.id)
        let singleChats = await chatRecorder.count()
        let singleLooks = await lookRecorder.count()
        XCTAssertEqual(singleChats, batchChats + 1)
        XCTAssertEqual(singleLooks, batchLooks)
        let result = try XCTUnwrap(app.pipelineArchive(for: key)?.simpleWorks[0])
        XCTAssertEqual(result.segments[1].prompt, "完整提示词")
        XCTAssertEqual(result.segments[1].endPositions, "段末站位")
    }

    func testRemoveSegmentOnlyInvalidatesFromDeletionPoint() {
        var work = SimpleEpisodeWork(id: UUID(), sourceKey: "s", segments: [
            SimplePipelineSegment(text: "A"), SimplePipelineSegment(text: "B"), SimplePipelineSegment(text: "C"),
        ])
        work.segments[0].continuityKey = "k0"
        work.segments[1].continuityKey = "k1"
        work.segments[2].continuityKey = "k2"
        PipelineEditingRules.removeSegment(work.segments[1].id, from: &work)
        XCTAssertEqual(work.segments.count, 2)
        XCTAssertEqual(work.segments[0].continuityKey, "k0", "删除点之前的段落不应失效")
        XCTAssertEqual(work.segments[1].continuityKey, "", "删除点及其后的段落应重建承接")
    }
}
