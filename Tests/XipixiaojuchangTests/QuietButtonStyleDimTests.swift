import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-10 用户：进出项目时主页大图左边的黑色渐变会闪——大图是个 `QuietButtonStyle` 按钮，进项目时被禁用，禁用态把整块变淡到 40%。
@MainActor
final class QuietButtonStyleDimTests: XCTestCase {
    private func centerBrightness(dims: Bool, enabled: Bool) async throws -> Double {
        let view = Button {} label: { Color.black.frame(width: 80, height: 40) }
            .buttonStyle(QuietButtonStyle(dimsWhenDisabled: dims))
            .disabled(!enabled)
            .environment(\.colorScheme, .light)
            .padding(10).background(Color.white)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<3 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let c = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return Double(c.redComponent)
    }

    func testDisabledButtonDimsByDefaultButNotWhenAskedNotTo() async throws {
        let dimmed = try await centerBrightness(dims: true, enabled: false)
        XCTAssertGreaterThan(dimmed, 0.4, "默认：禁用 → 变淡（黑色被冲淡）")
        let kept = try await centerBrightness(dims: false, enabled: false)
        XCTAssertLessThan(kept, 0.05, "不变淡：禁用了也还是纯黑")
        let enabled = try await centerBrightness(dims: true, enabled: true)
        XCTAssertLessThan(enabled, 0.05)
    }
}
