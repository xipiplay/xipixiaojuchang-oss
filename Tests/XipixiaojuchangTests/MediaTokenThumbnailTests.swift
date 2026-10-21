import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 提示词里的「视频N / 音频N」也显示成缩略图（2026-10-16 用户：原来只是文字，不像图片有缩略图）：
/// 视频 = 本地文件首帧，音频（和没有本地文件的视频）= 「图标 + 名字」小标签
@MainActor
final class MediaTokenThumbnailTests: XCTestCase {
    override func setUp() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = true } }
    override func tearDown() async throws { await MainActor.run { WorkbenchSegmentDetail.testStartsOnPreview = false } }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    func testAudioChipIsAWideImage() throws {
        let url = try XCTUnwrap(MediaTokenThumbnail.chip(symbol: "waveform", text: "周承山的声音"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertTrue(MediaTokenThumbnail.isChip(image), "宽扁的小标签：\(image.size)")
        XCTAssertEqual(MediaTokenThumbnail.chip(symbol: "waveform", text: "周承山的声音"), url, "同样的内容只画一次，之后读缓存")
        let long = try XCTUnwrap(NSImage(contentsOf: try XCTUnwrap(MediaTokenThumbnail.chip(symbol: "waveform", text: String(repeating: "很长的名字", count: 10)))))
        XCTAssertLessThanOrEqual(long.size.width / long.size.height, MediaTokenThumbnail.chipMaxWidth / MediaTokenThumbnail.chipHeight + 0.1, "名字太长会截断")
    }

    func testVideoUsesItsFirstFrame() throws {
        // 用 ffmpeg 现做一段 1 秒的视频（没有 ffmpeg 就跳过）
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { throw XCTSkip("没有 ffmpeg") }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent("mtt-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: video) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "color=c=red:s=320x180:d=1", "-pix_fmt", "yuv420p", video.path]
        try process.run(); process.waitUntilExit()
        let url = try XCTUnwrap(MediaTokenThumbnail.videoFrame(path: video.path), "取得到首帧")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertFalse(MediaTokenThumbnail.isChip(image), "首帧是 16:9 的图，按图片缩略图贴")
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let color = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.8, "是那段视频的画面（红色）")
    }

    /// 二级页面的提示词编辑器里：挂了音频和（没本地文件的）视频，「音频1」「视频1」都换成附件，不再是字
    func testEditorShowsMediaTokensAsAttachments() throws {
        let app = AppModel()
        let key = "mtt-" + UUID().uuidString
        var audio = LibraryItem(kind: .audio, localPath: "/tmp/none.wav", fileName: "周承山.wav", projectKey: key)
        audio.remoteURL = "https://oss.test/a.wav"
        var video = LibraryItem(kind: .video, localPath: "/tmp/none.mp4", fileName: "动作参考.mp4", projectKey: key)
        video.remoteURL = "https://oss.test/v.mp4"
        app.library += [audio, video]
        var shot = ShotDraft(projectKey: key, prompt: "[ ][甲][ ]\n镜头1：甲推门进来，动作参考视频1。\n音频1是甲的音色。")
        shot.audioRefs = [MaterialRef(libraryItemID: audio.id)]
        shot.videoRefs = [MaterialRef(libraryItemID: video.id)]
        app.shots.append(shot)
        var episode = Episode(title: "第1集", text: "原文")
        episode.splitText = "=== [00:00-00:30] ===\n【场景】：无\n【角色】：甲\n【道具】：无\n【本段在场】：甲\n△ 甲推门进来。\n"
        episode.shotIDs = [shot.id]
        app.currentProjectKey = key
        app.savePipelineArchive(ProjectPipelineArchive(wholeScript: "全文", episodes: [episode]), for: key)
        app.isInWorkspace = true
        app.projectPage = .script
        app.workbenchLocations[key] = .init(projectKey: key, episodeIndex: 0, segment: 1)
        defer { app.shots.removeAll { $0.projectKey == key } }

        let host = NSHostingView(rootView: WorkbenchBoardProvider { PipelinePage() }.environment(app).environment(\.glassEffectEnabled, false)
            .frame(width: 1300, height: 800))
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1300, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let tv = try XCTUnwrap(views(PromptTextView.self, in: host).first)
        var tokens: [String] = []
        tv.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage?.length ?? 0)) { value, _, _ in
            if let a = value as? SlotAttachment { tokens.append(a.token) }
        }
        XCTAssertEqual(Set(tokens), ["视频1", "音频1"], "音视频都成了附件：\(tv.string)")
        XCTAssertFalse(tv.string.contains("音频1"), "文字「音频1」被换掉了")
        if let env = ProcessInfo.processInfo.environment["XIPI_SHOT"] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: env))
        }
    }
}
