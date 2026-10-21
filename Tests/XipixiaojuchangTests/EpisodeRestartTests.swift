import XCTest
@testable import Xipixiaojuchang

/// 重启软件后，批量分割的结果（时长分割）和推理分镜建的卡要还在（2026-10-07 用户实测：重启后分割内容没了）。
/// 原因是存盘要把剧本存档换算成项目文件里的「集」，换算时只带了 id / 标题 / 原文，新加的字段全被丢掉。
/// 这里走的是真正的存盘 → 重新读盘。
@MainActor
final class EpisodeRestartTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xipi-restart-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func snapshot(episodes: [Episode], shots: [ShotDraft] = []) -> LegacySnapshot {
        LegacySnapshot(
            metas: ["P": ProjectMeta(name: "剧", createdAt: Date(), updatedAt: Date())],
            shots: shots,
            pipelines: ["P": ProjectPipelineArchive(wholeScript: "全文", episodes: episodes)])
    }

    /// 存一次、换一个全新的 ProjectStore 重新读（= 重启）
    private func restart(saving s: LegacySnapshot) -> LegacySnapshot {
        let first = ProjectStore(root: root)
        _ = first.loadAll()
        _ = first.save(s)
        let second = ProjectStore(root: root)
        return LegacyProjection.snapshot(from: second.loadAll(), projectsRoot: root)
    }

    func testSplitTextSurvivesARestartAndTheOriginalIsUntouched() throws {
        var e1 = Episode(title: "第1集", text: "原文一")
        e1.splitText = "场景：客厅\n△ 画面\n--- 00:00 - 00:30"
        let e2 = Episode(title: "第2集", text: "原文二")          // 没分割过
        let back = restart(saving: snapshot(episodes: [e1, e2]))
        let episodes = try XCTUnwrap(back.pipelines["P"]).episodes
        XCTAssertEqual(episodes.map(\.text), ["原文一", "原文二"])
        XCTAssertEqual(episodes.map(\.splitText), [e1.splitText, nil])
        XCTAssertEqual(episodes, [e1, e2])
    }

    func testStoryboardCardsStayLinkedToTheirEpisodeAfterARestart() throws {
        var e1 = Episode(title: "第1集", text: "原文一")
        let a = ShotDraft(projectKey: "P", prompt: "[客厅][甲][表]\n第一段", numbering: ShotNumbering(a: 1, b: 1))
        let b = ShotDraft(projectKey: "P", prompt: "[客厅][甲][表]\n第二段", numbering: ShotNumbering(a: 1, b: 2))
        e1.shotIDs = [a.id, b.id]
        let back = restart(saving: snapshot(episodes: [e1], shots: [a, b]))
        let archive = try XCTUnwrap(back.pipelines["P"])
        XCTAssertEqual(archive.episodes[0].shotIDs, [a.id, b.id])
        XCTAssertEqual(back.shots.map(\.id), [a.id, b.id], "卡片的 ID 重启后不变，所以链接还对得上")
        XCTAssertEqual(back.shots.map(\.numbering), [ShotNumbering(a: 1, b: 1), ShotNumbering(a: 1, b: 2)])
    }

    func testEditsAfterARestartKeepWorking() throws {
        var e1 = Episode(title: "第1集", text: "原文一")
        e1.splitText = "分割结果"
        let once = restart(saving: snapshot(episodes: [e1]))
        // 第二次存盘（改了标题）再重启，分割结果还在
        var archive = try XCTUnwrap(once.pipelines["P"])
        archive.episodes[0].title = "改过的标题"
        let twice = restart(saving: LegacySnapshot(metas: once.metas, pipelines: ["P": archive]))
        let episode = try XCTUnwrap(twice.pipelines["P"]).episodes[0]
        XCTAssertEqual(episode.title, "改过的标题")
        XCTAssertEqual(episode.splitText, "分割结果")
    }
}
