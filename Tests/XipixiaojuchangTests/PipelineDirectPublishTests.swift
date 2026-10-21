import XCTest
@testable import Xipixiaojuchang

final class PipelineDirectPublishTests: XCTestCase {

    private func makeTestDictionary() -> [DictEntry] {
        var room = DictEntry(
            kind: "场景",
            name: "老茶馆",
            desc: "阳光透过窗棂",
            identity: "青砖灰瓦老建筑，木质桌椅陈设",
            fromEp: 1
        )
        room.sceneLayout = SceneLayoutData(
            text: "正门在画面左侧。八仙桌置于画面中心。后景为通往后院的木门。主要光源来自左侧窗户。",
            relativePosition: "",
            reviewed: true,
            source: "测试",
            uncertainties: "",
            lastError: ""
        )

        var subRoom = DictEntry(
            kind: "场景",
            name: "老茶馆·后柜台",
            desc: "账本堆放整齐",
            identity: room.identity,
            fromEp: 1,
            basedOn: "老茶馆",
            relation: "子场景"
        )
        subRoom.sceneLayout = SceneLayoutData(
            text: "木质柜台横向贯穿画面中景，背后为整面药柜/茶叶隔板。",
            relativePosition: "位于老茶馆正门右后方通道旁",
            reviewed: true,
            source: "测试",
            uncertainties: "",
            lastError: ""
        )

        let chen = DictEntry(
            kind: "角色",
            name: "陈掌柜",
            desc: "灰布长衫",
            identity: "方脸浓眉，目光坚定",
            fromEp: 1,
            stage: "50岁，花白胡须",
            identityVersion: 1
        )

        let youngChen = DictEntry(
            kind: "角色",
            name: "陈掌柜·年轻时",
            desc: "粗布短打",
            identity: chen.identity,
            fromEp: 1,
            basedOn: "陈掌柜",
            relation: "变体",
            stage: "25岁，短黑发",
            identityVersion: 1
        )

        return [room, subRoom, chen, youngChen]
    }

    // MARK: - 1. 生图条目测试

    func testPublishImageItemsEarlyAndPreserveGenerated() {
        let dict = makeTestDictionary()
        let projectKey = "test-project-1"

        // 初始发布：应新建 4 个条目
        let (items1, res1) = DirectPublishService.publishImageItems(
            projectKey: projectKey,
            entries: dict,
            existingItems: []
        )
        XCTAssertEqual(res1.createdItems.count, 4)
        XCTAssertEqual(res1.updatedItems.count, 0)
        XCTAssertEqual(res1.conflicts.count, 0)

        // 模拟用户生成了其中一个条目
        var workingItems = items1
        let chenIdx = workingItems.firstIndex(where: { $0.name == "陈掌柜" })!
        workingItems[chenIdx].results.append(ImageGenResult(localPath: "/tmp/chen.png", prompt: "历史生成提示词"))

        // 再次发布（假设有轻微更新），已生成条目不得覆盖
        let (items2, res2) = DirectPublishService.publishImageItems(
            projectKey: projectKey,
            entries: dict,
            existingItems: workingItems
        )
        XCTAssertEqual(res2.conflicts.count, 1)
        XCTAssertTrue(res2.conflicts.first?.contains("陈掌柜") == true)
        let protectedChen = items2.first(where: { $0.name == "陈掌柜" })!
        XCTAssertEqual(protectedChen.results.count, 1)
    }

    func testVariantBaseImageReferenceLinking() {
        let dict = makeTestDictionary()
        let projectKey = "test-project-variant"

        // 素材库中存在基条目「陈掌柜」
        let baseLibItem = LibraryItem(
            kind: .image,
            localPath: "/tmp/chen.png",
            name: "陈掌柜",
            projectKey: projectKey
        )

        let (items, _) = DirectPublishService.publishImageItems(
            projectKey: projectKey,
            entries: dict,
            existingItems: [],
            library: [baseLibItem]
        )

        // 验证变体条目「陈掌柜·年轻时」是否成功关联基图为参考图
        let variantItem = items.first(where: { $0.name == "陈掌柜·年轻时" })
        XCTAssertNotNil(variantItem)
        XCTAssertEqual(variantItem?.imageRefs.count, 1)
        XCTAssertEqual(variantItem?.imageRefs.first?.libraryItemID, baseLibItem.id)
    }

    // MARK: - 2. 分镜卡直导与建卡测试

    func testDirectPublishEpisodeShots() {
        let dict = makeTestDictionary()
        let projectKey = "test-project-shots"

        let finalShots = [
            "[老茶馆][陈掌柜][无]\n【画面状态】陈掌柜：50岁，花白胡须；灰布长衫。\n【角色初始站位与朝向】陈掌柜立于八仙桌旁。\n镜头1：中景，陈掌柜擦拭桌面。",
            "[老茶馆·后柜台][陈掌柜·年轻时][无]\n【画面状态】陈掌柜：25岁，短黑发；粗布短打。\n【角色初始站位与朝向】年轻掌柜在柜台后翻看账目。\n镜头1：特写，柜台上泛黄的账册。"
        ]

        var boundSeg1 = BoundSegment(text: "原文字段1")
        boundSeg1.bindings = [
            SegmentBinding(entryId: dict.first(where: { $0.name == "老茶馆" })!.id, internalName: "老茶馆", kind: "场景", usage: "出镜"),
            SegmentBinding(entryId: dict.first(where: { $0.name == "陈掌柜" })!.id, internalName: "陈掌柜", kind: "角色", usage: "出镜")
        ]

        var boundSeg2 = BoundSegment(text: "原文字段2")
        boundSeg2.bindings = [
            SegmentBinding(entryId: dict.first(where: { $0.name == "老茶馆·后柜台" })!.id, internalName: "老茶馆·后柜台", kind: "场景", usage: "出镜"),
            SegmentBinding(entryId: dict.first(where: { $0.name == "陈掌柜·年轻时" })!.id, internalName: "陈掌柜·年轻时", kind: "角色", usage: "出镜")
        ]

        // 首次直建分镜卡：零 AI 纯 Swift 直建
        let (shots1, lib1, res1) = DirectPublishService.publishEpisodeShotsDirect(
            projectKey: projectKey,
            episodeIndex: 1,
            durationSeconds: 15,
            finalShots: finalShots,
            boundSegments: [boundSeg1, boundSeg2],
            dictionary: dict,
            existingShots: [],
            existingLibrary: []
        )

        XCTAssertEqual(res1.createdShots.count, 2)
        XCTAssertEqual(res1.createdLibraryCount, 4) // 老茶馆, 陈掌柜, 老茶馆·后柜台, 陈掌柜·年轻时
        XCTAssertEqual(shots1.count, 2)
        XCTAssertEqual(shots1[0].numbering?.a, 1)
        XCTAssertEqual(shots1[0].numbering?.b, 1)
        XCTAssertEqual(shots1[1].numbering?.a, 1)
        XCTAssertEqual(shots1[1].numbering?.b, 2)
        XCTAssertEqual(shots1[0].imageRefs.count, 2)

        // 模拟第 1 张分镜已有生成任务
        var existingShots = shots1
        existingShots[0].taskID = "task-gen-001"

        // 再次发布：第 1 张卡片由于有任务，保护跳过；第 2 张由于未变动，跳过；整体幂等不重复创建
        let (shots2, _, res2) = DirectPublishService.publishEpisodeShotsDirect(
            projectKey: projectKey,
            episodeIndex: 1,
            durationSeconds: 15,
            finalShots: finalShots,
            boundSegments: [boundSeg1, boundSeg2],
            dictionary: dict,
            existingShots: existingShots,
            existingLibrary: lib1
        )

        XCTAssertEqual(res2.createdShots.count, 0)
        XCTAssertEqual(res2.conflicts.count, 1)
        XCTAssertTrue(res2.conflicts.first?.contains("第 1 集第 1 段已有生成任务") == true)
        XCTAssertEqual(shots2.count, 2)
    }

    // MARK: - 3. 场景布局与空间约束测试

    func testSceneLayoutEffectiveAndInjection() {
        let dict = makeTestDictionary()
        let subRoom = dict.first(where: { $0.name == "老茶馆·后柜台" })!

        // 验证子场景正确继承父场景布局
        let effective = LayoutRules.effective(subRoom, dictionary: dict)
        XCTAssertTrue(effective.contains("基场景 老茶馆（以基图画面左右为准）："))
        XCTAssertTrue(effective.contains("正门在画面左侧"))
        XCTAssertTrue(effective.contains("子区 老茶馆·后柜台：相对位置：位于老茶馆正门右后方通道旁"))
        XCTAssertTrue(effective.contains("木质柜台横向贯穿画面中景"))

        // 验证完整句子截取
        let shortText = LayoutRules.limited(effective, characters: 40)
        XCTAssertFalse(shortText.isEmpty)

        // 验证分镜提示词空间注入
        var seg = BoundSegment(text: "测试分段")
        seg.bindings = [
            SegmentBinding(entryId: subRoom.id, internalName: subRoom.name, kind: "场景", usage: "出镜", approved: true)
        ]
        let injection = LayoutRules.injection(seg, dictionary: dict, characterLimit: 300)
        XCTAssertTrue(injection.contains("【场景布局】"))
        XCTAssertTrue(injection.contains("本段场景 老茶馆·后柜台"))
        XCTAssertTrue(injection.contains("正门在画面左侧"))
    }

    func testSceneLayoutVisionParsing() throws {
        let rawJson = """
        ```json
        {
            "layout": "正门在画面右侧，窗户朝南。柜台在左前方。通道直通后堂。",
            "uncertainties": "右侧暗部不可辨认是否还有角门"
        }
        ```
        """
        let parsed = try LayoutRules.parseVision(rawJson)
        XCTAssertEqual(parsed.text, "正门在画面右侧，窗户朝南。柜台在左前方。通道直通后堂。")
        XCTAssertEqual(parsed.uncertainties, "右侧暗部不可辨认是否还有角门")
        XCTAssertFalse(parsed.reviewed)
        XCTAssertEqual(parsed.source, "看图提取")
    }
}
