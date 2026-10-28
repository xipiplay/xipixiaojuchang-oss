import AppKit
import SwiftUI
import XCTest
@testable import Xipixiaojuchang

/// 点击掉到遮罩挡板上时，点在本层面板里不关（2026-10-28 用户：看图、下拉、抽屉等好多弹层点里面就关）：
/// 挡板拿到的面板区域要和面板画的位置对得上（偏移、留边、叠层都算）
@MainActor
final class ShieldExemptTests: XCTestCase {
    private func host<V: View>(_ root: V, size: CGSize = CGSize(width: 800, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root.frame(width: size.width, height: size.height))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return window
    }

    private static func shields(in view: NSView) -> [OverlayEventShieldView] {
        ((view as? OverlayEventShieldView).map { [$0] } ?? []) + view.subviews.flatMap { shields(in: $0) }
    }

    /// 窗口坐标（左下原点）的点，在不在挡板认的面板区域里
    private func exempt(_ shield: OverlayEventShieldView, _ x: CGFloat, _ y: CGFloat) -> Bool {
        let local = shield.convert(NSPoint(x: x, y: y), from: nil)
        return shield.exemptRects.contains { $0.contains(local) }
    }

    func testModalPanelIsExempt() throws {
        // 面板 400×300 居中：x 200…600，窗口坐标 y 150…450
        let window = host(Color.gray.appModal(isPresented: .constant(true), width: 400, height: 300, handlesEsc: false) {
            Text("弹窗")
        })
        defer { window.orderOut(nil) }
        let shield = try XCTUnwrap(Self.shields(in: window.contentView!).first)
        XCTAssertTrue(exempt(shield, 400, 300), "面板正中")
        XCTAssertTrue(exempt(shield, 210, 160), "面板左下角里面")
        XCTAssertTrue(exempt(shield, 590, 440), "面板右上角里面")
        XCTAssertFalse(exempt(shield, 190, 300), "面板左边外面")
        XCTAssertFalse(exempt(shield, 400, 460), "面板上边外面")
        XCTAssertFalse(exempt(shield, 50, 50), "窗口角落")
    }

    /// 下拉面板靠 offset 定位，挡板还留了边（同抽屉的 padding）：区域照样对得上
    func testOffsetPanelWithPaddedShield() throws {
        let root = ZStack(alignment: .topLeading) {
            OverlayEventShield(onTap: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 60)
            Color.blue.frame(width: 200, height: 100)
                .shieldExempt()
                .offset(x: 300, y: 50)
        }
        .collectsShieldExemptions()
        let window = host(root)
        defer { window.orderOut(nil) }
        let shield = try XCTUnwrap(Self.shields(in: window.contentView!).first)
        // 面板（左上原点）x 300…500、y 50…150 → 窗口坐标 y 450…550
        XCTAssertTrue(exempt(shield, 400, 500))
        XCTAssertFalse(exempt(shield, 250, 500), "面板左边外面")
        XCTAssertFalse(exempt(shield, 400, 420), "面板下边外面")
    }

    /// 叠开的弹窗各管各的：上层面板外、下层面板里，上层挡板照样当成点外面（关上层）
    func testStackedModalsKeepOwnPanels() throws {
        let window = host(Color.gray
            .appModal(isPresented: .constant(true), width: 700, height: 500, handlesEsc: false) {
                Color.clear.appModal(isPresented: .constant(true), width: 200, height: 150, handlesEsc: false) {
                    Text("上层")
                }
            })
        defer { window.orderOut(nil) }
        let all = Self.shields(in: window.contentView!)
        XCTAssertEqual(all.count, 2)
        let lower = try XCTUnwrap(all.first { exempt($0, 100, 80) })
        let upper = try XCTUnwrap(all.first { $0 !== lower })
        XCTAssertTrue(exempt(upper, 400, 300), "上层面板正中")
        XCTAssertFalse(exempt(upper, 100, 80), "下层面板里、上层面板外：上层该关")
        XCTAssertTrue(exempt(lower, 400, 300))
    }
}
