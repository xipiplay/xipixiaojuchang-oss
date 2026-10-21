import Foundation

/// 走阿里云 OSS 的上传服务：本地文件 → 上传 → 返回公网直链
struct OSSUploadService: UploadService {
    let config: OSSConfig

    var supportsLocalFiles: Bool { true }

    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        switch item.source {
        case .remote(let url):
            return RemoteMaterial(url: url, duration: item.duration)
        case .local(let fileURL):
            let data = try Data(contentsOf: fileURL)
            let ext = fileURL.pathExtension.lowercased()
            let contentType = Self.contentType(forExtension: ext)
            let key = "\(UUID().uuidString.lowercased()).\(ext.isEmpty ? "bin" : ext)"
            let publicURL = try await OSSUploader.upload(data: data, key: key, contentType: contentType, config: config)
            return RemoteMaterial(url: publicURL.absoluteString, duration: item.duration)
        }
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aac": "audio/aac"
        case "m4a": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    /// 判断一个直链是否已经是本 OSS 桶上的地址（上游可直接拉取，无需重传）。
    ///
    /// 优先按配置里的 `桶.域名` 精确比对；配置缺失时回落到阿里云 OSS 标准域名形态
    ///（`<bucket>.oss-<region>.aliyuncs.com`），保证删掉配置也能复用历史 OSS 直链。
    static func isOSSDirectLink(_ urlString: String, config: OSSConfig?) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased(), !host.isEmpty else { return false }
        if let config {
            let endpoint = normalizedEndpoint(config.endpoint)
            let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !endpoint.isEmpty, !bucket.isEmpty, host == "\(bucket).\(endpoint)" { return true }
        }
        return host.hasSuffix(".aliyuncs.com") && host.contains(".oss-")
    }

    /// `https://oss-cn-qingdao.aliyuncs.com/` → `oss-cn-qingdao.aliyuncs.com`
    private static func normalizedEndpoint(_ endpoint: String) -> String {
        endpoint
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
