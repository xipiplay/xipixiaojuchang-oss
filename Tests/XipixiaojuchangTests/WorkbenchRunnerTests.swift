import XCTest
@testable import Xipixiaojuchang

/// 一键推进（2026-10-07 P3-2 第 3 步，用户按推荐定的口径）：
/// 只推进选中的一集；只在「挑定妆图」「提交视频」停下；失败停在那一步、再点接着做；停止后保留已做完的。
@MainActor
final class WorkbenchRunnerTests: XCTestCase {
    private final class Counter { var split = 0, extract = 0, infer = 0, images = 0, submitted: [UUID] = [] }

    private struct Fixture {
        let app: AppModel
        let key: String
        let episode: Episode
        let runner: WorkbenchRunner
        let counter: Counter
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WorkbenchRunner.autoPickKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkbenchRunner.autoPickKey)
        UserDefaults.standard.removeObject(forKey: "modelChannels")
        super.tearDown()
    }

    /// 一集原文、什么都还没做；钩子换成立刻完成的假实现，计数方便断言
    private func fixture(imageModel: Bool = true) -> Fixture {
        let app = AppModel()
        if imageModel {
            app.saveChannel(ModelChannel(name: "测试渠道", baseURL: "http://x", apiKey: "",
                                         models: [ChannelModel(name: "图片模型", capability: .image)]))
        }
        let key = "runner-" + UUID().uuidString
        let episode = Episode(title: "第1集", text: "甲走进客栈。")
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        let runner = app.workbenchRunner   // 界面读的就是它
        let counter = Counter()
        runner.hooks.pollInterval = .milliseconds(5)
        runner.hooks.splitDuration = { app, project, index in
            counter.split += 1
            var archive = app.pipelineArchive(for: project)!
            var work = SimplePipeline.work(in: archive, index: index)
            work.segments = [SimplePipelineSegment(text: "第一段", assetNames: ["客栈", "甲"]),
                             SimplePipelineSegment(text: "第二段", assetNames: ["客栈"])]
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        runner.hooks.extract = { app, project, index in
            counter.extract += 1
            var archive = app.pipelineArchive(for: project)!
            var work = SimplePipeline.work(in: archive, index: index)
            work.assets = [SimplePipelineAsset(kind: "场景", name: "客栈", description: "木头客栈"),
                           SimplePipelineAsset(kind: "角色", name: "甲", description: "红衣少女")]
            work.assetsExtracted = true
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        runner.hooks.generateImage = { app, id in
            counter.images += 1
            guard let i = app.imageItems.firstIndex(where: { $0.id == id }) else { return }
            app.imageItems[i].results.append(ImageGenResult(createdAt: Date()))
            app.imageItems[i].status = .success
        }
        runner.hooks.infer = { app, project, index in
            counter.infer += 1
            var archive = app.pipelineArchive(for: project)!
            var work = SimplePipeline.work(in: archive, index: index)
            for i in work.segments.indices {
                work.segments[i].prompt = "提示词\(i + 1)"
                work.segments[i].endPositions = "站位\(i + 1)"
            }
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        runner.hooks.submit = { _, segment, _, _ in counter.submitted.append(segment.id) }
        return Fixture(app: app, key: key, episode: episode, runner: runner, counter: counter)
    }

    @discardableResult
    private func go(_ f: Fixture) async throws -> WorkbenchRunner.Run {
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        return try XCTUnwrap(f.runner.run(project: f.key, episode: f.episode.id))
    }

    // MARK: 一路跑到闸门

    func testFreshEpisodeRunsEveryStepUpToThePickGate() async throws {
        let f = fixture()
        let run = try await go(f)
        XCTAssertEqual(run.phase, .waitingPick, "分段 → 提取素材 → 出图都做完，停在挑定妆图")
        XCTAssertEqual([f.counter.split, f.counter.extract, f.counter.images, f.counter.infer], [1, 1, 2, 0])
        XCTAssertEqual(run.generated.count, 2, "场景和角色各出一张")
        XCTAssertEqual(f.app.imageItems.filter { $0.projectKey == f.key }.count, 2)
    }

    func testConfirmingPicksWritesTheChoiceAndRunsToTheSubmitGate() async throws {
        let f = fixture()
        let run = try await go(f)
        let picks = Dictionary(uniqueKeysWithValues: run.generated.compactMap { id in
            f.app.imageItems.first { $0.id == id }.flatMap { $0.latestResult?.id }.map { (id, $0) }
        })
        f.runner.confirmPicks(app: f.app, project: f.key, episode: f.episode.id, picks: picks)
        await f.runner.wait(project: f.key, episode: f.episode.id)

        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.phase, .waitingSubmit)
        XCTAssertEqual(f.counter.infer, 1)
        for (itemID, resultID) in picks {
            XCTAssertEqual(f.app.imageItems.first { $0.id == itemID }?.selectedResultID, resultID, "挑的那张明确记下来")
        }
        let toSubmit = WorkbenchRunner.segmentsToSubmit(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertEqual(toSubmit.map(\.prompt), ["提示词1", "提示词2"])
    }

    func testSubmitGateSubmitsOnlyTheChosenSegments() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        let toSubmit = WorkbenchRunner.segmentsToSubmit(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.phase, .waitingSubmit)
        let failures = f.runner.confirmSubmit(app: f.app, project: f.key, episode: f.episode.id,
                                              segmentIDs: [toSubmit[1].id], params: { _ in .legacyDefault })
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(f.counter.submitted, [toSubmit[1].id])
        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.phase, .finished("已提交 1 条视频，进度在任务抽屉里"))
    }

    func testSubmitFailuresAreReportedPerSegment() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        f.runner.hooks.submit = { _, _, _, _ in throw WorkbenchActions.Failure("没有可用的视频模型") }
        let all = WorkbenchRunner.segmentsToSubmit(app: f.app, project: f.key, episode: f.episode.id).map(\.id)
        let failures = f.runner.confirmSubmit(app: f.app, project: f.key, episode: f.episode.id, segmentIDs: all,
                                              params: { _ in .legacyDefault })
        XCTAssertEqual(failures.map(\.segment), [1, 2])
        if case .failed(let step, let message)? = f.runner.run(project: f.key, episode: f.episode.id)?.phase {
            XCTAssertEqual(step, "提交视频")
            XCTAssertTrue(message.contains("第 1 段") && message.contains("没有可用的视频模型"))
        } else { XCTFail("应该是失败状态") }
    }

    // MARK: 自动选最新

    func testAutoPickSettingSkipsThePickGate() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        let run = try await go(f)
        XCTAssertEqual(run.phase, .waitingSubmit, "勾了自动选最新：挑定妆图不停，直接到提交视频")
        XCTAssertEqual(f.counter.infer, 1)
    }

    func testNoPickGateWhenNothingNewWasGenerated() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        UserDefaults.standard.removeObject(forKey: WorkbenchRunner.autoPickKey)
        // 重新开始（已有图）：这次没出新图，就没有可挑的，直接往下
        f.runner.dismiss(project: f.key, episode: f.episode.id)
        let run = try await go(f)
        XCTAssertEqual(run.phase, .waitingSubmit)
        XCTAssertEqual(f.counter.images, 2, "已有的图不会再生成")
    }

    // MARK: 失败与接着做

    func testFailureStopsAtThatStepAndRetrySkipsFinishedSteps() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        let goodInfer = f.runner.hooks.infer
        f.runner.hooks.infer = { _, _, _ in f.counter.infer += 1 }   // 推理没有写出任何提示词
        let failed = try await go(f)
        guard case .failed(let step, let message) = failed.phase else { return XCTFail("应该停在推理分镜") }
        XCTAssertEqual(step, "推理分镜")
        XCTAssertTrue(message.contains("接着做"))
        XCTAssertEqual([f.counter.split, f.counter.extract, f.counter.images], [1, 1, 2])

        f.runner.hooks.infer = goodInfer
        let resumed = try await go(f)
        XCTAssertEqual(resumed.phase, .waitingSubmit)
        XCTAssertEqual([f.counter.split, f.counter.extract, f.counter.images], [1, 1, 2], "前面做完的步骤不重做")
        XCTAssertEqual(f.counter.infer, 2)
    }

    func testImageFailureStopsAtImagingAndNamesTheSettings() async throws {
        let f = fixture()
        f.runner.hooks.generateImage = { app, id in
            guard let i = app.imageItems.firstIndex(where: { $0.id == id }) else { return }
            app.imageItems[i].status = .failed
            app.imageItems[i].errorMessage = "额度不足"
        }
        let run = try await go(f)
        guard case .failed(let step, let message) = run.phase else { return XCTFail("应该停在出图") }
        XCTAssertEqual(step, "出图")
        XCTAssertTrue(message.contains("2 个设定出图失败") && message.contains("客栈") && message.contains("额度不足"), message)
        XCTAssertEqual(f.counter.infer, 0, "出图没成功，不会往后做")
    }

    func testMissingImageModelStopsAtImagingBeforeSpendingAnything() async throws {
        let f = fixture(imageModel: false)
        let run = try await go(f)
        guard case .failed(let step, let message) = run.phase else { return XCTFail("应该停在出图") }
        XCTAssertEqual(step, "出图")
        XCTAssertTrue(message.contains("图片模型"))
        XCTAssertEqual(f.counter.images, 0)
        XCTAssertTrue(f.app.imageItems.filter { $0.projectKey == f.key }.isEmpty)
    }

    func testSwitchingProjectsStopsTheRun() async throws {
        let f = fixture()
        f.app.currentProjectKey = "另一个项目"
        let run = try await go(f)
        guard case .failed(_, let message) = run.phase else { return XCTFail("应该停下") }
        XCTAssertTrue(message.contains("切换"))
        XCTAssertEqual(f.counter.split, 0, "不会在别的项目里动手")
    }

    // MARK: 停止

    func testStopWhileImagesAreGeneratingMarksStoppedAndKeepsEarlierSteps() async throws {
        let f = fixture()
        f.runner.hooks.generateImage = { app, id in   // 一直「生成中」，模拟很慢
            if let i = app.imageItems.firstIndex(where: { $0.id == id }) { app.imageItems[i].status = .generating }
        }
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        for _ in 0..<200 where f.counter.extract == 0 || f.runner.run(project: f.key, episode: f.episode.id)?.generated.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(f.runner.isActive(project: f.key, episode: f.episode.id))
        f.runner.stop(app: f.app, project: f.key, episode: f.episode.id)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.phase, .stopped)
        XCTAssertFalse(f.runner.isActive(project: f.key, episode: f.episode.id))
        let archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        let work = SimplePipeline.work(in: archive, index: 0)
        XCTAssertEqual(work.segments.count, 2, "分段的结果保留")
        XCTAssertTrue(work.assetsExtracted, "提取的素材保留")
    }

    func testRestartRightAfterStopIsNotOverwrittenByTheOldRun() async throws {
        let f = fixture()
        let instant = f.runner.hooks.generateImage
        f.runner.hooks.generateImage = { app, id in
            if let i = app.imageItems.firstIndex(where: { $0.id == id }) { app.imageItems[i].status = .generating }
        }
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        for _ in 0..<200 where f.runner.run(project: f.key, episode: f.episode.id)?.generated.count != 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        f.runner.stop(app: f.app, project: f.key, episode: f.episode.id)
        // 不等旧任务收尾，马上再点开始（这次出图是立刻完成的）
        for item in f.app.imageItems where item.projectKey == f.key { f.app.stopImageGeneration(item.id) }
        for i in f.app.imageItems.indices where f.app.imageItems[i].projectKey == f.key { f.app.imageItems[i].status = .pending }
        f.runner.hooks.generateImage = instant
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.phase, .waitingPick, "新一轮的状态不会被旧任务改成已停止")
    }

    func testStartIsIgnoredWhileARunIsActive() async throws {
        let f = fixture()
        f.runner.hooks.generateImage = { app, id in
            if let i = app.imageItems.firstIndex(where: { $0.id == id }) { app.imageItems[i].status = .generating }
        }
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        for _ in 0..<200 where f.counter.extract == 0 { try await Task.sleep(for: .milliseconds(10)) }
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        f.runner.stop(app: f.app, project: f.key, episode: f.episode.id)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(f.counter.split, 1, "重复点击不会再开一轮")
    }

    // MARK: 已经全做完

    func testEpisodeWithVideosEverywhereFinishesImmediately() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        // 给每一段挂上分镜卡和一条已完成的视频
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        for i in work.segments.indices {
            let taskID = "done-\(i)"
            let shot = ShotDraft(projectKey: f.key, prompt: work.segments[i].prompt, taskIDs: [taskID])
            f.app.shots.append(shot)
            work.segments[i].shotID = shot.id
            f.app.store.add(LocalTask(id: taskID, model: "m", prompt: shot.prompt, duration: 30, phase: .completed,
                                      createdAt: Date(), updatedAt: Date()))
        }
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)

        f.runner.dismiss(project: f.key, episode: f.episode.id)
        let run = try await go(f)
        if case .finished = run.phase {} else { XCTFail("没有要提交的段：直接完成，实际 \(run.phase)") }
    }

    // MARK: 匹配素材（推理分镜之后、提交视频之前）

    func testRunMatchesMaterialsAfterInferenceBeforeTheSubmitGate() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        // 出图时顺便建好素材库条目（真实流程里是入库那一步），推理写出带方括号行的提示词
        f.runner.hooks.generateImage = { app, id in
            guard let i = app.imageItems.firstIndex(where: { $0.id == id }) else { return }
            let result = ImageGenResult(createdAt: Date())
            app.imageItems[i].results.append(result)
            app.imageItems[i].status = .success
            let item = app.imageItems[i]
            var lib = LibraryItem(kind: .image, localPath: nil, name: "\(item.type!.namePrefix)-\(item.name)", projectKey: f.key)
            lib.imageGenResultID = result.id
            app.library.append(lib)
        }
        f.runner.hooks.infer = { app, project, index in
            f.counter.infer += 1
            var archive = app.pipelineArchive(for: project)!
            var work = SimplePipeline.work(in: archive, index: index)
            for i in work.segments.indices {
                work.segments[i].prompt = "[客栈][甲]\n第\(i + 1)段，甲在客栈。"
                work.segments[i].endPositions = "站位"
            }
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        let run = try await go(f)
        XCTAssertEqual(run.phase, .waitingSubmit)
        let shots = f.app.shots.filter { $0.projectKey == f.key }.sorted { ($0.numbering?.b ?? 0) < ($1.numbering?.b ?? 0) }
        XCTAssertEqual(shots.count, 2, "两段各建了一张分镜卡")
        XCTAssertEqual(shots[0].prompt, "[图1客栈][图2甲]\n第1段，甲在客栈。")
        XCTAssertEqual(shots[0].imageRefs.count, 2)
        XCTAssertEqual(shots[1].prompt, "[图1客栈][甲]\n第2段，甲在客栈。", "第 2 段只用到客栈：甲不在它的素材里，不匹配")
        XCTAssertEqual(shots[1].imageRefs.count, 1)
        XCTAssertEqual(run.matches.count, 2)
        XCTAssertEqual(run.matches.values.map(\.matched.count).sorted(), [1, 2])
    }

    // MARK: 重做（一键推进不是只进不退：做完的步骤可以重做，再接着往后推）

    private struct Boom: LocalizedError { var errorDescription: String? { "AI 超时了" } }

    private func redo(_ f: Fixture, _ step: String) async {
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id, redo: step)
        await f.runner.wait(project: f.key, episode: f.episode.id)
    }

    private func phase(_ f: Fixture) -> WorkbenchRunner.Phase? { f.runner.run(project: f.key, episode: f.episode.id)?.phase }

    func testRedoInferenceFromTheSubmitGateRunsOnlyInferenceAndClearsTheFingerprints() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        XCTAssertEqual(phase(f), .waitingSubmit)
        // 假装这些段的承接指纹都在（真流程推理完会写）
        var archive = try XCTUnwrap(f.app.pipelineArchive(for: f.key))
        var work = SimplePipeline.work(in: archive, index: 0)
        for i in work.segments.indices { work.segments[i].continuityKey = "k\(i)" }
        SimplePipeline.save(work, to: &archive)
        f.app.savePipelineArchive(archive, for: f.key)

        var keysSeenByInference: [String] = []
        let fakeInfer = f.runner.hooks.infer
        f.runner.hooks.infer = { app, project, index in
            let a = app.pipelineArchive(for: project)!
            keysSeenByInference = SimplePipeline.work(in: a, index: index).segments.map(\.continuityKey)
            fakeInfer(app, project, index)
        }
        await redo(f, "推理分镜")
        XCTAssertEqual(f.counter.infer, 2)
        XCTAssertEqual(keysSeenByInference, ["", ""], "重做时每段的承接指纹被清掉，旧流程才会重推")
        XCTAssertEqual([f.counter.split, f.counter.extract, f.counter.images], [1, 1, 2], "前面的步骤不动")
        XCTAssertEqual(phase(f), .waitingSubmit)
        XCTAssertTrue(f.runner.run(project: f.key, episode: f.episode.id)?.redo.isEmpty == true, "做成了就不再算重做中")
    }

    func testRedoInferenceDoesNotReopenAnAlreadyConfirmedPickGate() async throws {
        let f = fixture()
        let first = try await go(f)
        XCTAssertEqual(first.phase, .waitingPick)
        var picks: [UUID: UUID] = [:]
        for id in first.generated { picks[id] = f.app.imageItems.first { $0.id == id }?.latestResult?.id }
        f.runner.confirmPicks(app: f.app, project: f.key, episode: f.episode.id, picks: picks)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(phase(f), .waitingSubmit)

        await redo(f, "推理分镜")
        XCTAssertEqual(phase(f), .waitingSubmit, "挑过的定妆图不会再弹一遍")
        XCTAssertEqual(f.counter.infer, 2)
    }

    func testRedoExtractionKeepsTheImages() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        await redo(f, "提取素材")
        XCTAssertEqual(f.counter.extract, 2)
        XCTAssertEqual(f.counter.images, 2, "图不重出（想重出请重做「出图」）")
        XCTAssertEqual(phase(f), .waitingSubmit)
    }

    func testRedoImagesRegeneratesEverythingAndReopensThePickGateForTheNewOnes() async throws {
        let f = fixture()
        let first = try await go(f)
        var picks: [UUID: UUID] = [:]
        for id in first.generated { picks[id] = f.app.imageItems.first { $0.id == id }?.latestResult?.id }
        f.runner.confirmPicks(app: f.app, project: f.key, episode: f.episode.id, picks: picks)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(phase(f), .waitingSubmit)

        await redo(f, "出图")
        XCTAssertEqual(f.counter.images, 4, "本集 2 个设定各重新出一张")
        let run = try XCTUnwrap(f.runner.run(project: f.key, episode: f.episode.id))
        XCTAssertEqual(run.phase, .waitingPick, "重新出了图，要重新挑")
        XCTAssertEqual(run.generated.count, 2)
        for id in run.generated { XCTAssertEqual(f.app.imageItems.first { $0.id == id }?.results.count, 2, "旧图保留成历史版本") }
        XCTAssertEqual(f.counter.infer, 1, "还没挑，不会往下推理（仍是第一轮那 1 次）")
    }

    func testRetryAfterAFailedRedrawOnlyRegeneratesTheOnesThatFailed() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        var calls: [String] = []
        let instant = f.runner.hooks.generateImage
        f.runner.hooks.generateImage = { app, id in
            let name = app.imageItems.first { $0.id == id }?.name ?? ""
            calls.append(name)
            if name == "客栈" {
                if let i = app.imageItems.firstIndex(where: { $0.id == id }) { app.imageItems[i].status = .failed }
            } else { instant(app, id) }
        }
        await redo(f, "出图")
        guard case .failed(let step, _)? = phase(f) else { return XCTFail("应该停在出图，实际 \(String(describing: phase(f)))") }
        XCTAssertEqual(step, "出图")
        XCTAssertEqual(Set(calls), ["客栈", "甲"])

        calls = []
        f.runner.hooks.generateImage = { app, id in
            calls.append(app.imageItems.first { $0.id == id }?.name ?? "")
            instant(app, id)
        }
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(calls, ["客栈"], "出成功的「甲」不再重出")
        XCTAssertEqual(phase(f), .waitingSubmit)
    }

    func testAFailedRedoStaysPendingUntilItSucceeds() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)
        let fakeExtract = f.runner.hooks.extract
        // 走真实的流程（它会记「这次出错了」），AI 那一步抛错
        f.runner.hooks.extract = { app, project, index in
            f.counter.extract += 1
            app.pipelineFlow.extract(app: app, project: project, episodeIndex: index, chat: { _, _ in throw Boom() })
        }
        await redo(f, "提取素材")
        guard case .failed(let step, let message)? = phase(f) else { return XCTFail("应该失败，实际 \(String(describing: phase(f)))") }
        XCTAssertEqual(step, "提取素材")
        XCTAssertTrue(message.contains("AI 超时了"), message)
        XCTAssertEqual(f.runner.run(project: f.key, episode: f.episode.id)?.redo, ["提取素材"], "没成功，重做记着")

        f.runner.hooks.extract = fakeExtract
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id)     // 直接「继续推进」
        await f.runner.wait(project: f.key, episode: f.episode.id)
        XCTAssertEqual(phase(f), .waitingSubmit)
        XCTAssertTrue(f.runner.run(project: f.key, episode: f.episode.id)?.redo.isEmpty == true)
    }

    func testOnlyExtractImagesAndInferenceCanBeRedone() async throws {
        let f = fixture()
        f.runner.start(app: f.app, project: f.key, episode: f.episode.id, redo: "分段")
        XCTAssertNil(f.runner.run(project: f.key, episode: f.episode.id), "分段不在可重做之列：什么都不会发生")
        XCTAssertEqual(f.counter.split, 0)
    }

    func testRunAlsoGeneratesImagesForSettingsUsedBySegmentsButNotExtracted() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        // 项目里有个「监护仪」道具设定（生图卡片已建、没有图），段落里写了它，但这次提取没提取到它
        var item = ImageGenItem(projectKey: f.key, type: .prop, name: "监护仪", prompt: "台式医疗监护仪")
        item.status = .pending
        f.app.imageItems.append(item)
        let split = f.runner.hooks.splitDuration
        f.runner.hooks.splitDuration = { app, project, index in
            split(app, project, index)
            var archive = app.pipelineArchive(for: project)!
            var work = SimplePipeline.work(in: archive, index: index)
            work.segments[0].assetNames.append("监护仪")
            SimplePipeline.save(work, to: &archive)
            app.savePipelineArchive(archive, for: project)
        }
        try await go(f)
        XCTAssertEqual(f.counter.images, 3, "客栈、甲，加上段落里用到的监护仪")
        XCTAssertFalse(f.app.imageItems.first { $0.projectKey == f.key && $0.name == "监护仪" }?.results.isEmpty ?? true)
    }

    // MARK: 开始前的说明

    func testPlanForAFreshEpisodeListsEveryAutomaticStepAndBothGates() throws {
        let f = fixture()
        let plan = WorkbenchRunner.plan(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertTrue(plan.needsConfirm)
        XCTAssertEqual(plan.lines.count, 5, "分段、提取、出图（张数未知）、推理、匹配素材")
        XCTAssertTrue(plan.lines.contains { $0.contains("张数提取后才知道") })
        XCTAssertEqual(plan.gates.count, 2)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testPlanSaysHowManyImagesWillBeGeneratedOnceExtracted() throws {
        let f = fixture()
        f.runner.hooks.splitDuration(f.app, f.key, 0)
        f.runner.hooks.extract(f.app, f.key, 0)
        let plan = WorkbenchRunner.plan(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertEqual(plan.lines.count, 3, "只剩出图、推理和匹配素材")
        XCTAssertTrue(plan.lines.contains { $0.contains("2 个设定还没有图") && $0.contains("2 张图") }, "\(plan.lines)")
        XCTAssertTrue(plan.gates.contains { $0.contains("挑定妆图") })
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        let auto = WorkbenchRunner.plan(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertTrue(auto.gates.contains { $0.contains("自动选最新") }, "勾了自动选最新：说明里不再说会停下挑图")
    }

    func testPlanWarnsAboutAMissingImageModel() throws {
        let f = fixture(imageModel: false)
        let plan = WorkbenchRunner.plan(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertTrue(plan.warnings.contains { $0.contains("图片模型") })
    }

    func testPlanNeedsNoConfirmationWhenNothingAutomaticIsLeft() async throws {
        let f = fixture()
        UserDefaults.standard.set(true, forKey: WorkbenchRunner.autoPickKey)
        try await go(f)            // 一路做到「提交视频」的闸门：分段 / 素材 / 图 / 提示词都有了
        let plan = WorkbenchRunner.plan(app: f.app, project: f.key, episode: f.episode.id)
        XCTAssertFalse(plan.needsConfirm, "只剩提交闸门：不需要先确认")
        XCTAssertEqual(plan.gates.count, 1)
    }
}
