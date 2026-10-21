import Foundation

/// 上传后的远程素材
struct RemoteMaterial: Sendable {
    let url: String
    let duration: Double?
}

/// 上传进度回调：0~1。**拿不到总量时不会回调**（不回调 = 该服务/该次上传不支持进度）。
typealias UploadProgressHandler = @Sendable (Double) -> Void

/// 素材上传服务：本地文件 → 公网直链
protocol UploadService: Sendable {
    /// 是否支持本地文件（不支持时校验器会拦截本地素材）
    var supportsLocalFiles: Bool { get }
    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial
}

extension UploadService {
    /// 不需要进度时的便捷入口（大多数调用点用这个）
    func upload(_ item: ReferenceDraftItem) async throws -> RemoteMaterial {
        try await upload(item, onProgress: nil)
    }
}

/// 兜底实现：直链直接可用；本地文件提示未接入
struct URLPasteUploadService: UploadService {
    let supportsLocalFiles = false

    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        switch item.source {
        case .remote(let url):
            return RemoteMaterial(url: url, duration: item.duration)
        case .local:
            throw UploadError.notAvailable
        }
    }
}

enum UploadError: LocalizedError {
    case notAvailable
    case server(String)
    /// 上传接口回了直链，但**远端文件校验不过**（长度对不上 / 0 字节）。
    /// 单列一个 case：`FallbackUploadService` 只对这种错误**原地重试一次**（catbox 偶发空文件），
    /// 其它错误（超时 / 网络）直接切备用链路，不白等两轮。
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "平台上传接口尚未接入，请改用「粘贴素材直链」"
        case .server(let message):
            message
        case .verifyFailed(let message):
            message
        }
    }

    /// 是不是"远端文件校验不过"（决定要不要原地重试）
    var isVerifyFailure: Bool {
        if case .verifyFailed = self { return true }
        return false
    }
}
