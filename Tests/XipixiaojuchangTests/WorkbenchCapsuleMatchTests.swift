import XCTest
@testable import Xipixiaojuchang

private struct InstantUploader: UploadService {
    let supportsLocalFiles = true
    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        RemoteMaterial(url: "https://fake.test/\(UUID().uuidString).png", duration: nil)
    }
}

/// 工作台工具条的「匹配」和分段弹窗的「应用素材」同一套（2026-10-12 用户：原来只匹配了入库的）：
/// 每段按头行里的名字挂上它该用的那一版卡；还没入库的先入库
@MainActor
final class WorkbenchCapsuleMatchTests: XCTestCase {
    func testMatchAttachesCardsThatAreNotInTheLibraryYet() async throws {
        let app = AppModel()
        app.uploadServiceOverride = InstantUploader()
        let key = "capsule-match-" + UUID().uuidString
        app.currentProjectKey = key
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("capmatch-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "红衣少女")
        card.results = [ImageGenResult(localPath: file.path, createdAt: Date())]; card.status = .success
        app.imageItems.append(card)
        let noImage = ImageGenItem(projectKey: key, type: .character, name: "乙", prompt: "p")
        app.imageItems.append(noImage)
        let shot = ShotDraft(projectKey: key, prompt: "[ ][甲、乙][ ]\n镜头1：甲推门进来。")
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲、乙\n【道具】：无\n【本段在场】：甲、乙\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        XCTAssertFalse(app.library.contains { $0.projectKey == key }, "开始时素材库里没有这张图")

        let board = app.workbenchBoard(project: key, archive: try XCTUnwrap(app.pipelineArchive(for: key)))
        let plan = WorkbenchBatch.matchPlan(board: board, indices: [0], app: app)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(WorkbenchBatch.matchNeedsLibrary(plan, app: app), 1, "面板里会提前说有 1 张要先入库")

        let report = WorkbenchBatch.match(board: board, indices: [0], app: app)
        XCTAssertEqual(report.shots, 1)
        XCTAssertEqual(report.applied, 1, "没入库的甲也挂上了")
        XCTAssertEqual(report.withoutImage, 1, "乙还没出图，没挂")
        let after = try XCTUnwrap(app.shots.first { $0.id == shot.id })
        XCTAssertEqual(after.imageRefs.count, 1)
        let lib = try XCTUnwrap(app.library.first { $0.projectKey == key }, "先存进了素材库")
        XCTAssertEqual(after.imageRefs.first?.libraryItemID, lib.id)
        XCTAssertTrue(after.prompt.contains("图1"), after.prompt)

        // 入库会在后台上传：等它做完再清数据（否则上传回来按旧下标写，崩整个测试进程，见交接文档「测试里别真的触发…」）
        for _ in 0..<40 where [.pending, .uploading].contains(app.library.first(where: { $0.id == lib.id })?.uploadState) {
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .milliseconds(200))
        app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }; app.removePipelineArchive(for: key)
    }

    /// 生视频页拖选的「批量匹配」：选中的里属于某一集的走同一套；生视频页自己新建的（不属于任何一集）不在计划里，照旧按素材库名字匹配
    func testSelectionPlanOnlyCoversShotsThatBelongToAnEpisode() throws {
        let app = AppModel()
        let key = "sel-match-" + UUID().uuidString
        app.currentProjectKey = key
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p")
        card.results = [ImageGenResult(localPath: "/tmp/sel-match-none.png", createdAt: Date())]; card.status = .success
        app.imageItems.append(card)
        let inEpisode = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头")
        let manual = ShotDraft(projectKey: key, prompt: "生视频页自己写的分镜")
        app.shots.append(contentsOf: [inEpisode, manual])
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲。\n"
        episode.shotIDs = [inEpisode.id]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        defer { app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key }; app.removePipelineArchive(for: key) }

        let board = app.workbenchBoard(project: key, archive: try XCTUnwrap(app.pipelineArchive(for: key)))
        let plan = WorkbenchBatch.matchPlan(board: board, shotIDs: [inEpisode.id, manual.id], app: app)
        XCTAssertEqual(plan.map(\.shotID), [inEpisode.id], "只有属于第 1 集的那张")
        XCTAssertEqual(plan.first?.selections.map(\.cardID), [card.id], "挂的是这一集该用的那一版")
    }
    /// 编辑提示词弹窗的「自动匹配」（2026-10-14 用户：三处匹配要统一）：属于某一集的分镜走同一套——
    /// 已经挂着旧版本的原位换成卡上现在显示的那一版、不按 `[X-Y 秒]` 改时长；不属于任何一集的拿不到这一项，照旧按素材库名字
    func testEditDialogAutoMatchUsesTheSameRulesForEpisodeShots() throws {
        let app = AppModel()
        let key = "dialog-match-" + UUID().uuidString
        app.currentProjectKey = key
        let old = ImageGenResult(localPath: "/tmp/dialog-match-old.png", createdAt: Date(timeIntervalSinceNow: -60))
        let new = ImageGenResult(localPath: "/tmp/dialog-match-new.png", createdAt: Date())
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "p")
        card.results = [old, new]; card.selectedResultID = new.id; card.status = .success
        app.imageItems.append(card)
        func libraryItem(for result: ImageGenResult) -> Xipixiaojuchang.LibraryItem {
            var item = Xipixiaojuchang.LibraryItem(kind: .image, localPath: result.localPath, name: "角色-甲", projectKey: key)
            item.uploadState = .uploaded; item.remoteURL = "https://fake.test/\(result.id).png"
            item.source = .imageGenerated; item.imageGenItemID = card.id; item.imageGenResultID = result.id
            return item
        }
        let oldLib = libraryItem(for: old), newLib = libraryItem(for: new)
        app.library.append(contentsOf: [oldLib, newLib])
        var shot = ShotDraft(projectKey: key, prompt: "[ ][图1甲][ ]\n[0-12 秒] 镜头1：甲推门进来。")
        shot.imageRefs = [MaterialRef(libraryItemID: oldLib.id, role: .referenceImage)]
        shot.duration = 5
        let manual = ShotDraft(projectKey: key, prompt: "[甲] 生视频页自己写的分镜")
        app.shots.append(contentsOf: [shot, manual])
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        defer {
            app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key }
            app.library.removeAll { $0.projectKey == key }; app.removePipelineArchive(for: key)
        }

        XCTAssertNil(WorkbenchBatch.matchItem(shotID: manual.id, app: app), "不属于任何一集：照旧按素材库名字匹配")
        let item = try XCTUnwrap(WorkbenchBatch.matchItem(shotID: shot.id, app: app))
        XCTAssertEqual(WorkbenchBatch.matchNeedsLibrary([item], app: app), 0, "现在显示的那一版已经入库，不用问")
        let report = WorkbenchBatch.match([item], app: app)
        XCTAssertEqual(report.applied, 1)
        let after = try XCTUnwrap(app.shots.first { $0.id == shot.id })
        XCTAssertEqual(after.imageRefs.map(\.libraryItemID), [newLib.id], "原位换成卡上现在显示的那一版")
        XCTAssertEqual(after.prompt, shot.prompt, "编号不变、不多插")
        XCTAssertEqual(after.duration, 5, "不按提示词里的时间段改时长")
    }
}
