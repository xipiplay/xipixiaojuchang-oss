import XCTest
import SwiftUI
import Observation
@testable import Xipixiaojuchang

@MainActor
final class MediaWorkspacePresentationTests: XCTestCase {
    func testPrebindingDoesNotBuildMediaAndOnlyVisitedPagesAreMaterialized() throws {
        let presentation = MediaWorkspacePresentation()
        XCTAssertNil(presentation.resolve(projectKey: "A", visible: false, mode: .image))
        let image = try XCTUnwrap(presentation.resolve(projectKey: "A", visible: true, mode: .image))
        XCTAssertTrue(image.hasImages)
        XCTAssertFalse(image.hasVideo)
        XCTAssertEqual(presentation.resolve(projectKey: "B", visible: false, mode: .video), image)
        XCTAssertEqual(presentation.resolve(projectKey: nil, visible: false, mode: .video), image)
        let video = try XCTUnwrap(presentation.resolve(projectKey: "A", visible: true, mode: .video))
        XCTAssertTrue(video.hasImages && video.hasVideo, "同一项目切换后保留两页")
        let other = try XCTUnwrap(presentation.resolve(projectKey: "B", visible: true, mode: .video))
        XCTAssertFalse(other.hasImages, "换项目时没访问的页面不创建")
        XCTAssertTrue(other.hasVideo)
    }

    func testHiddenInputStopsObservingLiveDataAndRefreshesWhenShown() {
        let app = AppModel()
        let input = MediaWorkspaceInput<[ImageGenItem]>()
        let first = ImageGenItem(projectKey: "A", name: "甲", prompt: "原提示词")
        app.imageItems = [first]
        XCTAssertEqual(input.value(active: true) { app.imageItems }, [first])
        var reads = 0
        withObservationTracking {
            XCTAssertEqual(input.value(active: false) { reads += 1; return app.imageItems }, [first])
        } onChange: {
            XCTFail("隐藏的输入不能继续订阅实时素材")
        }
        app.imageItems[0].name = "乙"
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(input.value(active: true) { app.imageItems }.first?.name, "乙")
    }

    func testANilInspectorRemainsFrozenUntilItsPageIsShown() {
        let input = MediaWorkspaceInput<ImageGenItem?>()
        let item = ImageGenItem(projectKey: "A", name: "甲", prompt: "提示词")
        XCTAssertNil(input.value(active: true) { nil })
        XCTAssertNil(input.value(active: false) { XCTFail("空详情也应缓存"); return item })
        XCTAssertEqual(input.value(active: true) { item }?.id, item.id)
    }

    func testReopeningTheSameProjectStartsAFreshMediaSessionOnlyWhenVisited() throws {
        let presentation = MediaWorkspacePresentation()
        let old = try XCTUnwrap(presentation.resolve(projectKey: "A", visible: true, mode: .video))
        presentation.didLeaveProject()
        XCTAssertEqual(presentation.resolve(projectKey: "A", visible: false, mode: .image), old)
        let reopened = try XCTUnwrap(presentation.resolve(projectKey: "A", visible: true, mode: .image))
        XCTAssertNotEqual(reopened.id, old.id)
        XCTAssertFalse(reopened.hasVideo, "重开后没访问的媒体页重新按需加载")
    }

    func testRootOnlyBuildsTheVisitedMediaPageAndKeepsItFrozenAcrossProjects() throws {
        let app = AppModel()
        let keys = ["media-A-" + UUID().uuidString, "media-B-" + UUID().uuidString]
        for key in keys {
            app.projectMetas[key] = ProjectMeta(name: key, createdAt: Date(), updatedAt: Date())
            app.imageItems.append(ImageGenItem(projectKey: key, name: key == keys[0] ? "甲角色" : "乙场景", prompt: "提示词"))
            app.shots.append(ShotDraft(projectKey: key, prompt: "[客栈][甲][ ]\n镜头"))
            app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "第1集\n剧情", episodes: [Episode(title: "第1集", text: "剧情")]), for: key)
        }
        let host = NSHostingView(rootView: RootView().environment(app).environment(\.glassEffectEnabled, false).frame(width: 1275, height: 796))
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1275, height: 796), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle(_ seconds: Double = 0.35) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
        }
        settle()
        BodyEvalCounter.counts = [:]
        app.preBindProject(keys[0]); settle()
        app.openProject(keys[0]); settle(0.9)
        XCTAssertNil(BodyEvalCounter.counts["ImageGenPanel"], "工作台不创建生图页")
        XCTAssertNil(BodyEvalCounter.counts["GenerateView"], "等再久也不预热生视频页")
        app.switchWorkspaceMode(.image); settle()
        XCTAssertGreaterThan(BodyEvalCounter.counts["ImageGenPanel"] ?? 0, 0)
        XCTAssertNil(BodyEvalCounter.counts["GenerateView"], "只访问生图时不创建生视频")
        app.goHome(); settle(0.5)
        BodyEvalCounter.counts = [:]
        app.openProject(keys[1]); settle(0.7)
        XCTAssertEqual(app.currentProjectKey, keys[1])
        XCTAssertLessThanOrEqual(BodyEvalCounter.counts["ImageGenPanel"] ?? 0, 1, "页壳至多求值一次，列表输入保持冻结")
        XCTAssertNil(BodyEvalCounter.counts["ImageItemInspector"], "旧详情也不应随换绑重建")
        app.switchWorkspaceMode(.image); settle()
        XCTAssertEqual(app.inspectedImageItem?.projectKey, keys[1], "真正进入时接上新项目")
        XCTAssertEqual(app.inspectedImageItemID, app.currentImageItems.first?.id, "旧项目的选中 ID 不能让新列表没有高亮")
        XCTAssertGreaterThan(BodyEvalCounter.counts["ImageGenPanel"] ?? 0, 0)
        app.switchWorkspaceMode(.video); settle()
        XCTAssertGreaterThan(BodyEvalCounter.counts["GenerateView"] ?? 0, 0)
        XCTAssertEqual(app.inspectedShot?.projectKey, keys[1])
    }
}
