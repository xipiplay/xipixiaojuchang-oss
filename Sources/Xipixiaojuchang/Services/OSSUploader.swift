import Foundation
import CCommonCrypto

/// 阿里云 OSS 直传（REST PUT Object，V1 签名 HMAC-SHA1）
enum OSSUploader {
    /// ⚠️ **上传必须带 `x-oss-object-acl: public-read`**（2026-09-19 修）：
    /// 不带的话对象继承 bucket 默认 ACL = **私有** → 上游服务商拉参考图时 403
    /// （实测报错：`Input material could not be downloaded (HTTP 403)`；
    /// 匿名 GET 回 `AccessDenied ... because of bucket acl`）。
    /// 该 header 是 `x-oss-*` 规范头，**必须按小写、排序后进 V1 签名的 CanonicalizedOSSHeaders**，
    /// 漏签会 `SignatureDoesNotMatch`。
    static func upload(data: Data, key: String, contentType: String, config: OSSConfig) async throws -> URL {
        let bucket = config.bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        var endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = endpoint.replacingOccurrences(of: "https://", with: "")
        endpoint = endpoint.replacingOccurrences(of: "http://", with: "")
        endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let date = rfc1123Date()
        let canonicalizedOSSHeaders = "x-oss-object-acl:public-read\n"
        let canonicalizedResource = "/\(bucket)/\(key)"
        let stringToSign = "PUT\n\n\(contentType)\n\(date)\n\(canonicalizedOSSHeaders)\(canonicalizedResource)"
        let signature = hmacSHA1(key: config.accessKeySecret, message: stringToSign).base64EncodedString()
        let authorization = "OSS \(config.accessKeyId):\(signature)"

        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(bucket).\(endpoint)"
        components.path = "/" + key
        guard let url = components.url else {
            throw OSSUploadError.invalidEndpoint(endpoint: endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(date, forHTTPHeaderField: "Date")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("public-read", forHTTPHeaderField: "x-oss-object-acl")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OSSUploadError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw OSSUploadError.http(status: http.statusCode, body: body)
        }
        return url
    }

    /// 这个对象现在**能不能被匿名访问**（HEAD 200 = 可以）。
    /// 用途：提交前复用库里已有的 OSS 直链时先验一下 —— 2026-09-19 之前上传的对象是私有的，
    /// 直接复用会让上游 403（用户实测报错）。HEAD 对 OSS 返回真实状态，可靠。
    static func isPubliclyReadable(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private static func rfc1123Date(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    private static func hmacSHA1(key: String, message: String) -> Data {
        let keyData = Data(key.utf8)
        let messageData = Data(message.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            messageData.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress, keyData.count,
                    messageBytes.baseAddress, messageData.count,
                    &digest
                )
            }
        }
        return Data(digest)
    }
}

enum OSSUploadError: LocalizedError {
    case invalidEndpoint(endpoint: String)
    case transport(String)
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Endpoint 格式不对（当前「\(endpoint)」）。Endpoint 只需填域名，如 oss-cn-qingdao.aliyuncs.com，不要带 https://"
        case .transport(let message):
            return "上传失败：\(message)"
        case .http(let status, let body):
            return "上传被拒绝（HTTP \(status)）：\(Self.parseOSSBody(body))"
        }
    }

    /// 从 OSS 的 XML 错误里抽出 Code 和 Message，并给出中文提示
    private static func parseOSSBody(_ body: String) -> String {
        let code = extractTag("Code", in: body)
        let message = extractTag("Message", in: body)
        let endpoint = extractTag("Endpoint", in: body)
        var parts: [String] = []
        if let code { parts.append(code) }
        if let message { parts.append(message) }
        let base: String = parts.isEmpty ? String(body.prefix(300)) : parts.joined(separator: "：")

        // 地域不匹配：OSS 会返回桶真实所在的地域节点
        let isEndpointMismatch = (message?.contains("specified endpoint") == true)
            || (message?.contains("must be addressed") == true)
        if isEndpointMismatch {
            if let endpoint {
                return "\(base) —— 你的桶不在这个地域，正确 Endpoint 是「\(endpoint)」，请把它填到 Endpoint 字段"
            }
            return "\(base) —— 桶实际地域与 Endpoint 不一致，请到 OSS 控制台核对桶所在「地域」"
        }

        let hint: String?
        switch code {
        case "AccessDenied":
            hint = "没有上传权限——请确认给 RAM 用户授予了「AliyunOSSFullAccess」权限"
        case "InvalidAccessKeyId":
            hint = "AccessKey ID 不对或不存在，请检查是否复制完整"
        case "SignatureDoesNotMatch":
            hint = "签名不匹配——通常是 AccessKey Secret 复制错了，或多了空格/换行"
        default:
            hint = nil
        }
        if let hint { return "\(base)（\(hint)）" }
        return base
    }

    private static func extractTag(_ tag: String, in xml: String) -> String? {
        let pattern = "<\(tag)>([^<]*)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, range: nsRange),
              let range = Range(match.range(at: 1), in: xml) else { return nil }
        return String(xml[range])
    }
}
