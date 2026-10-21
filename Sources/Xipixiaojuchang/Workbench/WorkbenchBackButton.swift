import SwiftUI

/// 生图 / 生视频页头部最左边的「返回第 N 段」（2026-10-10 用户：从分段跳到这两页之后老得从第一层重新进工作台）。
/// 只在从工作台的分段详情跳过来时出现；点一下回到工作台，并接着回到那一段（见 `AppModel.workbenchLocations`）。
/// 自己是一个独立小视图：页头不跟着 `workbenchJumpBack` 重算。
struct WorkbenchBackButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let back = app.workbenchJumpBack, back.projectKey == app.currentProjectKey {
            Button { app.openScriptPage() } label: {
                Label("返回第 \(back.segment) 段", systemImage: "chevron.left")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(OutlineButtonStyle())
            .controlSize(.small)
            .help("回到工作台，第 \(back.episodeIndex + 1) 集的第 \(back.segment) 段")
            .accessibilityIdentifier("workbench-jump-back")
        }
    }
}
