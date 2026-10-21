import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分镜一级页面的滚动内容高度（2026-10-16 A/B 实验）：A = 懒加载网格自己估总高（会随滑动变），
/// B = 按 `SectionLayout.contentHeight` 定死。B 要做到：往返滑高度不变、懒加载还在、节头位置和算的一样、首尾不多不少
@MainActor
final class WorkbenchStableHeightTests: XCTestCase {
    /// 段数各不相同：0 = 还没分割（只有节头），含末行不满、刚好排满、只有一张
    static let counts = [7, 0, 3, 8, 1, 6, 5, 0, 0, 9, 4, 2, 12, 3, 6, 5, 1, 8, 7, 0, 10, 6, 3, 4]

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkbenchSegmentGrid.stableHeightKey)
        WorkbenchSegmentGrid.testBuiltCells = nil
        HeaderTopProbe.record = nil
        super.tearDown()
    }

    private func makeApp(_ counts: [Int] = counts) -> (AppModel, String) {
        let app = AppModel()
        let key = "stable-" + UUID().uuidString
        var episodes: [Episode] = []
        for (e, count) in counts.enumerated() {
            var split = ""
            var ids: [UUID] = []
            for i in 0..<count {
                let shot = ShotDraft(projectKey: key, prompt: "[客栈 日 内][甲][ ]\n镜头1：甲。")
                app.shots.append(shot); ids.append(shot.id)
                split += String(format: "=== [%02d:%02d-%02d:%02d] ===\n", i / 2, (i % 2) * 30, (i + 1) / 2, ((i + 1) % 2) * 30)
                split += "【场景】：客栈 日 内\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 第\(e + 1)集第\(i + 1)段。\n"
            }
            var episode = Episode(title: "标题\(e + 1)", text: "原文")
            if count > 0 { episode.splitText = split; episode.shotIDs = ids }
            episodes.append(episode)
        }
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: episodes), for: key)
        app.isInWorkspace = true; app.projectPage = .script
        return (app, key)
    }

    private func show(_ app: AppModel, width: CGFloat) -> (NSWindow, NSScrollView) {
        // 关掉悬停反馈：全量测试时真鼠标可能正停在某张卡上，那张卡会亮（截图比对实测碰到过）
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .environment(\.hoverFeedbackEnabled, false))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: width, height: 800), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        func views(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap { views($0) } }
        let grid = views(host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
        return (window, grid)
    }

    private func layout(_ grid: NSScrollView, _ counts: [Int] = counts) -> WorkbenchSegmentGrid.SectionLayout {
        WorkbenchSegmentGrid.SectionLayout(rowCounts: counts, episodes: Array(counts.indices),
                                           columns: WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, cell: WorkbenchSegmentGrid.cardHeight)
    }

    private struct Pass {
        var heights: [CGFloat] = []
        var headers: [Int: CGFloat] = [:]
        var drift: CGFloat = 0
    }

    /// 一步一步滑，每步记内容高度、偏移回写误差、看得见的节头在整列里的位置
    private func sweep(_ grid: NSScrollView, from: CGFloat, to: CGFloat, step: CGFloat, into pass: inout Pass) {
        var y = from
        while step > 0 ? y <= to : y >= to {
            grid.contentView.scroll(to: NSPoint(x: 0, y: y)); grid.reflectScrolledClipView(grid.contentView)
            HeaderTopProbe.record = [:]
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            pass.heights.append(grid.documentView?.frame.height ?? 0)
            let actual = grid.contentView.bounds.origin.y
            pass.drift = max(pass.drift, abs(actual - y))
            for (ep, top) in HeaderTopProbe.record ?? [:] { pass.headers[ep] = top + actual }
            y += step
        }
    }

    private func roundTrip(stable: Bool, width: CGFloat) throws -> (pass: Pass, built: Int, total: Int, grid: NSScrollView, window: NSWindow) {
        UserDefaults.standard.set(stable, forKey: WorkbenchSegmentGrid.stableHeightKey)
        let (app, _) = makeApp()
        WorkbenchSegmentGrid.testBuiltCells = []
        let (window, grid) = show(app, width: width)
        let firstScreen = WorkbenchSegmentGrid.testBuiltCells?.count ?? 0
        var pass = Pass()
        let maxY = (grid.documentView?.frame.height ?? 0) - grid.contentView.bounds.height
        // 中途内容高度若变短，也照样从 maxY 往回滑（滑不到的地方 drift 会记下来）
        sweep(grid, from: 0, to: maxY, step: 97, into: &pass)
        sweep(grid, from: maxY, to: 0, step: -131, into: &pass)
        sweep(grid, from: 0, to: maxY, step: 113, into: &pass)
        print("[stable-height] \(stable ? "B" : "A") 宽 \(width)：首屏建卡 \(firstScreen)，高度 \(Set(pass.heights).sorted())，回写误差 \(pass.drift)")
        return (pass, firstScreen, Self.counts.reduce(0, +), grid, window)
    }

    func testStableHeightDoesNotChangeWhileScrolling() throws {
        for width in [1100.0, 1410.0] {
            let b = try roundTrip(stable: true, width: width)
            defer { b.window.orderOut(nil) }
            let layout = layout(b.grid)
            XCTAssertEqual(Set(b.pass.heights).count, 1, "宽 \(width)：B 往返滑内容高度不变")
            // 内容 = 网格总高 + 底部 padding 14；胶囊留白走 contentMargins（滚动区的 inset），不在内容里
            XCTAssertEqual(b.pass.heights.first ?? 0, layout.contentHeight + 14, accuracy: 0.5, "宽 \(width)：内容高度就是算出来的")
            XCTAssertEqual(b.pass.drift, 0, accuracy: 0.5, "宽 \(width)：滚到哪就停在哪")
            print("[stable-height] 宽 \(width) 没量到的节头：\(Set(Self.counts.indices).subtracting(b.pass.headers.keys).sorted())")
            XCTAssertGreaterThan(b.pass.headers.count, Self.counts.count - 3, "宽 \(width)：几乎每个节头都量到了")
            for (ep, top) in b.pass.headers {
                XCTAssertEqual(layout.starts[ep], top, accuracy: 1, "宽 \(width)：第 \(ep + 1) 集节头在算的位置")
            }
        }
    }

    /// 对照：A 的高度会不会变（只记录，不当失败）——确认这个实验条件确实不同
    func testBaselineHeightIsRecorded() throws {
        let a = try roundTrip(stable: false, width: 1100)
        a.window.orderOut(nil)
        XCTAssertFalse(a.pass.heights.isEmpty)
    }

    func testLazinessSurvives() throws {
        let b = try roundTrip(stable: true, width: 1100)
        b.window.orderOut(nil)
        XCTAssertLessThan(b.built, 24, "首屏只建看得见附近的卡（共 \(b.total) 张）")
        XCTAssertGreaterThan(b.built, 0)
    }

    /// 最后一行能完整滚到胶囊上面，再往下没有多余空白；滚动区底部 inset = 胶囊留白 − 14
    func testBottomEdge() throws {
        let b = try roundTrip(stable: true, width: 1100)
        defer { b.window.orderOut(nil) }
        let grid = b.grid
        let inset = grid.contentInsets.bottom
        XCTAssertEqual(inset, PipelinePageLayout.capsuleClearance - 14, accuracy: 0.5)
        // 走 NSView.scroll(_:)：会按滚动范围夹住，等于用户一直往下推到推不动
        grid.documentView?.scroll(NSPoint(x: 0, y: 1_000_000)); grid.reflectScrolledClipView(grid.contentView)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let docHeight = grid.documentView?.frame.height ?? 0
        let bottom = grid.contentView.bounds.maxY
        // 滚到底时视口下沿 = 内容底 + inset，网格最后一行底边离视口下沿 = 14 + inset = 胶囊留白
        XCTAssertEqual(bottom, docHeight + inset, accuracy: 1, "滚到底不多不少")
        XCTAssertEqual(bottom - layout(grid).contentHeight, PipelinePageLayout.capsuleClearance, accuracy: 1, "最后一行停在胶囊上面")
    }

    /// 窗口宽度变 → 一行几张变：内容高度跟着重算，节头还在算的位置
    func testWidthChangeRecomputes() throws {
        UserDefaults.standard.set(true, forKey: WorkbenchSegmentGrid.stableHeightKey)
        let (app, _) = makeApp()
        let (window, grid) = show(app, width: 1410)
        defer { window.orderOut(nil) }
        let before = grid.documentView?.frame.height ?? 0
        let columnsBefore = WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count
        XCTAssertEqual(before, layout(grid).contentHeight + 14, accuracy: 0.5)
        window.setContentSize(NSSize(width: 1100, height: 800))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = grid.documentView?.frame.height ?? 0
        XCTAssertNotEqual(columnsBefore, WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, "列数确实变了")
        XCTAssertEqual(after, layout(grid).contentHeight + 14, accuracy: 0.5, "换列数后高度跟着算对")
        var pass = Pass()
        sweep(grid, from: 0, to: after - grid.contentView.bounds.height, step: 151, into: &pass)
        XCTAssertEqual(Set(pass.heights).count, 1)
        for (ep, top) in pass.headers { XCTAssertEqual(layout(grid).starts[ep], top, accuracy: 1, "第 \(ep + 1) 集") }
    }

    /// 在无障碍树里找某个标识的元素
    private func element(_ id: String, in root: Any) -> NSAccessibilityProtocol? {
        guard let e = root as? NSAccessibilityProtocol else { return nil }
        if e.accessibilityIdentifier() == id { return e }
        for child in e.accessibilityChildren() ?? [] {
            if let found = element(id, in: child) { return found }
        }
        return nil
    }

    /// 点左边的集 / 进页面恢复 / 关掉详情：B 的落点要和 A 一模一样，并且在该在的地方。
    /// ⚠️ 程序 `scrollTo` 之后，离屏窗口里 NSClipView 的 bounds 和 SwiftUI 真画的位置不同步（截图对、clip y 差上千），
    /// 所以落点用 `HeaderTopProbe` 量节头离滚动区上沿多远（SwiftUI 自己的坐标）。
    /// A 本来就有 ~7.5 点的过冲（`scrollToEpisode` 的锚点算法，跟这次实验无关），所以允许 −10…+2
    func testJumpsLandWhereComputed() throws {
        var results: [Bool: [CGFloat]] = [:]
        var shots: [Bool: Data?] = [:]
        for stable in [false, true] {
            UserDefaults.standard.set(stable, forKey: WorkbenchSegmentGrid.stableHeightKey)
            let tag = stable ? "B" : "A"
            var landed: [CGFloat] = []
            // 1. 点左边的集（离屏窗口没有无障碍树，只能真的点）：沿左栏从上往下点，点到第 5 集以后、有段的那一集为止
            do {
                let (app, key) = makeApp()
                HeaderTopProbe.record = [:]
                let (window, _) = show(app, width: 1100)
                defer { window.orderOut(nil) }
                var target: Int?
                for y in stride(from: 760.0, to: 40.0, by: -29.0) {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 90, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                        window.sendEvent(event)
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                    if let ep = app.pipelineArchive(for: key)?.epIndex, ep >= 4, Self.counts[ep] > 0 { target = ep; break }
                }
                let ep = try XCTUnwrap(target, "\(tag)：点到了左栏的一集")
                let top = try XCTUnwrap(HeaderTopProbe.record?[ep], "\(tag)：第 \(ep + 1) 集节头排出来了")
                print("[stable-height] \(tag) 点第 \(ep + 1) 集：节头离上沿 \(top)")
                XCTAssert((-10...2).contains(top), "\(tag)：第 \(ep + 1) 集节头贴顶（\(top)）")
                landed.append(top)
            }
            // 2. 进页面恢复到上次看的第 18 集
            do {
                let (app, key) = makeApp()
                var archive = try XCTUnwrap(app.pipelineArchive(for: key)); archive.epIndex = 17
                app.savePipelineArchive(archive, for: key)
                HeaderTopProbe.record = [:]
                let (window, _) = show(app, width: 1100)
                defer { window.orderOut(nil) }
                let top = try XCTUnwrap(HeaderTopProbe.record?[17], "\(tag)：第 18 集节头排出来了")
                print("[stable-height] \(tag) 进页面第 18 集：节头离上沿 \(top)")
                XCTAssert((-10...2).contains(top), "\(tag)：进来停在第 18 集开头（\(top)）")
                landed.append(top)
            }
            // 3. 接着打开第 21 集第 9 段（10 段、一行 3 张 → 第 3 行），关掉详情
            do {
                let (app, key) = makeApp()
                var archive = try XCTUnwrap(app.pipelineArchive(for: key)); archive.epIndex = 20
                app.savePipelineArchive(archive, for: key)
                app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 20, segment: 9)
                let (window, grid) = show(app, width: 1100)
                defer { window.orderOut(nil) }
                try XCTUnwrap(app.closeWorkbenchSegmentDetail, "\(tag)：详情开着")()
                RunLoop.main.run(until: Date().addingTimeInterval(1.5))     // 等左栏淡入等动画走完
                // 节头这时已滑出去、被回收，探针留的是旧值，量不准：只截网格那一块，A、B 比像素（人工看过：第 3 行 7～9 段在视口中间）
                let rep = try XCTUnwrap(grid.bitmapImageRepForCachingDisplay(in: grid.bounds))
                grid.cacheDisplay(in: grid.bounds, to: rep)
                shots[stable] = rep.tiffRepresentation
            }
            results[stable] = landed
        }
        XCTAssertEqual(results[true]?.count, results[false]?.count)
        for (b, a) in zip(results[true] ?? [], results[false] ?? []) {
            XCTAssertEqual(b, a, accuracy: 0.5, "B 和 A 落点一样（只差亚像素）")
        }
        // 落点不同会整块错开（几乎每个像素都变）；只差个别像素不算
        let b = try XCTUnwrap(shots[true] ?? nil), a = try XCTUnwrap(shots[false] ?? nil)
        XCTAssertEqual(b.count, a.count, "两张截图一样大")
        let differing = zip(b, a).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertLessThan(Double(differing) / Double(max(b.count, 1)), 0.02, "关详情回来，B 和 A 截图几乎一样（不同字节 \(differing)）")
    }

    /// 换筛选（「待提取」把还没分割的空集藏掉）：内容高度按剩下的集重算，滑动中照样不变
    func testFilterChangeRecomputes() throws {
        UserDefaults.standard.set(true, forKey: WorkbenchSegmentGrid.stableHeightKey)
        let (app, _) = makeApp()
        let (window, grid) = show(app, width: 1100)
        defer { window.orderOut(nil) }
        XCTAssertEqual(grid.documentView?.frame.height ?? 0, layout(grid).contentHeight + 14, accuracy: 0.5)
        // 「待提取 110」小标签：筛选条第二个（窗口 1100 宽时约在 x 333、离窗口上沿 67）
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 333, y: 800 - 67), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let nonEmpty = Self.counts.filter { $0 > 0 }
        let filtered = WorkbenchSegmentGrid.SectionLayout(rowCounts: nonEmpty, episodes: Array(nonEmpty.indices),
                                                          columns: WorkbenchSegmentGrid.columns(forWidth: grid.frame.width).count, cell: WorkbenchSegmentGrid.cardHeight)
        let height = grid.documentView?.frame.height ?? 0
        print("[stable-height] 筛选后高度 \(height)，算的 \(filtered.contentHeight + 14)，全部时 \(layout(grid).contentHeight + 14)")
        XCTAssertEqual(height, filtered.contentHeight + 14, accuracy: 0.5, "筛选后按剩下 \(nonEmpty.count) 集算")
        var pass = Pass()
        sweep(grid, from: 0, to: height - grid.contentView.bounds.height, step: 157, into: &pass)
        sweep(grid, from: height - grid.contentView.bounds.height, to: 0, step: -173, into: &pass)
        XCTAssertEqual(Set(pass.heights).count, 1, "筛选后往返滑高度不变")
    }
}
