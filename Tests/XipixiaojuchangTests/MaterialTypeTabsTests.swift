import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 分镜素材区的分类标签（2026-10-30 用户：数素材得一个个数）：「全部 (N) / 图片 / 视频 / 音频」，0 个不写括号
@MainActor
final class MaterialTypeTabsTests: XCTestCase {
    private var app: AppModel!
    private var key: String!

    override func setUp() async throws {
        app = AppModel()
        key = "material-tabs-" + UUID().uuidString
    }
    override func tearDown() async throws {
        app.library.removeAll { $0.projectKey == key }
    }

    func testTabLabelShowsCountOnlyWhenThereIsAny() {
        XCTAssertEqual(MaterialSection.tabLabel("全部", count: 11), "全部 (11)")
        XCTAssertEqual(MaterialSection.tabLabel("视频", count: 0), "视频")
    }

    /// 人工核对：设 `XIPI_SHOT=路径` 才出图（分镜带标签 / 生图不带）
    func testSectionRenders() {
        guard let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] else { return }
        let names = ["第一集的韩峥", "第二集的沈怀川", "第一集的周承山", "第一集的沈知夏", "测试安排", "赛车", "工具车", "赛车旁", "通道"]
        let images = names.map { Xipixiaojuchang.LibraryItem(kind: .image, localPath: nil, fileName: "\($0).png", name: $0, projectKey: key) }
        let audios = ["韩峥-音色", "周承山-音色"].map {
            Xipixiaojuchang.LibraryItem(kind: .audio, localPath: "/不存在/\($0).mp3", fileName: "\($0).mp3", name: $0, duration: 7, projectKey: key)
        }
        app.library += images + audios
        let imageRefs = images.map { MaterialRef(libraryItemID: $0.id) }
        let audioRefs = audios.map { MaterialRef(libraryItemID: $0.id) }
        for (name, tabs) in [("shot", true), ("image", false)] {
            let size = CGSize(width: 1040, height: 90)
            let section = MaterialSection(imageRefs: imageRefs, audioRefs: tabs ? audioRefs : [], showsTypeTabs: tabs,
                                          onAdd: {}, onDrop: { _ in })
            let host = NSHostingView(rootView: section.padding(8)
                .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark)
                .environment(app).frame(width: size.width, height: size.height))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "-\(name).png"))
            }
            window.orderOut(nil)
        }
    }
}
