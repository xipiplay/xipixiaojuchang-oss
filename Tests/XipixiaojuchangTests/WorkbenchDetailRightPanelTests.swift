import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 二级页面右栏（2026-10-16 用户）：「本段剧情」只有名字和 30 秒剧情、占满整栏；本段素材只在「本段预览」下面。
/// 用户还说素材区和剧情框能左右滑（录屏：妙控鼠标横划，字 / 卡整体偏一截再弹回）：不是内容超宽，是滚动区横向橡皮筋，
/// 改成横向位置一偏就拉回 0（文本框 `VerticalOnlyClipView`，素材区 `VerticalScrollLock`）。离屏模拟不了手势，直接改滚动位置看会不会被拉回
@MainActor
final class WorkbenchDetailRightPanelTests: XCTestCase {
    override func tearDown() async throws {
        await MainActor.run { WorkbenchSegmentDetail.testStartsOnStory = false; WorkbenchSegmentDetail.testStartsOnPreview = false }
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func setUp(_ key: String) -> AppModel {
        let app = AppModel()
        let shot = ShotDraft(projectKey: key, prompt: "[客栈 日 内][甲、乙、丙、丁][饭盒、赛车、测试记录]\n镜头1：甲推门进来。")
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：客栈 日 内\n【角色】：甲、乙、丙、丁\n【道具】：饭盒、赛车、测试记录\n【本段在场】：甲\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 1)
        return app
    }

    private func show(_ app: AppModel) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .environment(\.hoverFeedbackEnabled, false).frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        return (window, host)
    }

    /// 右栏里的滚动区（不算剧情 / 名字 / 提示词那些文本框自带的）
    private func rightScrollViews(_ host: NSView) -> [NSScrollView] {
        views(NSScrollView.self, in: host).filter { sv in
            sv.convert(sv.bounds, to: host).minX > 720 && !(sv.documentView is NSTextView)
        }
    }

    func testStoryTabHasOnlyNameAndStoryFillingTheColumn() throws {
        WorkbenchSegmentDetail.testStartsOnStory = true
        let key = "right-story-" + UUID().uuidString
        let app = setUp(key)
        defer { app.shots.removeAll { $0.projectKey == key } }
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let story = try XCTUnwrap(views(ScriptTextView.self, in: host).first { $0.string.contains("甲推门进来") })
        let frame = try XCTUnwrap(story.enclosingScrollView).convert(story.enclosingScrollView!.bounds, to: host)
        print("[right] 剧情框 \(frame)")
        XCTAssertGreaterThan(frame.height, 450, "剧情框占满名字下面的整栏（原来下面还有素材，只有一百多高）")
        XCTAssertTrue(rightScrollViews(host).isEmpty, "剧情页下面不再挂本段素材")
        // 名字框、剧情框：横向推不动
        for text in views(ScriptTextView.self, in: host) where text.convert(text.bounds, to: host).minX > 720 {
            let scroll = try XCTUnwrap(text.enclosingScrollView)
            scroll.contentView.setBoundsOrigin(NSPoint(x: 20, y: 0))
            scroll.contentView.scroll(to: NSPoint(x: 20, y: 0))
            XCTAssertEqual(scroll.contentView.bounds.origin.x, 0, "「\(text.string.prefix(6))」框横向钉在 0")
            XCTAssertEqual(scroll.horizontalScrollElasticity, .none)
        }
    }

    func testPreviewTabHasMaterialsThatOnlyScrollVertically() throws {
        WorkbenchSegmentDetail.testStartsOnPreview = true
        let key = "right-preview-" + UUID().uuidString
        let app = setUp(key)
        defer { app.shots.removeAll { $0.projectKey == key } }
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let list = try XCTUnwrap(rightScrollViews(host).first, "预览下面有本段素材")
        let doc = list.documentView?.frame ?? .zero
        print("[right] 素材滚动区 \(list.frame) 内容 \(doc) 横向回弹 \(list.horizontalScrollElasticity.rawValue) 竖向回弹 \(list.verticalScrollElasticity.rawValue) 横向滚动条 \(list.hasHorizontalScroller)")
        XCTAssertLessThanOrEqual(doc.width, list.contentView.bounds.width + 0.5, "内容不比滚动区宽")
        XCTAssertEqual(list.horizontalScrollElasticity, .none, "横向不回弹：左右划不动")
        // 横向被推开：拉回 0。⚠️ 素材区是 SwiftUI 的滚动区，代码直接改位置它自己就会夹回去（去掉 VerticalScrollLock 这条也过），
        // 真手势的橡皮筋离屏模拟不了——这条只守「不会停在偏开的位置」；文本框那条去掉修复会失败
        list.contentView.setBoundsOrigin(NSPoint(x: 40, y: list.contentView.bounds.origin.y))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(list.contentView.bounds.origin.x, 0, accuracy: 0.5, "素材区横向位置拉回 0")
    }
}
