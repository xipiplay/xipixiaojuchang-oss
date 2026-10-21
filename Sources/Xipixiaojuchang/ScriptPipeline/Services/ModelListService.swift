import Foundation

/// 「获取模型」（2026-10-11）：向文字服务商要它的模型列表，设置里从列表里选，不用手输模型名。
/// OpenAI 兼容的服务商都有 `GET {地址}/v1/models`（NVIDIA、DeepSeek 都有）；没有这个接口的中转站，设置里保留手动输入作为备用。
enum ModelListService {
    /// 模型列表的地址。地址已经写到 `/v1` 的只补 `/models`；写成完整的 `…/chat/completions` 的先去掉这一截
    static func endpoint(for baseURL: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        while base.hasSuffix("/") { base.removeLast() }
        let path = base.hasSuffix("/models") ? base : base + (base.hasSuffix("/v1") ? "/models" : "/v1/models")
        guard let url = URL(string: path), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw PipelineAIError.invalidURL(baseURL)
        }
        return url
    }

    /// 从回答里取出模型名：OpenAI 的 `{"data":[{"id":…}]}`；也认 `{"models":[…]}` 和直接一个数组。去重、按名字排
    static func parse(_ data: Data) -> [String] {
        let object = try? JSONSerialization.jsonObject(with: data)
        var entries: [Any] = []
        if let dictionary = object as? [String: Any] {
            entries = (dictionary["data"] as? [Any]) ?? (dictionary["models"] as? [Any]) ?? []
        } else if let array = object as? [Any] {
            entries = array
        }
        var seen = Set<String>()
        var names: [String] = []
        for entry in entries {
            var raw: String?
            if let text = entry as? String {
                raw = text
            } else if let item = entry as? [String: Any] {
                raw = (item["id"] as? String) ?? (item["name"] as? String)
            }
            guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            if name.hasPrefix("models/") { name.removeFirst("models/".count) }       // 有的兼容接口带这个前缀
            if seen.insert(name).inserted { names.append(name) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// 向服务商要模型列表。服务商返回错误就把状态码和回复带出来；一个模型都没有也算失败（说明地址 / Key 多半不对）
    static func fetch(baseURL: String, apiKey: String, session: URLSession = PipelineAIService.defaultSession) async throws -> [String] {
        var request = URLRequest(url: try endpoint(for: baseURL))
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PipelineAIError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw PipelineAIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let names = parse(data)
        guard !names.isEmpty else { throw PipelineAIError.invalidResult("服务商没有返回模型列表（地址或 Key 可能不对，或者它没有这个接口）") }
        return names
    }
}
