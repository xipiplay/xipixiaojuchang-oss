import XCTest
@testable import Xipixiaojuchang

/// 生图右栏的「用到它的分段」：哪些分镜的头行用到了这张卡（按这一集该用的版本算）
@MainActor
final class CardUsageTests: XCTestCase {
    private let key = "card-usage"

    private func card(_ name: String, _ type: ImageSubjectType) -> ImageGenItem { ImageGenItem(projectKey: key, type: type, name: name, prompt: "p") }
    private func shot(_ head: String, a: Int, b: Int) -> ShotDraft {
        ShotDraft(projectKey: key, prompt: head + "\n正文", numbering: ShotNumbering(a: a, b: b))
    }
    private func archive(_ episodes: [[ShotDraft]]) -> ProjectPipelineArchive {
        ProjectPipelineArchive(wholeScript: "全文", episodes: episodes.map { shots in
            var e = Episode(title: "集", text: "原文", splitText: "x"); e.shotIDs = shots.map(\.id); return e
        })
    }

    func testListsTheSegmentsWhoseHeadLineNamesTheCardInOrder() {
        let zhou = card("周承山", .character), xu = card("许曼", .character), room = card("客厅", .scene)
        let s1 = shot("[客厅][周承山、许曼][ ]", a: 1, b: 1), s2 = shot("[客厅][许曼][ ]", a: 1, b: 2), s3 = shot("[卧室][周承山][ ]", a: 2, b: 1)
        let entries = CardUsage.entries(for: zhou, cards: [zhou, xu, room], shots: [s1, s2, s3], archive: archive([[s1, s2], [s3]]), title: { "分镜\($0.numbering!.a)-\($0.numbering!.b)" })
        XCTAssertEqual(entries.map(\.title), ["分镜1-1", "分镜2-1"])
        XCTAssertEqual(entries.map(\.episodeIndex), [0, 1])
        XCTAssertEqual(entries.map(\.segment), [1, 1])
        XCTAssertEqual(CardUsage.entries(for: room, cards: [zhou, xu, room], shots: [s1, s2, s3], archive: archive([[s1, s2], [s3]]), title: { $0.numbering!.title }).map(\.segment), [1, 2],
                       "场景也一样")
    }

    func testWhenAnNameHasSeveralVersionsEachSegmentCountsForTheOneInForceInItsEpisode() {
        let early = card("第1集的周承山", .character), late = card("第3集的周承山", .character)
        let s1 = shot("[客厅][周承山][ ]", a: 1, b: 1), s2 = shot("[客厅][周承山][ ]", a: 3, b: 1)
        let arch = archive([[s1], [], [s2]])
        let cards = [early, late]
        XCTAssertEqual(CardUsage.entries(for: early, cards: cards, shots: [s1, s2], archive: arch, title: { $0.numbering!.title }).map(\.shotID), [s1.id], "第 1 集用早的那张")
        XCTAssertEqual(CardUsage.entries(for: late, cards: cards, shots: [s1, s2], archive: arch, title: { $0.numbering!.title }).map(\.shotID), [s2.id], "第 3 集起用晚的那张")
    }

    func testTheSameNameWithADuplicateNumberIsTheFallbackWhenThereIsNoExactCard() {
        let second = card("周承山 2", .character)
        let s1 = shot("[客厅][周承山][ ]", a: 1, b: 1)
        XCTAssertEqual(CardUsage.entries(for: second, cards: [second], shots: [s1], archive: archive([[s1]]), title: { $0.numbering!.title }).count, 1)
    }

    /// 2026-10-17（项目82）：这一段挂着的卡优先——第7集这段挂的是第6集那张的图，
    /// 第6集卡的「用到它的分段」里就要有这一段；第7集的空卡不再算「在用」。
    func testAnAttachedCardCountsForItsSegmentEvenWhenTheEpisodeRuleWouldUseALaterVersion() {
        let early = card("第6集的驾驶训练区", .scene), late = card("第7集的驾驶训练区", .scene)
        let s7 = shot("[驾驶训练区][ ][ ]", a: 7, b: 1)
        let arch = archive([[], [], [], [], [], [], [s7]])
        let cards = [early, late]
        let attached: (CardUsage.Kind, String, ShotDraft) -> UUID? = { _, _, s in s.id == s7.id ? early.id : nil }
        XCTAssertEqual(CardUsage.entries(for: early, cards: cards, shots: [s7], archive: arch, attachedCardID: attached,
                                         title: { $0.numbering!.title }).map(\.shotID), [s7.id], "挂着第6集那张：这一段算在用第6集的卡")
        XCTAssertTrue(CardUsage.entries(for: late, cards: cards, shots: [s7], archive: arch, attachedCardID: attached,
                                        title: { $0.numbering!.title }).isEmpty, "挂上之后第7集空卡就不算在用了")
        XCTAssertEqual(CardUsage.entries(for: late, cards: cards, shots: [s7], archive: arch,
                                         title: { $0.numbering!.title }).map(\.shotID), [s7.id], "不给闭包时还是按版本规则（老口径）")
    }

    func testCardsWithoutATypeOrWithoutEpisodesHaveNoUsage() {
        let plain = ImageGenItem(projectKey: key, type: nil, name: "随便画的", prompt: "p")
        let s1 = shot("[客厅][随便画的][ ]", a: 1, b: 1)
        XCTAssertTrue(CardUsage.entries(for: plain, cards: [plain], shots: [s1], archive: archive([[s1]]), title: { $0.numbering!.title }).isEmpty)
        let zhou = card("周承山", .character)
        XCTAssertTrue(CardUsage.entries(for: zhou, cards: [zhou], shots: [s1], archive: nil, title: { $0.numbering!.title }).isEmpty)
    }

    /// 2026-10-10 用户：进项目感觉慢——卡顿采样里「用到它的分段」占了主线程 ~18%。重写成「卡一次归组、名字查表」，结果必须和老算法（`cardInForce`）一样
    func testTheFastLookupGivesExactlyTheSameAnswerAsPickingEachNameFromAllTheCards() {
        let names = ["周承山", "许曼", "沈砚", "刘领班", "韩峥"]
        var cards: [ImageGenItem] = []
        for (i, name) in names.enumerated() {
            cards.append(card(name, .character))
            cards.append(card("第\(3 + i)集的\(name)", .character))
            cards.append(card("第\(9 + i)集的\(name)", .character))
            cards.append(card("\(name) 2", .character))
        }
        for place in ["客厅", "赛场", "后台"] { cards.append(card(place, .scene)); cards.append(card("第5集的\(place)", .scene)) }
        cards.append(card("怀表", .prop))
        var episodes: [[ShotDraft]] = []
        var all: [ShotDraft] = []
        for e in 0..<14 {
            var shots: [ShotDraft] = []
            for b in 1...4 {
                let roles = [names[(e + b) % 5], names[(e + 2 * b) % 5]].joined(separator: "、")
                shots.append(shot("[\(["客厅", "赛场", "后台"][(e + b) % 3])][\(roles)][怀表]", a: e + 1, b: b))
            }
            episodes.append(shots); all += shots
        }
        let arch = archive(episodes)
        // 老算法：每个名字把全部卡过滤一遍
        func reference(_ target: ImageGenItem) -> [UUID] {
            guard let type = target.type, let kind = CardUsage.Kind.allCases.first(where: { $0.subjectType == type }) else { return [] }
            var out: [UUID] = []
            for (ei, ep) in arch.episodes.enumerated() {
                for id in ep.shotIDs ?? [] {
                    guard let sh = all.first(where: { $0.id == id }), let head = StoryboardNames.head(of: sh.prompt) else { continue }
                    let list: [String] = kind == .scene ? head.scenes : (kind == .role ? head.roles : head.props)
                    if list.contains(where: { CardUsage.cardInForce(kind: kind, name: $0, episode: ei + 1, cards: cards)?.id == target.id }) { out.append(id) }
                }
            }
            return out
        }
        for target in cards {
            XCTAssertEqual(CardUsage.entries(for: target, cards: cards, shots: all, archive: arch, title: { $0.numbering!.title }).map(\.shotID),
                           reference(target), "\(target.name)")
        }
    }

    func testEntriesStayFastWithManyCardsAndSegments() {
        var cards: [ImageGenItem] = []
        for i in 0..<300 { cards.append(card(i % 3 == 0 ? "第\(i % 40 + 1)集的人物\(i / 6)" : "人物\(i / 6) 2", .character)) }
        var episodes: [[ShotDraft]] = []
        var all: [ShotDraft] = []
        for e in 0..<40 {
            var shots: [ShotDraft] = []
            for b in 1...5 { shots.append(shot("[客厅][人物\((e * 5 + b) % 50)、人物\((e + b) % 50)、人物\((e * 3 + b) % 50)][怀表]", a: e + 1, b: b)) }
            episodes.append(shots); all += shots
        }
        let arch = archive(episodes)
        let start = Date()
        for target in cards.prefix(20) { _ = CardUsage.entries(for: target, cards: cards, shots: all, archive: arch, title: { $0.numbering!.title }) }
        let perCall = Date().timeIntervalSince(start) / 20
        XCTAssertLessThan(perCall, 0.02, "每次 \(perCall * 1000)ms（300 张卡 × 200 个分镜）")
    }

    func testOpeningASegmentSelectsItsEpisodeAndRemembersTheSegmentForTheWorkbench() {
        let app = AppModel()
        let k = "open-seg-" + UUID().uuidString
        app.currentProjectKey = k
        app.isInWorkspace = true
        defer { app.removePipelineArchive(for: k); app.isInWorkspace = false; app.currentProjectKey = nil; app.workbenchLocations[k] = nil }
        var e1 = Episode(title: "一", text: "原文", splitText: "x"), e2 = Episode(title: "二", text: "原文", splitText: "x")
        e1.shotIDs = []; e2.shotIDs = []
        var archive = ProjectPipelineArchive(wholeScript: "全文", episodes: [e1, e2]); archive.epIndex = 0
        app.savePipelineArchive(archive, for: k)
        app.workbenchOpenSegment(episodeIndex: 1, segment: 4)
        XCTAssertEqual(app.pipelineArchive(for: k)?.epIndex, 1)
        XCTAssertEqual(app.workbenchLocations[k], .init(projectKey: k, episodeIndex: 1, segment: 4))
        XCTAssertEqual(app.projectPage, .script)
    }
}
