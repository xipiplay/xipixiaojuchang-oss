import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 生成参数搬进底部工具条（2026-10-08）：右栏原来钉在底部的「生成参数 + 提交生成」现在在工具条里。
@MainActor
final class ToolbarGenerationParamsTests: XCTestCase {
    private func makeApp(mode: AppModel.WorkspaceMode) -> (AppModel, String) {
        let app = AppModel()
        let key = "toolbar-params-" + UUID().uuidString
        app.currentProjectKey = key
        app.workspaceMode = mode
        app.shots.append(ShotDraft(projectKey: key, prompt: "镜头", numbering: ShotNumbering(a: 3, b: 2)))
        app.imageItems.append(ImageGenItem(projectKey: key, name: "林知夏", prompt: "角色图"))
        return (app, key)
    }

    /// 工具条里「导入 / 新增（真按钮）+ 参数」摆成一排的理想宽度；`container` = 工具条所在的可用宽度（决定常规 / 紧凑档）
    private func idealContentWidth(_ app: AppModel, container: CGFloat) -> CGFloat {
        let content = HStack(spacing: 12) {
            BarIconButton(icon: "doc.badge.plus", help: "导入") {}
            BarIconButton(icon: "plus", help: "新增") {}
            ToolbarGenerationParams()
        }
        .environment(app)
        .environment(\.toolbarContainerWidth, container)
        return NSHostingView(rootView: content).fittingSize.width
    }

    /// 胶囊本身占的宽度：内边距 12×2 + 两侧留白 16×2。用真的 `ToolbarRow` 量一次，确认这个常数没变
    private let chrome: CGFloat = 56

    func testTheCapsuleChromeIsWhatTheOtherTestsAssume() {
        let (app, _) = makeApp(mode: .video)
        let bar = ToolbarRow {
            HStack(spacing: 12) {
                BarIconButton(icon: "doc.badge.plus", help: "导入") {}
                BarIconButton(icon: "plus", help: "新增") {}
                ToolbarGenerationParams()
            }
        }
        // 不在窗口里量 → 容器宽度还是 0 → 常规档
        let whole = NSHostingView(rootView: bar.environment(app)).fittingSize.width
        XCTAssertEqual(whole, idealContentWidth(app, container: 0) + chrome, accuracy: 1)
    }

    func testTheRightPanelAndTheToolbarAgreeOnWhichCardIsBeingViewed() {
        let (app, _) = makeApp(mode: .video)
        XCTAssertEqual(app.inspectedShot?.id, app.currentShots.first?.id, "没点过：退回第一张")
        app.timelineShotID = UUID()
        XCTAssertEqual(app.inspectedShot?.id, app.currentShots.first?.id, "点的那张已经不在了：退回第一张")
        let second = ShotDraft(projectKey: app.currentProjectKey ?? "", prompt: "第二张", numbering: ShotNumbering(a: 3, b: 3))
        app.shots.append(second)
        app.timelineShotID = second.id
        XCTAssertEqual(app.inspectedShot?.id, second.id)

        app.imageItems.append(ImageGenItem(projectKey: app.currentProjectKey ?? "", name: "第二个", prompt: "x"))
        let target = app.currentImageItems.last!
        XCTAssertEqual(app.inspectedImageItem?.id, app.currentImageItems.first?.id)
        app.inspectedImageItemID = target.id
        XCTAssertEqual(app.inspectedImageItem?.id, target.id)
    }

    func testTheSubmitRulesAreTheSameOnesTheRightPanelUsed() {
        let (app, _) = makeApp(mode: .video)
        let shot = app.currentShots[0]
        let issues = ShotSubmitRules.issues(shot, app: app)
        XCTAssertFalse(issues.isEmpty, "没有提示词以外的条件时也要说清缺什么（没配视频模型）")
        XCTAssertTrue(issues.contains { $0.contains("模型") })
        XCTAssertFalse(ShotSubmitRules.isSubmitting(shot, app: app))
        app.submittingShotIDs.insert(shot.id)
        XCTAssertTrue(ShotSubmitRules.isSubmitting(shot, app: app), "点了提交、拿到任务号之前也算提交中（按钮要灰）")
    }

    func testTheBarWithParamsFitsEvenTheSmallestWindowAndShrinksWhenSqueezed() {
        // 工具条在整个内容区居中；最小窗口 1160 − 左栏 52 = 1108
        let smallest: CGFloat = 1108
        XCTAssertGreaterThanOrEqual(smallest, ToolbarGenerationParams.compactBelow, "最小窗口用常规档")
        for mode in [AppModel.WorkspaceMode.video, .image] {
            let (app, _) = makeApp(mode: mode)
            let normal = idealContentWidth(app, container: smallest) + chrome
            print("TOOLBAR-WIDTH \(mode) 常规档=\(Int(normal))/\(Int(smallest))")
            XCTAssertLessThanOrEqual(normal, smallest, "\(mode)：最小窗口里放得下")
            XCTAssertLessThanOrEqual(normal, ToolbarGenerationParams.compactBelow, "常规档的宽度不超过切换阈值")

            let squeezed = ToolbarGenerationParams.compactBelow - 20
            let compact = idealContentWidth(app, container: squeezed) + chrome
            print("TOOLBAR-WIDTH \(mode) 紧凑档=\(Int(compact))/\(Int(squeezed))")
            XCTAssertLessThan(compact, normal)
            XCTAssertLessThanOrEqual(compact, squeezed, "\(mode)：窗口被压窄时紧凑档放得下")
        }
    }

    /// 用户要求（2026-10-08）：生图和生视频的工具条一样宽
    func testTheImageAndVideoToolbarsAreExactlyTheSameWidth() {
        for container in [CGFloat(1108), ToolbarGenerationParams.compactBelow - 20] {
            let (video, _) = makeApp(mode: .video)
            let (image, _) = makeApp(mode: .image)
            let v = idealContentWidth(video, container: container)
            let i = idealContentWidth(image, container: container)
            print("TOOLBAR-SAME container=\(Int(container)) video=\(v) image=\(i)")
            XCTAssertEqual(v, i, accuracy: 0.5, "容器宽 \(Int(container))：两页工具条同宽")
        }
    }

    /// 用户要求（2026-10-08）：工具条在整个窗口里居中，和弹窗对齐（原来在内容区里居中，比窗口中心偏右 22）
    func testTheToolbarIsCenteredInTheWholeWindowLikeTheModals() async throws {
        for mode in [AppModel.WorkspaceMode.video, .image] {
            let (app, key) = makeApp(mode: mode)
            app.projectMetas[key] = ProjectMeta(name: "居中", createdAt: Date(), updatedAt: Date())
            app.isInWorkspace = true
            app.projectPage = .production
            let host = NSHostingView(rootView: RootView().environment(app))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            for _ in 0..<10 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
            let frame = app.workspaceToolbarFrame
            let windowWidth = host.bounds.width
            print("TOOLBAR-CENTER \(mode) 胶囊 midX=\(frame.midX) 窗口中心=\(windowWidth / 2) 宽=\(frame.width)")
            XCTAssertGreaterThan(frame.width, 100, "\(mode)：量到了工具条")
            XCTAssertEqual(frame.midX, windowWidth / 2, accuracy: 1.5, "\(mode)：工具条中心 = 窗口中心")
        }
    }

    // MARK: 抽屉打开时胶囊让位（从根上解「抽屉一开胶囊换色」：不叠，就不用换）

    func testTheCapsuleOnlyYieldsWhenADrawerWouldCoverIt() {
        let capsule: CGFloat = 650                    // 视频侧常规档的胶囊宽
        let limitGap = ToolbarRowLayout.drawerGap
        func shift(_ container: CGFloat, open: Bool = true) -> CGFloat {
            ToolbarRowLayout.drawerAvoidanceShift(containerWidth: container, capsuleWidth: capsule, drawerOpen: open)
        }
        XCTAssertEqual(shift(1100, open: false), 0, "抽屉没开：不动")
        XCTAssertEqual(shift(1500), 0, "窗口够大，本来就不叠：不动")
        XCTAssertEqual(shift(0), 0, "还没量到宽度：不动")

        // 最小窗口 1160（内容区 1100）：要让，让完刚好离抽屉 12pt，且还在容器里
        let narrow = shift(1100)
        XCTAssertGreaterThan(narrow, 0)
        let center = 1100 / 2 - AppWindowShellLayout.contentCenterOffset - narrow
        XCTAssertEqual(center + capsule / 2, 1100 - AppWindowShellLayout.drawerWidth - limitGap, accuracy: 0.01, "右端离抽屉左边正好 12pt")
        XCTAssertGreaterThanOrEqual(center - capsule / 2, 0, "没挪出容器")

        // 容器越窄让得越多，直到贴到容器左缘为止
        XCTAssertGreaterThan(shift(1000), shift(1100))
        let tiny = shift(700)
        XCTAssertEqual(700 / 2 - AppWindowShellLayout.contentCenterOffset - tiny - capsule / 2, 0, accuracy: 0.01, "放不下时只挪到容器左缘（紧凑档接手）")
    }

    private func toolbarFrame(inWindowOfWidth width: CGFloat, drawerOpen: Bool) async throws -> CGRect {
        let (app, key) = makeApp(mode: .video)
        app.projectMetas[key] = ProjectMeta(name: "让位", createdAt: Date(), updatedAt: Date())
        app.isInWorkspace = true
        app.projectPage = .production
        let host = NSHostingView(rootView: RootView().environment(app))
        host.sizingOptions = []                       // 让窗口大小由测试定，不被 SwiftUI 的理想尺寸改回去
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<6 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        // RootView 出现时会把窗口设回默认尺寸（`AppWindowShellLayout.minimumWidth/Height`）：等它设完，再改成要测的宽度
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: true)
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        XCTAssertEqual(host.bounds.width, width, accuracy: 0.5, "窗口宽度没设成功：\(host.bounds.width)")
        if drawerOpen { app.showTaskDrawer = true }
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        return app.workspaceToolbarFrame
    }

    func testWithTheDrawerOpenTheCapsuleNeverTouchesItAtAnyRealisticWindowWidth() async throws {
        for width in [AppWindowShellLayout.minimumWidth, 1322, 1440] {   // 窗口最小 1275（2026-10-15），比它窄的设不出来
            let closed = try await toolbarFrame(inWindowOfWidth: width, drawerOpen: false)
            let open = try await toolbarFrame(inWindowOfWidth: width, drawerOpen: true)
            let drawerLeft = width - AppWindowShellLayout.edgeInset - AppWindowShellLayout.drawerWidth
            print("TOOLBAR-DRAWER width=\(Int(width)) 关: \(Int(closed.minX))…\(Int(closed.maxX)) 开: \(Int(open.minX))…\(Int(open.maxX)) 抽屉左边=\(Int(drawerLeft))")
            XCTAssertEqual(closed.midX, width / 2, accuracy: 1.5, "\(Int(width))：抽屉关着，在窗口正中")
            XCTAssertLessThanOrEqual(open.maxX, drawerLeft - ToolbarRowLayout.drawerGap + 1.5, "\(Int(width))：抽屉开着，胶囊不碰抽屉")
            XCTAssertGreaterThan(open.minX, AppWindowShellLayout.railWidth, "\(Int(width))：也没挪进左边的导航栏")
            if width >= 1440 { XCTAssertEqual(open.midX, closed.midX, accuracy: 1.5, "窗口够大：抽屉开关，胶囊纹丝不动") }
        }
    }

    func testTheCardNameIsNotInTheToolbarSoALongNameCannotStretchIt() {
        let (app, key) = makeApp(mode: .image)
        let short = idealContentWidth(app, container: 1108)
        app.imageItems.removeAll { $0.projectKey == key }
        app.imageItems.append(ImageGenItem(projectKey: key, name: String(repeating: "很长很长的素材名", count: 8), prompt: "x"))
        XCTAssertEqual(idealContentWidth(app, container: 1108), short, accuracy: 0.5, "卡片名字长短不影响工具条宽度")
    }

    func testNothingShowsWhenTheProjectHasNoCards() {
        let app = AppModel()
        app.currentProjectKey = "empty-" + UUID().uuidString
        app.workspaceMode = .video
        let params = NSHostingView(rootView: ToolbarGenerationParams().environment(app).environment(\.toolbarContainerWidth, 1108))
        XCTAssertLessThan(params.fittingSize.width, 1, "空项目没有卡：工具条里不出现参数")
    }
}
