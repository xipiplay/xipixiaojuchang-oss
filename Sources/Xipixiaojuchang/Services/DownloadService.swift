import Foundation
import CryptoKit

enum DownloadService {
    /// 目标文件名已存在时**自动加后缀**（`xxx-2.mp4`），**绝不删除已有文件**。
    ///
    /// ⚠️ 原来是"存在就 `removeItem` 再写" —— 一旦文件名真的撞上就会**静默丢掉旧视频**。
    /// 文件名序号现在是插入式编号（见 `ShotNumbering`），理论上不会再撞；
    /// 这里是**安全网**：万一还是撞上（老文件、手工改名、将来新的命名路径），
    /// 宁可多留一个文件，也不丢数据（用户 2026-09-11 提出的风险）。
    private static func uniqueDestination(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }

    /// 视频下载会话：**慢链容忍**（断点续传的搭档）——
    /// 空闲超时 120s（卡住就失败，下次续传补上），总超时 2 小时（慢链也能一点点拉完）。
    /// ⚠️ 不用 `URLSession.shared`（默认资源超时对慢链太短，转存坏时反复从头拉）。
    private static let videoSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7200
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    /// 断点续传用的临时文件（同一 URL 复用同一份 → 重试只补缺的字节）
    private static func resumeFile(for url: URL) -> URL {
        let dir = FileLocations.appSupport.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(key).part")
    }

    /// 把续传分片追加到临时文件（不存在就整块移过去）
    private static func append(_ chunk: URL, to part: URL) throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.moveItem(at: chunk, to: part)
            return
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try Data(contentsOf: chunk))
        try? FileManager.default.removeItem(at: chunk)
    }

    /// 下载结果视频并转存到项目缓存目录 缓存/<projectKey>/视频/<fileName>.mp4（原子移动）。
    ///
    /// **支持断点续传**：半截数据留在 `Downloads/<hash>.part`，下次带 `Range` 只补缺的字节
    /// （慢链 / 转存抽风时靠它慢慢拉完；配合 `PollingManager` 的自动重试）。
    /// - Parameter authorization: 结果链接**要渠道认证**时才传（如 `"Bearer xxx"`）。
    ///   有些中转的结果直链是 `{base}/v1/videos/{id}/content`，要它自己的 key，
    ///   裸 GET 会 401（用户实测"视频已生成，但下载转存失败 HTTP 401"）。
    ///   调用方只在**链接与渠道同域**时才传，公开直链（r2.dev 等）不受影响。
    static func downloadVideo(from url: URL, fileName: String, projectKey: String,
                              authorization: String? = nil) async throws -> URL {
        let part = resumeFile(for: url)
        let existing = (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int ?? 0
        var request = URLRequest(url: url)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }
        let (tmpURL, response) = try await videoSession.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("视频下载失败")
        }
        switch http.statusCode {
        case 206:
            try append(tmpURL, to: part)
        case 200..<300:
            // 服务端忽略了 Range（或本来就没续）→ 这一份就是完整内容
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: tmpURL, to: part)
        case 416:
            // Range 不满足：多半是本地这份已经完整（也可能服务端不支持续传）→ 继续走落盘校验
            break
        default:
            throw APIError.transport("视频下载失败（HTTP \(http.statusCode)）")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: part.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 1024 else {
            throw APIError.transport("下载内容过小，直链可能已失效")
        }

        let directory = FileLocations.projectVideosDirectory(projectKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 撞名不覆盖（见 `uniqueDestination` 的说明）
        let destination = uniqueDestination(in: directory, base: fileName, ext: "mp4")
        try FileManager.default.moveItem(at: part, to: destination)
        return destination
    }

    /// 内容端点（`GET /v1/videos/{id}/content`）返回的二进制直接落盘。
    /// 与 `downloadVideo(from:)` 同一套命名与不覆盖规则，只是数据已在内存里。
    static func downloadVideo(data: Data, fileName: String, projectKey: String) throws -> URL {
        guard data.count > 1024 else {
            throw APIError.transport("下载内容过小，直链可能已失效")
        }
        let directory = FileLocations.projectVideosDirectory(projectKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(in: directory, base: fileName, ext: "mp4")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// b64 已落盘的图片 → 项目图片目录（同一套命名/去重规则）。
    static func saveImage(fromFile path: String, name: String, projectKey: String) throws -> URL {
        let source = URL(fileURLWithPath: path)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let directory = FileLocations.projectImagesDirectory(projectKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueDestination(in: directory, base: name, ext: ext)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// 图片下载会话：60 秒超时兜底，避免下载挂起一直卡在「下载中」
    private static let imageSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    /// 下载图片并转存到项目缓存目录 缓存/<projectKey>/图片/<name>.png（图片生成结果用）
    static func downloadImage(from url: URL, name: String, projectKey: String) async throws -> URL {
        let (tmpURL, response) = try await imageSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.transport("图片下载失败")
        }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let directory = FileLocations.projectImagesDirectory(projectKey)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 撞名不覆盖（同视频那条，见 `uniqueDestination` 的说明）
        let destination = uniqueDestination(in: directory, base: name, ext: ext)
        try FileManager.default.moveItem(at: tmpURL, to: destination)
        return destination
    }
}
