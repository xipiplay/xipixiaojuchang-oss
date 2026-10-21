import Foundation

/// 页面导航独立于图片/视频的生成模式，避免媒体分支把剧本当作图片处理。
enum ProjectPage: Sendable {
    case production, script
}
