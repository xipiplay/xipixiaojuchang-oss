import Foundation

/// 素材条目（本地文件或已粘贴的直链）
struct ReferenceDraftItem: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case local(URL)      // 本地文件，需上传为直链
        case remote(String)  // 公网 URL
    }

    let id: UUID
    var source: Source
    var role: ReferenceImageRole?   // 仅图片使用
    var duration: Double?           // 音视频时长（秒），AVFoundation 探测
    var durationUnknown = false     // 时长探测失败

    var remoteURL: String? {
        if case .remote(let url) = source { return url }
        return nil
    }

    var fileName: String? {
        if case .local(let url) = source { return url.lastPathComponent }
        return nil
    }

    static func local(url: URL, role: ReferenceImageRole? = nil) -> ReferenceDraftItem {
        ReferenceDraftItem(id: UUID(), source: .local(url), role: role)
    }

    static func remote(url: String, role: ReferenceImageRole? = nil) -> ReferenceDraftItem {
        ReferenceDraftItem(id: UUID(), source: .remote(url), role: role)
    }
}
