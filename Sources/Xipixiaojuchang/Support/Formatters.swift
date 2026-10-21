import Foundation

enum Formatters {
    static let taskDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    /// 秒数 → 「5 秒」「3.5 秒」
    static func durationText(_ seconds: Double) -> String {
        if seconds == seconds.rounded() {
            return "\(Int(seconds)) 秒"
        }
        return String(format: "%.1f 秒", seconds)
    }

    /// 把错误原文压成**给人看的摘要**（任务行 / 分镜卡片用）。
    ///
    /// 服务商返回的原文常常是「中文前缀 + 一整段 JSON」：
    /// ```
    /// 请求失败（HTTP 503）：{"code":"fail_to_fetch_task","message":"系统升级中，暂停任务提交","data":null}
    /// ```
    /// 直接显示没法看 —— 这里把 JSON 里的 `message` 抠出来，并把 HTTP 码并到末尾：
    /// ```
    /// 系统升级中，暂停任务提交（HTTP 503）
    /// ```
    ///
    /// 抠不到就**原样返回**（纯文本错误很常见：内容审核未通过 / 未配置模型 / 下载失败…）。
    /// **不做截断** —— 截断交给调用方（任务行 2 行、卡片 2 行）。
    static func errorSummary(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }

        // HTTP 码：从「（HTTP 503）」里抠出来并到摘要末尾（半角括号也认）
        // ⚠️ 这里**用拼接、不用字符串插值**：`\(…)` 后面紧跟全角 `）` 时编译器会解析失败
        //（实测报 "cannot find ')' to match opening '(' in string interpolation"）
        var httpTag = ""
        if let r = text.range(of: #"[（(]HTTP ?\d{3}[）)]"#, options: .regularExpression) {
            let code = text[r].filter { $0.isNumber }
            httpTag = "（HTTP " + code + "）"
        }

        // JSON 一定拼在字符串尾部。没有 `{`、或解析不出来 → 原样返回。
        guard let brace = text.firstIndex(of: "{"),
              let data = String(text[brace...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = firstMessage(in: obj) else {
            return text
        }
        return message + httpTag
    }

    /// 按优先级找一条「人话」：`message` → `error.message` → `error`（字符串形式）
    private static func firstMessage(in obj: [String: Any]) -> String? {
        if let s = obj["message"] as? String, !s.isEmpty { return s }
        if let err = obj["error"] as? [String: Any],
           let s = err["message"] as? String, !s.isEmpty { return s }
        if let s = obj["error"] as? String, !s.isEmpty { return s }
        return nil
    }
}
