import XCTest
@testable import Xipixiaojuchang

private actor NamesCapture {
    var users: [String] = []
    func add(_ u: String) { users.append(u) }
}

/// 2026-10-10 用户实测：在提取面板里写「第一集的周承山是年轻时候的」，AI 把这一集的 16 个角色全重提了一遍（多出 16 张「名字 2」的卡）。
/// 现在可以只勾要提取的名字；勾选区默认只勾还没有卡的。
@MainActor
final class ExtractChosenNamesTests: XCTestCase {
    private func fixture(_ app: AppModel) -> String {
        let key = "extract-names-" + UUID().uuidString
        let shots = [
            ShotDraft(projectKey: key, prompt: "[客厅][周承山、许曼][怀表]\n甲。", numbering: ShotNumbering(a: 1, b: 1)),
            ShotDraft(projectKey: key, prompt: "[客厅][周承山、沈知夏][ ]\n乙。", numbering: ShotNumbering(a: 1, b: 2)),
        ]
        app.shots.append(contentsOf: shots)
        var episode = Episode(title: "第1集", text: "周承山年轻时英俊。许曼干练。沈知夏年轻。", splitText: "x\n--- 00:00 - 00:30")
        episode.shotIDs = shots.map(\.id)
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        return key
    }
    private func cleanup(_ app: AppModel, _ key: String) {
        app.removePipelineArchive(for: key)
        app.shots.removeAll { $0.projectKey == key }
        app.imageItems.removeAll { $0.projectKey == key }
    }

    func testOnlyTheChosenNamesAreSentAndTheOthersAreLeftOutOfTheRequest() async throws {
        let app = AppModel(), capture = NamesCapture()
        let key = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], note: "第一集的周承山是年轻时候的", names: ["周承山"],
                                      prompt: "ROLE-RULE", chat: { _, user in await capture.add(user); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertEqual(users.count, 1)
        let roster = users[0].components(separatedBy: "【原文").first ?? ""
        XCTAssertTrue(roster.contains("1. 周承山"), roster)
        XCTAssertFalse(roster.contains("许曼"), "没勾的名字不在名单里（原文里还是整段原文）")
        XCTAssertFalse(roster.contains("沈知夏"))
        XCTAssertTrue(users[0].hasPrefix(RerunNote.opening + "\n第一集的周承山是年轻时候的\n"), "补充要求照样带上")
    }

    func testWithoutNamesEveryNameOfThatKindIsStillSent() async throws {
        let app = AppModel(), capture = NamesCapture()
        let key = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], prompt: "ROLE-RULE", chat: { _, user in await capture.add(user); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        let user = await capture.users.first ?? ""
        XCTAssertTrue(user.contains("1. 周承山") && user.contains("2. 许曼") && user.contains("3. 沈知夏"), user)
    }

    func testNamesThatAreNotInTheHeadLinesSendNothingAndSayWhy() async throws {
        let app = AppModel(), capture = NamesCapture()
        let key = fixture(app)
        defer { cleanup(app, key) }
        app.pipelineFlow.batchExtract(app: app, project: key, kind: .role, episodeIndices: [0], names: ["路人甲"], prompt: "ROLE-RULE",
                                      chat: { _, user in await capture.add(user); return "" })
        await app.pipelineFlow.waitForAll(project: key)
        let users = await capture.users
        XCTAssertTrue(users.isEmpty)
        XCTAssertTrue(app.pipelineFlow.batches[key]?.notes.contains { $0.contains("指定的名字不在选中的分镜头行里") } == true,
                      "\(app.pipelineFlow.batches[key]?.notes ?? [])")
    }

    func testAnAgentCommandCanLimitTheNamesAndAnEmptyListIsRejected() async throws {
        let app = AppModel(), capture = NamesCapture()
        let key = fixture(app)
        defer { cleanup(app, key) }
        let json = #"{"cmd":"extract","project":"\#(key)","kinds":["角色"],"episodes":[1],"names":["周承山"]}"#
        let command = try JSONDecoder().decode(AgentCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.names, ["周承山"])
        let outcome = AgentCommandRunner.run(command, app: app, chat: { _, user in await capture.add(user); return "" })
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertTrue(outcome.message.contains("只提取：周承山"), outcome.message)
        await app.pipelineFlow.waitForAll(project: key)
        let user = await capture.users.first ?? ""
        let roster = user.components(separatedBy: "【原文").first ?? ""
        XCTAssertTrue(roster.contains("1. 周承山") && !roster.contains("许曼"), roster)

        let empty = try JSONDecoder().decode(AgentCommand.self, from: Data(#"{"cmd":"extract","project":"\#(key)","kinds":["角色"],"episodes":[1],"names":[]}"#.utf8))
        let rejected = AgentCommandRunner.run(empty, app: app, chat: { _, _ in "" })
        XCTAssertFalse(rejected.ok)
        XCTAssertTrue(rejected.message.contains("names 是空的"), rejected.message)
    }
}
