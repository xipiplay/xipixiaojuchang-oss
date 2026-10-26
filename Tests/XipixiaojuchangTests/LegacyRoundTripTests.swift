import XCTest
@testable import Xipixiaojuchang

/// P1 适配层：旧数组 → 项目文档 → 旧数组 → 项目文档，来回一遍不能丢东西、不能漂。
/// 旧页面每次存盘都走这一圈，任何一处不稳都会表现成「重启后卡片变了 / ID 变了 / 文件路径断了」。
final class LegacyRoundTripTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/项目根", isDirectory: true)
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func live(_ s: LegacySnapshot, previous: [ProjectDocument] = []) -> [ProjectDocument] {
        let prev = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var options = MigrationOptions.live(root: root, previous: prev, now: t0)
        options.targetExists = { _, _ in false }
        return LegacyMigrationPlanner.plan(s, options: options) { _ in true }.projects
    }

    private func path(_ relative: String) -> String { root.appendingPathComponent("P/\(relative)").path }

    /// 一个把旧页面能产生的东西都放进去的项目
    private func richSnapshot() -> LegacySnapshot {
        let ep = Episode(title: "第1集", text: "甲在客栈")
        // 剧本页生的图（素材挂着生图条目）
        var portrait = ImageGenItem(projectKey: "P", type: .character, name: "甲", prompt: "红衣", status: .success)
        let r1 = ImageGenResult(localPath: path("images/甲-1.png"), createdAt: t0, prompt: "红衣", model: "img")
        let r2 = ImageGenResult(localPath: path("images/甲-2.png"), createdAt: t0.addingTimeInterval(5))
        portrait.results = [r1, r2]
        portrait.selectedResultID = r1.id
        portrait.paramsDirty = true
        // 生图页随手生的图（没类型）+ 存进素材库的复制件
        var loose = ImageGenItem(projectKey: "P", type: nil, name: "云", prompt: "白云", status: .failed)
        loose.errorMessage = "超时"
        let r3 = ImageGenResult(localPath: path("images/云.png"), createdAt: t0)
        loose.results = [r3]
        var saved = LibraryItem(kind: .image, localPath: path("images/角色-甲.png"), fileName: "角色-甲.png",
                                name: "角色-甲", projectKey: "P")
        saved.source = .imageGenerated
        saved.imageGenItemID = portrait.id
        saved.imageGenResultID = r1.id
        saved.remoteURL = "https://cdn/甲"
        saved.uploadState = .uploaded
        // 导入的音频，生图条目已删的复制件
        let song = LibraryItem(kind: .audio, localPath: path("imports/歌.mp3"), fileName: "歌.mp3", duration: 12, projectKey: "P")
        var orphanCopy = LibraryItem(kind: .image, localPath: path("images/道具-剑.png"), name: "道具-剑", projectKey: "P")
        orphanCopy.source = .imageGenerated
        orphanCopy.imageGenItemID = UUID()
        loose.imageRefs = [MaterialRef(libraryItemID: orphanCopy.id)]
        // 分镜卡：一张挂在剧本段上，两张自由卡（其中一张「显示当前」指向旧版本）
        let linked = ShotDraft(projectKey: "P", prompt: "卡上改过的提示词", duration: 15,
                               imageRefs: [MaterialRef(libraryItemID: saved.id, role: .firstFrame)],
                               taskIDs: ["t1"], numbering: ShotNumbering(a: 1, b: 1))
        var freeA = ShotDraft(projectKey: "P", prompt: "自由二", audioRefs: [MaterialRef(libraryItemID: song.id)],
                              taskID: "t2", taskIDs: ["t2", "t3"], numbering: ShotNumbering(a: 2, b: 1))
        freeA.paramsDirty = true
        let freeB = ShotDraft(projectKey: "P", prompt: "自由一", numbering: ShotNumbering(a: 3, b: 1))
        var work = SimpleEpisodeWork(id: ep.id, sourceKey: SimplePipeline.key(ep.text))
        work.assets = [SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣", imageItemID: portrait.id),
                       SimplePipelineAsset(kind: "场景", name: "客栈", description: "木头")]
        work.assetsExtracted = true
        var seg = SimplePipelineSegment(text: "甲在客栈", assetNames: ["客栈", "甲", "乙"], prompt: "段提示词", shotID: linked.id)
        seg.endPositions = "甲在门口"
        work.segments = [seg]
        var archive = ProjectPipelineArchive(projectId: UUID(), wholeScript: "全文", loadedFileName: "剧.txt",
                                             episodes: [ep], simpleWorks: [work])
        archive.epIndex = 0
        func task(_ id: String, _ phase: TaskPhase, _ file: String?) -> LocalTask {
            var t = LocalTask(id: id, model: "v", prompt: "p-\(id)", duration: 10, phase: phase, createdAt: t0, updatedAt: t0)
            t.localVideoPath = file.map(path)
            return t
        }
        return LegacySnapshot(
            metas: ["P": ProjectMeta(name: "剧", createdAt: t0, updatedAt: t0)],
            shots: [freeA, linked, freeB],
            imageItems: [loose, portrait],
            library: [song, saved, orphanCopy],
            tasks: [task("t1", .completed, "videos/1-1-1.mp4"), task("t2", .completed, "videos/2-1-1.mp4"),
                    task("t3", .inProgress, nil)],
            pipelines: ["P": archive])
    }

    func testDocumentIsAFixedPointOfTheAdapter() throws {
        let legacy = richSnapshot()
        let docs = live(legacy)
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        back.tasks = legacy.tasks
        XCTAssertEqual(live(back, previous: docs), docs)
    }

    /// 失败的生图（2026-10-16 留成版本）：存进项目文件、读回来还在；来回一圈不漂
    func testImageFailuresSurviveTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        let index = try XCTUnwrap(legacy.imageItems.indices.first)
        legacy.imageItems[index].failures = [ImageGenFailure(createdAt: Date(timeIntervalSince1970: 1_800_000_000), error: "HTTP 503",
                                                              prompt: "那一次的提示词", model: "gpt-image", type: .character,
                                                              aspectRatio: .ratio16x9, quality: .k2, imageRefs: [])]
        let docs = live(legacy)
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        let item = try XCTUnwrap(back.imageItems.first { $0.id == legacy.imageItems[index].id })
        XCTAssertEqual(item.failures, legacy.imageItems[index].failures)
        back.tasks = legacy.tasks
        XCTAssertEqual(live(back, previous: docs), docs, "来回一圈不漂")
    }

    /// 时代背景（2026-10-11）：存进项目文件，重启后还在；没填的项目（没有这个键）原样是 nil；来回一圈不漂
    func testTheEraBackgroundSurvivesTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        var archive = try XCTUnwrap(legacy.pipelines["P"])
        archive.eraBackground = "民国背景"
        legacy.pipelines["P"] = archive
        let docs = live(legacy)
        XCTAssertEqual(docs.first?.legacy?.pipelineEra, "民国背景")
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        XCTAssertEqual(back.pipelines["P"]?.eraBackground, "民国背景")
        back.tasks = legacy.tasks
        XCTAssertEqual(live(back, previous: docs), docs, "来回一圈不漂")
        XCTAssertNil(LegacyProjection.snapshot(from: live(richSnapshot()), projectsRoot: root).pipelines["P"]?.eraBackground)
    }

    /// 推理分镜时的段落结构（2026-10-12）：存进项目文件、读回来还在（丢了的话重启后就不知道分割改没改过）
    func testTheStoryboardSplitSignatureSurvivesTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        var archive = try XCTUnwrap(legacy.pipelines["P"])
        guard !archive.episodes.isEmpty else { return XCTFail("样例里要有集") }
        archive.episodes[0].storyboardSplitSignature = "3|00:00 - 00:30|00:30 - 01:00|01:00 - 01:30"
        legacy.pipelines["P"] = archive
        let docs = live(legacy)
        let back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        XCTAssertEqual(back.pipelines["P"]?.episodes.first?.storyboardSplitSignature, "3|00:00 - 00:30|00:30 - 01:00|01:00 - 01:30")
    }

    /// 卡片的阶段 / 起始集（2026-10-14 名字与形态分离）：存进项目文件、读回来还在（丢了的话名字只剩基础名，版本就分不清了）；
    /// 旧卡名字里的「第N集的」读回来时拆成起始集；来回一圈不漂
    func testCardStageAndStartEpisodeSurviveTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        var staged = ImageGenItem(projectKey: "P", type: .character, name: "周承山", prompt: "这个人是：\"周承山\"", status: .pending)
        staged.stage = "四十岁"; staged.fromEpisode = 3
        let voiceID = UUID()
        staged.voiceAudioID = voiceID; staged.voiceText = "低沉沙哑"; staged.voiceMode = .text   // 音色（2026-10-26）
        var old = ImageGenItem(projectKey: "P", type: .character, name: "第5集的许曼", prompt: "这个人是：\"第5集的许曼\"", status: .pending)
        old.referenceCardID = staged.id          // 变化版记着基础版（出图时挂它的图）
        legacy.imageItems += [staged, old]
        let docs = live(legacy)
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        let stagedBack = try XCTUnwrap(back.imageItems.first { $0.id == staged.id })
        XCTAssertEqual(stagedBack.stage, "四十岁")
        XCTAssertEqual(stagedBack.fromEpisode, 3)
        let oldBack = try XCTUnwrap(back.imageItems.first { $0.id == old.id })
        XCTAssertEqual(oldBack.name, "许曼", "旧卡读回来就拆开")
        XCTAssertEqual(oldBack.fromEpisode, 5)
        XCTAssertEqual(oldBack.referenceCardID, staged.id, "基础版关联重开项目还在")
        back.tasks = legacy.tasks
        let again = live(back, previous: docs)
        let backAgain = LegacyProjection.snapshot(from: again, projectsRoot: root)
        XCTAssertEqual(backAgain.imageItems.first { $0.id == old.id }?.fromEpisode, 5, "拆开以后存一次再读，起始集还在")
        XCTAssertEqual(backAgain.imageItems.first { $0.id == staged.id }?.stage, "四十岁")
        XCTAssertEqual(backAgain.imageItems.first { $0.id == old.id }?.referenceCardID, staged.id)
        XCTAssertEqual(stagedBack.voiceAudioID, voiceID, "音色重开项目还在")
        XCTAssertEqual(stagedBack.voiceText, "低沉沙哑")
        XCTAssertEqual(stagedBack.voiceMode, .text)
        XCTAssertEqual(backAgain.imageItems.first { $0.id == staged.id }?.voiceAudioID, voiceID)
        XCTAssertNil(oldBack.voiceAudioID)
    }

    /// 「待生成」版本（2026-10-15）：当前是它的卡重开项目还是它（不能兜底成最后一版），收起来的提示词也在
    func testPendingVersionSurvivesTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        let linked = try XCTUnwrap(legacy.shots.firstIndex { $0.taskIDs == ["t1"] })
        legacy.shots[linked].pendingIsCurrent = true
        legacy.shots[linked].taskID = nil
        let free = try XCTUnwrap(legacy.shots.firstIndex { $0.taskIDs == ["t2", "t3"] })
        legacy.shots[free].pendingPrompt = "收起来的新提示词"
        let docs = live(legacy)
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        let a = try XCTUnwrap(back.shots.first { $0.id == legacy.shots[linked].id })
        XCTAssertTrue(a.showsPendingVersion)
        XCTAssertNil(a.taskID, "当前是「待生成」：没有当前视频")
        let b = try XCTUnwrap(back.shots.first { $0.id == legacy.shots[free].id })
        XCTAssertEqual(b.pendingPrompt, "收起来的新提示词")
        XCTAssertEqual(b.taskID, "t2")
        back.tasks = legacy.tasks
        let again = LegacyProjection.snapshot(from: live(back, previous: docs), projectsRoot: root)
        XCTAssertTrue(again.shots.first { $0.id == a.id }?.showsPendingVersion == true, "存一次再读还是它")
        XCTAssertEqual(again.shots.first { $0.id == b.id }?.pendingPrompt, "收起来的新提示词")
    }

    /// 「添加集」加的空集（原文空、没分割）存盘再读还在（2026-10-15）
    func testAddedEmptyEpisodeSurvivesTheStoredProjectFormat() throws {
        var legacy = richSnapshot()
        let archive = try XCTUnwrap(legacy.pipelines["P"])
        legacy.pipelines["P"] = EpisodeEdit.appending(to: archive).archive
        let back = LegacyProjection.snapshot(from: live(legacy), projectsRoot: root)
        let episodes = try XCTUnwrap(back.pipelines["P"]?.episodes)
        XCTAssertEqual(episodes.count, archive.episodes.count + 1)
        XCTAssertEqual(episodes.last?.title, "第\(archive.episodes.count + 1)集")
        XCTAssertEqual(episodes.last?.text, "")
    }

    func testOldPagesGetTheirDataBack() throws {
        let legacy = richSnapshot()
        let back = LegacyProjection.snapshot(from: live(legacy), projectsRoot: root)

        XCTAssertEqual(back.shots.map(\.id), legacy.shots.map(\.id), "分镜卡 ID 和顺序不变")
        for (a, b) in zip(back.shots, legacy.shots) {
            XCTAssertEqual(a.prompt, b.prompt)
            XCTAssertEqual(a.taskIDs, b.taskIDs)
            XCTAssertEqual(a.taskID ?? a.taskIDs.last, b.taskID ?? b.taskIDs.last, "「显示当前」的版本不变")
            XCTAssertEqual(a.imageRefs, b.imageRefs)
            XCTAssertEqual(a.audioRefs, b.audioRefs)
            XCTAssertEqual(a.numbering, b.numbering)
            XCTAssertEqual(a.duration, b.duration)
            XCTAssertEqual(a.paramsDirty, b.paramsDirty)
        }
        XCTAssertEqual(back.imageItems.map(\.id), legacy.imageItems.map(\.id))
        for (a, b) in zip(back.imageItems, legacy.imageItems) {
            XCTAssertEqual(a.results.map(\.id), b.results.map(\.id))
            XCTAssertEqual(a.results.map(\.localPath), b.results.map(\.localPath))
            XCTAssertEqual(a.selectedResultID, b.selectedResultID)
            XCTAssertEqual(a.status, b.status)
            XCTAssertEqual(a.errorMessage, b.errorMessage)
            XCTAssertEqual(a.paramsDirty, b.paramsDirty)
            XCTAssertEqual(a.imageRefs, b.imageRefs)
            XCTAssertEqual(a.type, b.type)
        }
        XCTAssertEqual(back.library.map(\.id), legacy.library.map(\.id))
        for (a, b) in zip(back.library, legacy.library) {
            XCTAssertEqual(a.localPath, b.localPath)
            XCTAssertEqual(a.remoteURL, b.remoteURL)
            XCTAssertEqual(a.uploadState, b.uploadState)
            XCTAssertEqual(a.name, b.name)
            XCTAssertEqual(a.kind, b.kind)
            XCTAssertEqual(a.duration, b.duration)
            XCTAssertEqual(a.source, b.source)
            XCTAssertEqual(a.imageGenItemID, b.imageGenItemID)
        }
        let archive = try XCTUnwrap(back.pipelines["P"])
        let original = try XCTUnwrap(legacy.pipelines["P"])
        XCTAssertEqual(archive.projectId, original.projectId)
        XCTAssertEqual(archive.wholeScript, original.wholeScript)
        XCTAssertEqual(archive.episodes, original.episodes)
        let w = try XCTUnwrap(archive.simpleWorks.first), o = try XCTUnwrap(original.simpleWorks.first)
        XCTAssertEqual(w.assets, o.assets)
        XCTAssertEqual(w.segments.map(\.id), o.segments.map(\.id))
        XCTAssertEqual(w.segments[0].assetNames, o.segments[0].assetNames)
        XCTAssertEqual(w.segments[0].shotID, o.segments[0].shotID)
        XCTAssertEqual(w.segments[0].endPositions, "甲在门口")
        XCTAssertEqual(w.segments[0].prompt, "卡上改过的提示词", "以卡为准")
        XCTAssertEqual(back.metas["P"]?.name, "剧")
    }

    /// P2：没有 tasks.json 了，任务记录从视频版本还原 —— 还原出来的要和原来一样，再存一遍也不变
    func testVideoTasksRebuildFromProjectFiles() throws {
        let legacy = richSnapshot()
        let docs = live(legacy)
        let rebuilt = LegacyProjection.tasks(from: docs, projectsRoot: root)
        XCTAssertEqual(Set(rebuilt.map(\.id)), Set(legacy.tasks.map(\.id)))
        for original in legacy.tasks {
            let t = try XCTUnwrap(rebuilt.first { $0.id == original.id })
            XCTAssertEqual(t.phase, original.phase)
            XCTAssertEqual(t.prompt, original.prompt)
            XCTAssertEqual(t.localVideoPath, original.localVideoPath)
            XCTAssertEqual(t.duration, original.duration)
            XCTAssertEqual(t.groupKey, "P", "按项目归组（任务抽屉、角标都按它筛）")
        }
        var back = LegacyProjection.snapshot(from: docs, projectsRoot: root)
        back.tasks = rebuilt
        XCTAssertEqual(live(back, previous: docs), docs)
    }

    func testInProgressVideoStaysOnTheShotAcrossSaves() throws {
        let doc = try XCTUnwrap(live(richSnapshot()).first)
        let free = try XCTUnwrap(doc.episodes.first { $0.isFree })
        XCTAssertEqual(free.segments[0].videos.map(\.phase), [.completed, .inProgress])
        XCTAssertEqual(free.segments[0].selectedVideoTaskID, "t2")
    }

    func testFilesInsideProjectFolderAreNotCopiedAndOutsideFilesAre() throws {
        var s = richSnapshot()
        s.library.append(LibraryItem(kind: .image, localPath: "/Users/x/Downloads/图.png", projectKey: "P"))
        let plan = LegacyMigrationPlanner.plan(s, options: MigrationOptions.live(root: root, previous: [:], now: t0)) { _ in true }
        XCTAssertEqual(plan.copies.map(\.source), ["/Users/x/Downloads/图.png"])
        XCTAssertEqual(plan.copies.first?.relativePath, "imports/图.png")
    }

    func testMissingOutsideFileKeepsItsPathWhenSaving() throws {
        var s = richSnapshot()
        s.library.append(LibraryItem(kind: .image, localPath: "/Volumes/外接盘/图.png", projectKey: "P"))
        let doc = try XCTUnwrap(LegacyMigrationPlanner.plan(
            s, options: MigrationOptions.live(root: root, previous: [:], now: t0)) { !$0.hasPrefix("/Volumes") }.projects.first)
        let back = LegacyProjection.snapshot(from: [doc], projectsRoot: root)
        XCTAssertTrue(back.library.contains { $0.localPath == "/Volumes/外接盘/图.png" })
    }

    func testDeletedProjectsLibraryDoesNotResurrectTheProject() {
        var s = richSnapshot()
        s.metas = [:]
        s.shots = []
        s.imageItems = []
        s.pipelines = [:]
        s.library = []
        XCTAssertTrue(live(s).isEmpty)
    }
}
