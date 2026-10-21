import XCTest
@testable import Xipixiaojuchang

/// 缩略图磁盘缓存只增不减（用户机器上 600MB / 近 3000 个文件）：超过上限从最旧的开始删，删到目标大小。
final class ThumbnailDiskCacheTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func makeFile(_ name: String, megabytes: Int, ageDays: Int) throws {
        let url = dir.appendingPathComponent(name)
        try Data(count: megabytes * 1024 * 1024).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-Double(ageDays) * 86400)], ofItemAtPath: url.path)
    }

    private var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    func testNothingIsDeletedUnderTheLimit() throws {
        for i in 0..<4 { try makeFile("a\(i).png", megabytes: 1, ageDays: i) }
        XCTAssertEqual(ThumbnailDiskCache.trim(directory: dir, limit: 5 * 1024 * 1024, target: 3 * 1024 * 1024), 0)
        XCTAssertEqual(names.count, 4)
    }

    func testOverTheLimitTheOldestGoFirstDownToTheTarget() throws {
        for i in 0..<8 { try makeFile("t\(i).png", megabytes: 1, ageDays: 10 - i) }       // t0 最旧、t7 最新
        let removed = ThumbnailDiskCache.trim(directory: dir, limit: 5 * 1024 * 1024, target: 3 * 1024 * 1024)
        XCTAssertEqual(removed, 5, "8MB 超过 5MB 上限：删到 3MB 以内 = 删 5 个")
        XCTAssertEqual(names, ["t5.png", "t6.png", "t7.png"], "留下的是最新的三个")
    }

    func testSubfoldersAndHiddenFilesAreLeftAlone() throws {
        for i in 0..<6 { try makeFile("t\(i).png", megabytes: 1, ageDays: 10 - i) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("子文件夹"), withIntermediateDirectories: true)
        try Data(count: 1024).write(to: dir.appendingPathComponent(".DS_Store"))
        _ = ThumbnailDiskCache.trim(directory: dir, limit: 4 * 1024 * 1024, target: 2 * 1024 * 1024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("子文件夹").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".DS_Store").path))
    }
}
