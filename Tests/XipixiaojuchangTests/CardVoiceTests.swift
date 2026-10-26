import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 角色卡绑音色（2026-10-26 用户）：每张卡只有自己的（不沿用）、文本 / 音频二选一、素材库删了音频就解绑，弹窗关掉不回滚音色
@MainActor
final class CardVoiceTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "card-voice-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.imageItems.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
    }

    private func card(_ name: String, type: ImageSubjectType? = .character, stage: String? = nil, from: Int? = nil) -> ImageGenItem {
        var c = ImageGenItem(projectKey: key, type: type, name: name, prompt: "这个人是：\"\(name)\"")
        c.stage = stage
        c.fromEpisode = from
        return c
    }
    private func audio(_ name: String) -> Xipixiaojuchang.LibraryItem {
        Xipixiaojuchang.LibraryItem(kind: .audio, localPath: "/不存在/\(name).mp3", fileName: "\(name).mp3", name: name, duration: 7, projectKey: key)
    }

    func testEachCardHasOnlyItsOwnVoiceAndTheChosenKindIsUsed() {
        let voice = audio("周承山-音色")
        let lookup: (UUID) -> Xipixiaojuchang.LibraryItem? = { $0 == voice.id ? voice : nil }
        var base = card("周承山", from: 1)
        base.voiceAudioID = voice.id
        base.voiceText = "  低沉沙哑的中年男声  "
        var older = card("周承山", stage: "四十岁")
        older.referenceCardID = base.id

        XCTAssertEqual(CardVoice.resolve(base, library: lookup), .audio(voice), "没选过：有音频用音频")
        base.voiceMode = .text
        XCTAssertEqual(CardVoice.resolve(base, library: lookup), .text("低沉沙哑的中年男声"), "选了文本就用文字（去掉首尾空白）")
        XCTAssertNil(CardVoice.resolve(older, library: lookup), "四十岁是另一个形象：没绑就是没有，不沿用")

        older.voiceText = "沙哑"
        XCTAssertEqual(CardVoice.resolve(older, library: lookup), .text("沙哑"), "只有文字：没选过就用文字")
        older.voiceMode = .audio
        XCTAssertNil(CardVoice.resolve(older, library: lookup), "选了音频但没绑音频：没有音色（不悄悄换成文字）")

        var scene = card("周家客厅", type: .scene)
        scene.voiceText = "不该有"
        XCTAssertNil(CardVoice.resolve(scene, library: lookup), "场景 / 道具没有音色")
    }

    func testBindingDeletingAndClosingTheSheet() {
        let voice = audio("许曼-音色")
        let image = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, fileName: "a.png", projectKey: key)
        app.library += [voice, image]
        let c = card("许曼")
        app.imageItems.append(c)
        let backup = c
        func current() -> ImageGenItem { app.imageItems.first { $0.id == c.id }! }

        app.updateImageItemVoiceAudio(c.id, audioID: image.id)
        XCTAssertNil(current().voiceAudioID, "只认音频")
        app.updateImageItemVoiceAudio(c.id, audioID: voice.id)
        app.updateImageItemVoiceText(c.id, text: "  ")
        XCTAssertNil(current().voiceText, "空白算没有")
        app.updateImageItemVoiceText(c.id, text: "沙哑女声")

        XCTAssertEqual(current().voiceMode, .audio, "绑上音频就切到音频音色")
        app.updateImageItemVoiceMode(c.id, mode: .text)
        XCTAssertEqual(current().voiceMode, .text)
        XCTAssertEqual(current().voiceAudioID, voice.id, "切到文本：音频还绑着")
        app.updateImageItemVoiceMode(c.id, mode: .audio)

        app.rollbackImageItemEdits(to: backup)
        XCTAssertEqual(current().voiceAudioID, voice.id, "弹窗没提交就关掉：音色不回滚（改了马上算数）")
        XCTAssertEqual(current().voiceText, "沙哑女声")

        // 离屏渲染编辑提示词弹窗（XIPI_SHOT 给了路径才写图，人工核对用）：绑了音频的 / 没绑的（另一个形象）各一张
        try? renderSheet(c, to: ProcessInfo.processInfo.environment["XIPI_SHOT"])
        let variant = card("许曼", stage: "少年")
        app.imageItems.append(variant)
        try? renderSheet(variant, to: ProcessInfo.processInfo.environment["XIPI_SHOT"].map { $0.replacingOccurrences(of: ".png", with: "-没绑.png") })
        // 套上真实浮层（宽度由内容定）：用户窗口 1275×828 / 窄窗口 900
        for width in [1275.0, 900.0] {
            try? renderSheet(c, to: ProcessInfo.processInfo.environment["XIPI_SHOT"].map { $0.replacingOccurrences(of: ".png", with: "-浮层\(Int(width)).png") },
                             size: CGSize(width: width, height: 828), inModal: true)
        }
        // 有历史版本的卡（两张图 + 一次失败）：右栏上面「当前：第 N 版」+「历史版本」，点了失败那版预览写原因
        var versioned = card("沈知夏")
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("voice-v-\(UUID().uuidString).png")
        let img = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { r in NSColor.systemPink.setFill(); r.fill(); return true }
        try? NSBitmapImageRep(data: img.tiffRepresentation!)?.representation(using: .png, properties: [:])?.write(to: png)
        let t0 = Date().addingTimeInterval(-600)
        versioned.results = [ImageGenResult(id: UUID(), localPath: png.path, resultURL: nil, createdAt: t0, prompt: "第一版"),
                             ImageGenResult(id: UUID(), localPath: png.path, resultURL: nil, createdAt: t0.addingTimeInterval(120), prompt: "第二版")]
        versioned.failures = [ImageGenFailure(createdAt: t0.addingTimeInterval(300), error: "上游 503：模型繁忙", prompt: "第三版")]
        app.imageItems.append(versioned)
        try? renderSheet(versioned, to: ProcessInfo.processInfo.environment["XIPI_SHOT"].map { $0.replacingOccurrences(of: ".png", with: "-版本.png") })
        app.applyImageFailure(versioned.id, failureID: versioned.failures[0].id)
        try? renderSheet(app.imageItems.first { $0.id == versioned.id }!, to: ProcessInfo.processInfo.environment["XIPI_SHOT"].map { $0.replacingOccurrences(of: ".png", with: "-失败版.png") })
        try? FileManager.default.removeItem(at: png)
        let scene = card("周家客厅", type: .scene)
        app.imageItems.append(scene)
        try? renderSheet(scene, to: ProcessInfo.processInfo.environment["XIPI_SHOT"].map { $0.replacingOccurrences(of: ".png", with: "-场景.png") })

        app.removeLibraryItem(id: voice.id)
        XCTAssertNil(current().voiceAudioID, "素材库删了这段音频：解绑")
        XCTAssertEqual(current().voiceText, "沙哑女声", "文字描述留着")
    }

    private func renderSheet(_ item: ImageGenItem, to out: String?, size: CGSize = CGSize(width: 1000, height: 600), inModal: Bool = false) throws {
        guard out != nil else { return }
        let sheet = EditImagePromptSheet(item: item, onClose: {})
        let root: AnyView = inModal ? AnyView(AppModal(handlesEsc: false, onClose: {}) { sheet }) : AnyView(sheet)
        let host = NSHostingView(rootView: root.environment(app)
            .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if let out, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        }
    }
}
