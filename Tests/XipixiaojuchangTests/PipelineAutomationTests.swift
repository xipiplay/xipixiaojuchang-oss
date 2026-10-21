import XCTest
@testable import Xipixiaojuchang

final class PipelineAutomationTests: XCTestCase {

    // MARK: - 1. 命令行参数解析测试

    func testRunOptionsParsing() throws {
        let args = ["app", "--run", "--from", "2", "--to", "4", "--archive", "/tmp/archive.json", "--interactive"]
        let options = try RunOptions.parse(args)

        XCTAssertEqual(options.from, 2)
        XCTAssertEqual(options.to, 4)
        XCTAssertEqual(options.archive?.path, "/tmp/archive.json")
        XCTAssertTrue(options.interactive)
        XCTAssertTrue(options.report.path.contains(".verification/run-报告-"))

        let range = try options.range(totalEpisodes: 5)
        XCTAssertEqual(range, 2...4)

        // 校验 --episode 单集快捷参数
        let epArgs = ["app", "--run", "--episode", "3"]
        let epOptions = try RunOptions.parse(epArgs)
        XCTAssertEqual(try epOptions.range(totalEpisodes: 5), 3...3)

        // 校验 --all 全剧参数
        let allArgs = ["app", "--run", "--all"]
        let allOptions = try RunOptions.parse(allArgs)
        XCTAssertEqual(try allOptions.range(totalEpisodes: 5), 1...5)

        // 校验 --help 抛出 help
        let helpArgs = ["app", "--run", "--help"]
        XCTAssertThrowsError(try RunOptions.parse(helpArgs)) { error in
            guard case RunError.help = error else {
                XCTFail("预期抛出 RunError.help，实际收到：\(error)")
                return
            }
        }

        // 校验非法范围异常
        let badArgs = ["app", "--run", "--from", "5", "--to", "2"]
        XCTAssertThrowsError(try RunOptions.parse(badArgs))
    }

    // MARK: - 2. 自动化安全策略测试（沿用自动过、变体安全停）

    func testRunRulesPendingPolicyOnVariantAndReuse() {
        let room = DictEntry(kind: "场景", name: "大堂", desc: "日常陈设", identity: "木质古建筑", fromEp: 1)
        let hero = DictEntry(kind: "角色", name: "李捕头", desc: "捕快服", identity: "浓眉大眼", fromEp: 1, stage: "30岁", identityVersion: 1)
        let dict = [room, hero]

        // 场景 A：纯沿用合规数据 -> pending 为空，允许自动推进
        var workA = EpWork()
        workA.descDraft = [
            DescUpdate(kind: "场景", name: "大堂", action: "沿用", order: 1),
            DescUpdate(kind: "角色", name: "李捕头", action: "沿用", order: 2)
        ]
        let pendingA = RunRules.pending(
            step: 0,
            episode: 1,
            text: "李捕头走入大堂，环顾四周。",
            work: workA,
            dictionary: dict,
            seconds: 15
        )
        XCTAssertTrue(pendingA.isEmpty, "全部沿用且无矛盾时应无 pending 障碍")

        // 场景 B：出现变体 -> 自动化红线生效，停下出待拍板清单
        var workB = EpWork()
        workB.descDraft = [
            DescUpdate(kind: "场景", name: "大堂", action: "沿用", order: 1),
            DescUpdate(kind: "角色", name: "李捕头", action: "变体", variantName: "李捕头·重伤", evidence: "浑身血迹", order: 2)
        ]
        let pendingB = RunRules.pending(
            step: 0,
            episode: 1,
            text: "李捕头浑身血迹，跌跌撞撞走入大堂。",
            work: workB,
            dictionary: dict,
            seconds: 15
        )
        XCTAssertFalse(pendingB.isEmpty, "出现变体时必须停下出待拍板清单")
        XCTAssertTrue(pendingB.contains { $0.kind == "变体" })
        XCTAssertTrue(pendingB.contains { $0.reviewable })

        // 场景 C：原文明示时间切换词汇（闪回/回忆），但全部沿用 -> 拦截出时间版本待审
        let pendingC = RunRules.pending(
            step: 0,
            episode: 1,
            text: "李捕头陷入回忆，想起二十年前的那一天。",
            work: workA,
            dictionary: dict,
            seconds: 15
        )
        XCTAssertTrue(pendingC.contains { $0.kind == "时间版本待审" })
    }

    // MARK: - 3. 全链路自动化执行测试

    func testRunPipelineEndToEndOneEpisode() async throws {
        let room = DictEntry(kind: "场景", name: "正堂", desc: "日常", identity: "古典堂屋", fromEp: 1)
        let dict = [room]

        let shotText = "[正堂][无][无]\n【画面状态】正堂：日常。\n【角色初始站位与朝向】室内空无一人。\n镜头1：全景，阳光洒在地面。"
        var boundSeg = BoundSegment(
            text: "阳光洒在地面。",
            openingSceneId: room.id,
            closingSceneId: room.id,
            reviewed: true
        )
        boundSeg.bindings = [
            SegmentBinding(
                entryId: room.id,
                internalName: "正堂",
                kind: "场景",
                scope: "全段",
                evidence: "阳光洒在地面。",
                usage: "出镜",
                approved: true,
                lockedEntryKey: BindingRules.entryKey(room)
            )
        ]
        try BindingRules.lock(&boundSeg, dictionary: dict)

        var work = EpWork()
        work.descDraft = [DescUpdate(kind: "场景", name: "正堂", action: "沿用", order: 1)]
        work.segmentsRaw = "阳光洒在地面。"
        work.boundSegments = [boundSeg]
        work.shots = [shotText]
        work.checked = [shotText]

        var archive = ProjectPipelineArchive(
            episodes: [Episode(title: "第一集", text: "阳光洒在地面。")],
            dictionary: dict,
            works: [work],
            segmentSeconds: 15
        )

        let reportURL = URL(fileURLWithPath: "/tmp/test-run-report-\(UUID().uuidString).json")
        let options = RunOptions(
            from: 1,
            to: 1,
            archive: URL(fileURLWithPath: "/tmp/fake-archive.json"),
            report: reportURL,
            signal: URL(fileURLWithPath: "/tmp/fake-signal")
        )

        let config = PipelineAISettings(baseURL: "https://example.com", apiKey: "test", model: "test-model")

        let (report, newShots, _) = try await RunAutomationService.runPipeline(
            archive: &archive,
            options: options,
            config: config,
            projectKey: "test-auto-proj"
        )

        // 验证执行结果
        XCTAssertEqual(report.summary.completed, 1)
        XCTAssertEqual(report.summary.stopped, 0)
        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.episodes.count, 1)
        guard let firstEp = report.episodes.first else {
            XCTFail("报告未包含任何分集")
            return
        }
        XCTAssertEqual(firstEp.status, "完成")
        XCTAssertFalse(newShots.isEmpty, "必须成功直建生成分镜卡")
        guard let firstShot = newShots.first else { return }
        XCTAssertEqual(firstShot.numbering?.a, 1)
        XCTAssertEqual(firstShot.numbering?.b, 1)

        // 验证报告文件已生成落盘
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        try? FileManager.default.removeItem(at: reportURL)
    }

    func testRunPipelineStopsOnVariant() async throws {
        let hero = DictEntry(kind: "角色", name: "张三", desc: "便服", identity: "瘦高个", fromEp: 1)
        let dict = [hero]

        var work = EpWork()
        // 含有变体，预期在步骤 0 停车
        work.descDraft = [
            DescUpdate(kind: "角色", name: "张三", action: "变体", variantName: "张三·夜行衣", evidence: "换上黑衣", order: 1)
        ]

        var archive = ProjectPipelineArchive(
            episodes: [Episode(title: "第一集", text: "张三换上黑衣潜入夜色。")],
            dictionary: dict,
            works: [work],
            segmentSeconds: 15
        )

        let reportURL = URL(fileURLWithPath: "/tmp/test-stop-report-\(UUID().uuidString).json")
        let options = RunOptions(
            from: 1,
            to: 1,
            archive: URL(fileURLWithPath: "/tmp/fake-archive.json"),
            report: reportURL,
            signal: URL(fileURLWithPath: "/tmp/fake-signal")
        )

        let config = PipelineAISettings(baseURL: "https://example.com", apiKey: "test", model: "test-model")

        let (report, _, _) = try await RunAutomationService.runPipeline(
            archive: &archive,
            options: options,
            config: config,
            projectKey: "test-stop-proj"
        )

        // 验证停车与待拍板清单
        XCTAssertEqual(report.summary.completed, 0)
        XCTAssertEqual(report.summary.stopped, 1)
        XCTAssertEqual(report.episodes[0].status, "停车")
        XCTAssertFalse(report.episodes[0].pending.isEmpty)
        XCTAssertTrue(report.episodes[0].pending.first?.kind == "变体")

        try? FileManager.default.removeItem(at: reportURL)
    }
}
