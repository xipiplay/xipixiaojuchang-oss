import XCTest
@testable import Xipixiaojuchang

/// 匹配素材按分镜的集号选「第N集的」版本（2026-10-09）：头行里写的是不带前缀的名字
@MainActor
final class AutoMatchVersionTests: XCTestCase {
    // SwiftUI 里也有个 `LibraryItem`（Xcode 库用的），不写模块名会有歧义
    private typealias Item = Xipixiaojuchang.LibraryItem
    private let head = "[老城区客厅][沈惊澜][怀表]\n【角色初始站位与朝向】沈惊澜站在窗边。"

    private func setup(_ app: AppModel, episode: Int?, library names: [String]) -> (shot: ShotDraft, items: [Item], key: String) {
        let key = "match-version-" + UUID().uuidString
        let items = names.map { Item(kind: .image, localPath: nil, fileName: nil, name: $0, projectKey: key) }
        let shot = ShotDraft(projectKey: key, prompt: head, numbering: episode.map { ShotNumbering(a: $0, b: 1) })
        app.shots.append(shot)
        return (shot, items, key)
    }
    private func cleanup(_ app: AppModel, _ shot: ShotDraft) { app.shots.removeAll { $0.id == shot.id } }
    private func run(_ app: AppModel, _ shot: ShotDraft, _ items: [Item]) -> (matched: Int, refs: [UUID], prompt: String) {
        let count = app.autoMatchMaterials(shot.id, candidates: items, detectsDuration: false)
        let updated = app.shots.first { $0.id == shot.id }
        return (count, updated?.imageRefs.map(\.libraryItemID) ?? [], updated?.prompt ?? "")
    }

    func testPrefixedLibraryItemsMatchPlainNamesInTheHeadLine() {
        let app = AppModel()
        let (shot, items, _) = setup(app, episode: 1, library: ["角色-第1集的沈惊澜", "场景-第1集的老城区客厅", "道具-第1集的怀表"])
        defer { cleanup(app, shot) }
        let result = run(app, shot, items)
        XCTAssertEqual(result.matched, 3, "头行里是「沈惊澜」，库里是「第1集的沈惊澜」：以前一张都匹配不上")
        XCTAssertEqual(result.refs.count, 3)
        XCTAssertTrue(result.prompt.hasPrefix("[图1老城区客厅][图2沈惊澜][图3怀表]"), result.prompt)
    }

    func testTheVersionFollowsTheShotsEpisode() {
        let app = AppModel()
        let names = ["角色-第1集的沈惊澜", "角色-第8集的沈惊澜", "角色-第20集的沈惊澜"]
        for (episode, expected) in [(1, 0), (7, 0), (8, 1), (19, 1), (20, 2), (60, 2)] {
            let (shot, items, _) = setup(app, episode: episode, library: names)
            defer { cleanup(app, shot) }
            let result = run(app, shot, items)
            XCTAssertEqual(result.refs, [items[expected].id], "第 \(episode) 集该用 \(names[expected])")
            XCTAssertEqual(result.matched, 1, "同一个人的多个版本只挂一张")
        }
    }

    func testAnEarlyShotIsNotMatchedToAVariantThatOnlyAppearsMuchLater() {
        // 用户的真实情况：第一次出现的卡叫「周承山四十岁时期」，基础名恰好是「周承山」的只有后面集的变化版
        let app = AppModel()
        let names = ["角色-第24集的沈惊澜", "角色-第30集的沈惊澜", "角色-第45集的沈惊澜"]
        for (episode, expected) in [(2, nil), (23, nil), (24, 0), (29, 0), (30, 1), (60, 2)] as [(Int, Int?)] {
            let (shot, items, _) = setup(app, episode: episode, library: names)
            defer { cleanup(app, shot) }
            let result = run(app, shot, items)
            XCTAssertEqual(result.refs, expected.map { [items[$0].id] } ?? [], "第 \(episode) 集")
            if expected == nil { XCTAssertEqual(result.prompt, head, "不匹配时提示词原样不动") }
        }
    }

    func testAShotWithoutAnEpisodeUsesTheEarliestVersion() {
        let app = AppModel()
        let (shot, items, _) = setup(app, episode: nil, library: ["角色-第8集的沈惊澜", "角色-第1集的沈惊澜"])
        defer { cleanup(app, shot) }
        XCTAssertEqual(run(app, shot, items).refs, [items[1].id])
    }

    func testUnprefixedItemsKeepTheirOldBehaviourAndActAsTheBaseVersion() {
        let app = AppModel()
        // 没有前缀的（手动建的 / 旧格式）全程有效：第 3 集用它；第 9 集有更晚的版本就用「第8集的」
        for (episode, expected) in [(3, 0), (9, 1)] {
            let (shot, items, _) = setup(app, episode: episode, library: ["角色-沈惊澜", "角色-第8集的沈惊澜"])
            defer { cleanup(app, shot) }
            XCTAssertEqual(run(app, shot, items).refs, [items[expected].id], "第 \(episode) 集")
        }
        // 同名多次入库（「角色-沈惊澜 / -1」）：和原来一样取库里靠前的
        let (shot, items, _) = setup(app, episode: 5, library: ["角色-沈惊澜", "角色-沈惊澜-1"])
        defer { cleanup(app, shot) }
        XCTAssertEqual(run(app, shot, items).refs, [items[0].id])
    }

    func testAnAlreadyAttachedVersionBlocksTheOtherVersionsOfTheSamePerson() {
        let app = AppModel()
        let (shot, items, _) = setup(app, episode: 9, library: ["角色-第1集的沈惊澜", "角色-第8集的沈惊澜"])
        defer { cleanup(app, shot) }
        // 已挂的素材要在本项目素材库里才查得到它的名字（真实使用时一定在）
        app.currentProjectKey = shot.projectKey
        app.library = items
        defer { app.library = []; app.currentProjectKey = nil }
        let idx = app.shots.firstIndex { $0.id == shot.id }!
        app.shots[idx].imageRefs = [MaterialRef(libraryItemID: items[0].id, role: .referenceImage)]
        app.shots[idx].prompt = "[老城区客厅][图1沈惊澜][怀表]"
        let result = run(app, shot, items)
        XCTAssertEqual(result.matched, 0, "已经挂了这个人的一个版本，重复点匹配不再加第二个版本")
        XCTAssertEqual(result.refs, [items[0].id])
    }

    func testDifferentPeopleWithOverlappingNamesStillMatchLongestFirst() {
        let app = AppModel()
        let (shot, items, _) = setup(app, episode: 2, library: ["角色-第1集的沈砚", "角色-第1集的沈砚衡"])
        defer { cleanup(app, shot) }
        let idx = app.shots.firstIndex { $0.id == shot.id }!
        app.shots[idx].prompt = "[蕴古斋][沈砚衡、沈砚][怀表]"
        let result = run(app, shot, items)
        XCTAssertEqual(result.matched, 2)
        XCTAssertTrue(result.prompt.contains("图2沈砚衡") || result.prompt.contains("图1沈砚衡"), result.prompt)
        XCTAssertFalse(result.prompt.contains("沈砚衡衡"))
    }
}
