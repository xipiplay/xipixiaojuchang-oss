import XCTest
@testable import Xipixiaojuchang

/// 制作页的写操作（2026-10-07 P3-2 第 1 步）：改提示词 / 选版本 / 提交视频，做法和旧「推理分镜」页保持一致。
@MainActor
final class WorkbenchActionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func video(_ id: String, _ phase: TaskPhase, prompt: String) -> VideoVersion {
        VideoVersion(id: UUID(), taskID: id, createdAt: t0, phase: phase, prompt: prompt, params: .legacyDefault)
    }

    /// 一个有剧本段 + 自由分镜的项目（项目里没配视频模型，所以提交只会走到校验那一步，不会发网络请求）
    private struct Fixture {
        let app: AppModel
        let key: String
        let episode: Episode
        let freeShot: ShotDraft
        let linkedShot: ShotDraft
    }

    private func fixture() -> Fixture {
        let app = AppModel()
        let key = "wb-actions-" + UUID().uuidString
        let ep = Episode(title: "第1集", text: "甲出场")
        let linked = ShotDraft(projectKey: key, prompt: "卡上的旧提示词", numbering: ShotNumbering(a: 1, b: 1))
        let free = ShotDraft(projectKey: key, prompt: "自由分镜", taskIDs: ["t1", "t2"], numbering: ShotNumbering(a: 2, b: 1))
        var work = SimpleEpisodeWork(id: ep.id, sourceKey: SimplePipeline.key(ep.text))
        work.assets = [SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣")]
        work.assetsExtracted = true
        var seg = SimplePipelineSegment(text: "甲出场", assetNames: ["甲"], prompt: "段上的旧提示词", shotID: linked.id)
        seg.continuityKey = "旧指纹"
        work.segments = [seg]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [ep], simpleWorks: [work]), for: key)
        app.shots = [linked, free]
        return Fixture(app: app, key: key, episode: ep, freeShot: free, linkedShot: linked)
    }

    private func doc(_ f: Fixture) throws -> ProjectDocument { try XCTUnwrap(f.app.workbenchDocument(for: f.key)) }

    // MARK: 规则

    func testPromptChangedIgnoresFailedAttemptsAndWhitespace() {
        var s = SegmentRecord(id: UUID(), params: .legacyDefault)
        s.prompt = "新提示词"
        XCTAssertFalse(WorkbenchRules.promptChangedSinceLastVideo(s), "没有视频：谈不上「改过」")
        s.videos = [video("a", .completed, prompt: "旧提示词")]
        XCTAssertTrue(WorkbenchRules.promptChangedSinceLastVideo(s))
        s.videos = [video("a", .completed, prompt: "  新提示词\n")]
        XCTAssertFalse(WorkbenchRules.promptChangedSinceLastVideo(s), "首尾空白不算改")
        s.videos = [video("a", .completed, prompt: "新提示词"), video("b", .failed, prompt: "别的")]
        XCTAssertFalse(WorkbenchRules.promptChangedSinceLastVideo(s), "失败的那次没出片，不参与比较")
        s.prompt = "  "
        XCTAssertFalse(WorkbenchRules.promptChangedSinceLastVideo(s))
    }

    // MARK: 准备分镜卡（纯函数）

    func testPreparedShotCreatesNumberedShotFromParams() {
        var params = VideoParams.legacyDefault
        params.model = "视频模型"; params.duration = 20; params.aspectRatio = .ratio9x16; params.resolution = .p1080
        let shot = WorkbenchActions.preparedShot(
            existing: nil, projectKey: "P", episodeNumber: 3, segmentNumber: 2, prompt: "提示词", params: params,
            generateAudio: false, watermark: true)
        XCTAssertEqual(shot.numbering, ShotNumbering(a: 3, b: 2))
        XCTAssertEqual(shot.projectKey, "P")
        XCTAssertEqual(shot.prompt, "提示词")
        XCTAssertEqual([shot.model, shot.duration.description, shot.aspectRatio.rawValue, shot.resolution.rawValue],
                       ["视频模型", "20", "9:16", "p1080"])
        XCTAssertFalse(shot.generateAudio)
        XCTAssertTrue(shot.watermark)
        XCTAssertTrue(shot.imageRefs.isEmpty, "素材引用不在这里挂（和提示词里的「图N」一起，由 WorkbenchMatching 负责）")
    }

    func testPreparedShotKeepsExistingCardAndItsRefs() {
        let lib = UUID()
        var existing = ShotDraft(projectKey: "P", prompt: "旧", generateAudio: false, watermark: true,
                                 imageRefs: [MaterialRef(libraryItemID: lib, role: .firstFrame)],
                                 audioRefs: [MaterialRef(libraryItemID: UUID())], taskIDs: ["t1"],
                                 numbering: ShotNumbering(a: 1, b: 1))
        existing.taskID = "t1"
        var params = VideoParams.legacyDefault
        params.model = "m2"
        let shot = WorkbenchActions.preparedShot(
            existing: existing, projectKey: "P", episodeNumber: 9, segmentNumber: 9, prompt: "新", params: params,
            generateAudio: true, watermark: false)
        XCTAssertEqual(shot.id, existing.id)
        XCTAssertEqual(shot.numbering, ShotNumbering(a: 1, b: 1), "已有卡的编号不变")
        XCTAssertEqual(shot.prompt, "新")
        XCTAssertEqual(shot.model, "m2")
        XCTAssertEqual(shot.imageRefs.count, 1)
        XCTAssertEqual(shot.imageRefs[0].role, .firstFrame, "已有引用的角色不被改")
        XCTAssertEqual(shot.audioRefs.count, 1)
        XCTAssertEqual(shot.taskIDs, ["t1"])
        XCTAssertFalse(shot.generateAudio, "已有卡的音频 / 水印开关不被默认值覆盖")
        XCTAssertTrue(shot.watermark)
    }

    // MARK: 改提示词

    func testSavePromptOnScriptSegmentUpdatesArchiveSegmentAndShotAndClearsContinuity() throws {
        let f = fixture()
        let d = try doc(f)
        let ep = try XCTUnwrap(d.episodes.first { !$0.isFree })
        try WorkbenchActions.savePrompt("改过的提示词", segment: ep.segments[0], episode: ep, app: f.app)

        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let seg = SimplePipeline.work(in: archive, index: 0).segments[0]
        XCTAssertEqual(seg.prompt, "改过的提示词")
        XCTAssertEqual(seg.continuityKey, "", "站位承接的指纹清掉，下次推理重算")
        XCTAssertEqual(seg.shotID, f.linkedShot.id)
        XCTAssertEqual(f.app.shots.first { $0.id == f.linkedShot.id }?.prompt, "改过的提示词")

        // 页面重新换算后看到的就是新提示词
        let after = try doc(f)
        XCTAssertEqual(after.episodes.first { !$0.isFree }?.segments[0].prompt, "改过的提示词")
    }

    func testSavePromptOnFreeSegmentOnlyTouchesTheShot() throws {
        let f = fixture()
        let d = try doc(f)
        let free = try XCTUnwrap(d.episodes.first { $0.isFree })
        let segment = try XCTUnwrap(free.segments.first { $0.legacy?.shotID == f.freeShot.id })
        try WorkbenchActions.savePrompt("自由分镜改过", segment: segment, episode: free, app: f.app)
        XCTAssertEqual(f.app.shots.first { $0.id == f.freeShot.id }?.prompt, "自由分镜改过")
        XCTAssertEqual(SimplePipeline.work(in: try XCTUnwrap(f.app.pipelineArchive(for: f.key)), index: 0).segments[0].prompt,
                       "段上的旧提示词", "自由集的修改不碰剧本存档")
    }

    func testSavePromptRejectsEmptyText() throws {
        let f = fixture()
        let ep = try XCTUnwrap(try doc(f).episodes.first { !$0.isFree })
        XCTAssertThrowsError(try WorkbenchActions.savePrompt("  \n ", segment: ep.segments[0], episode: ep, app: f.app))
        XCTAssertEqual(f.app.shots.first { $0.id == f.linkedShot.id }?.prompt, "卡上的旧提示词", "被拒绝就什么都不改")
    }

    // MARK: 选版本

    func testSelectVersionPointsTheShotAtThatTaskWithoutTouchingPrompt() throws {
        let f = fixture()
        let free = try XCTUnwrap(try doc(f).episodes.first { $0.isFree })
        let segment = try XCTUnwrap(free.segments.first { $0.legacy?.shotID == f.freeShot.id })
        WorkbenchActions.selectVersion(taskID: "t1", segment: segment, app: f.app)
        let shot = try XCTUnwrap(f.app.shots.first { $0.id == f.freeShot.id })
        XCTAssertEqual(shot.taskID, "t1")
        XCTAssertEqual(shot.taskIDs, ["t1", "t2"], "版本顺序不变")
        XCTAssertEqual(shot.prompt, "自由分镜")
        // 没有分镜卡的段（还没提交过）：什么都不发生
        WorkbenchActions.selectVersion(taskID: "t1", segment: SegmentRecord(id: UUID(), params: .legacyDefault), app: f.app)
    }

    // MARK: 提交校验

    func testSubmitReportsProblemsBeforeAnythingIsWritten() throws {
        let f = fixture()
        let ep = try XCTUnwrap(try doc(f).episodes.first { !$0.isFree })
        let shotCount = f.app.shots.count
        var params = VideoParams.legacyDefault
        params.model = "没配置的模型"
        XCTAssertThrowsError(try WorkbenchActions.submit(segment: ep.segments[0], episode: ep, params: params, app: f.app)) {
            XCTAssertTrue($0.localizedDescription.contains("模型"))
        }
        var noPrompt = ep.segments[0]
        noPrompt.prompt = ""
        XCTAssertThrowsError(try WorkbenchActions.submit(segment: noPrompt, episode: ep, params: params, app: f.app)) {
            XCTAssertTrue($0.localizedDescription.contains("提示词"))
        }
        XCTAssertEqual(f.app.shots.count, shotCount)
        XCTAssertTrue(f.app.store.tasks.isEmpty, "校验没过不会产生任务")
    }
}
