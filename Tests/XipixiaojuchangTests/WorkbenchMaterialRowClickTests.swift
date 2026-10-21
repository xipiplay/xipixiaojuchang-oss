import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分段弹窗「本段素材」的一行（2026-10-12 用户定）：点缩略图 = 看大图；点这一行别处 = 这张卡的编辑提示词
@MainActor
final class WorkbenchMaterialRowClickTests: XCTestCase {
    // 2026-10-16 起本段素材只在「本段预览」下面（没视频时默认是「本段剧情」）
    override func setUp() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = true } }
    override func tearDown() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = false } }

    private func click(_ window: NSWindow, x: CGFloat, yFromTop: CGFloat) {
        let location = NSPoint(x: x, y: window.contentView!.bounds.height - yFromTop)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
    }

    func testClickingTheThumbnailShowsTheBigImage() throws {
        let app = AppModel()
        let key = "matrow-" + UUID().uuidString
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("matrow-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var card = ImageGenItem(projectKey: key, type: .character, name: "甲", prompt: "红衣少女")
        card.results = [ImageGenResult(localPath: file.path, createdAt: Date())]; card.status = .success
        app.imageItems.append(card)
        let shot = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头1：甲推门进来。")
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 1)
        defer { app.shots.removeAll { $0.projectKey == key }; app.imageItems.removeAll { $0.projectKey == key } }

        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertNotNil(app.closeWorkbenchSegmentDetail, "分段弹窗开着")

        // 位置按这个窗口尺寸下的布局量的：右下「本段素材」（角色标签）第一张卡的缩略图（2026-10-15 新布局）
        click(window, x: 767, yFromTop: 521)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(app.previewingImageItemID, card.id, "点缩略图 = 看大图")
        // ⚠️ 「点这一行别处 = 编辑提示词」「点缩略图时整行不跟着响应」都测不了：那是 onTapGesture，sendEvent 模拟的点击触发不了（见 WorkbenchSegmentPlayButtonTests）
    }
}
