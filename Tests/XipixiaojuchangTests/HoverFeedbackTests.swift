import XCTest
import SwiftUI
import AppKit
@testable import Xipixiaojuchang

/// 2026-10-10 用户：软件里好些可点的东西悬停没反应。安静按钮（`QuietButtonStyle`）和点一下的区域（`hoverHighlight`）
/// 悬停时要有反馈；抽屉里（`hoverFeedbackEnabled == false`）和自己带悬停效果的（`.none`）不加。
@MainActor
final class HoverFeedbackTests: XCTestCase {
    /// 把 `content` 放进窗口，量中心像素的亮度（`hover` = 把「正在悬停」硬设成真，见 `hoverFeedbackForced`）
    private func brightness<V: View>(_ content: V, hover: Bool) async throws -> Double {
        let host = NSHostingView(rootView: content.environment(\.hoverFeedbackForced, hover)
            .environment(\.colorScheme, .light).frame(width: 100, height: 40).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua); window.isReleasedWhenClosed = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded() }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let c = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return Double(c.redComponent)
    }

    private func button(_ hover: HoverFeedback) -> some View {
        Button {} label: { Color.clear.frame(width: 80, height: 30).contentShape(Rectangle()) }
            .buttonStyle(QuietButtonStyle(hover: hover))
    }

    func testQuietButtonShowsAFillWhenHovered() async throws {
        let idle = try await brightness(button(.fill()), hover: false)
        let hovered = try await brightness(button(.fill()), hover: true)
        XCTAssertLessThan(hovered, idle - 0.02, "悬停：垫了一层淡底（浅色下变暗一点）")
    }

    func testNoneDoesNotReact() async throws {
        let idle = try await brightness(button(.none), hover: false)
        let hovered = try await brightness(button(.none), hover: true)
        XCTAssertEqual(hovered, idle, accuracy: 0.005)
    }

    func testDrawersTurnTheFeedbackOff() async throws {
        let idle = try await brightness(button(.fill()).environment(\.hoverFeedbackEnabled, false), hover: false)
        let hovered = try await brightness(button(.fill()).environment(\.hoverFeedbackEnabled, false), hover: true)
        XCTAssertEqual(hovered, idle, accuracy: 0.005, "抽屉里不做悬停反馈（2026-10-08 用户定）")
    }

    func testClickAreasHighlightOnlyWhileClickable() async throws {
        func area(clickable: Bool) -> some View {
            Color.clear.frame(width: 80, height: 30).contentShape(Rectangle()).hoverHighlight(radius: 6, clickable: clickable).onTapGesture {}
        }
        let idle = try await brightness(area(clickable: true), hover: false)
        let hovered = try await brightness(area(clickable: true), hover: true)
        XCTAssertLessThan(hovered, idle - 0.02, "点得动：悬停有淡底")
        let blocked = try await brightness(area(clickable: false), hover: true)
        XCTAssertEqual(blocked, idle, accuracy: 0.005, "点不动（比如还没有视频）：不亮")
    }
}
