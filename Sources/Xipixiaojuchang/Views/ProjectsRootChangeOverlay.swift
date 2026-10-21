import SwiftUI

/// 更换项目文件夹、正在搬项目的时候盖住整个窗口：搬的过程中不能再动项目（写盘会写到旧位置）。搬完软件自己重启。
struct ProjectsRootChangeOverlay: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay {
            if let change = app.projectsRootChange {
                ZStack {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}                                  // 吃掉点击
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(change.total > 0 ? "正在移动项目文件夹  \(change.done) / \(change.total)" : "正在更换项目文件夹…")
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .background(SolidTheme.card(.dark), in: RoundedRectangle(cornerRadius: 16))
                    .environment(\.colorScheme, .dark)
                }
                .accessibilityIdentifier("projects-root-change-overlay")
            }
        }
    }
}
