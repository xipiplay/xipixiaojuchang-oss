import XCTest
@testable import Xipixiaojuchang

/// D08（2026-10-23 用户定）：批量设置参数点「应用」后先当草稿；提交确认点「取消」就改回原值，
/// 点「提交」/「只保存参数」才留下。只改回参数几项，卡片别的内容不动。
@MainActor
final class BatchParamDraftTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "batch-param-draft-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
    }

    private func addShot(model: String, duration: Int) -> ShotDraft {
        var shot = ShotDraft(projectKey: key, prompt: "[客厅][周承山][ ]\n正文")
        shot.model = model
        shot.duration = duration
        shot.paramsDirty = false
        app.shots.append(shot)
        return shot
    }
    private func shot(_ id: UUID) -> ShotDraft { app.shots.first { $0.id == id }! }
    private func item(_ id: UUID) -> ImageGenItem { app.imageItems.first { $0.id == id }! }

    func testCancellingTheSubmitConfirmPutsTheShotParamsBack() {
        let a = addShot(model: "模型甲", duration: 15)
        let b = addShot(model: "模型乙", duration: 30)
        let untouched = addShot(model: "模型丙", duration: 15)
        let config = BatchParamConfig(model: "新模型", resolution: shot(a.id).resolution, aspectRatio: shot(a.id).aspectRatio, duration: 10)
        app.draftBatchParameters(config, ids: [a.id, b.id])
        XCTAssertEqual(shot(a.id).model, "新模型", "草稿先写进卡片，检查和提交都读卡片")
        XCTAssertEqual(shot(b.id).duration, 10)

        // 草稿期间卡片别的内容变了（比如后台改了提示词），改回参数时不能把它盖掉
        app.shots[app.shots.firstIndex { $0.id == a.id }!].prompt = "后来改的提示词"

        app.revertBatchParamDraft()
        XCTAssertEqual(shot(a.id).model, "模型甲")
        XCTAssertEqual(shot(a.id).duration, 15)
        XCTAssertFalse(shot(a.id).paramsDirty)
        XCTAssertEqual(shot(b.id).model, "模型乙")
        XCTAssertEqual(shot(b.id).duration, 30)
        XCTAssertEqual(shot(a.id).prompt, "后来改的提示词", "只改回参数几项")
        XCTAssertEqual(shot(untouched.id).model, "模型丙")
        XCTAssertNil(app.batchParamDraftOriginals)
    }

    func testSubmittingOrSavingOnlyKeepsTheParams() {
        let a = addShot(model: "模型甲", duration: 15)
        let config = BatchParamConfig(model: "新模型", resolution: shot(a.id).resolution, aspectRatio: shot(a.id).aspectRatio, duration: 10)
        app.draftBatchParameters(config, ids: [a.id])
        app.keepBatchParamDraft()
        app.revertBatchParamDraft()                    // 已经算数了：再「改回」什么都不做
        XCTAssertEqual(shot(a.id).model, "新模型")
        XCTAssertEqual(shot(a.id).duration, 10)
        XCTAssertTrue(shot(a.id).paramsDirty)
    }

    func testCancellingPutsTheImageParamsBack() {
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "红衣少女")
        card.model = "图片模型甲"
        card.paramsDirty = false
        app.imageItems.append(card)
        let otherAspect = ImageAspect.allCases.first { $0 != card.aspectRatio }!
        let otherQuality = ImageQuality.allCases.first { $0 != card.quality }!
        app.draftBatchImageParams(ids: [card.id], model: "图片模型乙", aspect: otherAspect, quality: otherQuality)
        XCTAssertEqual(item(card.id).model, "图片模型乙")

        app.revertBatchParamDraft()
        XCTAssertEqual(item(card.id).model, "图片模型甲")
        XCTAssertEqual(item(card.id).aspectRatio, card.aspectRatio)
        XCTAssertEqual(item(card.id).quality, card.quality)
        XCTAssertFalse(item(card.id).paramsDirty)
    }
}
