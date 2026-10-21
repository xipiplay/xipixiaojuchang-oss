import XCTest
@testable import Xipixiaojuchang

private actor NoteCapture {
    var users: [String] = []
    func add(_ u: String) { users.append(u) }
}

/// 重跑时用户手写的补充要求（2026-10-09）：只对这一次请求生效，放在发给 AI 的内容最前面。
@MainActor
final class RerunNoteTests: XCTestCase {
    func testABlankNoteChangesNothingAndAWrittenOneGoesInFrontOfTheContent() {
        XCTAssertEqual(RerunNote.block(""), "")
        XCTAssertEqual(RerunNote.block("  \n "), "")
        XCTAssertEqual(RerunNote.prefixed("原文", note: ""), "原文")
        let text = RerunNote.prefixed("原文", note: "  把第 2 段和第 3 段合并  ")
        XCTAssertTrue(text.hasPrefix(RerunNote.opening + "\n把第 2 段和第 3 段合并\n" + RerunNote.closing + "\n\n"), text)
        XCTAssertTrue(text.hasSuffix("\n\n原文"), "原来的内容原样放在后面")
    }

    private func fixture(_ app: AppModel) -> (key: String, shots: [ShotDraft]) {
        let key = "rerun-note-" + UUID().uuidString
        let split = "场景：客厅 日 内\n甲说话。\n--- 00:00 - 00:30\n乙说话。\n--- 00:30 - 01:00"
        let shots = (1...2).map { i in ShotDraft(projectKey: key, prompt: "[客厅][人\(i)][ ]\n原来的提示词\(i)。", numbering: ShotNumbering(a: 1, b: i)) }
        app.shots.append(contentsOf: shots)
        var episode = Episode(title: "第1集", text: "这一集的原文", splitText: split)
        episode.shotIDs = shots.map(\.id)
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        return (key, shots)
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.shots.removeAll { $0.projectKey == key }
    }

    func testSplitSendsTheNoteBeforeTheEpisodeTextAndOverwritesTheWholeEpisodeSplit() async throws {
        let app = AppModel(), capture = NoteCapture()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], note: "把第 1 段和第 2 段合并", chat: { _, user in
            await capture.add(user)
            return "场景：客厅\n合并后的一段。\n--- 00:00 - 00:30"
        })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].hasPrefix(RerunNote.opening + "\n把第 1 段和第 2 段合并\n"), users[0])
        XCTAssertTrue(users[0].hasSuffix("这一集的原文"))
        XCTAssertEqual(try XCTUnwrap(app.pipelineArchive(for: key)).episodes[0].splitText, "场景：客厅\n合并后的一段。\n--- 00:00 - 00:30", "这一集的分段整个被新结果覆盖")
    }

    func testWithoutANoteTheSplitRequestIsExactlyTheEpisodeText() async throws {
        let app = AppModel(), capture = NoteCapture()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchSplit(app: app, project: key, episodeIndices: [0], chat: { _, user in await capture.add(user); return "x\n--- 00:00 - 00:30" })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertEqual(users, ["这一集的原文"])
    }

    func testInferAndTheSingleSegmentRerunBothCarryTheNote() async throws {
        let app = AppModel(), capture = NoteCapture()
        let (key, shots) = fixture(app)
        defer { cleanup(app, key) }
        let two = "[客厅][甲][ ]\n新一\n[客厅][乙][ ]\n新二"
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], note: "镜头再紧凑一点", chat: { _, user in await capture.add(user); return two })
        await app.pipelineFlow.waitForAll(project: key)
        app.pipelineFlow.inferSegment(app: app, project: key, episodeIndex: 0, segmentNumber: 2, note: "多给反应镜头", chat: { _, user in
            await capture.add(user); return "[客厅][乙][ ]\n再来一遍"
        })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertEqual(users.count, 2)
        XCTAssertTrue(users[0].hasPrefix(RerunNote.opening + "\n镜头再紧凑一点\n"), users[0])
        XCTAssertTrue(users[1].hasPrefix(RerunNote.opening + "\n多给反应镜头\n"), users[1])
        XCTAssertEqual(app.shots.first { $0.id == shots[1].id }!.prompt, "[客厅][乙][ ]\n再来一遍")
    }

    func testExtractionRequestsCarryTheNoteToo() async throws {
        let app = AppModel(), capture = NoteCapture()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], note: "服装按剧情写变化", prompt: "ROLE-RULE", chat: { _, user in
            await capture.add(user); return ""
        })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertEqual(users.count, 1)
        XCTAssertTrue(users[0].hasPrefix(RerunNote.opening + "\n服装按剧情写变化\n"), users[0])
        XCTAssertTrue(users[0].contains("1. 人1"), "名单还在")
    }

    func testReInferringAWholeEpisodeAlsoClearsTheReferenceImagesThatNoLongerHaveATokenInThePrompt() async throws {
        let app = AppModel()
        let (key, shots) = fixture(app)
        defer { cleanup(app, key); app.library.removeAll { $0.projectKey == key } }
        let lib = Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, name: "角色-人1", projectKey: key)
        app.library.append(lib)
        var withRef = shots[0]
        withRef.prompt = "[客厅][图1人1][ ]\n原来的提示词1。"
        withRef.imageRefs = [MaterialRef(libraryItemID: lib.id, role: .referenceImage)]
        app.shots[app.shots.firstIndex { $0.id == withRef.id }!] = withRef
        app.pipelineFlow.batchInfer(app: app, project: key, episodeIndices: [0], chat: { _, _ in "[客厅][人1][ ]\n新一\n[客厅][人2][ ]\n新二" })
        await app.pipelineFlow.waitForAll(project: key)
        let after = app.shots.first { $0.id == shots[0].id }!
        XCTAssertEqual(after.prompt, "[客厅][人1][ ]\n新一")
        XCTAssertTrue(after.imageRefs.isEmpty, "新提示词里没有「图1」了：旧的参考图跟着清掉（和单段「重新推理」一样），要点「应用素材」重新挂")
    }

    func testAnAgentCommandCanCarryTheNoteAndItReachesTheRequest() async throws {
        let app = AppModel(), capture = NoteCapture()
        let (key, _) = fixture(app)
        defer { cleanup(app, key) }
        let json = #"{"cmd":"split","project":"\#(key)","episodes":[1],"note":"把第 2 段拆成两段"}"#
        let command = try JSONDecoder().decode(AgentCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.note, "把第 2 段拆成两段")
        let outcome = AgentCommandRunner.run(command, app: app, chat: { _, user in await capture.add(user); return "x\n--- 00:00 - 00:30" })
        XCTAssertTrue(outcome.ok, outcome.message)
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertTrue(users.first?.hasPrefix(RerunNote.opening + "\n把第 2 段拆成两段\n") == true, users.first ?? "")
    }
}
