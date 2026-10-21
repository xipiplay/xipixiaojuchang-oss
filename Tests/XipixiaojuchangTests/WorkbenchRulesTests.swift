import XCTest
@testable import Xipixiaojuchang

/// 制作页的显示规则（2026-10-07 P3-1）。
final class WorkbenchRulesTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func segment(prompt: String = "", names: [String] = [], settings: [UUID] = [],
                         videos: [VideoVersion] = []) -> SegmentRecord {
        var s = SegmentRecord(id: UUID(), text: "原文", params: .legacyDefault)
        s.prompt = prompt
        s.unresolvedNames = names
        s.settingIDs = settings
        s.videos = videos
        return s
    }

    private func video(_ id: String, _ phase: TaskPhase) -> VideoVersion {
        VideoVersion(id: UUID(), taskID: id, createdAt: t0, phase: phase, prompt: "p", params: .legacyDefault)
    }

    private func setting(_ name: String, withImage: Bool) -> SettingRecord {
        var s = SettingRecord(id: UUID(), kind: .character, name: name)
        if withImage { s.versions = [MediaVersion(id: UUID(), file: "images/a.png", createdAt: t0)] }
        return s
    }

    private func doc(_ episodes: [EpisodeRecord], settings: [SettingRecord] = []) -> ProjectDocument {
        ProjectDocument(id: "P", name: "项目", createdAt: t0, updatedAt: t0, episodes: episodes, settings: settings)
    }

    // MARK: 段

    func testVideoStateFollowsLatestSubmissionButKeepsEarlierSuccessVisible() {
        XCTAssertEqual(WorkbenchRules.videoState(segment()), .none)
        XCTAssertEqual(WorkbenchRules.videoState(segment(videos: [video("a", .completed)])), .done)
        XCTAssertEqual(WorkbenchRules.videoState(segment(videos: [video("a", .completed), video("b", .inProgress)])), .running)
        XCTAssertEqual(WorkbenchRules.videoState(segment(videos: [video("a", .completed), video("b", .queued)])), .running)
        XCTAssertEqual(WorkbenchRules.videoState(segment(videos: [video("a", .completed), video("b", .failed)])), .failed)
        XCTAssertEqual(WorkbenchRules.videoState(segment(videos: [video("a", .paused)])), .paused)
        let s = segment(videos: [video("a", .completed), video("b", .failed)])
        XCTAssertEqual(WorkbenchRules.displayedVideo(s)?.taskID, "a", "最新失败了，缩略图仍显示成功的那一版")
    }

    func testSelectedVideoWinsOverLatest() {
        var s = segment(videos: [video("a", .completed), video("b", .completed)])
        s.selectedVideoTaskID = "a"
        XCTAssertEqual(WorkbenchRules.displayedVideo(s)?.taskID, "a")
    }

    func testTitlesAndTimecodes() {
        var free = segment()
        free.numbering = ShotNumbering(a: 3, b: 2)
        XCTAssertEqual(WorkbenchRules.segmentTitle(free, index: 0, isFree: true), "分镜 3-2")
        XCTAssertEqual(WorkbenchRules.segmentTitle(segment(), index: 3, isFree: false), "第 4 段")
        XCTAssertEqual(WorkbenchRules.timecode(index: 0, segmentSeconds: 30), "00:00–00:30")
        XCTAssertEqual(WorkbenchRules.timecode(index: 3, segmentSeconds: 30), "01:30–02:00")
    }

    func testPromptExcerptSkipsTheReferenceTagLine() {
        XCTAssertEqual(WorkbenchRules.promptExcerpt("[图1门口][图2母亲]\n【站位】母亲在左\n\n镜头1：近景"),
                       "【站位】母亲在左 镜头1：近景")
        XCTAssertEqual(WorkbenchRules.promptExcerpt("[只有一行]"), "[只有一行]")
        XCTAssertEqual(WorkbenchRules.promptExcerpt("没有标签行\n第二行"), "没有标签行 第二行")
    }

    /// 卡顿排查（2026-10-07）：段落表一格的文字必须在交给 Text 之前截短，长度有硬上限
    func testExcerptsAreAlwaysShort() {
        let long = "[图1门口]\n" + String(repeating: "很长的一段提示词。", count: 600)
        let excerpt = WorkbenchRules.promptExcerpt(long)
        XCTAssertLessThanOrEqual(excerpt.count, WorkbenchRules.excerptLimit + 1)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.contains("[图1门口]"))
        let text = WorkbenchRules.textExcerpt(String(repeating: "原文。\n", count: 2000))
        XCTAssertLessThanOrEqual(text.count, WorkbenchRules.textExcerptLimit + 1)
        XCTAssertEqual(WorkbenchRules.textExcerpt("短原文"), "短原文", "不超长的原样返回")
        XCTAssertEqual(WorkbenchRules.promptExcerpt(""), "")
    }

    // MARK: 集

    func testProgressCountsPromptsVideosNamesAndMissingImages() {
        let withImage = setting("甲", withImage: true), without = setting("乙", withImage: false)
        var episode = EpisodeRecord(id: UUID(), title: "第1集")
        episode.settingIDs = [withImage.id, without.id]
        episode.segments = [
            segment(prompt: "有", names: ["蒸蛋"], settings: [withImage.id], videos: [video("a", .completed)]),
            segment(prompt: "有", names: ["蒸蛋", "围裙"], settings: [without.id], videos: [video("b", .inProgress)]),
            segment(prompt: "  ", videos: [video("c", .failed)]),
            segment(),
        ]
        let p = WorkbenchRules.progress(of: episode, in: doc([episode], settings: [withImage, without]))
        XCTAssertEqual(p, EpisodeProgress(segments: 4, promptsReady: 2, videosDone: 1, videosRunning: 1, videosFailed: 1,
                                          unresolvedNames: 2, settingsWithoutImage: 1))
        XCTAssertEqual(WorkbenchRules.summaryLine(p, textLength: 100, isFree: false), "4 段 · 视频 1/4 · 生成中 1 · 失败 1")
        let names = WorkbenchRules.unresolvedNames(in: episode)
        XCTAssertEqual(names.map(\.name), ["蒸蛋", "围裙"])
        XCTAssertEqual(names[0].segments, [1, 2])
    }

    func testSummaryLineBeforeSegmenting() {
        XCTAssertEqual(WorkbenchRules.summaryLine(EpisodeProgress(), textLength: 872, isFree: false), "872 字 · 待分段")
        XCTAssertEqual(WorkbenchRules.summaryLine(EpisodeProgress(), textLength: 0, isFree: true), "还没有分镜")
    }

    func testStepsMarkTheFirstUnfinishedStepAsCurrent() {
        let img = setting("甲", withImage: true)
        var episode = EpisodeRecord(id: UUID(), title: "第1集")
        func states() -> [EpisodeStep.State] { WorkbenchRules.steps(of: episode, in: doc([episode], settings: [img])).map(\.state) }

        XCTAssertEqual(states(), [.current, .todo, .todo, .todo, .todo, .todo, .todo])

        episode.segments = [segment(settings: [img.id])]
        XCTAssertEqual(states(), [.done, .current, .todo, .todo, .todo, .todo, .todo])

        episode.assetsExtracted = true
        episode.settingIDs = [img.id]
        XCTAssertEqual(states(), [.done, .done, .done, .done, .current, .todo, .todo])

        episode.segments[0].prompt = "提示词"
        XCTAssertEqual(states(), [.done, .done, .done, .done, .done, .current, .todo], "有提示词但还没把图对上：当前是匹配素材")

        episode.segments[0].references = [MediaReference(id: UUID(), settingID: img.id, media: .image, role: .referenceImage, legacyLibraryItemID: nil)]
        XCTAssertEqual(states(), [.done, .done, .done, .done, .done, .done, .current])

        episode.segments[0].references = []
        episode.segments[0].videos = [video("a", .completed)]
        XCTAssertEqual(states(), Array(repeating: .done, count: 7), "已经出过视频的段不再要求匹配")
        XCTAssertEqual(WorkbenchRules.steps(of: episode, in: doc([episode])).filter(\.isGate).map(\.title), ["挑定妆图", "提交视频"])
    }

    func testStepsWaitAtImagingWhileASettingHasNoImage() {
        let without = setting("乙", withImage: false)
        var episode = EpisodeRecord(id: UUID(), title: "第1集")
        episode.assetsExtracted = true
        episode.settingIDs = [without.id]
        episode.segments = [segment(settings: [without.id])]
        let steps = WorkbenchRules.steps(of: episode, in: doc([episode], settings: [without]))
        XCTAssertEqual(steps.first { $0.title == "出图" }?.state, .current)
    }

    // MARK: 选中

    func testDefaultSelectionKeepsPreferredAndFallsBack() {
        let empty = EpisodeRecord(id: UUID(), title: "第1集")
        var full = EpisodeRecord(id: UUID(), title: "第2集")
        full.segments = [segment(), segment()]
        var free = EpisodeRecord(id: UUID(), title: "自由集")
        free.isFree = true
        let d = doc([empty, full, free])
        XCTAssertEqual(WorkbenchRules.defaultEpisodeID(in: d, preferred: nil), full.id, "第一个有段的剧本集")
        XCTAssertEqual(WorkbenchRules.defaultEpisodeID(in: d, preferred: free.id), free.id)
        XCTAssertEqual(WorkbenchRules.defaultEpisodeID(in: d, preferred: UUID()), full.id, "选中的集没了")
        XCTAssertEqual(WorkbenchRules.defaultEpisodeID(in: doc([empty]), preferred: nil), empty.id)
        XCTAssertNil(WorkbenchRules.defaultEpisodeID(in: doc([]), preferred: nil))
        XCTAssertEqual(WorkbenchRules.defaultSegmentID(in: full, preferred: full.segments[1].id), full.segments[1].id)
        XCTAssertEqual(WorkbenchRules.defaultSegmentID(in: full, preferred: UUID()), full.segments[0].id)
    }

    // MARK: 从旧数据换算

    @MainActor
    func testWorkbenchDocumentIsDerivedFromLegacyArraysForOneProject() throws {
        let app = AppModel()
        let key = "wb-test-" + UUID().uuidString
        let other = "wb-other-" + UUID().uuidString
        let ep = Episode(title: "第1集", text: "甲出场")
        var work = SimpleEpisodeWork(id: ep.id, sourceKey: SimplePipeline.key(ep.text))
        work.assets = [SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣")]
        work.assetsExtracted = true
        work.segments = [SimplePipelineSegment(text: "甲出场", assetNames: ["甲", "蒸蛋"], prompt: "镜头")]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [ep], simpleWorks: [work]), for: key)
        app.shots = [ShotDraft(projectKey: key, prompt: "自由分镜", numbering: ShotNumbering(a: 1, b: 1)),
                     ShotDraft(projectKey: other, prompt: "别的项目")]

        let doc = try XCTUnwrap(app.workbenchDocument(for: key))
        XCTAssertEqual(doc.episodes.map(\.title), ["第1集", "自由集"])
        XCTAssertEqual(doc.episodes[0].segments[0].unresolvedNames, ["蒸蛋"])
        XCTAssertEqual(doc.episodes[0].segments[0].settingIDs.count, 1)
        XCTAssertEqual(doc.episodes[1].segments.map(\.prompt), ["自由分镜"], "只带本项目的分镜")
        XCTAssertNil(app.workbenchDocument(for: ""))
    }

    @MainActor
    func testDataRevisionIncreasesWhenProjectDataChanges() {
        let app = AppModel()
        let before = app.dataRevision
        app.persistShots()
        XCTAssertGreaterThan(app.dataRevision, before)
    }
}
