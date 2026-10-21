import XCTest
@testable import Xipixiaojuchang

/// 分段一级页面（2026-10-10 改成封面卡 + 概览条）里不碰界面的那部分：每段四步的状态、顶上的筛选
@MainActor
final class SegmentGridModelTests: XCTestCase {
    private typealias Status = WorkbenchStatus
    private let key = "grid-model"

    private func card(_ name: String, _ type: ImageSubjectType, image: Bool = false, status: ImageGenStatus = .pending) -> ImageGenItem {
        var item = ImageGenItem(projectKey: key, type: type, name: name, prompt: "p")
        if image { item.results = [ImageGenResult(localPath: nil, createdAt: Date())]; item.status = .success } else { item.status = status }
        return item
    }

    /// 一集一段：头行 [客厅][甲][ ]，给定的卡和参考图，返回这一段的状态
    private func status(cards: [ImageGenItem], attached: Bool = false, video: Status.VideoState = .none) -> Status.ShotStatus {
        let sceneLib = UUID(), roleLib = UUID()
        var shot = ShotDraft(projectKey: key, prompt: "[客厅][甲][无]\n正文")
        if attached { shot.imageRefs = [sceneLib, roleLib].map { MaterialRef(libraryItemID: $0, role: .referenceImage) } }
        var ep = Episode(title: "集", text: "原文", splitText: "分割"); ep.shotIDs = [shot.id]
        let board = Status.board(.init(episodes: [ep], shots: [shot.id: shot], cards: cards,
                                       libraryKeyword: { $0 == sceneLib ? "客厅" : ($0 == roleLib ? "甲" : nil) }, videoState: { _ in video }))
        return board.episodes[0].shots[shot.id]!
    }

    func testTheFourStepsFollowTheNamesImagesRefsAndVideo() {
        let scene = card("客厅", .scene, image: true), role = card("甲", .character, image: true)
        // 缺卡：提取没做，后面都还没轮到
        XCTAssertEqual(status(cards: [scene]).steps, .init(extract: .pending, images: .pending, match: .pending, video: .pending))
        // 有卡没图：提取做完了；出图还没动 / 在出 / 出失败了
        XCTAssertEqual(status(cards: [scene, card("甲", .character)]).steps.images, .pending)
        XCTAssertEqual(status(cards: [scene, card("甲", .character, status: .generating)]).steps.images, .running)
        XCTAssertEqual(status(cards: [scene, card("甲", .character, status: .failed)]).steps.images, .problem)
        XCTAssertEqual(status(cards: [scene, card("甲", .character)]).steps.extract, .done)
        // 都有图、还没挂
        XCTAssertEqual(status(cards: [scene, role]).steps, .init(extract: .done, images: .done, match: .pending, video: .pending))
        // 挂上了，再看视频
        XCTAssertEqual(status(cards: [scene, role], attached: true).steps.match, .done)
        XCTAssertEqual(status(cards: [scene, role], attached: true, video: .running).steps.video, .running)
        XCTAssertEqual(status(cards: [scene, role], attached: true, video: .failed).steps.video, .problem)
        XCTAssertEqual(status(cards: [scene, role], attached: true, video: .completed).steps, .init(extract: .done, images: .done, match: .done, video: .done))
    }

    func testTheFiltersPickSegmentsByWhereTheyAre() {
        let scene = card("客厅", .scene, image: true), role = card("甲", .character, image: true)
        let toExtract = status(cards: [scene]), toImages = status(cards: [scene, card("甲", .character)])
        let imageFailed = status(cards: [scene, card("甲", .character, status: .failed)])
        let toMatch = status(cards: [scene, role]), done = status(cards: [scene, role], attached: true, video: .completed)
        let videoFailed = status(cards: [scene, role], attached: true, video: .failed)
        XCTAssertTrue(SegmentFilter.toExtract.matches(toExtract) && !SegmentFilter.toExtract.matches(toImages))
        XCTAssertTrue(SegmentFilter.toImages.matches(toImages) && SegmentFilter.toImages.matches(imageFailed))
        XCTAssertTrue(SegmentFilter.toMatch.matches(toMatch))
        XCTAssertTrue(SegmentFilter.done.matches(done) && !SegmentFilter.done.matches(videoFailed))
        XCTAssertTrue(SegmentFilter.problem.matches(imageFailed) && SegmentFilter.problem.matches(videoFailed))
        XCTAssertFalse(SegmentFilter.problem.matches(toImages), "只是还没出图不算有问题")
        XCTAssertTrue(SegmentFilter.all.matches(nil), "还没推理分镜的段只在「全部」里")
        XCTAssertFalse(SegmentFilter.toImages.matches(nil) || SegmentFilter.problem.matches(nil) || SegmentFilter.done.matches(nil))
    }
}

/// 分段卡片只画 `SegmentCardModel`：数据没变就不重画（退回网格 / 视频轮询时不再整页重算，2026-10-10 用户：从二级页面退回一级页面很慢）
@MainActor
final class SegmentCardModelTests: XCTestCase {
    func testTheModelCarriesWhatTheCardShowsAndOnlyChangesWhenThatChanges() throws {
        let app = AppModel()
        let key = "card-model-" + UUID().uuidString
        app.currentProjectKey = key
        defer { app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key } }
        let sceneImage = FileManager.default.temporaryDirectory.appendingPathComponent("card-model-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: sceneImage)
        var scene = ImageGenItem(projectKey: key, type: .scene, name: "客厅", prompt: "p")
        scene.results = [ImageGenResult(localPath: sceneImage.path, createdAt: Date())]; scene.status = .success
        var role = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p"); role.status = .pending
        let other = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "p")
        let prop = ImageGenItem(projectKey: key, type: .prop, name: "怀表", prompt: "p")
        app.imageItems.append(contentsOf: [scene, role, other, prop])
        let shot = ShotDraft(projectKey: key, prompt: "[客厅][甲、乙][怀表]\n正文", numbering: ShotNumbering(a: 1, b: 1))
        app.shots.append(shot)
        let segment = SplitSegments.Segment(number: 3, start: "01:00", end: "01:30", text: "【角色】：甲、乙\n△ 甲说话。\n乙回答。", scene: "客厅", roles: ["甲", "乙"], props: ["怀表"])
        var episode = Episode(title: "集", text: "原文", splitText: "分割"); episode.shotIDs = [shot.id]
        let board = Status.board(.init(episodes: [episode], shots: [shot.id: shot], cards: [scene, role, other, prop], libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        let status = board.episodes[0].shots[shot.id]

        func make(_ status: WorkbenchStatus.ShotStatus?) -> SegmentCardModel {
            SegmentCardModel.make(episodeIndex: 0, segment: segment, shot: shot, status: status, cards: [scene, role, other, prop], library: [:], app: app)
        }
        let model = make(status)
        XCTAssertEqual(model.number, 3)
        XCTAssertEqual(model.timeRange, "01:00–01:30")
        XCTAssertEqual(model.sceneName, "客厅")
        XCTAssertEqual(model.scenePath, sceneImage.path, "封面用场景卡现在显示的图")
        XCTAssertEqual(model.people.map(\.name), ["甲", "乙"])
        XCTAssertEqual(model.people.map(\.imagePath), [nil, nil], "没图的角色画成空头像")
        XCTAssertEqual(model.propNames, ["怀表"])
        XCTAssertEqual(model.excerpt, "△ 甲说话。 乙回答。", "去掉列素材的那一行")
        XCTAssertEqual(model.shotID, shot.id)
        XCTAssertEqual(model, make(status), "同样的数据算两遍，结果一样（卡片据此跳过重画）")

        // 别的地方变了、和这张卡无关：模型不变
        app.imageItems.append(ImageGenItem(projectKey: key, type: .character, name: "路人", prompt: "p"))
        XCTAssertEqual(model, make(status))
        // 状态变了（这一段有视频了 / 出图失败了）：模型变，卡片才重画
        var failed = role; failed.status = .failed
        let board2 = Status.board(.init(episodes: [episode], shots: [shot.id: shot], cards: [scene, failed, other, prop], libraryKeyword: { _ in nil }, videoState: { _ in .none }))
        XCTAssertNotEqual(model, SegmentCardModel.make(episodeIndex: 0, segment: segment, shot: shot, status: board2.episodes[0].shots[shot.id], cards: [scene, failed, other, prop], library: [:], app: app))
        // 还没推理分镜：按分割文本预估，没有图
        let guess = make(nil)
        XCTAssertEqual(guess.people.map(\.name), ["甲", "乙"])
        XCTAssertEqual(guess.statusText, WorkbenchStatus.Stage.toInfer.title)
        XCTAssertNil(guess.steps)
        // 各段还没名字（分割只管切之后、命名之前）：卡片上写「待命名」，剧情摘要里不带头行
        var unnamed = segment; unnamed.scene = nil; unnamed.text = "【本段在场】：甲\n△ 甲说话。"
        let beforeNaming = SegmentCardModel.make(episodeIndex: 0, segment: unnamed, shot: nil, status: nil, cards: [], library: [:], app: app)
        XCTAssertEqual(beforeNaming.statusText, WorkbenchStatus.Stage.toName.title)
        XCTAssertEqual(beforeNaming.excerpt, "△ 甲说话。", "本段在场那一行也不进摘要")
    }

    private typealias Status = WorkbenchStatus
}
