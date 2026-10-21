import Foundation
import AVFoundation
import ImageIO

enum MediaInspector {
    /// 探测音视频时长（秒）
    static func mediaDuration(at url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw InspectionError.unknownDuration
        }
        return seconds
    }

    /// 图片有效性校验（可解码）
    static func isValidImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }
}

enum InspectionError: LocalizedError {
    case unknownDuration

    var errorDescription: String? {
        "无法读取媒体时长"
    }
}
