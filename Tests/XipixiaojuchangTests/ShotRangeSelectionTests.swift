import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 生视频页「按范围选」（2026-10-27）：集范围 + 最多几个（按显示顺序）+ 跳过已完成 / 正在生成的
@MainActor
final class ShotRangeSelectionTests: XCTestCase {
    private typealias Options = ShotRangeSelection.Options

    /// 3 集各 3 段 + 1 条不属于任何一集的；第 1 集第 1 段已完成，第 2 集第 2 段生成中
    private func fixture() -> (shots: [ShotDraft], episodeOf: [UUID: Int], busy: Set<UUID>) {
        var shots: [ShotDraft] = [], episodeOf: [UUID: Int] = [:]
        for e in 1...3 {
            for s in 1...3 {
                let shot = ShotDraft(projectKey: "k", prompt: "\(e)-\(s)", numbering: ShotNumbering(a: e, b: s))
                shots.append(shot)
                episodeOf[shot.id] = e
            }
        }
        shots.append(ShotDraft(projectKey: "k", prompt: "其他"))
        return (shots, episodeOf, [shots[0].id, shots[4].id])
    }

    private func pick(_ options: Options) -> [String] {
        let f = fixture()
        let ids = ShotRangeSelection.pick(f.shots, options: options, episodeOf: { f.episodeOf[$0] }, isBusyOrDone: { f.busy.contains($0.id) })
        return ids.map { id in f.shots.first { $0.id == id }!.prompt }
    }

    func testAllEpisodesSkipsBusyAndKeepsShotsOutsideEpisodes() {
        XCTAssertEqual(pick(Options()), ["1-2", "1-3", "2-1", "2-3", "3-1", "3-2", "3-3", "其他"])
        XCTAssertEqual(pick(Options(skipsBusyOrDone: false)).count, 10)
    }

    func testEpisodeRangeAndLimitFollowTheDisplayOrder() {
        XCTAssertEqual(pick(Options(episodes: 2...3)), ["2-1", "2-3", "3-1", "3-2", "3-3"], "指定集：不属于任何一集的不算")
        XCTAssertEqual(pick(Options(episodes: 2...3, limit: 3)), ["2-1", "2-3", "3-1"], "跳过的不占名额")
        XCTAssertEqual(pick(Options(limit: 2, skipsBusyOrDone: false)), ["1-1", "1-2"])
    }

    func testEpisodeIndexComesFromEachEpisodesShotList() {
        let a = UUID(), b = UUID(), c = UUID()
        var first = Episode(title: "第1集", text: ""), second = Episode(title: "第2集", text: "")
        first.shotIDs = [a, b]
        second.shotIDs = [c]
        let map = ShotRangeSelection.episodeIndex(ProjectPipelineArchive(wholeScript: "", episodes: [first, second]))
        XCTAssertEqual(map, [a: 1, b: 1, c: 2])
        XCTAssertTrue(ShotRangeSelection.episodeIndex(nil).isEmpty)
    }

    /// 人工核对：设 `XIPI_SHOT=路径` 才出图
    func testPanelRenders() {
        guard let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] else { return }
        for (name, episodes) in [("episodes", 12), ("free", 0)] {
            let size = CGSize(width: 360, height: 360)
            let host = NSHostingView(rootView: ShotRangePanel(episodeCount: episodes, count: { $0.limit ?? 37 }, onPick: { _ in }, onClose: {})
                .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "-\(name).png"))
            }
            window.orderOut(nil)
        }
    }
}
