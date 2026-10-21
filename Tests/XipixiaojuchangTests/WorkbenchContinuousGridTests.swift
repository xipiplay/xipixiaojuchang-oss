import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分镜一级页面所有集连着滑（2026-10-13 用户：现在只能点选集、滑这一集里的）：
/// 一整列每集一节，节头吸顶；用户滑到哪一集，左边集列表 / 页头 / 胶囊跟着换；左边点一集 = 滑到那一集开头
@MainActor
final class WorkbenchContinuousGridTests: XCTestCase {
    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews($0) }
    }

    private func makeApp(episodes count: Int = 4, segments: Int = 6, epIndex: Int = 0) -> (AppModel, String) {
        let app = AppModel()
        let key = "cont-" + UUID().uuidString
        var episodes: [Episode] = []
        for e in 0..<count {
            var split = ""
            var ids: [UUID] = []
            for i in 0..<segments {
                // 有分镜卡才默认看「分镜」（只有分割时默认看「分割」）
                let shot = ShotDraft(projectKey: key, prompt: "[客栈 日 内][甲][ ]\n镜头1：甲。")
                app.shots.append(shot)
                ids.append(shot.id)
                split += String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
                split += "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 第\(e + 1)集第\(i + 1)段。\n"
            }
            var episode = Episode(title: "标题\(e + 1)", text: "原文")
            episode.splitText = split
            episode.shotIDs = ids
            episodes.append(episode)
        }
        var archive = ProjectPipelineArchive(wholeScript: "全文", episodes: episodes)
        archive.epIndex = epIndex
        app.currentProjectKey = key
        app.savePipelineArchive(archive, for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        return (app, key)
    }

    private func show(_ app: AppModel) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        return (window, host)
    }

    private func grid(_ host: NSView) throws -> NSScrollView {
        try XCTUnwrap(scrollViews(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
    }

    private func epIndex(_ app: AppModel, _ key: String) -> Int? { app.pipelineArchive(for: key)?.epIndex }

    /// 「用户滑」：直接改滚动位置，网格那边当成用户在滑（见 `testTreatsAnyScrollAsUser`）。分几步滑，节头一个个吸上去
    private func userScroll(_ scrollView: NSScrollView, to y: CGFloat, steps: Int = 10) {
        WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = true
        defer { WorkbenchSegmentGrid.testTreatsAnyScrollAsUser = false }
        let start = scrollView.contentView.bounds.origin.y
        for i in 1...steps {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: start + (y - start) * CGFloat(i) / CGFloat(steps)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func testAllEpisodesAreInOneScrollingList() throws {
        let (app, _) = makeApp()
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        // 4 集 × 6 段（每行 3 张，约 450 高一行）：一集一屏多，四集连起来远比一集高
        XCTAssertGreaterThan(grid.documentView?.frame.height ?? 0, 2000, "所有集排在同一列里（一集只有 600 来高）")
    }

    func testUserScrollingIntoAnotherEpisodeFollowsIt() throws {
        let (app, key) = makeApp()
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        XCTAssertEqual(epIndex(app, key), 0)
        // 往下滑过第 1 集（约 2 行卡 + 节头）
        // 4 集一样长：滑到大约 3/8 处 = 第 2 集中间
        userScroll(grid, to: (grid.documentView?.frame.height ?? 0) * 0.375)
        XCTAssertGreaterThan(grid.contentView.bounds.origin.y, 500, "确实滑下去了")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(epIndex(app, key), 0, "滑的时候不写存档（存档一变很多地方要重算，会卡）")
        // 离开这一页：「看到第几集」这时才存
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(epIndex(app, key), 1, "滑进第 2 集：当前集跟着换，离开页面时存下")
        app.projectPage = .script
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // 再滑回顶上
        userScroll(grid, to: 0)
        XCTAssertLessThan(grid.contentView.bounds.origin.y, 50)
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(epIndex(app, key), 0, "滑回第 1 集")
    }

    func testProgrammaticScrollDoesNotChangeTheEpisode() throws {
        let (app, key) = makeApp()
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        // 不是用户滑的（比如弹窗关掉后网格自己滚到那一段）：不改当前集
        grid.contentView.scroll(to: NSPoint(x: 0, y: (grid.documentView?.frame.height ?? 0) * 0.6))
        grid.reflectScrolledClipView(grid.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        XCTAssertEqual(epIndex(app, key), 0)
    }

    func testOpensAtTheSavedEpisode() throws {
        let (app, _) = makeApp(epIndex: 2)
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        XCTAssertGreaterThan(grid.contentView.bounds.origin.y, (grid.documentView?.frame.height ?? 0) * 0.4, "进来时滑到上次看的第 3 集")
    }

    func testClosingDetailOfAnotherEpisodeScrollsBackToIt() throws {
        // 从生图 / 生视频页回来接着打开第 3 集第 5 段：关掉弹窗，网格停在那一段
        let (app, key) = makeApp(epIndex: 2)
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 2, segment: 5)
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        try XCTUnwrap(app.closeWorkbenchSegmentDetail, "弹窗开着")()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertGreaterThan(grid.contentView.bounds.origin.y, (grid.documentView?.frame.height ?? 0) * 0.5, "停在第 3 集第 5 段附近")
        XCTAssertEqual(epIndex(app, key), 2)
    }

    func testFlippingIntoTheNextEpisodeThenClosingReturnsToWhereItOpened() throws {
        // 接着打开第 1 集最后一段（第 6 段），⌘] 翻到第 2 集第 1 段，再关掉
        let (app, key) = makeApp()
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 6)
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let grid = try grid(host)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "]",
                                                   charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30))
        _ = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(app.workbenchLocations[key]?.episodeIndex, 1, "翻到了第 2 集")
        XCTAssertEqual(app.workbenchLocations[key]?.segment, 1, "第 2 集第 1 段")
        try XCTUnwrap(app.closeWorkbenchSegmentDetail)()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let y = grid.contentView.bounds.origin.y
        XCTAssertLessThan(y, (grid.documentView?.frame.height ?? 0) * 0.25, "网格回到打开时的第 1 集第 6 段附近，没停在第 2 集")
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(epIndex(app, key), 0, "关掉后当前集也回到第 1 集")
    }

    func testOpeningASegmentFromElsewhereWhilePageIsHidden() throws {
        // 生图页「用到它的分段」→ 第 2 集第 4 段：工作台常驻、藏着，回来时要接上
        let (app, key) = makeApp()
        let (window, _) = show(app)
        defer { window.orderOut(nil) }
        app.projectPage = .production
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        app.workbenchOpenSegment(episodeIndex: 1, segment: 4)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertTrue(app.isScriptPageVisible)
        XCTAssertNotNil(app.closeWorkbenchSegmentDetail, "弹窗打开了")
        XCTAssertEqual(app.workbenchLocations[key]?.episodeIndex, 1)
        XCTAssertEqual(app.workbenchLocations[key]?.segment, 4)
    }
}

/// 左边集数跟着滑动走，靠的是按位置查「每集从多高开始」（`SectionLayout`）——算出来的起点要和真排出来的节头位置对得上
/// （2026-10-14 用户：滑动时左边集数跳得不准、乱跳；一集只有 7 段时屏幕上同时好几个节头，原来看节头吸没吸顶的办法会乱报）
@MainActor
final class WorkbenchSectionLayoutTests: XCTestCase {
    func testComputedStartsMatchTheRealHeaders() throws {
        HeaderTopProbe.record = [:]
        defer { HeaderTopProbe.record = nil }
        let app = AppModel()
        let key = "layout-" + UUID().uuidString
        var episodes: [Episode] = []
        for e in 0..<6 {
            var split = ""
            var ids: [UUID] = []
            // 段数各不相同（含整行排满、剩一张的情况）
            for i in 0..<[7, 3, 8, 1, 6, 5][e] {
                let shot = ShotDraft(projectKey: key, prompt: "[客栈 日 内][甲][ ]\n镜头1：甲。")
                app.shots.append(shot); ids.append(shot.id)
                split += String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
                split += "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 第\(e + 1)集第\(i + 1)段。\n"
            }
            var episode = Episode(title: "标题\(e + 1)", text: "原文")
            episode.splitText = split; episode.shotIDs = ids
            episodes.append(episode)
        }
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: episodes), for: key)
        app.isInWorkspace = true; app.projectPage = .script
        defer { app.shots.removeAll { $0.projectKey == key } }
        for width in [1100.0, 1410.0] {
            HeaderTopProbe.record = [:]
            let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
                .frame(width: width, height: 800))
            let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            func views(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap { views($0) } }
            let grid = try XCTUnwrap(views(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
            // 一点点往下滑，把每个节头都排出来，记下它在整列里的真实位置（离上沿多远 + 当时滑了多少）
            var real: [Int: CGFloat] = [:]
            var y: CGFloat = 0
            let maxY = (grid.documentView?.frame.height ?? 0) - grid.contentView.bounds.height
            while y <= maxY {
                grid.contentView.scroll(to: NSPoint(x: 0, y: y)); grid.reflectScrolledClipView(grid.contentView)
                HeaderTopProbe.record = [:]
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                for (ep, top) in HeaderTopProbe.record ?? [:] where real[ep] == nil { real[ep] = top + y }
                y += 150
            }
            let columns = WorkbenchSegmentGrid.columns(forWidth: grid.frame.width)
            let layout = WorkbenchSegmentGrid.SectionLayout(rowCounts: [7, 3, 8, 1, 6, 5], episodes: Array(0..<6), columns: columns.count, cell: WorkbenchSegmentGrid.cardHeight)
            XCTAssertGreaterThan(real.count, 3, "宽 \(width)：滑过的节头都量到了")
            for (ep, top) in real {
                XCTAssertEqual(layout.starts[ep], top, accuracy: 2, "宽 \(width)：第 \(ep + 1) 集起点算得对（一行 \(columns.count) 张）")
            }
            window.orderOut(nil)
        }
    }
}

/// 分段弹窗的上一段 / 下一段不限于这一集（2026-10-14 用户）：到了一集的尾巴接下一集的第一段，没分割的集跳过
@MainActor
final class WorkbenchDetailNeighborTests: XCTestCase {
    private func archive(_ counts: [Int]) -> ProjectPipelineArchive {
        let episodes: [Episode] = counts.map { count in
            var episode = Episode(title: "", text: "原文")
            if count > 0 {
                episode.splitText = (0..<count).map { i in
                    String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30) + "△ 第\(i + 1)段。\n"
                }.joined()
            }
            return episode
        }
        return ProjectPipelineArchive(wholeScript: "全文", episodes: episodes)
    }
    typealias Spot = WorkbenchSegmentGrid.Spot

    func testNeighborsCrossEpisodesAndSkipUnsplitOnes() {
        let a = archive([3, 0, 2])
        var n = WorkbenchSegmentDetail.neighbors(of: Spot(episode: 0, segment: 2), in: a)
        XCTAssertEqual(n.previous, Spot(episode: 0, segment: 1)); XCTAssertEqual(n.next, Spot(episode: 0, segment: 3))
        n = WorkbenchSegmentDetail.neighbors(of: Spot(episode: 0, segment: 3), in: a)
        XCTAssertEqual(n.next, Spot(episode: 2, segment: 1), "第 1 集最后一段的下一段 = 第 3 集第 1 段（第 2 集还没分割，跳过）")
        n = WorkbenchSegmentDetail.neighbors(of: Spot(episode: 2, segment: 1), in: a)
        XCTAssertEqual(n.previous, Spot(episode: 0, segment: 3), "往回也一样")
        n = WorkbenchSegmentDetail.neighbors(of: Spot(episode: 0, segment: 1), in: a)
        XCTAssertNil(n.previous, "整部剧的第一段没有上一段")
        n = WorkbenchSegmentDetail.neighbors(of: Spot(episode: 2, segment: 2), in: a)
        XCTAssertNil(n.next, "最后一段没有下一段")
    }
}
