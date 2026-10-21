import XCTest
@testable import Xipixiaojuchang

/// 2026-10-12 逻辑审查的几处修补：
/// ① 分镜推理完再改分割、段落结构变了 → 旧卡和段对不上，不再按位置硬配；② 生视频页删了某一段的卡 → 单段重新推理能补一张；
/// ③ 有素材图却还没挂上的段（重新推理后）→ 生视频前提醒
@MainActor
final class StoryboardAlignmentTests: XCTestCase {
    private let split3 = "场景：客厅 日 内\n甲说话。\n--- 00:00 - 00:30\n乙说话。\n--- 00:30 - 01:00\n丙说话。\n--- 01:00 - 01:30"

    private func fixture(_ app: AppModel, signature: Bool = true) -> (key: String, shots: [ShotDraft]) {
        let key = "align-" + UUID().uuidString
        let shots = (1...3).map { i in ShotDraft(projectKey: key, prompt: "[客厅][人\(i)][ ]\n提示词\(i)。", numbering: ShotNumbering(a: 1, b: i)) }
        app.shots.append(contentsOf: shots)
        var episode = Episode(title: "第1集", text: "原文", splitText: split3)
        episode.shotIDs = shots.map(\.id)
        if signature { episode.storyboardSplitSignature = Episode.splitSignature(split3) }
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        return (key, shots)
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.shots.removeAll { $0.projectKey == key }
    }
    private func setSplit(_ app: AppModel, _ key: String, _ text: String) {
        var archive = app.pipelineArchive(for: key)!
        archive.episodes[0].splitText = text
        app.savePipelineArchive(archive, for: key)
    }

    func testChangingTheTextInsideSegmentsKeepsThePairing() {
        var episode = Episode(title: "第1集", text: "原文", splitText: split3)
        episode.shotIDs = [UUID(), UUID(), UUID()]
        episode.storyboardSplitSignature = Episode.splitSignature(split3)
        episode.splitText = split3.replacingOccurrences(of: "乙说话。", with: "乙大声说话。")
        XCTAssertFalse(episode.storyboardIsStale, "只改了段里的字：段落结构没变")
        XCTAssertEqual(episode.pairedShotIDs.count, 3)
    }

    func testMergingSegmentsAfterInferenceUnpairsTheOldCards() throws {
        let app = AppModel()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        setSplit(app, key, "场景：客厅 日 内\n甲说话。乙说话。\n--- 00:00 - 00:30\n丙说话。\n--- 00:30 - 01:00")      // 第 1、2 段合并了
        let episode = try XCTUnwrap(app.pipelineArchive(for: key)?.episodes.first)
        XCTAssertTrue(episode.storyboardIsStale)
        XCTAssertTrue(episode.pairedShotIDs.isEmpty, "不拿旧卡按位置硬配")
        let board = app.workbenchBoard(project: key, archive: try XCTUnwrap(app.pipelineArchive(for: key)))
        XCTAssertEqual(board.episodes[0].stage, .toInfer, "回到「待推理分镜」")
        XCTAssertTrue(board.episodes[0].detail.contains("分割改过"), board.episodes[0].detail)
        XCTAssertFalse(app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 1, chat: { _, _ in "" }),
                       "单段重新推理会写到错的卡上：不做，要整集重推")
    }

    func testOldDataWithoutASignatureStillPairsByPosition() throws {
        let app = AppModel()
        let (key, _) = fixture(app, signature: false)
        defer { cleanup(app, key) }
        setSplit(app, key, "甲。\n--- 00:00 - 00:30")
        XCTAssertEqual(app.pipelineArchive(for: key)?.episodes.first?.pairedShotIDs.count, 3, "老数据没记过结构：照旧")
    }

    func testReinferringAWholeEpisodeRecordsTheSplitItWasMadeFrom() async throws {
        let app = AppModel()
        let (key, _) = fixture(app, signature: false)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: { _, _ in
            "[客厅][甲][ ]\n一。\n[客厅][乙][ ]\n二。\n[客厅][丙][ ]\n三。"
        })
        await app.pipelineFlow.waitForAll(project: key)
        XCTAssertEqual(app.pipelineArchive(for: key)?.episodes.first?.storyboardSplitSignature, Episode.splitSignature(split3))
    }

    func testReinferringASegmentWhoseCardWasDeletedPutsANewCardInItsSlot() async throws {
        let app = AppModel()
        let (key, shots) = fixture(app)
        defer { cleanup(app, key) }
        app.deleteShot(id: shots[1].id)                                     // 在生视频页把第 2 段的卡删了
        let started = app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 2, chat: { _, _ in
            "[客厅][新人][ ]\n补回来的提示词。"
        })
        XCTAssertTrue(started, "缺卡也能重新推理")
        await app.pipelineFlow.waitForAll(project: key)
        let ids = try XCTUnwrap(app.pipelineArchive(for: key)?.episodes.first?.shotIDs)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], shots[0].id)
        XCTAssertEqual(ids[2], shots[2].id, "别的段不动")
        let created = try XCTUnwrap(app.shots.first { $0.id == ids[1] })
        XCTAssertNotEqual(created.id, shots[1].id)
        XCTAssertEqual(created.prompt, "[客厅][新人][ ]\n补回来的提示词。")
        XCTAssertEqual(created.numbering, ShotNumbering(a: 1, b: 2), "编号就是这一段：1-2")
    }

    func testSegmentsWithImagesButNoAttachedRefsAreCountedForTheVideoWarning() throws {
        let app = AppModel()
        let key = "unmatched-" + UUID().uuidString
        app.currentProjectKey = key
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unmatched-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p")
        card.results = [ImageGenResult(localPath: file.path, createdAt: Date())]; card.status = .success
        app.imageItems.append(card)
        let shot = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头")          // 重新推理过：没挂参考图
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲。\n"
        episode.shotIDs = [shot.id]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        defer { app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key }; app.removePipelineArchive(for: key) }
        let board = app.workbenchBoard(project: key, archive: try XCTUnwrap(app.pipelineArchive(for: key)))
        XCTAssertEqual(WorkbenchBatch.unmatchedCount(board: board, shotIDs: [shot.id]), 1, "有甲的图却没挂上")
    }
}
