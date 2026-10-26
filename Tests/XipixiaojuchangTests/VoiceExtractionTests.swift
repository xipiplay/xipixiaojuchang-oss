import XCTest
import SwiftUI
@testable import Xipixiaojuchang

private actor VoiceRequests {
    var systems: [String] = [], users: [String] = []
    func add(_ system: String, _ user: String) { systems.append(system); users.append(user) }
}

/// 批量提取音色（2026-10-26）：给勾选的角色卡写文本音色，按「名字 + 阶段」对回；不动音频、不改选的是文本还是音频；
/// 写完分镜里的【音色】行跟着更新。关了「生成音频」的分镜不写文本音色
@MainActor
final class VoiceExtractionTests: XCTestCase {
    private typealias Lib = Xipixiaojuchang.LibraryItem

    // MARK: 解析与对名单

    func testParseReadsNameStageAndVoiceAndSkipsBlocksWithoutVoice() {
        let reply = """
        ```
        这个人是："周承山"
        音色：中年男声，低沉沙哑，
        语速偏慢。

        这个人是："周承山"
        阶段：少年
        音色：少年男声，清亮。

        这个人是："许曼"
        描述：没写音色
        ```
        """
        let parsed = VoiceExtraction.parse(reply)
        XCTAssertEqual(parsed.map(\.logical), ["周承山", "周承山（少年）"])
        XCTAssertEqual(parsed.map(\.voice), ["中年男声，低沉沙哑， 语速偏慢。", "少年男声，清亮。"], "「音色：」起到这一块结束，连成一行")
    }

    func testMatchWritesEveryCardOfTheSamePersonAndReportsWhatDidNotLineUp() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let targets = [VoiceExtraction.Target(logical: "沈惊澜", cardIDs: [a, b], look: "", episodes: [1]),
                       VoiceExtraction.Target(logical: "谢玄寂（少年）", cardIDs: [c], look: "", episodes: [2]),
                       VoiceExtraction.Target(logical: "老孙", cardIDs: [d], look: "", episodes: [3])]
        let result = VoiceExtraction.match([("沈惊澜", "女声"), ("谢玄寂", "少年音"), ("路人甲", "男声")], to: targets)
        XCTAssertEqual(result.voices, [a: "女声", b: "女声", c: "少年音"], "换装的变化版写同一段；没写阶段、名单里只有一个同名的也算它的")
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertTrue(result.notes[0].contains("路人甲"))
        XCTAssertTrue(result.notes[1].contains("老孙"))
    }

    func testSourceOnlyCarriesEpisodesTheyAppearInAndSharesTheBudgetRoundRobin() {
        let episodes = (1...4).map { (episode: $0, text: "第\($0)集正文" + String(repeating: "字", count: 50_000)) }
        let batch = [VoiceExtraction.Target(logical: "甲", cardIDs: [], look: "", episodes: [1, 2, 3]),
                     VoiceExtraction.Target(logical: "乙", cardIDs: [], look: "", episodes: [4])]
        let source = VoiceExtraction.source(episodes: episodes, for: batch)
        XCTAssertTrue(source.contains("第1集正文"))
        XCTAssertTrue(source.contains("第4集正文"), "超了上限也先让每个人分到第一次出场的那一集")
        XCTAssertFalse(source.contains("第3集正文"))
    }

    // MARK: 整条流程

    private func setUpProject(_ app: AppModel) -> (key: String, zhang: ImageGenItem, zhangLater: ImageGenItem, li: ImageGenItem, shot: ShotDraft) {
        let key = "voice-extract-" + UUID().uuidString
        let zhang = ImageGenItem(projectKey: key, type: .character, name: "张三", prompt: "这个人是：\"张三\"，三十岁男性，穿灰色西装。电影写实风格")
        var zhangLater = ImageGenItem(projectKey: key, type: .character, name: "张三", prompt: "这个人是：\"张三\"，换了黑色大衣。")
        zhangLater.fromEpisode = 2
        var li = ImageGenItem(projectKey: key, type: .character, name: "李四", prompt: "这个人是：\"李四\"，二十岁。")
        li.voiceText = "手写的音色"
        var image = Lib(kind: .image, localPath: nil, fileName: "zhang.png", name: "角色-张三", projectKey: key)
        image.imageGenItemID = zhang.id
        image.source = .imageGenerated
        let shot = ShotDraft(projectKey: key, prompt: "[客厅][图1张三、李四][怀表]\n张三说话",
                             imageRefs: [MaterialRef(libraryItemID: image.id)], numbering: ShotNumbering(a: 1, b: 1))
        let quiet = ShotDraft(projectKey: key, prompt: "[客厅][图1张三][ ]\n张三不出声", generateAudio: false,
                              imageRefs: [MaterialRef(libraryItemID: image.id)], numbering: ShotNumbering(a: 2, b: 1))
        app.imageItems += [zhang, zhangLater, li]
        app.library.append(image)
        app.shots += [shot, quiet]
        var first = Episode(title: "第1集", text: "张三：今天开会。李四：好的。", splitText: "分割")
        first.shotIDs = [shot.id]
        var second = Episode(title: "第2集", text: "张三沉默不语。", splitText: "分割")
        second.shotIDs = [quiet.id]
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "", episodes: [first, second]), for: key)
        return (key, zhang, zhangLater, li, shot)
    }

    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.imageItems.removeAll { $0.projectKey == key }
        app.shots.removeAll { $0.projectKey == key }
        app.library.removeAll { $0.projectKey == key }
    }

    func testFillsTheCheckedCardsSyncsShotsAndLeavesTheRestAlone() async throws {
        let app = AppModel(), requests = VoiceRequests()
        let p = setUpProject(app)
        defer { cleanup(app, p.key) }
        app.pipelineFlow.batchExtractVoices(app: app, project: p.key, cardIDs: [p.zhang.id, p.zhangLater.id], prompt: "VOICE-RULE") { system, user in
            await requests.add(system, user)
            return "这个人是：\"张三\"\n音色：中年男声，低沉。"
        }
        await app.pipelineFlow.waitForAll(project: p.key)

        let users = await requests.users, systems = await requests.systems
        XCTAssertEqual(users.count, 1, "张三的两张卡是同一个人：名单里只写一次")
        XCTAssertTrue(systems[0].contains("VOICE-RULE"))
        XCTAssertTrue(users[0].contains("1. 张三（第1、2集出场）"))
        XCTAssertTrue(users[0].contains("形象：这个人是：\"张三\"，三十岁男性，穿灰色西装"))
        XCTAssertTrue(users[0].contains("张三：今天开会。"), "带上出场那几集的原文")
        XCTAssertFalse(users[0].contains("李四（"), "没勾的不进名单")

        func card(_ id: UUID) -> ImageGenItem { app.imageItems.first { $0.id == id }! }
        XCTAssertEqual(card(p.zhang.id).voiceText, "中年男声，低沉。")
        XCTAssertEqual(card(p.zhangLater.id).voiceText, "中年男声，低沉。")
        XCTAssertNil(card(p.zhang.id).voiceMode, "不改选的是哪一种：没绑音频默认就是文本")
        XCTAssertEqual(card(p.li.id).voiceText, "手写的音色")

        let shots = app.shots.filter { $0.projectKey == p.key }
        XCTAssertEqual(shots[0].prompt, "[客厅][图1张三、李四][怀表]\n【音色】张三的音色：中年男声，低沉。\n张三说话")
        XCTAssertEqual(shots[1].prompt, "[客厅][图1张三][ ]\n张三不出声", "关了「生成音频」的分镜不写文本音色")
        XCTAssertEqual(app.voiceSyncSkips[shots[1].id], ["张三：这一段关了「生成音频」"])

        let state = try XCTUnwrap(app.pipelineFlow.batches[p.key])
        XCTAssertEqual(state.kind, .voice)
        XCTAssertEqual(state.created, 2)
        XCTAssertEqual(state.shotsUpdated, 1)
        XCTAssertTrue(state.failures.isEmpty)
        XCTAssertTrue(state.notes.isEmpty)
    }

    func testACardThatUsesAudioKeepsUsingAudio() async throws {
        let app = AppModel()
        let p = setUpProject(app)
        defer { cleanup(app, p.key) }
        let voice = Lib(kind: .audio, localPath: nil, fileName: "zhang.mp3", name: "张三音色", duration: 3, projectKey: p.key)
        app.library.append(voice)
        app.updateImageItemVoiceAudio(p.zhang.id, audioID: voice.id)
        app.pipelineFlow.batchExtractVoices(app: app, project: p.key, cardIDs: [p.zhang.id], prompt: "VOICE-RULE") { _, _ in
            "这个人是：\"张三\"\n音色：中年男声。"
        }
        await app.pipelineFlow.waitForAll(project: p.key)
        let card = try XCTUnwrap(app.imageItems.first { $0.id == p.zhang.id })
        XCTAssertEqual(card.voiceText, "中年男声。", "文本照样填进去，留着以后切")
        XCTAssertEqual(CardVoice.mode(of: card), .audio)
        let shot = try XCTUnwrap(app.shots.first { $0.id == p.shot.id })
        XCTAssertFalse(shot.prompt.contains("张三的音色："), "生效的还是音频")
    }

    /// 选择框：没音色的默认勾上、已有的不勾；人工核对设 `XIPI_SHOT=路径` 才出图
    func testPanelRendersWithTheRightDefaults() throws {
        guard let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] else { return }
        let app = AppModel()
        let p = setUpProject(app)
        defer { cleanup(app, p.key) }
        for scheme in [ColorScheme.dark, .light] {
            let size = CGSize(width: 380, height: 560)
            let host = NSHostingView(rootView: VoiceExtractPanel(app: app, project: p.key, onClose: {})
                .background(scheme == .dark ? Color(nsColor: NSColor(white: 0.16, alpha: 1)) : Color.white)
                .environment(app).environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "-\(scheme == .dark ? "dark" : "light").png"))
            }
            window.orderOut(nil)
        }
    }
}
