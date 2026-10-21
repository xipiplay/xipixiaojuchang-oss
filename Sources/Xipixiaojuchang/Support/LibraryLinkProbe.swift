import Foundation

/// 素材库链接检查的单个链接判定（2026-10-09）。
///
/// 用户：「批量入库之后点检查链接，出现很多失效，但素材其实已经上传成功了」。原来的问题：
/// ① 还没传完（没有直链）的素材也被算成失效；② 失效标记存下来就不会消；
/// ③ 网络抖动 / 被限流（429）/ 服务器临时 5xx 一律当成失效，不重试、不记原因。
/// 所以判定分三种：**确定可用 / 确定失效 / 没能确认**——只有「确定失效」才会标红，没能确认的不标，免得误报。
enum LinkVerdict: Equatable {
    case alive
    /// 确定失效（404 / 410 / 其他 4xx / 200 但 0 字节）
    case dead(String)
    /// 多次尝试仍没拿到明确答复（超时 / 断网 / 429 / 5xx）：不标失效
    case unsure(String)
}

enum LibraryLinkProbe {
    /// 临时性问题的重试间隔（第 1 次失败后等 1 秒、第 2 次失败后等 2 秒，再试最后一次；一共最多 3 次）
    static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(2)]

    static func verdict(for urlString: String?, session: URLSession? = nil,
                        retryDelays: [Duration] = defaultRetryDelays) async -> LinkVerdict {
        guard let urlString, let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            return .dead("没有可用的直链")
        }
        let session = session ?? URLSession(configuration: .ephemeral)
        var lastReason = ""
        for attempt in 0...retryDelays.count {
            switch await probeOnce(url, session) {
            case .alive: return .alive
            case .dead(let reason): return .dead(reason)
            case .unsure(let reason):
                lastReason = reason
                if attempt < retryDelays.count { try? await Task.sleep(for: retryDelays[attempt]) }
            }
        }
        return .unsure(lastReason)
    }

    /// 试一次：HEAD；HEAD 回 200 但长度 0（catbox 的 nginx 对 HEAD 一律回 0）/ 403 / 405 → 退回带 Range 的 GET 复核
    private static func probeOnce(_ url: URL, _ session: URLSession) async -> LinkVerdict {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) } catch { return .unsure(describe(error)) }
        guard let http = response as? HTTPURLResponse else { return .unsure("响应不是 HTTP") }
        switch http.statusCode {
        case 200:
            return http.expectedContentLength != 0 ? .alive : await rangedGet(session, request)
        case 403, 405:
            return await rangedGet(session, request)
        default:
            return classify(status: http.statusCode)
        }
    }

    /// 带 `Range: bytes=0-0` 的 GET：只看响应头，不等正文（拿到头就取消，防止不支持 Range 的服务器把整张图下下来）
    private static func rangedGet(_ session: URLSession, _ request: URLRequest) async -> LinkVerdict {
        var get = request
        get.httpMethod = "GET"
        get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: get)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { return .unsure("响应不是 HTTP") }
            guard (200..<300).contains(http.statusCode) else { return classify(status: http.statusCode) }
            // 206 优先看 Content-Range 的总长（形如 "bytes 0-0/2005963"）；没有就退回 Content-Length
            if let range = http.value(forHTTPHeaderField: "Content-Range"),
               let total = range.split(separator: "/").last, let n = Int(total) {
                return n > 0 ? .alive : .dead("文件是空的（0 字节）")
            }
            return http.expectedContentLength != 0 ? .alive : .dead("文件是空的（0 字节）")
        } catch {
            return .unsure(describe(error))
        }
    }

    /// 状态码 → 判定：限流 / 服务器临时出错是「没能确认」，其余非 2xx 是「确定失效」
    static func classify(status: Int) -> LinkVerdict {
        switch status {
        case 408, 425, 429, 500, 502, 503, 504: return .unsure("HTTP \(status)（对方限流或临时出错）")
        case 404, 410: return .dead("HTTP \(status)（文件已经不存在）")
        default: return .dead("HTTP \(status)")
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain ? "网络错误 \(nsError.code)（\(nsError.localizedDescription)）" : error.localizedDescription
    }
}
