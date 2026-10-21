import XCTest
@testable import Xipixiaojuchang

final class PipelineStepWorkflowTests: XCTestCase {

    // MARK: - 测试辅助夹具

    private func makeTestDictionary() -> [DictEntry] {
        let oldChen = DictEntry(
            kind: "角色",
            name: "陈掌柜",
            desc: "灰长衫",
            identity: "方脸、直鼻、深褐瞳；写实风格",
            fromEp: 1,
            stage: "60岁，花白发，皱纹明显",
            identityVersion: 1
        )
        let youngChen = DictEntry(
            kind: "角色",
            name: "陈掌柜·二十年前",
            desc: "靛蓝色长衫",
            identity: oldChen.identity,
            fromEp: 1,
            basedOn: "陈掌柜",
            relation: "变体",
            stage: "40岁，黑发，肤质平整",
            identityVersion: 1
        )
        let room = DictEntry(
            kind: "场景",
            name: "堂屋",
            desc: "完好无损",
            identity: "青砖地面、八仙桌、条案；自然光",
            fromEp: 1
        )
        let teacup = DictEntry(
            kind: "道具",
            name: "茶盏",
            desc: "完好，釉面光亮",
            identity: "青花瓷茶盏，空白背景",
            fromEp: 1
        )
        return [oldChen, youngChen, room, teacup]
    }

    private func makeSegment(
        entries: [DictEntry],
        text: String = "现在回忆堂屋茶盏",
        aliases: [String] = []
    ) -> BoundSegment {
        let scene = entries.first { $0.kind == "场景" }!
        return BoundSegment(
            text: text,
            bindings: entries.enumerated().map { i, e in
                SegmentBinding(
                    entryId: e.id,
                    internalName: e.name,
                    kind: e.kind,
                    submitNameOverride: aliases.indices.contains(i) ? aliases[i] : "",
                    evidence: text
                )
            },
            openingSceneId: scene.id,
            closingSceneId: scene.id
        )
    }

    // MARK: - 1. 标记清理与基本辅助

    func testStripMissingMarkers() {
        XCTAssertEqual(PipelineRules.stripMissingMarkers("茶盏〔词典缺:茶盏〕"), "茶盏")
        XCTAssertEqual(PipelineRules.stripMissingMarkers("茶盏〔词典缺：茶盏〕"), "茶盏")
        XCTAssertEqual(PipelineRules.stripMissingMarkers("〔词典缺:茶盏〕"), "茶盏")
        XCTAssertEqual(PipelineRules.stripMissingMarkers("〔词典缺：茶盏〕"), "茶盏")
        XCTAssertEqual(PipelineRules.stripMissingMarkers("[堂屋][沈砚〔词典缺:沈砚〕][〔词典缺：茶盏〕]。茶盏〔词典缺:茶盏〕"), "[堂屋][沈砚][茶盏]。茶盏")
        XCTAssertEqual(PipelineRules.stripMissingMarkers("沈砚说：茶盏在这里。"), "沈砚说：茶盏在这里。")
    }

    // MARK: - 2. 15s 与 30s 时长提示词生成

    func testDurationPrompt15And30() {
        let original = "按 30 秒分段。6-10 句。30s 分镜 12-16 个镜头。00:00-00:30 / 00:30-01:00 / 01:00-01:30"
        let shortPrompt = PipelineRules.durationPrompt(original, seconds: 15)
        XCTAssertTrue(shortPrompt.contains("15 秒"))
        XCTAssertTrue(shortPrompt.contains("3-5"))
        XCTAssertTrue(shortPrompt.contains("6-8"))
        XCTAssertTrue(shortPrompt.contains("00:00-00:15 / 00:15-00:30 / 00:30-00:45"))
        XCTAssertTrue(shortPrompt.contains("每段固定 15 秒"))

        let standardPrompt = PipelineRules.durationPrompt(original, seconds: 30)
        XCTAssertTrue(standardPrompt.hasPrefix(original))
        XCTAssertTrue(standardPrompt.contains("每段固定 30 秒"))
    }

    // MARK: - 3. 描述三层逻辑与变体校验

    func testDescUpdateThreeLayersAndVariantIntegrity() {
        let base = DictEntry(kind: "角色", name: "沈砚", desc: "布衣", identity: "面容清秀、剑眉星目", fromEp: 1, stage: "20岁，挺拔", identityVersion: 1)
        let dict = [base]

        // 变体骨相一致性：必须与基图一致
        var update = DescUpdate(
            kind: "角色",
            name: "沈砚",
            action: "变体",
            variantName: "沈砚·官服",
            evidence: "换上红色官服",
            identity: "被篡改的骨相",
            desc: "绯色官袍",
            stage: "20岁，挺拔",
            identityVersion: 1
        )
        XCTAssertEqual(PipelineRules.identityIssue(for: update, in: dict), "身份与基图不一致")

        // 修正为基图骨相
        update.identity = PipelineRules.baseIdentity(for: update, in: dict)!
        XCTAssertNil(PipelineRules.identityIssue(for: update, in: dict))

        // 时间状态改变必须给出修订点与依据
        update.stage = "40岁，蓄须"
        update.stageChanges = []
        XCTAssertNotNil(PipelineRules.descriptionIssue(for: update, in: dict))

        update.stageChanges = ["20岁改为40岁", "增加短须"]
        XCTAssertNil(PipelineRules.descriptionIssue(for: update, in: dict))
    }

    // MARK: - 4. 闪回先于基图出现（悬挂引用自动补齐）

    func testFlashbackBeforeBaseResolvesPending() {
        var dictionary: [DictEntry] = []
        let flashback = DescUpdate(
            kind: "角色",
            name: "陈掌柜",
            action: "变体",
            variantName: "陈掌柜·二十年前",
            evidence: "二十年前",
            stage: "40岁黑发",
            stageChanges: ["年轻二十岁"],
            identityVersion: 1
        )

        // 此时基图尚未登场，属于悬挂引用
        XCTAssertNotNil(PipelineRules.pendingBaseMessage(flashback, in: dictionary))
        XCTAssertTrue(PipelineRules.descriptionIssues([flashback], in: dictionary).isEmpty)

        // 应用到第 1 集词典
        PipelineRules.applyDescriptions([flashback], episode: 1, to: &dictionary)
        XCTAssertEqual(dictionary[0].basedOn, "陈掌柜")
        XCTAssertEqual(dictionary[0].identity, "") // 骨相暂留空等待基图

        // 第 2 集现在版本的基图登场
        let baseNow = DescUpdate(
            kind: "角色",
            name: "陈掌柜",
            action: "新增",
            identity: "方脸直鼻深褐瞳",
            stage: "60岁花白发",
            identityVersion: 1
        )
        PipelineRules.applyDescriptions([baseNow], episode: 2, to: &dictionary)

        // 闪回变体应自动解析补齐骨相
        XCTAssertEqual(dictionary[0].identity, "方脸直鼻深褐瞳")
        XCTAssertEqual(dictionary[0].stage, "40岁黑发")
    }

    // MARK: - 5. 同集多个变体顺序与区间计算

    func testTwoChangesInOneEpisodeHaveOrderedLegalIntervals() {
        let identity = "固定骨相"
        let updates = [
            DescUpdate(kind: "角色", name: "甲", action: "新增", identity: identity, desc: "布衣", order: 1),
            DescUpdate(kind: "角色", name: "甲", action: "变体", variantName: "甲·官服", evidence: "换官服", identity: identity, desc: "官服", order: 2),
            DescUpdate(kind: "角色", name: "甲", action: "变体", variantName: "甲·夜行衣", evidence: "换夜行衣", identity: identity, desc: "夜行衣", order: 3)
        ]
        var d: [DictEntry] = []
        PipelineRules.applyDescriptions(updates, episode: 1, to: &d)
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d.map(\.fromOrder), [1, 2, 3])
        XCTAssertEqual(d.map(\.toOrder), [1, 2, nil])
        XCTAssertEqual(d.map(\.toEp), [1, 1, nil])
        XCTAssertTrue(d[1].intervalText.contains("序 2"))
    }

    // MARK: - 6. 段级版本绑定与锁定

    func testSegmentBindingAndLocking() throws {
        let dict = makeTestDictionary()
        var s = makeSegment(entries: [dict[1], dict[2], dict[3]])

        // 未 lock 前 issues 应提示未确认
        XCTAssertFalse(BindingRules.issues(s, dictionary: dict, requireApproval: true).isEmpty)

        // 执行锁定
        try BindingRules.lock(&s, dictionary: dict)
        XCTAssertTrue(s.reviewed)
        XCTAssertTrue(s.bindings.allSatisfy { $0.approved && !$0.lockedEntryKey.isEmpty })
        XCTAssertTrue(BindingRules.issues(s, dictionary: dict, requireApproval: true).isEmpty)

        // 当词典条目发生变化时，锁定失效
        var changedDict = dict
        changedDict[1].stage = "45岁，略微蓄须"
        XCTAssertFalse(BindingRules.issues(s, dictionary: changedDict, requireApproval: true).isEmpty)
    }

    // MARK: - 7. 提交称呼优先级与同段冲突

    func testSubmitNamePriorityAndCollision() throws {
        var dict = makeTestDictionary()
        let youngChen = dict[1]
        var binding = SegmentBinding(entryId: youngChen.id, internalName: youngChen.name, kind: youngChen.kind)

        // 默认自然名应去除“·二十年前”变体后缀，回退至基名
        XCTAssertEqual(BindingRules.submitName(binding, in: dict), "陈掌柜")

        // 条目级覆盖
        dict[1].submitNameOverride = "年轻时的陈掌柜"
        XCTAssertEqual(BindingRules.submitName(binding, in: dict), "年轻时的陈掌柜")

        // 段级绑定覆盖
        binding.submitNameOverride = "二十年前的陈掌柜"
        XCTAssertEqual(BindingRules.submitName(binding, in: dict), "二十年前的陈掌柜")

        // 同段出现两个同名出镜角色必须报错
        let freshDict = makeTestDictionary()
        let collisionSeg = makeSegment(entries: [freshDict[0], freshDict[1], freshDict[2]])
        let issues = BindingRules.issues(collisionSeg, dictionary: freshDict, requireApproval: false)
        XCTAssertTrue(issues.contains { $0.contains("同段同名冲突") })
    }

    // MARK: - 8. 分镜文案渲染与引号台词不可变红线

    func testStateComesFromLockedEntriesAndDialoguesAreImmutable() throws {
        let dict = makeTestDictionary()
        let text = "[陈掌柜]：开门吧。"
        var s = makeSegment(entries: [dict[1], dict[2]], text: text)
        try BindingRules.lock(&s, dictionary: dict)

        let internalDraft = """
        [堂屋][陈掌柜·二十年前][]
        【角色初始站位与朝向】陈掌柜·二十年前在左侧。
        （陈掌柜·二十年前，中文）说："开门吧。"
        必须按照镜头描述和角色台词生成。电影写实风格，[晨光斜照]，无字幕，无音乐，角色说中文。【语言与台词锁定规则｜最高优先级】1. 用户提供的角色台词必须逐字保留，不得翻译、改写、润色、扩写、缩写、调换语序、替换词语。台词必须直接复制原文。2. 不得把中文台词翻译成其他语言后再翻译回来。
        """

        let submitted = try SubmissionRules.render(internalDraft, segment: s, dictionary: dict)

        // 提交稿中不应残留“·”等内部后缀
        XCTAssertFalse(submitted.contains("陈掌柜·二十年前"))
        XCTAssertTrue(submitted.contains("陈掌柜"))

        // 【画面状态】自动插入在第 2 行（头行之后、站位之前）
        let lines = submitted.components(separatedBy: "\n")
        XCTAssertEqual(lines[1], SubmissionRules.stateLine(s, dictionary: dict))
        XCTAssertTrue(lines[1].contains("40岁"))
        XCTAssertTrue(lines[1].contains("靛蓝色长衫"))

        // 台词绝对不可改
        XCTAssertEqual(SubmissionRules.spokenDialogues(submitted), ["开门吧。"])

        // 若分镜修改了台词原文，render 必须抛错拒绝
        let alteredDraft = internalDraft.replacingOccurrences(of: "开门吧。", with: "快开门！")
        XCTAssertThrowsError(try SubmissionRules.render(alteredDraft, segment: s, dictionary: dict))
    }

    // MARK: - 9. 跨集结尾状态与承接

    func testCrossEpisodeContinuityRules() throws {
        let state = EndState(
            episode: 1,
            sceneName: "堂屋",
            positions: "陈掌柜站在柜台左侧",
            axis: "画面左＝陈掌柜，画面右＝大门",
            lightingTime: "傍晚昏黄烛光",
            props: "茶盏放在桌角"
        )
        XCTAssertTrue(state.isComplete)

        // 同场景第 2 集第 0 段应注入承接
        let injection = ContinuityRules.injection(state, episode: 2, segmentIndex: 0, sceneName: "堂屋")
        XCTAssertFalse(injection.isEmpty)
        XCTAssertTrue(injection.contains("上一集结尾状态"))
        XCTAssertTrue(injection.contains("傍晚昏黄烛光"))

        // 不同场景或非第 0 段不注入
        XCTAssertTrue(ContinuityRules.injection(state, episode: 2, segmentIndex: 1, sceneName: "堂屋").isEmpty)
        XCTAssertTrue(ContinuityRules.injection(state, episode: 2, segmentIndex: 0, sceneName: "街道").isEmpty)
    }

    // MARK: - 10. 步骤联动失效与断点续跑

    func testPipelineInvalidateAndPrefixResume() {
        var w = EpWork()
        w.descDraft = [DescUpdate(kind: "角色", name: "沈砚", action: "沿用")]
        w.segmentsRaw = "段落1\n---\n段落2"
        w.shots = ["分镜1", "分镜2"]
        w.checked = ["校验1", "校验2"]
        w.states = Array(repeating: .approved, count: 5)

        // 从步骤 1（分段）失效：重置分段及之后所有下游步骤
        PipelineRules.invalidate(&w, from: 1)
        XCTAssertEqual(w.states, [.approved, .todo, .todo, .todo, .todo])
        XCTAssertTrue(w.segmentsRaw.isEmpty)
        XCTAssertTrue(w.shots.isEmpty)
        XCTAssertTrue(w.checked.isEmpty)
        XCTAssertEqual(w.descDraft.count, 1)

        // 断点续跑：输入键相同时保留已完成的前缀
        w.shotsInputKey = "keyA"
        w.shots = ["分镜1已完成"]
        XCTAssertEqual(PipelineRules.prepareShots(&w, key: "keyA", total: 2), 1)
        XCTAssertEqual(w.shots.count, 1)

        // 输入变更时重置
        XCTAssertEqual(PipelineRules.prepareShots(&w, key: "keyB", total: 2), 0)
        XCTAssertTrue(w.shots.isEmpty)
    }
}
