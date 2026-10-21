import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-16 用户：「提交的视频添加的音频怎么没有提交给 API 服务商」。
/// 查到两处：① 编辑器对账把提示词里没有 token 的素材删掉（音频就是这样丢的；2026-10-16 起不再按提示词删素材，见 `MaterialPromptRuleTests`）；
/// ② 提示词写了「音频1」却没挂音频照样能交
@MainActor
final class VideoAudioRefsTests: XCTestCase {
    private func shot(prompt: String, images: Int = 0, audios: Int = 0) -> ShotDraft {
        ShotDraft(projectKey: "p", prompt: prompt,
                  imageRefs: (0..<images).map { _ in MaterialRef(libraryItemID: UUID(), role: .referenceImage) },
                  audioRefs: (0..<audios).map { _ in MaterialRef(libraryItemID: UUID()) })
    }

    // MARK: ① 素材区删素材时提示词跟着重编号

    /// 删中间一张：token 序号从 1 起，别把前一张的 token 也删了（原来传的是从 0 起的下标）
    func testRenumberAfterRemovingMiddleKeepsTheOthers() {
        let edited = "[图1客栈][图3乙]"
        XCTAssertEqual(AppModel.removeTokenAndRenumber(edited, prefix: "图", removedIndex: 2), "[图1客栈][图2乙]")
        XCTAssertEqual(AppModel.removeTokenAndRenumber(edited, prefix: "图", removedIndex: 1), "[客栈][图2乙]",
                       "原来的写法：会把图1的 token 删掉")
    }

    /// 真实场景：二级页面里嵌着的编辑器，素材库加一段音频 → 改字 → 离开（存）→ 音频还在
    func testInlineEditorKeepsAudioAddedFromLibrary() async throws {
        let app = AppModel()
        let key = "audio-" + UUID().uuidString
        let audio = LibraryItem(kind: .audio, localPath: "/tmp/none.wav", fileName: "1.wav", projectKey: key)
        app.library.append(audio)
        var s = ShotDraft(projectKey: key, prompt: "镜头1：甲开口说话。")
        s.model = "m"
        app.shots.append(s)
        app.currentProjectKey = key
        defer { app.shots.removeAll { $0.projectKey == key }; app.library.removeAll { $0.id == audio.id } }

        let host = NSHostingView(rootView: EditPromptSheet(shot: s, onClose: {}, inline: true, availableWidth: 640)
            .environment(app).frame(width: 640, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))

        app.addShotMaterial(shotID: s.id, libraryItemID: audio.id)      // 素材库抽屉双击 / 拖进来
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.shots.first { $0.id == s.id }?.audioRefs.count, 1)

        func find(_ v: NSView) -> PromptTextView? {
            if let t = v as? PromptTextView { return t }
            for sub in v.subviews { if let t = find(sub) { return t } }
            return nil
        }
        let tv = try XCTUnwrap(find(host))
        // 平时只读、点一下才编辑（clickToEdit）：测试里直接打开编辑、聚焦
        tv.isEditable = true
        XCTAssertTrue(window.makeFirstResponder(tv))
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertText("周承山开口。", replacementRange: tv.selectedRange())      // 还没写「音频1」：先改了别的字
        try await Task.sleep(for: .milliseconds(200))
        // 点外面：嵌着的编辑器失焦就存（存之前对账）
        window.makeFirstResponder(nil)
        try await Task.sleep(for: .milliseconds(300))
        window.close()

        let saved = try XCTUnwrap(app.shots.first { $0.id == s.id })
        XCTAssertTrue(saved.prompt.contains("周承山开口"), "改的字存上了")
        XCTAssertEqual(saved.audioRefs.count, 1, "刚加的音频没被对账删掉")
        XCTAssertTrue(ShotValidator.danglingTokenIssues(saved).isEmpty)
    }

    // MARK: ② 提示词里引用了没挂的素材：拦下

    func testDanglingAudioTokenBlocksSubmit() {
        let issues = ShotValidator.validate(shot(prompt: "[图1客栈]\n图4音频1周承山说话。", images: 4))
        XCTAssertTrue(issues.contains { $0.contains("音频1") && $0.contains("没有挂音频") }, "\(issues)")
        XCTAssertTrue(ShotValidator.danglingTokenIssues(shot(prompt: "图4音频1周承山说话。", images: 4, audios: 1)).isEmpty)
        let tooMany = ShotValidator.danglingTokenIssues(shot(prompt: "图1、图5", images: 3))
        XCTAssertEqual(tooMany, ["提示词里写到「图5」，但只挂了 3 张图"])
        XCTAssertTrue(ShotValidator.danglingTokenIssues(shot(prompt: "镜头1：没有引用素材。")).isEmpty)
    }

}
