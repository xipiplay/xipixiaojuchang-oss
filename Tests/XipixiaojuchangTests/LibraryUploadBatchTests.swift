import XCTest
@testable import Xipixiaojuchang

/// 上传时的数量（2026-10-09）：批量入库一两百张同时在传，素材库底部显示「上传中 45/167 · 失败 3」，传完留一句结果。
final class LibraryUploadBatchStructTests: XCTestCase {
    private typealias Batch = AppModel.LibraryUploadBatch

    func testTheLabelCountsFinishedOverTotalAndMentionsFailures() {
        var batch = Batch()
        for _ in 0..<167 { batch.begin() }
        for _ in 0..<45 { batch.finish(failed: false) }
        XCTAssertTrue(batch.isRunning)
        XCTAssertEqual(batch.label, "上传中 45/167")
        for _ in 0..<3 { batch.finish(failed: true) }
        XCTAssertEqual(batch.label, "上传中 48/167 · 失败 3", "失败的也算传完了，但要看得见")
    }

    func testABatchIsDoneWhenEveryItemSucceededOrFailedAndANewUploadStartsAFreshCount() {
        var batch = Batch()
        batch.begin(); batch.begin()
        batch.finish(failed: false); batch.finish(failed: true)
        XCTAssertFalse(batch.isRunning)
        XCTAssertEqual(batch.succeeded, 1)
        batch.begin()                                           // 上一批传完了：新的一批从 0 开始数
        XCTAssertEqual(batch, { var b = Batch(); b.begin(); return b }())
        XCTAssertEqual(batch.label, "上传中 0/1")
    }

    func testUploadsAddedWhileABatchIsRunningJoinThatBatch() {
        var batch = Batch()
        batch.begin(); batch.begin()
        batch.finish(failed: false)
        batch.begin()                                           // 还有一张没传完：这张算同一批
        XCTAssertEqual(batch.total, 3)
        XCTAssertEqual(batch.finished, 1)
    }

    func testTheSummaryIsKeptOnlyWhenItIsWorthSaying() {
        func done(total: Int, failed: Int) -> Batch {
            var batch = Batch()
            for _ in 0..<total { batch.begin() }
            for index in 0..<total { batch.finish(failed: index < failed) }
            return batch
        }
        XCTAssertNil(done(total: 1, failed: 0).summary, "拖进一张图传成功了：不用说")
        XCTAssertNil(done(total: 4, failed: 0).summary)
        XCTAssertEqual(done(total: 167, failed: 0).summary, "上传完成：成功 167 个", "一批不少的，说一句")
        XCTAssertEqual(done(total: 2, failed: 1).summary, "上传完成：成功 1 个 · 失败 1 个（点「检查链接」，再点「重传失效」可以重传）", "有失败的一定要说")
        var running = Batch(); running.begin()
        XCTAssertNil(running.summary, "还在传：没有结果可说")
    }
}

private struct FakeUploader: UploadService {
    let supportsLocalFiles = true
    let failing: Set<String>
    let delay: Duration
    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        try await Task.sleep(for: delay)
        if case .local(let url) = item.source, failing.contains(url.lastPathComponent) { throw UploadError.notAvailable }
        return RemoteMaterial(url: "https://fake.test/\(UUID().uuidString).png", duration: nil)
    }
}

@MainActor
final class LibraryUploadBatchWiringTests: XCTestCase {
    private typealias Item = Xipixiaojuchang.LibraryItem

    func testTheBatchCountsEveryUploadAndLeavesASummaryWhenAllAreDone() async throws {
        let app = AppModel()
        let key = "upload-batch-" + UUID().uuidString
        app.currentProjectKey = key
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); app.library = []; app.currentProjectKey = nil }
        app.uploadServiceOverride = FakeUploader(failing: ["bad.png"], delay: .milliseconds(60))

        var items: [Item] = []
        for name in ["a.png", "b.png", "bad.png", "c.png", "d.png", "e.png"] {
            let url = folder.appendingPathComponent(name)
            try Data([0x89]).write(to: url)
            items.append(Item(kind: .image, localPath: url.path, fileName: name, projectKey: key))
        }
        app.library = items
        for item in items { app.uploadLibraryItem(item.id) }

        XCTAssertEqual(app.libraryUploadBatch.total, 6)
        XCTAssertTrue(app.libraryUploadBatch.isRunning)
        XCTAssertEqual(app.libraryUploadBatch.label, "上传中 0/6")

        while app.libraryUploadBatch.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(app.libraryUploadBatch.finished, 6)
        XCTAssertEqual(app.libraryUploadBatch.failed, 1)
        XCTAssertEqual(app.library.filter { $0.uploadState == .uploaded }.count, 5)
        XCTAssertEqual(app.library.first { $0.fileName == "bad.png" }?.uploadState, .failed)
        XCTAssertEqual(app.libraryLinkCheckNote, "上传完成：成功 5 个 · 失败 1 个（点「检查链接」，再点「重传失效」可以重传）")

        // 下一次上传是新的一批
        let url = folder.appendingPathComponent("again.png")
        try Data([0x89]).write(to: url)
        let again = Item(kind: .image, localPath: url.path, fileName: "again.png", projectKey: key)
        app.library.append(again)
        app.uploadLibraryItem(again.id)
        XCTAssertEqual(app.libraryUploadBatch.total, 1)
        XCTAssertEqual(app.libraryUploadBatch.finished, 0)
        while app.libraryUploadBatch.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    }
}
