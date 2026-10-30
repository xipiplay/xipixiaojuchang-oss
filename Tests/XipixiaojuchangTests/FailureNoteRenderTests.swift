import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 段落详情页头的「视频生成失败」：点开是任务列表同款浮层 `TaskErrorDetail`，不再弹系统确认框（2026-10-30 用户）
@MainActor
final class FailureNoteRenderTests: XCTestCase {
    /// 人工核对：设 `XIPI_SHOT=路径` 才出图（页头那一行 + 点开后的浮层内容）
    func testRowAndDetailRender() {
        guard let out = ProcessInfo.processInfo.environment["XIPI_SHOT"] else { return }
        let views: [(String, AnyView, CGSize)] = [
            ("row", AnyView(FailureNoteRow(reason: "画布参数菜单未能展开", retryDisabled: false, onRetry: {})), CGSize(width: 260, height: 50)),
            ("detail", AnyView(TaskErrorDetail(raw: "画布参数菜单未能展开").glassPanel(cornerRadius: 14, shadow: false)), CGSize(width: 460, height: 130)),
        ]
        for (name, view, size) in views {
            let host = NSHostingView(rootView: view.padding(10)
                .background(Color(nsColor: NSColor(white: 0.16, alpha: 1))).environment(\.colorScheme, .dark)
                .frame(width: size.width, height: size.height))
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
