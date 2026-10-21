import XCTest
@testable import Xipixiaojuchang

/// 2026-10-10 用户：素材库 / 任务抽屉变宽了，最小窗口下盖住了编辑提示词弹窗；以前抽屉的边刚好贴着弹窗的边。
final class DrawerBesidePromptModalTests: XCTestCase {
    func testAtTheMinimumWindowTheDrawerDoesNotCoverTheEditPromptModal() {
        let window = AppWindowShellLayout.minimumWidth
        let modalRight = window / 2 + AppWindowShellLayout.promptModalWidth / 2
        let drawerLeft = window - AppWindowShellLayout.edgeInset - AppWindowShellLayout.drawerWidth
        XCTAssertGreaterThanOrEqual(drawerLeft, modalRight - 4, "抽屉盖住了弹窗 \(modalRight - drawerLeft)pt")
        // 2026-10-15 最小窗口 1160 → 1275 之后两者之间多出约 60pt 空隙（原来刚好贴着），只要不盖住就行
    }
}
