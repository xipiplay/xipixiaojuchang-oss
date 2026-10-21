import XCTest
@testable import Xipixiaojuchang

final class PipelineVideoBoardTests: XCTestCase {
    private func fixture() throws -> (EpWork, [DictEntry]) {
        let room = DictEntry(kind: "场景", name: "茶馆", desc: "木桌", identity: "青砖茶馆", fromEp: 1)
        let voice = DictEntry(kind: "角色", name: "掌柜", desc: "长衫", identity: "方脸", fromEp: 1)
        var segment = BoundSegment(text: "茶馆里传来掌柜的声音。", bindings: [
            SegmentBinding(entryId: room.id, internalName: room.name, kind: room.kind, evidence: "茶馆"),
            SegmentBinding(entryId: voice.id, internalName: voice.name, kind: voice.kind, evidence: "掌柜", usage: "画外音")
        ], openingSceneId: room.id, closingSceneId: room.id)
        try BindingRules.lock(&segment, dictionary: [room, voice])
        var work = EpWork()
        work.segmentsRaw = segment.text
        work.boundSegments = [segment]
        work.shots = ["茶馆全景切至木桌特写，30秒多镜头。"]
        work.checked = work.shots
        work.states = [.approved, .approved, .approved, .approved, .todo]
        return (work, [room, voice])
    }

    private func cards(_ work: EpWork, _ dictionary: [DictEntry], library: [Xipixiaojuchang.LibraryItem] = [],
                       shots: [ShotDraft] = [], tasks: [LocalTask] = []) -> [PipelineVideoCard] {
        PipelineVideoCard.make(work: work, dictionary: dictionary, projectKey: "current", episode: 1,
                               library: library, shots: shots, tasks: tasks)
    }

    func testOnlyVisibleAssetsNeedImagesAndRemoteImageIsUsable() throws {
        let (work, dictionary) = try fixture()
        let absent = cards(work, dictionary)[0]
        XCTAssertTrue(absent.canProduce)
        XCTAssertEqual(absent.references.map(\.name), ["茶馆"])
        XCTAssertEqual(absent.action, "准备参考图")
        var remote = LibraryItem(kind: .image, localPath: nil, name: "茶馆", projectKey: "current")
        remote.remoteURL = "https://example.com/room.png"
        XCTAssertEqual(cards(work, dictionary, library: [remote])[0].action, "视频生成设置")
    }

    func testRealGeneratedLibraryNamesResolveAndPublishSameImageID() throws {
        let (work, dictionary) = try fixture()
        let placeholder = LibraryItem(kind: .image, localPath: nil, name: "茶馆", projectKey: "current")
        var actual = LibraryItem(kind: .image, localPath: nil, name: "场景-茶馆-2", projectKey: "current")
        actual.remoteURL = "https://example.com/room.png"
        var wrongKind = LibraryItem(kind: .image, localPath: nil, name: "角色-茶馆-1", projectKey: "current")
        wrongKind.remoteURL = "https://example.com/role.png"
        let library = [placeholder, wrongKind, actual]
        let card = cards(work, dictionary, library: library)[0]
        XCTAssertEqual(card.action, "视频生成设置")
        XCTAssertEqual(card.references[0].libraryItemID, actual.id)
        let result = DirectPublishService.publishEpisodeShotsDirect(
            projectKey: "current", episodeIndex: 1, durationSeconds: 30, finalShots: work.checked,
            boundSegments: work.boundSegments, dictionary: dictionary,
            existingShots: [], existingLibrary: library, segmentIndices: [0],
            referenceLibraryIDs: [0: card.references.compactMap(\.libraryItemID)])
        XCTAssertEqual(result.result.createdLibraryCount, 0)
        XCTAssertEqual(result.result.createdShots[0].imageRefs.map(\.libraryItemID), [actual.id])
    }

    func testOtherProjectMediaAndShotsCannotMakeCurrentCardReady() throws {
        let (work, dictionary) = try fixture()
        var foreign = LibraryItem(kind: .image, localPath: nil, name: "茶馆", projectKey: "other")
        foreign.remoteURL = "https://example.com/room.png"
        let foreignShot = ShotDraft(projectKey: "other", prompt: "外国项目文案", duration: 30, numbering: ShotNumbering(a: 1, b: 1))
        let card = cards(work, dictionary, library: [foreign], shots: [foreignShot])[0]
        XCTAssertNil(card.shotID)
        XCTAssertFalse(card.references[0].ready)
        XCTAssertEqual(card.action, "准备参考图")
    }

    func testChangedDictionaryOrUnreviewedBindingBlocksProduction() throws {
        let (work, dictionary) = try fixture()
        var changed = dictionary
        changed[0].desc = "桌子已破损"
        XCTAssertFalse(cards(work, changed)[0].canProduce)
        var unreviewed = work
        unreviewed.boundSegments[0].reviewed = false
        XCTAssertFalse(cards(unreviewed, dictionary)[0].canProduce)
        unreviewed = work
        unreviewed.boundSegments[0].bindings[0].entryId = nil
        unreviewed.boundSegments[0].bindings[0].internalName = "不存在的版本"
        XCTAssertFalse(cards(unreviewed, dictionary)[0].canProduce)
    }

    func testMissingNamesAndIncompleteCheckedTextBlockProduction() throws {
        var (work, dictionary) = try fixture()
        work.missing = [MissingName(name: "路人", kind: "角色", context: "路人出现")]
        XCTAssertFalse(cards(work, dictionary)[0].canProduce)
        work.missing = []
        work.checked = []
        XCTAssertFalse(cards(work, dictionary)[0].canProduce)
        work.checked = [" "]
        XCTAssertFalse(cards(work, dictionary)[0].canProduce)
    }

    func testPartialPreparationButtonExplicitlyResumesAIInsteadOfSayingConfirm() throws {
        var (work, _) = try fixture()
        work.segmentsRaw += "\n---\n第二条视频剧情"
        work.states[2] = .reviewing
        work.states[3] = .todo
        XCTAssertEqual(PipelineVideoCard.prepareTitle(work), "继续推理分镜")
        work.shots.append("第二段提示词")
        XCTAssertEqual(PipelineVideoCard.prepareTitle(work), "确认本集分镜")
        work.states[2] = .approved
        XCTAssertEqual(PipelineVideoCard.prepareTitle(work), "继续检查分镜")
    }

    func testTaskStatusComesFromLatestLinkedTaskAndCompletedFileMustExist() throws {
        let (work, dictionary) = try fixture()
        var shot = ShotDraft(projectKey: "current", prompt: work.checked[0], duration: 30, numbering: ShotNumbering(a: 1, b: 1))
        shot.taskIDs = ["older", "newer"]
        let now = Date()
        let old = LocalTask(id: "older", model: "test", prompt: "文案", duration: 30, phase: .failed,
                            createdAt: now.addingTimeInterval(-60), updatedAt: now)
        var task = LocalTask(id: "newer", model: "test", prompt: "文案", duration: 30, phase: .completed,
                             createdAt: now, updatedAt: now, localVideoPath: "/definitely-missing/video.mp4")
        var card = cards(work, dictionary, shots: [shot], tasks: [task, old])[0]
        XCTAssertEqual(card.status, "视频已生成 · 待下载")
        XCTAssertFalse(card.hasVideo)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data([0]).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        task.localVideoPath = path.path
        card = cards(work, dictionary, shots: [shot], tasks: [old, task])[0]
        XCTAssertTrue(card.hasVideo)
        XCTAssertEqual(card.action, "查看视频")
    }

    func testHistoricalTaskCannotHideCurrentPreparationOrChangedPrompt() throws {
        var (work, dictionary) = try fixture()
        var shot = ShotDraft(projectKey: "current", prompt: "旧版本提示词", duration: 30, numbering: ShotNumbering(a: 1, b: 1))
        shot.taskID = "old-video"
        let task = LocalTask(id: "old-video", model: "test", prompt: "旧版本提示词", duration: 30,
                             phase: .completed, createdAt: Date(), updatedAt: Date())
        XCTAssertTrue(cards(work, dictionary, shots: [shot], tasks: [task])[0].status.contains("历史"))
        work.states[0] = .reviewing
        let stale = cards(work, dictionary, shots: [shot], tasks: [task])[0]
        XCTAssertFalse(stale.canProduce)
        XCTAssertTrue(stale.status.contains("本集素材待提取"))
        XCTAssertTrue(stale.status.contains("历史视频已生成"))
    }

    func testSingleSegmentCreationPreservesOriginalEpisodeAndSegmentNumber() throws {
        let (work, dictionary) = try fixture()
        let other = ShotDraft(projectKey: "other", prompt: "保护外项目", duration: 30, numbering: ShotNumbering(a: 3, b: 2))
        let result = DirectPublishService.publishEpisodeShotsDirect(
            projectKey: "current", episodeIndex: 3, durationSeconds: 30,
            finalShots: ["第一段，不应创建", work.checked[0]],
            boundSegments: [BoundSegment(text: "不应关联"), work.boundSegments[0]], dictionary: dictionary,
            existingShots: [other], existingLibrary: [], segmentIndices: [1])
        XCTAssertEqual(result.result.createdShots.count, 1)
        XCTAssertEqual(result.result.createdShots[0].numbering, ShotNumbering(a: 3, b: 2))
        XCTAssertEqual(result.result.createdShots[0].duration, 30)
        XCTAssertEqual(result.allLibrary.map(\.name), ["茶馆"])
        XCTAssertEqual(result.allShots.first, other)
        let again = DirectPublishService.publishEpisodeShotsDirect(
            projectKey: "current", episodeIndex: 3, durationSeconds: 30,
            finalShots: ["第一段，不应创建", work.checked[0]],
            boundSegments: [BoundSegment(text: "不应关联"), work.boundSegments[0]], dictionary: dictionary,
            existingShots: result.allShots, existingLibrary: result.allLibrary, segmentIndices: [1])
        XCTAssertEqual(again.result.createdShots.count, 0)
        XCTAssertEqual(again.allShots.count, 2)
    }
}
