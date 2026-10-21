import XCTest
@testable import Xipixiaojuchang

/// 1.x → 2.0 迁移规划（2026-10-06 用户按推荐确认的「P1 迁移映射」）。
final class LegacyMigrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func meta(_ name: String, _ offset: Double = 0) -> ProjectMeta {
        ProjectMeta(name: name, createdAt: t0.addingTimeInterval(offset), updatedAt: t0.addingTimeInterval(offset))
    }
    private func plan(_ s: LegacySnapshot, missing: Set<String> = []) -> MigrationPlan {
        LegacyMigrationPlanner.plan(s, options: MigrationOptions(now: t0)) { !missing.contains($0) }
    }
    private func item(_ key: String, _ type: ImageSubjectType?, _ name: String, prompt: String,
                      results: [ImageGenResult] = [], selected: UUID? = nil) -> ImageGenItem {
        var i = ImageGenItem(projectKey: key, type: type, name: name, prompt: prompt, status: .success)
        i.results = results
        i.selectedResultID = selected
        return i
    }
    private func task(_ id: String, _ phase: TaskPhase, file: String? = nil) -> LocalTask {
        var t = LocalTask(id: id, model: "m", prompt: "提交时的提示词", duration: 10, phase: phase,
                          createdAt: t0, updatedAt: t0)
        t.localVideoPath = file
        return t
    }

    // MARK: 剧本素材 → 设定

    func testPipelineAssetsMergeAcrossEpisodesAndFlagDifferentDescriptions() throws {
        let e1 = Episode(title: "第1集", text: "甲出场"), e2 = Episode(title: "第2集", text: "甲又出场")
        var w1 = SimpleEpisodeWork(id: e1.id, sourceKey: SimplePipeline.key(e1.text))
        w1.assets = [SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣")]
        w1.segments = [SimplePipelineSegment(text: "甲出场", assetNames: ["甲", "乙"], prompt: "镜头")]
        var w2 = SimpleEpisodeWork(id: e2.id, sourceKey: SimplePipeline.key(e2.text))
        w2.assets = [SimplePipelineAsset(kind: "角色", name: "甲", description: "蓝衣")]
        let archive = ProjectPipelineArchive(wholeScript: "全文", episodes: [e1, e2], simpleWorks: [w1, w2])
        let doc = try XCTUnwrap(plan(LegacySnapshot(metas: ["P": meta("剧")], pipelines: ["P": archive])).projects.first)

        XCTAssertEqual(doc.settings.count, 1)
        let jia = doc.settings[0]
        XCTAssertEqual(jia.kind, .character)
        XCTAssertEqual(jia.description, "红衣")
        XCTAssertTrue(jia.needsReview)
        XCTAssertEqual(jia.reviewNotes, ["蓝衣"])
        XCTAssertEqual(doc.episodes.map(\.title), ["第1集", "第2集"])
        let seg = doc.episodes[0].segments[0]
        XCTAssertEqual(seg.settingIDs, [jia.id])
        XCTAssertEqual(seg.unresolvedNames, ["乙"])
        XCTAssertEqual(doc.script, "全文")
    }

    // MARK: 生图条目 → 设定版本

    func testImageItemsBecomeVersionsAndSelectionFallsBackToLatest() throws {
        let r1 = ImageGenResult(localPath: "/c/a.png", createdAt: t0)
        let r2 = ImageGenResult(localPath: "/c/b.png", createdAt: t0.addingTimeInterval(10))
        let r3 = ImageGenResult(localPath: "/c/a.png", createdAt: t0.addingTimeInterval(20)) // 同名文件
        let typed = item("P", .scene, "客栈", prompt: "木头客栈", results: [r1, r2])
        let picked = item("P", nil, "随手图", prompt: "云", results: [r3], selected: r3.id)
        let p = plan(LegacySnapshot(metas: ["P": meta("项")], imageItems: [typed, picked]))
        let doc = try XCTUnwrap(p.projects.first)

        let inn = try XCTUnwrap(doc.settings.first { $0.name == "客栈" })
        XCTAssertEqual(inn.kind, .scene)
        XCTAssertEqual(inn.description, "木头客栈")
        XCTAssertEqual(inn.versions.map(\.file), ["images/a.png", "images/b.png"])
        XCTAssertNil(inn.selectedVersionID, "没选过 → 不记，跟随最新")
        XCTAssertEqual(inn.portrait?.id, r2.id)
        let other = try XCTUnwrap(doc.settings.first { $0.name == "随手图" })
        XCTAssertEqual(other.kind, .other)
        XCTAssertEqual(other.selectedVersionID, r3.id)
        XCTAssertEqual(p.copies.count, 2, "同一源文件只拷一次")
    }

    func testSameTypedNameMergesAndDifferentPromptNeedsReview() throws {
        let a = item("P", .character, "甲", prompt: "版本一", results: [ImageGenResult(createdAt: t0)])
        let b = item("P", .character, "甲", prompt: "版本二", results: [ImageGenResult(createdAt: t0.addingTimeInterval(5))])
        let doc = try XCTUnwrap(plan(LegacySnapshot(metas: ["P": meta("项")], imageItems: [b, a])).projects.first)
        XCTAssertEqual(doc.settings.count, 1)
        XCTAssertEqual(doc.settings[0].versions.count, 2)
        XCTAssertEqual(doc.settings[0].description, "版本二", "按原列表顺序先出现的为准")
        XCTAssertTrue(doc.settings[0].needsReview)
    }

    // MARK: 素材库

    func testLibraryCopyOfGeneratedImageIsNotKeptSeparatelyAndFillsPublicURLAndMissingFile() throws {
        let result = ImageGenResult(localPath: "/gone/a.png", createdAt: t0)
        let gen = item("P", .prop, "剑", prompt: "长剑", results: [result])
        var copy = LibraryItem(kind: .image, localPath: "/c/剑.png", name: "道具-剑", projectKey: "P")
        copy.source = .imageGenerated
        copy.imageGenItemID = gen.id
        copy.imageGenResultID = result.id
        copy.remoteURL = "https://cdn/剑.png"
        let p = plan(LegacySnapshot(metas: ["P": meta("项")], imageItems: [gen], library: [copy]), missing: ["/gone/a.png"])
        let doc = try XCTUnwrap(p.projects.first)

        XCTAssertEqual(doc.settings.count, 1)
        let v = doc.settings[0].versions[0]
        XCTAssertEqual(v.publicURL, "https://cdn/剑.png")
        XCTAssertEqual(v.file, "images/剑.png", "原图丢了 → 用素材库复制件补")
        XCTAssertEqual(p.report.projects[0].missingFiles, [])
    }

    func testImportedLibraryItemsAndShotReferencesWithRoles() throws {
        let photo = LibraryItem(kind: .image, localPath: "/dl/照片.jpg", name: "照片", projectKey: "P")
        let music = LibraryItem(kind: .audio, localPath: "/dl/歌.mp3", projectKey: "P")
        var deletedSource = LibraryItem(kind: .image, localPath: "/c/角色-乙-1.png", name: "角色-乙-1", projectKey: "P")
        deletedSource.source = .imageGenerated
        deletedSource.imageGenItemID = UUID()
        let shot = ShotDraft(projectKey: "P", prompt: "走路",
                             imageRefs: [MaterialRef(libraryItemID: photo.id, role: .firstFrame),
                                         MaterialRef(libraryItemID: deletedSource.id),
                                         MaterialRef(libraryItemID: UUID())],
                             audioRefs: [MaterialRef(libraryItemID: music.id)],
                             numbering: ShotNumbering(a: 1, b: 1))
        let p = plan(LegacySnapshot(metas: ["P": meta("项")], shots: [shot], library: [photo, music, deletedSource]))
        let doc = try XCTUnwrap(p.projects.first)

        let imported = doc.settings.filter { $0.kind == .imported }
        XCTAssertEqual(Set(imported.map(\.name)), ["照片", "歌"])
        XCTAssertEqual(imported.first { $0.name == "歌" }?.media, .audio)
        XCTAssertEqual(imported.first { $0.name == "照片" }?.versions.first?.file, "imports/照片.jpg")
        let yi = try XCTUnwrap(doc.settings.first { $0.name == "乙" })
        XCTAssertEqual(yi.kind, .character, "来源已删的生图复制件按名字前缀定类型")

        let free = try XCTUnwrap(doc.episodes.first { $0.isFree })
        let seg = free.segments[0]
        XCTAssertEqual(seg.id, shot.id)
        XCTAssertEqual(seg.references.count, 3)
        XCTAssertEqual(seg.references[0].role, .firstFrame)
        XCTAssertEqual(seg.references[2].media, .audio)
        XCTAssertEqual(p.report.projects[0].danglingReferences, 1)
    }

    // MARK: 分镜卡 → 段 + 视频版本

    func testShotsKeepListOrderAndMigrateCompletedVideosOnly() throws {
        let late = ShotDraft(projectKey: "P", prompt: "二", taskIDs: ["ok2"], numbering: ShotNumbering(a: 2, b: 1))
        let early = ShotDraft(projectKey: "P", prompt: "一", taskIDs: ["ok1", "bad", "ghost", "ok3"],
                              numbering: ShotNumbering(a: 1, b: 1))
        let s = LegacySnapshot(metas: ["P": meta("项")], shots: [late, early],
                               tasks: [task("ok1", .completed, file: "/v/1-1-1.mp4"), task("bad", .failed),
                                       task("ok3", .completed, file: "/v/gone.mp4"), task("ok2", .completed),
                                       task("stray", .completed)])
        let p = plan(s, missing: ["/v/gone.mp4"])
        let free = try XCTUnwrap(p.projects.first?.episodes.first { $0.isFree })

        XCTAssertEqual(free.segments.map(\.prompt), ["二", "一"], "按旧列表顺序（页面就是这么显示的）")
        let videos = free.segments[1].videos
        XCTAssertEqual(videos.map(\.taskID), ["ok1", "ok3"])
        XCTAssertEqual(videos[0].file, "videos/1-1-1.mp4")
        XCTAssertNil(videos[1].file)
        XCTAssertEqual(free.segments[1].selectedVideo?.id, videos[1].id)
        let row = p.report.projects[0]
        XCTAssertEqual(row.skippedUnfinishedTasks, 1)
        XCTAssertEqual(row.missingTaskIDs, 1)
        XCTAssertEqual(row.missingFiles, ["/v/gone.mp4"])
        XCTAssertEqual(p.report.unownedTasks, 1)
    }

    func testShotLinkedFromPipelineSegmentMergesIntoThatSegment() throws {
        let ep = Episode(title: "第1集", text: "原文")
        let shot = ShotDraft(projectKey: "P", prompt: "卡上的提示词", duration: 15, taskIDs: ["ok"])
        var work = SimpleEpisodeWork(id: ep.id, sourceKey: SimplePipeline.key(ep.text))
        work.segments = [SimplePipelineSegment(text: "原文", prompt: "", shotID: shot.id)]
        let s = LegacySnapshot(metas: ["P": meta("项")], shots: [shot], tasks: [task("ok", .completed)],
                               pipelines: ["P": ProjectPipelineArchive(episodes: [ep], simpleWorks: [work])])
        let doc = try XCTUnwrap(plan(s).projects.first)
        XCTAssertEqual(doc.episodes.count, 1, "卡并进剧本段，不再出现在自由集")
        let seg = doc.episodes[0].segments[0]
        XCTAssertEqual(seg.prompt, "卡上的提示词")
        XCTAssertEqual(seg.params.duration, 15)
        XCTAssertEqual(seg.videos.count, 1)
    }

    // MARK: 项目层面

    func testExcludedOrphanAndDuplicateNames() throws {
        let s = LegacySnapshot(
            metas: ["A": meta("项目", 0), "B": meta("项目", 1), "STRESS-100-100": meta("压测")],
            shots: [ShotDraft(projectKey: "STRESS-100-100")],
            imageItems: [item("ghost1", .character, "甲", prompt: "x"), item("ghost2", .character, "甲", prompt: "y")])
        let p = plan(s)
        XCTAssertEqual(p.projects.map(\.name), ["项目", "项目 2", "迁移-未归属图片"])
        XCTAssertEqual(p.projects[1].migration?.previousName, "项目")
        XCTAssertNil(p.projects[0].migration?.previousName)
        XCTAssertFalse(p.projects.contains { $0.id == "STRESS-100-100" })
        XCTAssertEqual(p.report.excluded, ["压测（STRESS-100-100）"])
        let orphan = p.projects[2]
        XCTAssertEqual(orphan.migration?.legacyKeys, ["ghost1", "ghost2"])
        XCTAssertEqual(orphan.settings.count, 2, "不同旧 key 的同名设定不合并")
    }

    func testDuplicateDoesNotStealAnExistingNumberedName() {
        let s = LegacySnapshot(metas: ["A": meta("剧", 0), "B": meta("剧", 1), "C": meta("剧 2", 2)])
        XCTAssertEqual(plan(s).projects.map(\.name), ["剧", "剧 3", "剧 2"])
    }

    func testSharedFileIsCopiedIntoEachProject() {
        let a = item("A", nil, "图", prompt: "", results: [ImageGenResult(localPath: "/c/共用.png", createdAt: t0)])
        let b = item("B", nil, "图", prompt: "", results: [ImageGenResult(localPath: "/c/共用.png", createdAt: t0)])
        let p = plan(LegacySnapshot(metas: ["A": meta("甲"), "B": meta("乙", 1)], imageItems: [a, b]))
        XCTAssertEqual(Set(p.copies.map(\.projectID)), ["A", "B"])
    }

    // MARK: 执行

    func testExecuteWritesProjectFolderAndRefusesToOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: src)
        let p = plan(LegacySnapshot(metas: ["P": meta("项")],
                                    imageItems: [item("P", nil, "图", prompt: "",
                                                      results: [ImageGenResult(localPath: src.path, createdAt: t0)])]))
        let out = root.appendingPathComponent("项目")
        XCTAssertEqual(try LegacyMigrator.execute(p, projectsRoot: out), [])
        let doc = try ProjectDocument.decode(Data(contentsOf: out.appendingPathComponent("P/project.json")))
        XCTAssertEqual(doc, p.projects[0])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("P/images/src.png")), Data("png".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "源文件不动")
        XCTAssertThrowsError(try LegacyMigrator.execute(p, projectsRoot: out))
    }
}
