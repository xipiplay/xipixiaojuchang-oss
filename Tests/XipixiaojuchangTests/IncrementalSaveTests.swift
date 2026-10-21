import XCTest
@testable import Xipixiaojuchang

/// 存盘只重新组装改过的项目（2026-10-12 稳定性）。最怕的是**漏存**：改了某样东西，那个项目却没被当成「改过」。
/// 这里把会影响 `project.json` 的每一样都改一遍，确认对应的项目都重写了、别的项目没碰
@MainActor
final class IncrementalSaveTests: XCTestCase {
    private struct World {
        let app: AppModel
        let a: String, b: String
        let shotA: ShotDraft
        let cardA: ImageGenItem
        let libA: Xipixiaojuchang.LibraryItem
        let libB: Xipixiaojuchang.LibraryItem           // B 的素材，被 A 的分镜引用（跨项目）
        let taskA: String
    }

    private func world() -> World {
        let app = AppModel()
        let a = "inc-a-" + UUID().uuidString, b = "inc-b-" + UUID().uuidString
        app.projectMetas[a] = ProjectMeta(name: "甲项目", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        app.projectMetas[b] = ProjectMeta(name: "乙项目", createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 2))
        var libA = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-甲", projectKey: a)
        libA.remoteURL = "https://x.test/a.png"
        var libB = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "场景-乙家", projectKey: b)
        libB.remoteURL = "https://x.test/b.png"
        app.library.append(contentsOf: [libA, libB])
        let taskA = "inc-task-" + UUID().uuidString
        var shotA = ShotDraft(projectKey: a, prompt: "[乙家][图1甲][ ]\n镜头", taskIDs: [taskA])
        shotA.taskID = taskA
        shotA.imageRefs = [MaterialRef(libraryItemID: libA.id, role: .referenceImage), MaterialRef(libraryItemID: libB.id, role: .referenceImage)]
        app.shots.append(shotA)
        app.shots.append(ShotDraft(projectKey: b, prompt: "[乙家][乙][ ]\n镜头"))
        app.store.add(LocalTask(id: taskA, model: "m", prompt: "p", duration: 15, phase: .inProgress, createdAt: Date(), updatedAt: Date()))
        let cardA = ImageGenItem(projectKey: a, type: .character, name: "甲", prompt: "红衣")
        app.imageItems.append(cardA)
        app.imageItems.append(ImageGenItem(projectKey: b, type: .scene, name: "乙家", prompt: "老房子"))
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "甲的剧本", episodes: [Episode(title: "第1集", text: "原文")]), for: a)
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "乙的剧本", episodes: [Episode(title: "第1集", text: "原文")]), for: b)
        app.saveProjectsNow()                                        // 第一次：全部组装
        return World(app: app, a: a, b: b, shotA: shotA, cardA: cardA, libA: libA, libB: libB, taskA: taskA)
    }

    private func saved(_ w: World, _ key: String) -> ProjectDocument? { w.app.projectStore?.saved[key] }

    /// 改一样东西 → 存盘 → 只有 `expect` 这几个项目被重新组装，而且它们的文档真的变了
    private func check(_ label: String, expect: Set<String>, _ w: World, file: StaticString = #filePath, line: UInt = #line,
                       _ change: (World) -> Void) {
        let before = Dictionary(uniqueKeysWithValues: [w.a, w.b].map { ($0, saved(w, $0)) })
        change(w)
        w.app.saveProjectsNow()
        XCTAssertEqual(w.app.projectStore?.lastBuiltKeys, expect, "\(label)：重新组装的项目不对", file: file, line: line)
        for key in expect {
            XCTAssertNotEqual(saved(w, key), before[key] ?? nil, "\(label)：\(key == w.a ? "甲" : "乙")项目的文件没跟着变——漏存了", file: file, line: line)
        }
        for key in Set([w.a, w.b]).subtracting(expect) {
            XCTAssertEqual(saved(w, key), before[key] ?? nil, "\(label)：没改的项目不该变", file: file, line: line)
        }
    }

    func testEveryKindOfChangeIsSavedForItsProjectOnly() {
        let w = world()
        defer { cleanup(w) }
        XCTAssertNotNil(saved(w, w.a)); XCTAssertNotNil(saved(w, w.b))

        check("项目改名", expect: [w.a], w) { w in w.app.projectMetas[w.a]?.name = "甲项目（新）" }
        check("改分镜提示词", expect: [w.a], w) { w in
            let i = w.app.shots.firstIndex { $0.id == w.shotA.id }!; w.app.shots[i].prompt += "改"
        }
        check("改生图卡", expect: [w.a], w) { w in
            let i = w.app.imageItems.firstIndex { $0.id == w.cardA.id }!; w.app.imageItems[i].prompt += "改"
        }
        check("改自己的素材", expect: [w.a], w) { w in
            let i = w.app.library.firstIndex { $0.id == w.libA.id }!; w.app.library[i].name = "角色-甲（新）"
        }
        check("改被别的项目引用的素材", expect: [w.a, w.b], w) { w in
            let i = w.app.library.firstIndex { $0.id == w.libB.id }!; w.app.library[i].name = "场景-乙家（新）"
        }
        check("视频任务完成", expect: [w.a], w) { w in
            var task = w.app.store.task(id: w.taskA)!
            task.phase = .completed; task.localVideoPath = "/tmp/inc-done.mp4"
            w.app.store.add(task)
        }
        check("改剧本", expect: [w.a], w) { w in
            var archive = w.app.pipelineArchive(for: w.a)!
            archive.episodes[0].splitText = "=== [00:00-00:30] ===\n△ 新分割。"
            w.app.savePipelineArchive(archive, for: w.a)
        }
        check("加一张卡", expect: [w.b], w) { w in w.app.imageItems.append(ImageGenItem(projectKey: w.b, type: .prop, name: "碗", prompt: "瓷碗")) }

        // 什么都没改：一个都不组装
        w.app.saveProjectsNow()
        XCTAssertEqual(w.app.projectStore?.lastBuiltKeys, [w.b], "没改动时根本不进组装（上一次的记录还在）")
    }

    /// 只组装一个项目，和全部组装时的同一个项目一模一样（跨项目引用、视频任务都在里面）
    func testBuildingOneProjectGivesTheSameDocumentAsBuildingAll() throws {
        let w = world()
        defer { cleanup(w) }
        let snapshot = LegacySnapshot(metas: w.app.projectMetas, shots: w.app.shots, imageItems: w.app.imageItems, library: w.app.library,
                                      tasks: w.app.store.tasks, pipelines: [w.a: w.app.pipelineArchive(for: w.a)!, w.b: w.app.pipelineArchive(for: w.b)!])
        let root = try XCTUnwrap(w.app.projectStore?.root)
        let previous = try XCTUnwrap(w.app.projectStore?.saved)
        let fixedNow = Date(timeIntervalSince1970: 100)
        let all = LegacyMigrationPlanner.plan(snapshot, options: .live(root: root, previous: previous, now: fixedNow)) { _ in true }
        for key in [w.a, w.b] {
            var options = MigrationOptions.live(root: root, previous: previous, now: fixedNow)
            options.onlyKeys = [key]
            let one = LegacyMigrationPlanner.plan(snapshot, options: options) { _ in true }
            XCTAssertEqual(one.projects.map { $0.id }, [key])
            XCTAssertEqual(one.projects.first, all.projects.first { $0.id == key }, "只组装 \(key) 的结果和全部组装时一样")
        }
    }

    private func cleanup(_ w: World) {
        for key in [w.a, w.b] {
            w.app.projectMetas[key] = nil
            w.app.shots.removeAll { $0.projectKey == key }
            w.app.imageItems.removeAll { $0.projectKey == key }
            w.app.library.removeAll { $0.projectKey == key }
            w.app.removePipelineArchive(for: key)
        }
    }
}
