import XCTest
@testable import Xipixiaojuchang

private actor Calls {
    var count = 0, hosts: [MaterialUploadHost] = []
    func add(_ host: MaterialUploadHost? = nil) { count += 1; if let host { hosts.append(host) } }
}

/// 左栏「AI」「上传」图标（2026-10-07）：点一下就测，状态 暗 → 测试中 → 亮 / 红，不再跳设置页。
@MainActor
final class ConnectionProbeTests: XCTestCase {
    private func settle(_ app: AppModel, _ state: @escaping () -> ProbeState) async throws {
        for _ in 0..<300 where state() == .testing { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testIconsStartDim() {
        let app = AppModel()
        XCTAssertEqual(app.aiProbe, .unknown)
        XCTAssertEqual(app.uploadProbe, .unknown)
    }

    func testAIClickGoesTestingThenLitAndKeepsTheMessage() async throws {
        let app = AppModel()
        app.testAIConnection(using: {
            try? await Task.sleep(for: .milliseconds(40))
            return ProbeResult(ok: true, message: "连接成功")
        })
        XCTAssertEqual(app.aiProbe, .testing)
        try await settle(app) { app.aiProbe }
        XCTAssertEqual(app.aiProbe, .ok)
        XCTAssertEqual(app.aiProbeMessage, "连接成功")
    }

    func testAIFailureTurnsRedWithTheReason() async throws {
        let app = AppModel()
        app.testAIConnection(using: { ProbeResult(ok: false, message: "连接失败：API Key 不对") })
        try await settle(app) { app.aiProbe }
        XCTAssertEqual(app.aiProbe, .failed)
        XCTAssertEqual(app.aiProbeMessage, "连接失败：API Key 不对")
        // 再点一次测成功：从红变亮
        app.testAIConnection(using: { ProbeResult(ok: true, message: "连接成功") })
        try await settle(app) { app.aiProbe }
        XCTAssertEqual(app.aiProbe, .ok)
    }

    func testClickingWhileTestingDoesNotStartASecondTest() async throws {
        let app = AppModel(), calls = Calls()
        let slow: () async -> ProbeResult = {
            await calls.add()
            try? await Task.sleep(for: .milliseconds(60))
            return ProbeResult(ok: true, message: "ok")
        }
        app.testAIConnection(using: slow)
        app.testAIConnection(using: slow)
        try await settle(app) { app.aiProbe }
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testUploadClickTestsTheHostCurrentlySelectedInSettings() async throws {
        let app = AppModel(), calls = Calls()
        let saved = MaterialUploadHostStore.load()
        defer { MaterialUploadHostStore.save(saved) }
        for host in [MaterialUploadHost.oss, .freeHost] {
            MaterialUploadHostStore.save(host)
            app.testUploadConnection(using: { h in
                await calls.add(h)
                return ProbeResult(ok: h == .freeHost, message: h == .oss ? "OSS 没配" : "图床 ok")
            })
            try await settle(app) { app.uploadProbe }
            XCTAssertEqual(app.uploadProbeHost, host)
            XCTAssertEqual(app.uploadProbe, host == .freeHost ? .ok : .failed)
        }
        let hosts = await calls.hosts
        XCTAssertEqual(hosts, [.oss, .freeHost])
        XCTAssertEqual(app.uploadProbeMessage, "图床 ok")
    }

    func testOSSWithoutSavedConfigFailsWithAHintAndNeverTouchesTheNetwork() async throws {
        try XCTSkipIf(OSSConfigStore.load() != nil, "这台机器上存了真的 OSS 配置，跳过")
        let result = await ConnectionProbe.upload(host: .oss)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.message.contains("设置 → 素材上传"))
    }

    func testHostNames() {
        XCTAssertEqual(ConnectionProbe.hostName(.oss), "阿里云 OSS")
        XCTAssertEqual(ConnectionProbe.hostName(.freeHost), "免费图床")
    }

    /// 2026-10-12 用户：左栏点了测试、模型慢一直转圈；去设置里换了模型测成功了，左栏还在转。
    /// 设置页测的是在用的那份：左栏跟着它的结果，左栏那次慢的晚回来也不能盖掉
    func testSettingsResultReplacesTheSlowRailTestAndItsLateAnswerIsIgnored() async throws {
        let app = AppModel()
        app.testAIConnection(using: {
            try? await Task.sleep(for: .milliseconds(400))
            return ProbeResult(ok: false, message: "慢的那次")
        })
        XCTAssertEqual(app.aiProbe, .testing)
        app.reportAIProbe(ProbeResult(ok: true, message: "连接成功"))
        XCTAssertEqual(app.aiProbe, .ok, "不再转圈")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(app.aiProbe, .ok, "慢的那次晚回来，不盖掉")
        XCTAssertEqual(app.aiProbeMessage, "连接成功")
    }

    /// 保存了不同的 AI 配置：之前的结果不算数，回到「没测过」；还在跑的那次作废
    func testSavingADifferentConfigResetsTheRailIcon() async throws {
        let app = AppModel()
        app.reportAIProbe(ProbeResult(ok: true, message: "连接成功"))
        app.resetAIProbe()
        XCTAssertEqual(app.aiProbe, .unknown)
        app.testAIConnection(using: {
            try? await Task.sleep(for: .milliseconds(300))
            return ProbeResult(ok: true, message: "旧配置的结果")
        })
        app.resetAIProbe()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(app.aiProbe, .unknown, "作废的那次回来也不写")
        app.testAIConnection(using: { ProbeResult(ok: true, message: "新的") })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(app.aiProbe, .ok, "作废之后还能再测")
    }
}
