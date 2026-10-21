import SwiftUI

/// 剧本正文标题栏与素材、分镜操作栏使用相同高度、内边距和按钮位置。
enum PipelinePageLayout {
    static let headerContentHeight: CGFloat = 24
    static let headerHorizontalInset: CGFloat = 20
    static let headerVerticalInset: CGFloat = 14
    static let panelTopInset: CGFloat = 12
    /// 工作台底部胶囊浮在卡片上面（2026-10-10：原来在卡片下面留一条空带放它，页面显得残缺）：
    /// 卡片里的内容要给它让出的高度——滚动内容的底部边距、右栏固定按钮的抬高量都用这个。
    /// 胶囊高 54、离内容区底边 12，卡片离内容区底边 10，所以胶囊顶比卡片底高 54 + 12 − 10 = 56，再留 6 的呼吸
    static let capsuleClearance: CGFloat = 62
}

extension View {
    func pipelineHeaderLayout() -> some View {
        frame(height: PipelinePageLayout.headerContentHeight)
            .padding(.horizontal, PipelinePageLayout.headerHorizontalInset)
            .padding(.vertical, PipelinePageLayout.headerVerticalInset)
    }
}
