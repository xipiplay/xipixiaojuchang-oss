import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分段弹窗三栏并排（2026-10-13 用户定：剧情 | 提示词 | 素材，去掉两个标签和「引用素材」那一行）之后的交互：
/// 剧情和提示词同时在屏幕上，改着剧情去点提示词 / 翻到下一段，改的要先存下来
@MainActor
final class WorkbenchDetailColumnsTests: XCTestCase {
    // 2026-10-15 新布局：剧情收进右边「本段剧情」标签，这几个测试要它一打开就在屏幕上
    override func setUp() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnStory = true } }
    override func tearDown() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnStory = false } }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func setUp(_ key: String) -> (AppModel, ShotDraft) {
        let app = AppModel()
        let shot = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头1：甲推门进来。")
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲推门进来。\n"
            + "=== [00:30-01:00] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲坐下。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 1)
        return (app, shot)
    }

    private func show(_ app: AppModel, hover: Bool = false) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .environment(\.hoverFeedbackForced, hover).environment(\.colorScheme, .light)
            .frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        return (window, host)
    }

    /// 开始改剧情（点一下进编辑、在末尾加字）
    private func editStory(_ window: NSWindow, _ host: NSView) throws -> ScriptTextView {
        let story = try XCTUnwrap(views(ScriptTextView.self, in: host).first { $0.string.contains("甲推门进来") }, "剧情框和提示词同时在")
        // 测试进程不是前台应用，模拟的点击只会激活窗口、到不了文本框：直接走「只读时点了一下」那条路
        story.coordinator?.beginEditing(in: story)
        XCTAssertTrue(window.firstResponder === story, "点一下进编辑")
        story.setSelectedRange(NSRange(location: (story.string as NSString).length, length: 0))
        story.insertText("又退了出去。", replacementRange: story.selectedRange())
        return story
    }

    private func savedSplit(_ app: AppModel, _ key: String) -> String { app.pipelineArchive(for: key)?.episodes[0].splitText ?? "" }

    func testEditingStoryThenClickingThePromptSavesIt() throws {
        let key = "cols-" + UUID().uuidString
        let (app, _) = setUp(key)
        defer { app.shots.removeAll { $0.projectKey == key } }
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        XCTAssertTrue(views(NSView.self, in: host).allSatisfy { $0.accessibilityIdentifier() != "workbench-segment-references" }, "引用素材那一行去掉了")

        _ = try editStory(window, host)
        // 点中栏提示词（在窗口里换算出提示词正文的位置：它就在剧情框右边）。窗口级「点外面放手」的监听拿不到 sendEvent，直接喂坐标
        let story = try XCTUnwrap(views(ScriptTextView.self, in: host).first { $0.string.contains("又退了出去") })
        let frame = story.convert(story.bounds, to: nil)
        XCTAssertTrue(InputFocusGuard.process(window: window, locationInWindow: NSPoint(x: frame.maxX + 200, y: frame.midY)), "点在剧情框外面：放手")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(savedSplit(app, key).contains("甲推门进来。又退了出去。"), "放手就存回整集的时长分割")
        XCTAssertTrue(savedSplit(app, key).contains("△ 甲坐下。"), "别的段不动")
    }

    func testEditingStoryThenFlippingToNextSegmentSavesIt() throws {
        let key = "cols-flip-" + UUID().uuidString
        let (app, _) = setUp(key)
        defer { app.shots.removeAll { $0.projectKey == key } }
        let (window, host) = show(app)
        defer { window.orderOut(nil) }

        _ = try editStory(window, host)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "]",
                                                   charactersIgnoringModifiers: "]", isARepeat: false, keyCode: 30))
        _ = window.performKeyEquivalent(with: event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(app.workbenchLocations[key]?.segment, 2, "翻到了第 2 段")
        XCTAssertTrue(savedSplit(app, key).contains("甲推门进来。又退了出去。"), "翻页前先存")
        XCTAssertNotNil(views(ScriptTextView.self, in: host).first { $0.string.contains("甲坐下") }, "第 2 段的剧情显示出来")
    }

    /// 「本段剧情」两个格子和别的输入框同一套反馈（2026-10-13 用户：要和输入框的交互一样，见 `InputChrome`）：
    /// 正在改的那一格是一圈主色描边。悬停那一档用的是 SwiftUI 的 onHover，合成事件触发不了，测不了
    func testEditingStoryBoxShowsTheAccentBorder() throws {
        let key = "cols-border-" + UUID().uuidString
        let (app, _) = setUp(key)
        defer { app.shots.removeAll { $0.projectKey == key } }
        let (window, host) = show(app)
        defer { window.orderOut(nil) }
        let story = try XCTUnwrap(views(ScriptTextView.self, in: host).first { $0.string.contains("甲推门进来") })

        /// 剧情框左边线上的颜色（文本框左右各缩进 12，边线在它左边 12 处）
        func border() throws -> NSColor {
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let frame = story.convert(story.bounds, to: host)
            let scale = Double(rep.pixelsWide) / host.bounds.width
            let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
            return try XCTUnwrap(rep.colorAt(x: Int((frame.minX - 12 + 0.75) * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
        }
        let idle = try border()
        story.coordinator?.beginEditing(in: story)
        let editing = try border()
        let accent = try XCTUnwrap(NSColor(Theme.accent).usingColorSpace(.sRGB))
        func distance(_ a: NSColor, _ b: NSColor) -> Double {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        XCTAssertLessThan(distance(editing, accent), distance(idle, accent) - 0.2, "改着的时候边线变成主色")
    }
}
