import XCTest
import SwiftUI
@testable import Xipixiaojuchang

/// 页面里的弹窗交给窗口那一层弹（2026-10-26 用户：工作台点开的段落详情和生视频页点开的不一样大）。
/// 外面有窗口那一层时：开着就交出内容、大小按窗口算；页面藏着不交；关掉走页面自己的开关
@MainActor
final class WindowModalPortalTests: XCTestCase {
    private final class Box { var portal: WindowModalPortal? }

    private struct Probe: View {
        let box: Box
        let portal: WindowModalPortal?
        var body: some View {
            box.portal = portal
            return Color.clear
        }
    }

    private struct Page: View {
        @Binding var open: Bool
        let visible: Bool
        var body: some View {
            Color.clear
                .windowModal(isPresented: $open, pageVisible: visible, pageSize: CGSize(width: 300, height: 200),
                             size: PipelinePage.segmentDetailSize(in:)) {
                    Text("段落详情")
                }
        }
    }

    private func host(open: Binding<Bool>, visible: Bool, box: Box) -> NSHostingView<some View> {
        let view = Page(open: open, visible: visible)
            .environment(\.windowModalPortalAvailable, true)
            // 和 `RootModals` 一样从偏好值里取（这个值不能比较相等，用不了 onPreferenceChange）
            .backgroundPreferenceValue(WindowModalPortalKey.self) { value in Probe(box: box, portal: value) }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        host.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return host
    }

    func testOpenPageHandsContentToWindowLayer() {
        var open = true
        let box = Box()
        let binding = Binding(get: { open }, set: { open = $0 })
        _ = host(open: binding, visible: true, box: box)

        let portal = try? XCTUnwrap(box.portal, "开着就交给窗口那一层")
        let size = portal?.size(CGSize(width: 1400, height: 900))
        XCTAssertEqual(size, CGSize(width: 1328, height: 844), "按窗口大小算，和生视频页的段落详情同一个算法")
        portal?.close()
        XCTAssertFalse(open, "点遮罩 / Esc 关掉时写回页面自己的开关")
    }

    func testHiddenPageDoesNotHandOver() {
        var open = true
        let box = Box()
        _ = host(open: Binding(get: { open }, set: { open = $0 }), visible: false, box: box)
        XCTAssertNil(box.portal, "页面藏着（切到别的页）时不盖在别的页上")
    }

    func testClosedPageDoesNotHandOver() {
        var open = false
        let box = Box()
        _ = host(open: Binding(get: { open }, set: { open = $0 }), visible: true, box: box)
        XCTAssertNil(box.portal)
    }
}
