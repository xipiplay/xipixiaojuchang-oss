import Foundation

/// catbox 系上传的公共实现（catbox 主站 / litterbox 两个服务共用）。
///
/// 两家都是同一套公开 API 形态：`POST <api>` multipart 带 `reqtype=fileupload` + `fileToUpload`，
/// 成功返回**纯文本直链**（`https://files.catbox.moe/xxx.png` / `https://litter.catbox.moe/xxx.png`）。
/// 区别只在：
/// - catbox 主站：要账号 `userhash`，**永久**保存；
/// - litterbox：不要账号，要 `time=72h`，**72 小时**后过期。
enum CatboxUpload {
    /// 上传前把文件名规整成 catbox 能接受的形态（**硬约束**，2026-09-18 实测）：
    /// 只留字母数字，且总长 ≤ 16 字符（含扩展名）。
    /// 实测：中文名 → 返回 0 字节的"成功"直链 ✗；超长名（如完整 UUID）→ 直接拒绝 ✗。
    static func sanitizedFilename(_ raw: String) -> String {
        let ext = (raw as NSString).pathExtension.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let stem = String(String.UnicodeScalarView((raw as NSString).deletingPathExtension.unicodeScalars.filter { allowed.contains($0) }))
        let safeExt = String(String.UnicodeScalarView(ext.unicodeScalars.filter { allowed.contains($0) }))
        let maxStem = max(1, 15 - safeExt.count)   // 点号占 1 个字符
        let finalStem = stem.isEmpty
            ? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
            : String(stem.prefix(maxStem))
        return safeExt.isEmpty ? finalStem : "\(finalStem).\(safeExt)"
    }

    /// 通用上传：`extraFields` 按顺序拼进 multipart（litterbox 传 `time=72h`；catbox 主站传 `userhash`）。
    /// `label` 只用于错误文案（"catbox 上传失败" / "litterbox 上传失败"）。
    /// `onProgress`：上传进度 0~1（`URLSession` 的 `didSendBodyData`，见 `UploadProgressDelegate`）。
    static func uploadFile(data: Data,
                           filename: String,
                           apiURL: String,
                           extraFields: [(name: String, value: String)],
                           label: String,
                           onProgress: UploadProgressHandler? = nil) async throws -> String {
        // 本地文件本身是空的 → 别浪费一次请求（远端校验也救不了空文件）
        guard !data.isEmpty else {
            throw UploadError.server("\(label) 上传失败：本地文件是空的（0 字节）")
        }
        let filename = sanitizedFilename(filename)
        let boundary = "----Xipixiaojuchang\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"reqtype\"\r\n\r\n")
        append("fileupload\r\n")
        for field in extraFields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)--\r\n")

        guard let url = URL(string: apiURL) else { throw UploadError.notAvailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // ⚠️ UA 必须是浏览器形态（实测自定义 UA 会被拒；curl 用 Mozilla 能通）
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        // ⚠️ 超时别太长（2026-09-18 教训：以前设 120s，主链路挂掉时每次都要白等两分钟）。
        // 60s 够传完几 MB 的参考图；超了就让 FallbackUploadService 切另一条免费链路。
        request.timeoutInterval = 60

        // ⚠️ 走 `upload(for:from:delegate:)` 而不是 `data(for:)`：body 单独传，
        // 顺带挂进度代理（`data(for:)` 拿不到 didSendBodyData）。
        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: body,
            delegate: UploadProgressDelegate(onProgress: onProgress)
        )
        guard let http = response as? HTTPURLResponse else { throw UploadError.notAvailable }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8) ?? ""
            throw UploadError.server("\(label) 上传失败（HTTP \(http.statusCode)）：\(text.prefix(200))")
        }
        // 成功时返回纯文本直链；失败时返回一段错误说明
        let text = (String(data: responseData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("https://"), let url = URL(string: text), url.host != nil else {
            throw UploadError.server("\(label) 返回异常：\(text.prefix(200))")
        }

        // ⚠️ 上传后校验（2026-09-19）：接口回直链 ≠ 文件真的传上去了。
        // 用户实测过"显示上传成功、打开链接是空的"（catbox 偶发 0 字节）。
        // 这里立刻 Range GET 读远端总长，和本地字节数比对，不符就当失败（外层会重试/切链路）。
        let remoteBytes = await remoteContentLength(text)
        guard remoteBytes == data.count else {
            throw UploadError.verifyFailed(
                "\(label) 上传后校验失败：本地 \(data.count) 字节，远端 \(remoteBytes.map { "\($0) 字节" } ?? "读不到")（\(text)）"
            )
        }
        AppLog.write("upload", "\(label) 上传成功并已校验：\(data.count) 字节 → \(text)")
        return text
    }

    /// 远端文件总字节数（Range GET **只看响应头**，不下载正文）。
    ///
    /// ⚠️ 不能用 HEAD：catbox 对 HEAD 一律回 200 + `Content-Length: 0`，根本分不出空文件；
    /// Range GET 正常回 206 + `Content-Range: bytes 0-0/总长`，不存在的文件回 404。
    static func remoteContentLength(_ urlString: String) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let session = URLSession(configuration: .ephemeral)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }   // 拿到响应头就取消，别把正文拉下来
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last, let n = Int(total) {
                return n
            }
            return Int(http.expectedContentLength)
        } catch {
            return nil
        }
    }
}

/// 上传进度代理：把 `didSendBodyData` 换算成 0~1 回调给上层（素材库的「上传中 42%」就是它）。
/// 回调在 URLSession 的后台队列上，上层自己负责切主线程。
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: UploadProgressHandler?
    init(onProgress: UploadProgressHandler?) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let onProgress, totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// **catbox 主站**上传（永久，需要账号 `userhash`）——2026-09-19 起为**首选**。
///
/// 为什么从 litterbox 切回来：litterbox 的 API 被 Cloudflare 403 拦了
///（本机 2026-09-19 实测多次全 403，浏览器 UA 也一样，正文都到不了上游）；
/// 而 catbox 主站带 userhash 实测正常（2MB / 8MB 上传后下载字节数完全一致）。
/// userhash 存在 `CatboxConfigStore`（设置页「catbox 账号」里填过）。
struct CatboxMainUploadService: UploadService {
    var supportsLocalFiles: Bool { true }

    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        switch item.source {
        case .remote(let url):
            return RemoteMaterial(url: url, duration: item.duration)
        case .local(let fileURL):
            let data = try Data(contentsOf: fileURL)
            let ext = fileURL.pathExtension.lowercased()
            let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
            let name = "\(short).\(ext.isEmpty ? "bin" : ext)"
            let url = try await Self.uploadFile(data: data, filename: name, onProgress: onProgress)
            return RemoteMaterial(url: url, duration: item.duration)
        }
    }

    /// 上传一个文件，返回直链（catbox 主站，**永久**）。没有 userhash 时抛错（由外层切 litterbox）。
    static func uploadFile(data: Data, filename: String, onProgress: UploadProgressHandler? = nil) async throws -> String {
        guard let userhash = CatboxConfigStore.load() else {
            throw UploadError.server("catbox 上传失败：没有配置账号 userhash")
        }
        return try await CatboxUpload.uploadFile(
            data: data,
            filename: filename,
            apiURL: "https://catbox.moe/user/api.php",
            extraFields: [("userhash", userhash)],
            label: "catbox",
            onProgress: onProgress
        )
    }
}

/// **litterbox** 上传服务（catbox 的**临时版**，免账号，72 小时）——现在是**备用**链路。
///
/// ⚠️ 2026-09-19 起它被 Cloudflare 403 拦（见 `CatboxMainUploadService` 的说明），
/// 只在没配 userhash / catbox 主站失败时兜底用。
struct LitterboxUploadService: UploadService {
    var supportsLocalFiles: Bool { true }

    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        switch item.source {
        case .remote(let url):
            return RemoteMaterial(url: url, duration: item.duration)
        case .local(let fileURL):
            let data = try Data(contentsOf: fileURL)
            let ext = fileURL.pathExtension.lowercased()
            let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).lowercased()
            let name = "\(short).\(ext.isEmpty ? "bin" : ext)"
            let url = try await Self.uploadFile(data: data, filename: name, onProgress: onProgress)
            return RemoteMaterial(url: url, duration: item.duration)
        }
    }

    /// 上传一个文件，返回直链（litterbox 临时版，72 小时）
    static func uploadFile(data: Data, filename: String, onProgress: UploadProgressHandler? = nil) async throws -> String {
        try await CatboxUpload.uploadFile(
            data: data,
            filename: filename,
            apiURL: "https://litterbox.catbox.moe/resources/internals/api.php",
            extraFields: [("time", "72h")],
            label: "litterbox",
            onProgress: onProgress
        )
    }
}

/// 主备上传：先用 `primary`（catbox 主站），失败自动换 `backup`（litterbox）。
struct FallbackUploadService: UploadService {
    let primary: any UploadService
    let backup: any UploadService

    var supportsLocalFiles: Bool { primary.supportsLocalFiles || backup.supportsLocalFiles }

    func upload(_ item: ReferenceDraftItem, onProgress: UploadProgressHandler?) async throws -> RemoteMaterial {
        do {
            return try await primary.upload(item, onProgress: onProgress)
        } catch let error as UploadError where error.isVerifyFailure {
            // catbox 偶发"回直链但文件是空的"：先原地重试一次（大概率就好），再切备用
            AppLog.write("upload", "主上传校验失败（\(error.localizedDescription)）→ 原地重试一次")
            do {
                return try await primary.upload(item, onProgress: onProgress)
            } catch {
                AppLog.write("upload", "重试仍失败（\(error.localizedDescription)）→ 切备用")
                return try await backup.upload(item, onProgress: onProgress)
            }
        } catch {
            AppLog.write("upload", "主上传失败（\(error.localizedDescription)）→ 切备用")
            // 切备用后进度会从 0 重来（两个服务的总字节不同，不重来反而会跳）
            return try await backup.upload(item, onProgress: onProgress)
        }
    }
}
