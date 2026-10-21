import XCTest
import SwiftUI
@testable import Xipixiaojuchang

@MainActor
final class WorkbenchEpisodeScrollSyncTests: XCTestCase {
    func testStopSamplesFinalEpisodeBeforeLateGeometryNotification() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 52
        _ = metrics.phaseChanged(from: .idle, to: .interacting, episode: 52)
        // 页面停在第53集；最后的几何通知尚未送到，停下时视口已经到了第56集。
        let end = metrics.phaseChanged(from: .interacting, to: .idle, episode: 55)
        XCTAssertEqual(end.episode, 55)
        XCTAssertTrue(end.settled)
        XCTAssertEqual(metrics.visibleEpisode, 55)
        XCTAssertNil(metrics.moved(to: 55).episode, "晚到的几何通知不能重复换集")
    }

    func testStartSamplesGeometryAlreadyDeliveredBeforeInteraction() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 52
        XCTAssertNil(metrics.moved(to: 55).episode, "尚未认作用户滚动，不跟随")
        let begin = metrics.phaseChanged(from: .tracking, to: .interacting, episode: 55)
        XCTAssertEqual(begin.episode, 55, "几何结果按集号去重，不会重发；开始阶段自己校准")
        XCTAssertFalse(begin.settled)
    }

    func testMomentumOnlyCommitsWhenItStopsAndCanReverse() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 52
        _ = metrics.phaseChanged(from: .idle, to: .interacting, episode: 52)
        XCTAssertEqual(metrics.moved(to: 53).episode, 53)
        let momentum = metrics.phaseChanged(from: .interacting, to: .decelerating, episode: 54)
        XCTAssertEqual(momentum.episode, 54)
        XCTAssertFalse(momentum.settled)
        let end = metrics.phaseChanged(from: .decelerating, to: .idle, episode: 55)
        XCTAssertEqual(end.episode, 55)
        XCTAssertTrue(end.settled)
        _ = metrics.phaseChanged(from: .idle, to: .interacting, episode: 55)
        let reverse = metrics.phaseChanged(from: .interacting, to: .idle, episode: 51)
        XCTAssertEqual(reverse.episode, 51)
        XCTAssertTrue(reverse.settled)
    }

    func testGeometryBeforeStopCommitsWithoutDuplicateHighlight() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 52
        _ = metrics.phaseChanged(from: .idle, to: .interacting, episode: 52)
        XCTAssertEqual(metrics.moved(to: 55).episode, 55)
        let end = metrics.phaseChanged(from: .interacting, to: .idle, episode: 55)
        XCTAssertNil(end.episode)
        XCTAssertTrue(end.settled)
    }

    func testProgrammaticScrollDoesNotOverrideChosenEpisode() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 55
        XCTAssertNil(metrics.moved(to: 54).episode)
        XCTAssertNil(metrics.phaseChanged(from: .idle, to: .animating, episode: 54).episode)
        let end = metrics.phaseChanged(from: .animating, to: .idle, episode: 54)
        XCTAssertFalse(end.settled)
        XCTAssertEqual(metrics.visibleEpisode, 55)
    }

    func testLongGridWheelScrollMatchesVisibleHeader() throws {
        HeaderTopProbe.record = [:]
        defer { HeaderTopProbe.record = nil }
        let (app, key, counts) = makeApp()
        var visible = 0
        let host = NSHostingView(rootView: WorkbenchBoardProvider {
            WorkbenchSegmentGrid(currentEpisode: 0, projectKey: key,
                                 onVisibleEpisode: { visible = $0 })
        }.environment(app).environment(\.hoverFeedbackEnabled, false))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 750),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        let grid = try XCTUnwrap(scrolls(host).first)
        func wheel(_ delta: Int32, phase: Int64, momentum: Int64 = 0) throws {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                             wheel1: delta, wheel2: 0, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            grid.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
        }
        try wheel(-10, phase: 1)
        for _ in 0..<180 {
            try wheel(-260, phase: 2)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try wheel(0, phase: 4)
        try wheel(-1, phase: 0, momentum: 1)
        try wheel(-1, phase: 0, momentum: 2)
        try wheel(0, phase: 0, momentum: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(0..<56),
            columns: WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, cell: WorkbenchSegmentGrid.cardHeight)
        let y = grid.contentView.bounds.minY
        let expected = layout.episodes[layout.position(at: y, viewport: grid.contentView.bounds.height)]
        print("[scroll-sync] y=\(y) expected=\(expected) visible=\(visible)")
        XCTAssertGreaterThan(y, layout.starts[53])
        XCTAssertEqual(visible, expected)
    }

    private func makeApp(initialEpisode: Int = 0) -> (AppModel, String, [Int]) {
        let app = AppModel()
        let key = "scroll-sync-" + UUID().uuidString
        var counts = (0..<56).map { [6, 7, 3, 8, 5, 6][$0 % 6] }
        counts[50] = 3; counts[51] = 4; counts[52] = 4; counts[53] = 3; counts[54] = 5; counts[55] = 6   // 尾部按真实项目（第51～56集）
        let episodes = counts.enumerated().map { e, count in
            var episode = Episode(title: "第\(e + 1)集", text: "原文")
            episode.splitText = (0..<count).map { i in
                String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
                    + "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n△ 第\(e + 1)集第\(i + 1)段。\n"
            }.joined()
            if e == 52 {
                let shot = ShotDraft(projectKey: key, prompt: "[客栈 日 内][甲][ ]\n镜头1：甲。")
                app.shots.append(shot)
                episode.shotIDs = [shot.id]
            }
            return episode
        }
        app.currentProjectKey = key
        var archive = ProjectPipelineArchive(wholeScript: "全文", episodes: episodes)
        archive.epIndex = initialEpisode
        app.savePipelineArchive(archive, for: key)
        app.isInWorkspace = true; app.projectPage = .script
        return (app, key, counts)
    }

    /// 页面集号与长列表一起验证；手势通知顺序由上面的阶段测试覆盖。
    /// ⚠️ 窗高必须覆盖 828：用户真实窗口下视口 728pt > 末节块 712pt，最后一节的起点滚不到顶上
    /// （2026-10-17 真实反馈，见 `testBottomReportsLastWhenItsStartCannotReachTop`）；800 高时视口 700 够得到。
    func testPageFollowsBottomAndReverseAtTwoColumnCounts() throws {
        WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = true
        defer { WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = false; HeaderTopProbe.record = nil }
        for height in [800.0, 828.0] {
            for width in [1100.0, 1300.0] {
                let (app, key, counts) = makeApp(initialEpisode: 52)
                let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }
                    .environment(app).environment(\.glassEffectEnabled, false)
                    .environment(\.hoverFeedbackEnabled, false).environment(\.colorScheme, .dark))
                let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFront(nil)
                defer { window.orderOut(nil) }
                RunLoop.main.run(until: Date().addingTimeInterval(1))
                func scrolls(_ view: NSView) -> [NSScrollView] {
                    ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
                }
                let grid = try XCTUnwrap(scrolls(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
                let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(0..<56),
                    columns: WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, cell: WorkbenchSegmentGrid.cardHeight)
                // 先消除恢复定位造成的 AppKit / SwiftUI 偏移，再连续滑到末尾。
                let start = layout.starts[51]
                for y in stride(from: start, through: layout.contentHeight, by: 97) {
                    grid.documentView?.scroll(NSPoint(x: 0, y: y))
                    grid.reflectScrolledClipView(grid.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                grid.documentView?.scroll(NSPoint(x: 0, y: 1_000_000))
                grid.reflectScrolledClipView(grid.contentView)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                try snapshot(host, name: "bottom-\(Int(height))-\(Int(width))")
                app.projectPage = .production
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                XCTAssertEqual(app.pipelineArchive(for: key)?.epIndex, 55, "高\(Int(height)) 宽\(Int(width))：第56集与页面同步")
                app.projectPage = .script
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                for y in stride(from: grid.contentView.bounds.minY, through: layout.starts[51] + 100, by: -113) {
                    grid.contentView.scroll(to: NSPoint(x: 0, y: y))
                    grid.reflectScrolledClipView(grid.contentView)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                try snapshot(host, name: "reverse-\(Int(height))-\(Int(width))")
                app.projectPage = .production
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                XCTAssertEqual(app.pipelineArchive(for: key)?.epIndex, 51, "反向滑回第52集")
            }
        }
    }

    /// 2026-10-17 真实反馈：最后一集（第56集）整块 650 + 底垫 62 = 712pt，比视口 728pt 矮，
    /// 滚到最底它的起点还差 16pt 顶不到上面——视口里已经全是它、末尾也露出来了，按起点算却还是上一集。
    func testBottomReportsLastWhenItsStartCannotReachTop() {
        var counts = (0..<12).map { [6, 7, 3, 8, 5, 6][$0 % 6] }
        counts[11] = 6
        let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(0..<12),
            columns: 3, cell: WorkbenchSegmentGrid.cardHeight)
        let viewport: CGFloat = 728
        let last = counts.count - 1
        let maxOffset = layout.contentHeight + 62 - viewport     // 网格底垫 14 + 胶囊让位 48；页面里滚到底的偏移
        XCTAssertLessThan(maxOffset + 2, layout.starts[last], "前提：最后一节的起点确实滚不到（正是这次的情况）")
        XCTAssertEqual(layout.position(at: maxOffset), last - 1, "旧算法滚到底还是上一节——这次修的就是它")
        XCTAssertEqual(layout.position(at: maxOffset, viewport: viewport), last, "滚到底报最后一节")
        XCTAssertEqual(layout.position(at: maxOffset - 61, viewport: viewport), last, "末尾进视口起就算最后一节")
        XCTAssertEqual(layout.position(at: maxOffset - 63, viewport: viewport), last - 1, "末尾还没进视口时仍按视口顶那一节")
    }

    /// 中段不受影响：视口里没到末尾时，还是「起点在视口顶之上的最后一节」。
    func testViewportDoesNotChangeMidScroll() {
        var counts = (0..<12).map { [6, 7, 3, 8, 5, 6][$0 % 6] }
        counts[11] = 6
        let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(0..<12),
            columns: 3, cell: WorkbenchSegmentGrid.cardHeight)
        for offset in [0, 300, layout.starts[5], layout.starts[9]] {
            XCTAssertEqual(layout.position(at: offset, viewport: 728), layout.position(at: offset),
                           "offset=\(offset) 两种算法应一致")
        }
    }

    /// 2026-10-18：滑到最底常以回弹动画收尾（interacting/decelerating → animating → idle）。
    /// 从用户滚动接过来的动画，停稳时也要算一次落地——原来这种收尾会被当成程序滚动、跳过提交
    func testAnAnimationThatFollowsUserScrollingCommitsWhenItSettles() {
        let momentum = WorkbenchSegmentGrid.Metrics()
        momentum.visibleEpisode = 52
        _ = momentum.phaseChanged(from: .idle, to: .interacting, episode: 52)
        _ = momentum.phaseChanged(from: .interacting, to: .decelerating, episode: 53)
        _ = momentum.phaseChanged(from: .decelerating, to: .animating, episode: 54)
        let end = momentum.phaseChanged(from: .animating, to: .idle, episode: 55)
        XCTAssertEqual(end.episode, 55)
        XCTAssertTrue(end.settled, "回弹停稳：提交最终位置")

        let pull = WorkbenchSegmentGrid.Metrics()
        pull.visibleEpisode = 52
        _ = pull.phaseChanged(from: .idle, to: .interacting, episode: 52)
        _ = pull.phaseChanged(from: .interacting, to: .animating, episode: 54)
        let rebound = pull.phaseChanged(from: .animating, to: .idle, episode: 54)
        XCTAssertEqual(rebound.episode, 54)
        XCTAssertTrue(rebound.settled, "拉过头直接回弹：也算落地")
    }

    /// 程序自己的动画（点选集跳转的收尾，idle → animating → idle）不算落地：不能抢回用户选中的集
    func testAProgrammaticAnimationDoesNotSettle() {
        let metrics = WorkbenchSegmentGrid.Metrics()
        metrics.visibleEpisode = 55
        XCTAssertNil(metrics.phaseChanged(from: .idle, to: .animating, episode: 54).episode)
        let end = metrics.phaseChanged(from: .animating, to: .idle, episode: 54)
        XCTAssertFalse(end.settled)
        XCTAssertEqual(metrics.visibleEpisode, 55)
    }

    /// 内容不够一屏（很短的项目）：顶部不算「到底」，不要一进来就报最后一节。
    func testShortContentDoesNotJumpToLastAtTop() {
        let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: [2, 2], episodes: [0, 1], columns: 3,
            cell: WorkbenchSegmentGrid.cardHeight)
        XCTAssertLessThanOrEqual(layout.contentHeight, 728, "前提：内容比视口矮")
        XCTAssertEqual(layout.position(at: 0, viewport: 728), 0)
    }

    /// 2026-10-18：缩放窗口换了列数 → 内容整个重排（像素偏移不动，但对应的集变了）——
    /// 要按新位置表把当前集自动校准提交一次，不能等下一次滚动才更新。
    func testResizingTheWindowRecalibratesTheCommittedEpisode() throws {
        WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = true
        defer { WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = false; HeaderTopProbe.record = nil }
        // 第 52 集有分镜卡：页面自动停在「分镜」网格上（第 1 集没有卡会停在「分割」文本页，抓不到网格）
        let (app, key, counts) = makeApp(initialEpisode: 52)
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }
            .environment(app).environment(\.glassEffectEnabled, false)
            .environment(\.hoverFeedbackEnabled, false).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1300, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        func scrolls(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrolls)
        }
        let grid = try XCTUnwrap(scrolls(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        func layout() -> WorkbenchSegmentGrid.SectionLayout {
            WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(0..<56),
                columns: WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, cell: WorkbenchSegmentGrid.cardHeight)
        }
        // 从第 52 集往回扫到第 21 集开头（逐步扫，和页面测试同一个套路），确认提交的是它
        let target = 20
        for y in stride(from: layout().starts[51], through: layout().starts[target], by: -197) {
            grid.documentView?.scroll(NSPoint(x: 0, y: y))
            grid.reflectScrolledClipView(grid.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        grid.documentView?.scroll(NSPoint(x: 0, y: layout().starts[target]))
        grid.reflectScrolledClipView(grid.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(app.pipelineArchive(for: key)?.epIndex, target, "先落在第 \(target + 1) 集")
        app.projectPage = .script
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let columnsBefore = WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count
        XCTAssertGreaterThan(columnsBefore, 1, "前提：宽窗口是多列（抓到的是网格而不是文本框）")
        // 缩窄窗口：列数变了、内容重排；像素偏移不动，映射会落到更早的一集
        window.setContentSize(NSSize(width: 1000, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertNotEqual(WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, columnsBefore, "前提：列数确实变了")
        let offset = grid.contentView.bounds.minY
        let now = layout()
        let expected = now.episodes[now.position(at: offset, viewport: grid.contentView.bounds.height)]
        XCTAssertLessThan(expected, target, "前提：同样的像素偏移在窄窗口里对应更早的一集")
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(app.pipelineArchive(for: key)?.epIndex, expected, "缩放后按新位置表自动校准")
    }

    private func snapshot(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["XIPI_SCROLL_SHOTS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

}
