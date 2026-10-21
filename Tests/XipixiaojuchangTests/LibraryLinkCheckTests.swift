import XCTest
@testable import Xipixiaojuchang

/// 素材库「检查链接」（2026-10-09）：批量入库后还在上传的素材不能算失效；临时性错误重试、仍没答复的不标失效；失效标记传完就消。
private final class ScriptedProtocol: URLProtocol, @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String])
    /// 每个 URL 的应答脚本：按顺序消耗，用完了重复最后一条；`nil` = 抛网络错误
    nonisolated(unsafe) static var scripts: [String: [Reply?]] = [:]
    nonisolated(unsafe) static var hits: [String: [String]] = [:]     // URL → 依次收到的方法（HEAD / GET）
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!.absoluteString
        Self.lock.lock()
        Self.hits[url, default: []].append(request.httpMethod ?? "?")
        var script = Self.scripts[url] ?? [(404, [:])]
        let reply = script.count > 1 ? script.removeFirst() : script[0]
        Self.scripts[url] = script
        Self.lock.unlock()
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD" { client?.urlProtocol(self, didLoad: Data([0])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func reset() { lock.lock(); scripts = [:]; hits = [:]; lock.unlock() }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        return URLSession(configuration: configuration)
    }
}

final class LibraryLinkProbeTests: XCTestCase {
    private let fast: [Duration] = [.milliseconds(1), .milliseconds(1)]
    private func verdict(_ url: String, _ script: [ScriptedProtocol.Reply?]) async -> LinkVerdict {
        ScriptedProtocol.reset()
        ScriptedProtocol.scripts[url] = script
        return await LibraryLinkProbe.verdict(for: url, session: ScriptedProtocol.session(), retryDelays: fast)
    }

    func testNoLinkOrNotHTTPIsDead() async {
        let none = await LibraryLinkProbe.verdict(for: nil)
        let file = await LibraryLinkProbe.verdict(for: "file:///a.png")
        XCTAssertEqual(none, .dead("没有可用的直链"))
        XCTAssertEqual(file, .dead("没有可用的直链"))
    }

    func testHeadWithContentIsAlive() async {
        let v = await verdict("https://h.test/a.png", [(200, ["Content-Length": "2048"])])
        XCTAssertEqual(v, .alive)
        XCTAssertEqual(ScriptedProtocol.hits["https://h.test/a.png"], ["HEAD"])
    }

    func testZeroLengthHeadIsReCheckedWithARangedGet() async {
        // catbox 的 nginx 对 HEAD 一律回 0
        let url = "https://h.test/b.png"
        let v = await verdict(url, [(200, ["Content-Length": "0"]), (206, ["Content-Range": "bytes 0-0/2005963"])])
        XCTAssertEqual(v, .alive)
        XCTAssertEqual(ScriptedProtocol.hits[url], ["HEAD", "GET"])
    }

    func testAGenuinelyEmptyFileIsDead() async {
        let url = "https://h.test/c.png"
        let v = await verdict(url, [(200, ["Content-Length": "0"]), (206, ["Content-Range": "bytes 0-0/0"])])
        XCTAssertEqual(v, .dead("文件是空的（0 字节）"))
    }

    func test404And410AreDeadWithoutRetry() async {
        for status in [404, 410, 400] {
            let url = "https://h.test/\(status).png"
            let v = await verdict(url, [(status, [:])])
            guard case .dead = v else { return XCTFail("\(status) 应当确定失效：\(v)") }
            XCTAssertEqual(ScriptedProtocol.hits[url]?.count, 1, "确定失效就不重试")
        }
    }

    func testRateLimitedThenOKIsAlive() async {
        let url = "https://h.test/d.png"
        let v = await verdict(url, [(429, [:]), (503, [:]), (200, ["Content-Length": "10"])])
        XCTAssertEqual(v, .alive, "429 / 5xx 自动重试，后来拿到明确答复就用它")
        XCTAssertEqual(ScriptedProtocol.hits[url]?.count, 3)
    }

    func testStillNoAnswerAfterRetriesIsUnsureNotDead() async {
        for script in [[(429, [String: String]()) as ScriptedProtocol.Reply?], [(503, [:])], [nil]] {
            let v = await verdict("https://h.test/e.png", script)
            guard case .unsure = v else { return XCTFail("多次都没拿到明确答复：不能标失效，实际 \(v)") }
            XCTAssertEqual(ScriptedProtocol.hits["https://h.test/e.png"]?.count, 3, "一共试 3 次")
        }
    }

    func test403And405FallBackToARangedGet() async {
        for status in [403, 405] {
            let url = "https://h.test/\(status).png"
            let v = await verdict(url, [(status, [:]), (206, ["Content-Range": "bytes 0-0/99"])])
            XCTAssertEqual(v, .alive, "HEAD 被拒（\(status)）退回 GET 复核")
        }
    }
}

@MainActor
final class LibraryLinkCheckTests: XCTestCase {
    private typealias Item = Xipixiaojuchang.LibraryItem

    private func item(_ name: String, state: Xipixiaojuchang.LibraryItem.UploadState, url: String?, key: String) -> Item {
        var item = Item(kind: .image, localPath: nil, fileName: name, name: name, projectKey: key)
        item.uploadState = state
        item.remoteURL = url
        return item
    }

    func testStillUploadingItemsAreSkippedButFailedUploadsAreReportedAsDead() async {
        ScriptedProtocol.reset()
        let app = AppModel()
        let key = "link-check-" + UUID().uuidString
        let ok = item("好的", state: .uploaded, url: "https://h.test/ok.png", key: key)
        let gone = item("没了", state: .uploaded, url: "https://h.test/gone.png", key: key)
        let uploading = item("上传中", state: .uploading, url: nil, key: key)
        let pending = item("待上传", state: .pending, url: nil, key: key)
        let failed = item("上传失败", state: .failed, url: nil, key: key)
        ScriptedProtocol.scripts["https://h.test/ok.png"] = [(200, ["Content-Length": "5"])]
        ScriptedProtocol.scripts["https://h.test/gone.png"] = [(404, [:])]
        app.currentProjectKey = key
        app.library = [ok, gone, uploading, pending, failed]
        // 之前检查时留下的旧失效标记（那时它们还没传完）
        app.libraryLinkStatus = [uploading.id: false, pending.id: false]
        defer { app.library = []; app.currentProjectKey = nil }

        await app.checkLibraryLinks(session: ScriptedProtocol.session(), retryDelays: [.milliseconds(1)])

        XCTAssertEqual(app.libraryLinkStatus[ok.id], true)
        XCTAssertEqual(app.libraryLinkStatus[gone.id], false)
        XCTAssertNil(app.libraryLinkStatus[uploading.id], "还在上传：不检查，旧的失效标记也清掉")
        XCTAssertNil(app.libraryLinkStatus[pending.id])
        XCTAssertEqual(app.libraryLinkStatus[failed.id], false, "上传失败：没有可用的链接，算失效（列表里显示「失效」、能被一键重传）")
        XCTAssertEqual(app.deadLibraryLinkCount, 2, "真失效的 + 上传失败的")
        let note = app.libraryLinkCheckNote ?? ""
        XCTAssertTrue(note.contains("已检查 3 个") && note.contains("失效 2 个（其中 1 个是上传失败的"), note)
        XCTAssertTrue(note.contains("还在上传的 2 个没查"), note)
        XCTAssertFalse(app.checkingLibraryLinks)
    }

    func testAFailedUploadThatWasLaterRetriedAndSucceededIsCheckedLikeAnyOtherLink() async {
        ScriptedProtocol.reset()
        let app = AppModel()
        let key = "link-check-" + UUID().uuidString
        let healed = item("补传成功", state: .uploaded, url: "https://h.test/healed.png", key: key)
        ScriptedProtocol.scripts["https://h.test/healed.png"] = [(200, ["Content-Length": "5"])]
        app.currentProjectKey = key
        app.library = [healed]
        app.libraryLinkStatus = [healed.id: false]          // 上一次检查时它还是上传失败
        defer { app.library = []; app.currentProjectKey = nil }
        await app.checkLibraryLinks(session: ScriptedProtocol.session(), retryDelays: [.milliseconds(1)])
        XCTAssertEqual(app.libraryLinkStatus[healed.id], true, "重新查，链接是好的就改成可用")
        XCTAssertEqual(app.deadLibraryLinkCount, 0)
        XCTAssertFalse((app.libraryLinkCheckNote ?? "").contains("上传失败"))
    }

    func testReuploadingTellsHowManyCouldNotBeRetriedBecauseTheLocalFileIsGone() async {
        let app = AppModel()
        let key = "link-check-" + UUID().uuidString
        let lost = item("文件没了", state: .failed, url: nil, key: key)              // localPath = nil：没有本地文件，不会发起网络请求
        app.currentProjectKey = key
        app.library = [lost]
        app.libraryLinkStatus = [lost.id: false]
        defer { app.library = []; app.currentProjectKey = nil }
        await app.reuploadFailedLinks()
        XCTAssertEqual(app.libraryLinkCheckNote, "重传完成：成功 0 个 · 本地文件已不在 1 个（没法重传）")
        XCTAssertEqual(app.libraryLinkStatus[lost.id], false, "没传成的仍留着失效标记")
        XCTAssertFalse(app.reuploadingLibrary)
    }

    func testAnUnconfirmedLinkIsNotMarkedDeadAndLosesItsOldMark() async {
        ScriptedProtocol.reset()
        let app = AppModel()
        let key = "link-check-" + UUID().uuidString
        let flaky = item("抖动", state: .uploaded, url: "https://h.test/flaky.png", key: key)
        ScriptedProtocol.scripts["https://h.test/flaky.png"] = [(429, [:])]
        app.currentProjectKey = key
        app.library = [flaky]
        app.libraryLinkStatus = [flaky.id: false]          // 上一次检查误标的
        defer { app.library = []; app.currentProjectKey = nil }

        await app.checkLibraryLinks(session: ScriptedProtocol.session(), retryDelays: [.milliseconds(1)])

        XCTAssertNil(app.libraryLinkStatus[flaky.id], "没能确认：不标失效，旧的误标也撤掉")
        XCTAssertEqual(app.deadLibraryLinkCount, 0)
        XCTAssertTrue((app.libraryLinkCheckNote ?? "").contains("没能确认 1 个"))
    }
}
