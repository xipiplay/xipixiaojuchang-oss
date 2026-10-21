import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 素材和提示词的统一规则（2026-10-16 用户定）：**提示词里删素材，素材区的素材不删；只有素材区的素材删了，提示词里的才跟着删**。
/// 起因：二级页面左边「添加」挂了音频，后来在提示词里删掉「音频1是周承山的音色」那行字，音频就从分镜上被悄悄摘掉了，提交时没有音频直链
@MainActor
final class MaterialPromptRuleTests: XCTestCase {
    override func setUp() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = true } }
    override func tearDown() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = false } }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private struct Fixture {
        let app: AppModel
        let shotID: UUID
        let audio: Xipixiaojuchang.LibraryItem
        let key: String
    }

    /// 一集一段：头行有「甲」，甲有一张出过图的卡；素材库里有一段音频
    private func fixture() throws -> Fixture {
        let app = AppModel()
        let key = "rule-" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rule-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: file)
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "红衣少女")
        card.results = [ImageGenResult(localPath: file.path, createdAt: Date())]; card.status = .success
        app.imageItems.append(card)
        var audio = LibraryItem(kind: .audio, localPath: "/tmp/none.wav", fileName: "1.wav", projectKey: key)
        audio.remoteURL = "https://oss.test/1.wav"
        app.library.append(audio)
        let shot = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头1：甲推门进来。")
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 1)
        return Fixture(app: app, shotID: shot.id, audio: audio, key: key)
    }

    private func show(_ app: AppModel) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .environment(\.hoverFeedbackEnabled, false).frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        return (window, host)
    }

    private func wait(_ s: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// 在二级页面的提示词编辑器里改字：点进去、把 `range` 换成 `text`、点外面（失焦就存）
    private func edit(_ window: NSWindow, _ host: NSView, replacing target: String?, with text: String) throws {
        let tv = try XCTUnwrap(views(PromptTextView.self, in: host).first, "二级页面左边的提示词编辑器")
        tv.isEditable = true
        XCTAssertTrue(window.makeFirstResponder(tv))
        let range: NSRange
        if let target {
            range = (tv.string as NSString).range(of: target)
            XCTAssertNotEqual(range.location, NSNotFound, "编辑器里有「\(target)」：\(tv.string)")
        } else {
            range = NSRange(location: (tv.string as NSString).length, length: 0)
        }
        tv.insertText(text, replacementRange: range)
        wait(0.2)
        window.makeFirstResponder(nil)
        wait()
    }

    private func shot(_ f: Fixture) -> ShotDraft { f.app.shots.first { $0.id == f.shotID }! }

    /// 用户的现场：左边「添加」挂音频 → 提示词里写「音频1…」→ 自动匹配 → 再把那行字删掉 → 音频还在，提交时照样发出去
    func testDeletingAudioTextInPromptKeepsTheAudio() throws {
        let f = try fixture()
        defer { f.app.shots.removeAll { $0.projectKey == f.key } }
        let (window, host) = show(f.app)
        defer { window.orderOut(nil) }

        f.app.addShotMaterial(shotID: f.shotID, libraryItemID: f.audio.id)        // 左边「添加」→ 素材库双击
        wait()
        try edit(window, host, replacing: nil, with: "\n音频1是甲的音色。")
        XCTAssertTrue(shot(f).prompt.contains("音频1是甲的音色"))
        if let item = WorkbenchBatch.matchItem(shotID: f.shotID, app: f.app) { WorkbenchBatch.match([item], app: f.app) }   // 右边「自动匹配」
        wait()
        XCTAssertEqual(shot(f).imageRefs.count, 1, "甲的图挂上了")
        XCTAssertEqual(shot(f).audioRefs.count, 1)

        // 编辑器里「音频1」是内嵌小标签（附件字符 U+FFFC，2026-10-16 起音视频也显示成缩略图）
        try edit(window, host, replacing: "\n\u{FFFC}是甲的音色。", with: "")
        XCTAssertFalse(shot(f).prompt.contains("音频1"), "字删掉了")
        XCTAssertEqual(shot(f).audioRefs.count, 1, "提示词里删了字，素材区的音频不删")
        XCTAssertTrue(ShotValidator.danglingTokenIssues(shot(f)).isEmpty, "没有悬空引用，能提交")
    }

    /// 图片也一样：提示词里把「图1」删掉，图还挂着；再点自动匹配，「图1」补回名字前面（不会多挂一张）
    func testDeletingImageTokenKeepsTheImageAndAutoMatchRestoresIt() throws {
        let f = try fixture()
        defer { f.app.shots.removeAll { $0.projectKey == f.key } }
        let (window, host) = show(f.app)
        defer { window.orderOut(nil) }
        if let item = WorkbenchBatch.matchItem(shotID: f.shotID, app: f.app) { WorkbenchBatch.match([item], app: f.app) }
        wait()
        XCTAssertTrue(shot(f).prompt.hasPrefix("[ ][图1甲][ ]"), shot(f).prompt)

        try edit(window, host, replacing: "图1", with: "")
        XCTAssertTrue(shot(f).prompt.hasPrefix("[ ][甲][ ]"), "提示词里的「图1」删掉了：\(shot(f).prompt)")
        XCTAssertEqual(shot(f).imageRefs.count, 1, "素材区的图不删")

        if let item = WorkbenchBatch.matchItem(shotID: f.shotID, app: f.app) { WorkbenchBatch.match([item], app: f.app) }
        wait()
        XCTAssertTrue(shot(f).prompt.hasPrefix("[ ][图1甲][ ]"), "自动匹配把「图1」补回来：\(shot(f).prompt)")
        XCTAssertEqual(shot(f).imageRefs.count, 1, "没有多挂一张")
    }

    /// 反过来：素材区删素材，提示词里它的引用跟着删、后面的重新编号
    func testRemovingMaterialClearsItsTokenAndRenumbers() throws {
        let f = try fixture()
        defer { f.app.shots.removeAll { $0.projectKey == f.key } }
        var second = LibraryItem(kind: .audio, localPath: "/tmp/none2.wav", fileName: "2.wav", projectKey: f.key)
        second.remoteURL = "https://oss.test/2.wav"
        f.app.library.append(second)
        f.app.addShotMaterial(shotID: f.shotID, libraryItemID: f.audio.id)
        f.app.addShotMaterial(shotID: f.shotID, libraryItemID: second.id)
        f.app.updateShotPrompt(f.shotID, prompt: shot(f).prompt + "\n音频1是甲的音色，音频2是背景音乐。")
        f.app.removeShotMaterial(shotID: f.shotID, refID: shot(f).audioRefs[0].id)      // 素材区点叉
        XCTAssertEqual(shot(f).audioRefs.map(\.libraryItemID), [second.id])
        XCTAssertTrue(shot(f).prompt.hasSuffix("\n甲的音色，音频1是背景音乐。"), "删掉的那个引用（连同紧跟的「是」）没了，后面的前移：\(shot(f).prompt)")
    }

    /// 重新推理整段换掉提示词：没有「图N」的参考图照旧清掉（推理前有确认），手动挂的音频不动
    func testReinferClearsOnlyImages() throws {
        let f = try fixture()
        defer { f.app.shots.removeAll { $0.projectKey == f.key } }
        if let item = WorkbenchBatch.matchItem(shotID: f.shotID, app: f.app) { WorkbenchBatch.match([item], app: f.app) }
        f.app.addShotMaterial(shotID: f.shotID, libraryItemID: f.audio.id)
        XCTAssertEqual(shot(f).imageRefs.count, 1)
        let index = try XCTUnwrap(f.app.shots.firstIndex { $0.id == f.shotID })
        f.app.shots[index].prompt = "[ ][甲][ ]\n镜头1：甲转身离开。"        // 推理出来的新提示词（不带图号）
        f.app.clearImageRefsMissingFromPrompt(f.shotID)
        XCTAssertEqual(shot(f).imageRefs.count, 0, "参考图清掉")
        XCTAssertEqual(shot(f).audioRefs.count, 1, "音频留着")
    }
}
