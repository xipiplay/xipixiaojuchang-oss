import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分镜网格上点开某一段的弹窗、关掉后：网格停在那一段附近，不滑回顶部（2026-10-12 用户碰到）。
/// 根因是卡片和顶上概览进度条的每一格都拿段号当标识，`scrollTo(段号)` 找到的是顶上那一格
@MainActor
final class WorkbenchSegmentGridScrollTests: XCTestCase {
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }

    func testClosingSegmentDetailKeepsGridNearThatSegment() throws {
        let app = AppModel()
        let key = "grid-scroll-" + UUID().uuidString
        var split = ""
        for i in 0..<60 {
            split += String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
            split += "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 第\(i + 1)段的剧情。\n"
        }
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = split
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        // 进页面就接着回到第 55 段（和从生图 / 生视频页回来一样）：弹窗开着
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 55)

        let host = NSHostingView(rootView: PipelinePage().environment(app).frame(width: 1300, height: 800))
        host.frame = CGRect(x: 0, y: 0, width: 1300, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let grid = try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertGreaterThan(grid.documentView?.frame.height ?? 0, 2000, "60 段的网格比窗口高得多")

        let close = try XCTUnwrap(app.closeWorkbenchSegmentDetail, "弹窗开着时 Esc 路由拿得到关闭动作")
        close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(app.closeWorkbenchSegmentDetail, "关掉后收回")
        XCTAssertGreaterThan(grid.contentView.bounds.origin.y, 1000, "停在第 55 段附近，不回到顶部")
    }

    /// 弹窗里从第 3 段一路点「下一段」翻到第 28 段再关：网格停在打开时的第 3 段，不跟着跳到后面（2026-10-13 用户定）
    func testFlippingThroughSegmentsThenClosingStaysWhereOpened() throws {
        let app = AppModel()
        let key = "grid-flip-" + UUID().uuidString
        var split = ""
        for i in 0..<30 {
            split += String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
            split += "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 第\(i + 1)段的剧情。\n"
        }
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = split
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 3)

        let host = NSHostingView(rootView: PipelinePage().environment(app).frame(width: 1300, height: 800))
        host.frame = CGRect(x: 0, y: 0, width: 1300, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let grid = try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        let startY = grid.contentView.bounds.origin.y

        // ⌘] 下一段 × 25
        for _ in 0..<25 {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil, characters: "]",
                                                       charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30))
            _ = window.performKeyEquivalent(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(app.workbenchLocations[key]?.segment, 28, "确实翻到了第 28 段")

        try XCTUnwrap(app.closeWorkbenchSegmentDetail)()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(abs(grid.contentView.bounds.origin.y - startY), 50, "关掉后网格还在打开时的位置，没跳到第 28 段")
        window.orderOut(nil)
    }
}
