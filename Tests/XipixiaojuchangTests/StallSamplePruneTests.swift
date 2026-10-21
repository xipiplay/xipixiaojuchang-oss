import XCTest
@testable import Xipixiaojuchang

/// 卡顿 sample 不能无限攒（2026-10-14 用户电脑上 3052 份、5.4 GB）：只留最近 7 天、最多 50 份，别的文件不碰
final class StallSamplePruneTests: XCTestCase {
    func testKeepsRecentFiftyAndLeavesOtherFilesAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stall-prune-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        // 60 份最近 2 天的 + 5 份 10 天前的 + 不相干的文件
        for i in 0..<65 {
            let url = dir.appendingPathComponent(String(format: "stall-%03d.txt", i))
            try Data("x".utf8).write(to: url)
            let age: TimeInterval = i < 60 ? Double(i) * 1800 : 10 * 86400 + Double(i)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        for name in ["app.log", "stall-notes.md", "project.json"] { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }

        MainThreadWatchdog.pruneSamples(in: dir, now: now)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let samples = left.filter { $0.hasPrefix("stall-") && $0.hasSuffix(".txt") }.sorted()
        XCTAssertEqual(samples.count, 50, "最多留 50 份")
        XCTAssertEqual(samples.first, "stall-000.txt", "留的是最新的")
        XCTAssertEqual(samples.last, "stall-049.txt")
        XCTAssertTrue(Set(left).isSuperset(of: ["app.log", "stall-notes.md", "project.json"]), "别的文件不碰（只认 stall-*.txt）")
    }

    func testOldOnesGoEvenWhenFewerThanFifty() {
        let now = Date()
        let files: [(url: URL, date: Date)] = [
            (URL(fileURLWithPath: "/x/stall-a.txt"), now.addingTimeInterval(-3600)),
            (URL(fileURLWithPath: "/x/stall-b.txt"), now.addingTimeInterval(-8 * 86400)),
        ]
        XCTAssertEqual(MainThreadWatchdog.samplesToDelete(files, now: now).map(\.lastPathComponent), ["stall-b.txt"], "超过 7 天的删")
    }
}
