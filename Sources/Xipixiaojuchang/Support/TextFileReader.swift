import Foundation

/// 读取用户拖入/选择的纯文本文件。
///
/// **为什么单独抽出来**：视频侧「拖 txt 导入分镜」和生图侧「拖 txt 批量解析」都要读文件，
/// 而中文 txt 的编码在现实里**三种都常见** —— UTF-8（macOS 默认）、GBK（Windows 记事本另存）、
/// UTF-16（部分编辑器）。直接用 `String(contentsOf:encoding:.utf8)` 读 GBK 会得到 nil 或乱码。
///
/// 这里跟 `NSString(contentsOf:usedEncoding:)` 交给系统嗅探 —— 它对中文编码的识别相当可靠；
/// 只在嗅探失败时兜底试 UTF-8（系统偶尔对**纯 ASCII 内容**返回失败）。
enum TextFileReader {
    /// 读文本文件；读不出来返回 nil（**不抛错** —— 调用方只需要"成功/失败"两态）。
    static func read(_ url: URL) -> String? {
        var usedEncoding: UInt = 0
        if let text = try? NSString(contentsOf: url, usedEncoding: &usedEncoding) {
            return text as String
        }
        // 兜底：嗅探失败时按 UTF-8 再试一次（纯 ASCII 文件偶发嗅探失败）
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// 从一组拖入的 URL 里挑出**第一个纯文本文件**（`.txt` / `.text`）。
    ///
    /// 拖入多个时只取第一个：批量解析是"一个文件一次"，取多了反而要用户先合并。
    /// 返回 nil = 拖的东西里没有纯文本（调用方应返回 false 让系统显示"不可放置"）。
    static func firstTextFile(in urls: [URL]) -> URL? {
        urls.first { ["txt", "text"].contains($0.pathExtension.lowercased()) }
    }

    /// **把「文件路径文本」还原成文件内容**；不是路径、或读不出来就返回 nil。
    ///
    /// 为什么需要这个：`TextEditor` 底层是 `NSTextView`，它**自己**注册了文件拖放，
    /// 而且优先级高于 SwiftUI 的 `.dropDestination`（2026-09-22 实测：加的 `dropDestination`
    /// 完全不触发，`isTargeted` 也不亮）。它拖入 `.txt` 时插入的是**路径文本**，不是内容。
    ///
    /// 所以不再跟它抢，而是**接住它塞进来的路径**换掉 —— 调用方在 `onChange` 里用这个函数，
    /// 命中就把输入框内容替换成文件正文。
    ///
    /// 🧩 **两个批量解析弹窗共用**（生图 `BatchImageParseView` / 生视频 `BatchShotParseView`）。
    static func loadIfPath(_ text: String) -> String? {
        guard looksLikeTextFilePath(text) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 兼容两种形态：POSIX 路径（Finder 拖拽给的就是这个）和 file:// URL
        let url: URL
        if trimmed.lowercased().hasPrefix("file://") {
            guard let u = URL(string: trimmed) else { return nil }
            url = u
        } else {
            url = URL(fileURLWithPath: trimmed)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }

        return read(url)
    }

    /// 文本是否**看起来像**一个 txt/text 文件的路径（**不检查文件是否存在**）。
    ///
    /// 单独拆出来给调用方区分两种失败：**根本不是路径**（无视即可）vs
    /// **是路径但读不出来**（要提示用户，否则他对着输入框里一行路径不知道发生了什么）。
    ///
    /// 判定**从严**（单行、长度有限、以 `/` 开头、扩展名 txt/text），
    /// 免得误伤"用户真心想粘贴一段路径文本"的情况。
    static func looksLikeTextFilePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 1024,
              !trimmed.contains("\n"), !trimmed.contains("\r") else { return false }

        let path: String
        if trimmed.lowercased().hasPrefix("file://") {
            guard let u = URL(string: trimmed), !u.path.isEmpty else { return false }
            path = u.path
        } else {
            path = trimmed
        }

        guard path.hasPrefix("/") else { return false }
        return ["txt", "text"].contains((path as NSString).pathExtension.lowercased())
    }
}
