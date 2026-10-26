import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 音色跟着角色图进分镜（2026-10-26 第 2 步）：挂音频 + 头行下一行「【音色】」、幂等、摘掉不再需要的、挂不上说原因；
/// 头行名字前多出来的「@」不影响认名字
@MainActor
final class ShotVoiceSyncTests: XCTestCase {
    private typealias Lib = Xipixiaojuchang.LibraryItem
    private let head = "[图1客厅][图2周承山、图3许曼][ ]"

    private func audio(_ name: String) -> Lib {
        Lib(kind: .audio, localPath: nil, fileName: "\(name).mp3", name: name, duration: 3)
    }

    func testAudioVoiceIsAttachedAndWrittenUnderTheHeadLineOnce() {
        let zhou = audio("周承山-音色")
        let prompt = head + "\n正文"
        let plan = ShotVoiceSync.plan(prompt: prompt, audioRefs: [], voices: [.init(name: "周承山", resolved: .audio(zhou)),
                                                                            .init(name: "许曼", resolved: .text("清亮女声\n语速快"))],
                                      voiceAudioIDs: [zhou.id], blocker: nil)
        XCTAssertEqual(plan.audioRefs.map(\.libraryItemID), [zhou.id])
        XCTAssertEqual(plan.prompt, head + "\n【音色】音频1是周承山的音色；许曼的音色：清亮女声 语速快\n正文")
        XCTAssertTrue(plan.skipped.isEmpty)

        let again = ShotVoiceSync.plan(prompt: plan.prompt, audioRefs: plan.audioRefs,
                                       voices: [.init(name: "周承山", resolved: .audio(zhou)), .init(name: "许曼", resolved: .text("清亮女声\n语速快"))],
                                       voiceAudioIDs: [zhou.id], blocker: nil)
        XCTAssertEqual(again, plan, "再同步一次什么都不变")
    }

    func testVoiceNoLongerNeededIsRemovedAndManualAudioStays() {
        let bgm = audio("背景音乐"), old = audio("旧音色"), zhou = audio("周承山-音色")
        let prompt = head + "\n【音色】音频2是周承山的音色\n音频1做背景音乐"
        let refs = [MaterialRef(libraryItemID: bgm.id), MaterialRef(libraryItemID: old.id)]
        let plan = ShotVoiceSync.plan(prompt: prompt, audioRefs: refs, voices: [.init(name: "周承山", resolved: .audio(zhou))],
                                      voiceAudioIDs: [old.id, zhou.id], blocker: nil)
        XCTAssertEqual(plan.audioRefs.map(\.libraryItemID), [bgm.id, zhou.id], "旧音色摘掉，手动挂的背景音乐留着")
        XCTAssertEqual(plan.prompt, head + "\n【音色】音频2是周承山的音色\n音频1做背景音乐")

        let none = ShotVoiceSync.plan(prompt: plan.prompt, audioRefs: plan.audioRefs, voices: [],
                                      voiceAudioIDs: [old.id, zhou.id], blocker: nil)
        XCTAssertEqual(none.audioRefs.map(\.libraryItemID), [bgm.id])
        XCTAssertEqual(none.prompt, head + "\n音频1做背景音乐", "没有音色了：那一行也去掉")
    }

    func testBlockedOrFullIsReportedNotSilentlyDropped() {
        let a = audio("a"), b = audio("b"), c = audio("c"), d = audio("d")
        let blocked = ShotVoiceSync.plan(prompt: head, audioRefs: [], voices: [.init(name: "周承山", resolved: .audio(a)),
                                                                             .init(name: "许曼", resolved: .text("女声"))],
                                         voiceAudioIDs: [a.id], blocker: "这一段关了「生成音频」")
        XCTAssertTrue(blocked.audioRefs.isEmpty)
        XCTAssertEqual(blocked.skipped, ["周承山：这一段关了「生成音频」"])
        XCTAssertEqual(blocked.prompt, head + "\n【音色】许曼的音色：女声", "文字音色照写")

        let full = ShotVoiceSync.plan(prompt: head, audioRefs: [a, b, c].map { MaterialRef(libraryItemID: $0.id) },
                                      voices: [.init(name: "沈砚", resolved: .audio(d))], voiceAudioIDs: [d.id], blocker: nil)
        XCTAssertEqual(full.audioRefs.count, 3)
        XCTAssertEqual(full.skipped, ["沈砚：参考音频已经 3 段"])

        XCTAssertNotNil(ShotVoiceSync.audioBlocker(generateAudio: true, channelFormat: .openAI))
        XCTAssertNotNil(ShotVoiceSync.audioBlocker(generateAudio: true, channelFormat: .newAPI), "开源版两种渠道都不收参考音频")
        XCTAssertNil(ShotVoiceSync.audioBlocker(generateAudio: true, channelFormat: nil))
    }

    func testStrayAtSignBeforeANameIsIgnored() {
        XCTAssertEqual(StoryboardNames.cleanName("@图2周承山"), "周承山")
        XCTAssertEqual(StoryboardNames.cleanName("＠周承山"), "周承山")
        XCTAssertEqual(StoryboardNames.head(of: "[客厅][@图2周承山、图3许曼][ ]\n正文")?.roles, ["周承山", "许曼"])
    }
}

/// 接进 AppModel：自动匹配带上音色、删角色图音色跟着走、卡上改音色已挂的分镜跟着变、补「图N」时吃掉多余的「@」
@MainActor
final class ShotVoiceSyncAppTests: XCTestCase {
    private typealias Lib = Xipixiaojuchang.LibraryItem
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "shot-voice-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
    }

    func testMatchingCarriesTheVoiceAndRemovingTheImageTakesItAway() throws {
        var card = ImageGenItem(projectKey: key, type: .character, name: "周承山", prompt: "这个人是：\"周承山\"")
        var image = Lib(kind: .image, localPath: nil, fileName: "zhou.png", name: "角色-周承山", projectKey: key)
        image.imageGenItemID = card.id
        image.source = .imageGenerated
        let voice = Lib(kind: .audio, localPath: nil, fileName: "1.mp3", name: "1", duration: 3, projectKey: key)
        card.voiceAudioID = voice.id
        app.imageItems.append(card)
        app.library += [image, voice]
        let shot = ShotDraft(projectKey: key, prompt: "[客厅][@周承山][ ]\n周承山说话")
        app.shots.append(shot)
        func current() -> ShotDraft { app.shots.first { $0.id == shot.id }! }

        app.autoMatchMaterials(shot.id, candidates: [image], detectsDuration: false)
        XCTAssertEqual(current().imageRefs.map(\.libraryItemID), [image.id])
        XCTAssertEqual(current().audioRefs.map(\.libraryItemID), [voice.id], "角色图挂上，它的音色跟着挂")
        XCTAssertEqual(current().prompt, "[客厅][图1周承山][ ]\n【音色】音频1是周承山的音色\n周承山说话", "名字前的「@」被「图1」换掉")

        app.updateImageItemVoiceMode(card.id, mode: .text)
        app.updateImageItemVoiceText(card.id, text: "低沉沙哑")
        XCTAssertTrue(current().audioRefs.isEmpty, "卡上改成文本音色：已挂的分镜跟着摘掉音频")
        XCTAssertEqual(current().prompt, "[客厅][图1周承山][ ]\n【音色】周承山的音色：低沉沙哑\n周承山说话")

        app.updateImageItemVoiceMode(card.id, mode: .audio)
        XCTAssertEqual(current().audioRefs.map(\.libraryItemID), [voice.id])
        if let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] {
            // 人工核对：分镜编辑框里角色缩略图带小喇叭、【音色】那行的「音频1」显示成音频小标签
            let png = FileManager.default.temporaryDirectory.appendingPathComponent("voice-zhou-\(UUID().uuidString).png")
            let img = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
            try? NSBitmapImageRep(data: img.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: png)
            if let i = app.library.firstIndex(where: { $0.id == image.id }) { app.library[i].localPath = png.path }
            let size = CGSize(width: 1000, height: 620)
            let host = NSHostingView(rootView: EditPromptSheet(shot: current(), onClose: {}).environment(app)
                .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: png)
        }
        let imageRef = try XCTUnwrap(current().imageRefs.first)
        app.removeShotMaterial(shotID: shot.id, refID: imageRef.id)
        XCTAssertTrue(current().audioRefs.isEmpty, "删了角色图：音色也走")
        XCTAssertFalse(current().prompt.contains("【音色】"))
    }
}
