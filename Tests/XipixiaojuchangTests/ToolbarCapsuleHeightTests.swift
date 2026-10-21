import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-10 用户：工作台底部的流水线胶囊和生图 / 生视频页的工具条胶囊上下尺寸不一样。两条共用 `ToolbarRow`，高度只差在里面按钮的高度上。
@MainActor
final class ToolbarCapsuleHeightTests: XCTestCase {
    /// 把胶囊画在蓝底上，沿中线量「近白色」的那一段高度（点）。用实色（玻璃关）画：玻璃要真窗口才画得出来，布局是同一份
    private func capsuleHeight<V: View>(_ view: V) async throws -> Double {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light).environment(\.glassEffectEnabled, false)
            .frame(width: 1000, height: 120).background(Color(red: 0.55, green: 0.7, blue: 0.85)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        var top = -1, bottom = -1
        for y in 0..<rep.pixelsHigh {
            guard let c = rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.85 && c.greenComponent > 0.85 { if top < 0 { top = y }; bottom = y }
        }
        XCTAssertGreaterThanOrEqual(top, 0, "没量到胶囊")
        return Double(bottom - top + 1) / Double(rep.pixelsHigh / 120)
    }

    func testTheWorkbenchCapsuleAndTheImageVideoToolbarAreTheSameHeight() async throws {
        let app = AppModel()
        app.currentProjectKey = "capsule-height"
        defer { app.currentProjectKey = nil }
        let toolbar = try await capsuleHeight(WorkspaceBar { BarIconButton(icon: "trash", help: "x") {}; BarIconButton(icon: "square.and.arrow.down", help: "y") {} }.environment(app))
        let workbench = try await capsuleHeight(WorkbenchCapsule(currentEpisode: 0).environment(app))
        XCTAssertEqual(workbench, toolbar, accuracy: 0.5, "工作台 \(workbench)pt，工具条 \(toolbar)pt")
    }
}
