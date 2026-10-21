import Foundation

/// 素材名里的「第 N 集的」版本前缀（2026-10-09）。
///
/// 提取提示词要求同一个人 / 地方 / 物品**形象发生变化时**另出一条，名称前加「第 N 集的」：
/// `第1集的沈惊澜`、`第8集的沈惊澜` 是同一个角色的两个版本，**从第 N 集起生效，直到出现集号更高的同名版本**。
/// 分割 / 分镜里写的是不带前缀的名字（`沈惊澜`），所以匹配素材时：
/// - 用**基础名**（去掉前缀）去提示词里找；
/// - 同一个基础名有多个版本时，按分镜的集号选版本（`pick`），而不是谁先出现用谁。
/// 没有前缀的素材（手动建的、旧格式）当作「全程有效」，集号记 0。
enum AssetVersionName {
    struct Parsed: Equatable {
        /// 这个版本从第几集起生效
        let episode: Int
        /// 去掉「第 N 集的」之后的名字
        let base: String
    }

    // 数字：阿拉伯 / 全角 / 中文（零〇一二两三四五六七八九十百）；「的」必须有，免得把「第一集团」之类的名字误拆
    nonisolated(unsafe) private static let regex = try! NSRegularExpression(
        pattern: #"^\s*第\s*([0-9０-９零〇一二两三四五六七八九十百]+)\s*集\s*的\s*(\S.*?)\s*$"#)

    /// 拆「第N集的X」。不是这个格式 → nil
    static func parse(_ name: String) -> Parsed? {
        // 绝大多数名字没有「第N集的」前缀：先用便宜的字符串查找挡掉，不跑正则（匹配、状态、分段卡片每秒要认成千上万次名字）
        guard name.contains("第"), name.contains("集"), name.contains("的") else { return nil }
        let ns = name as NSString
        guard let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              let episode = number(ns.substring(with: m.range(at: 1))), episode > 0 else { return nil }
        return Parsed(episode: episode, base: ns.substring(with: m.range(at: 2)))
    }

    /// 基础名：有前缀就去掉，没有就原样
    static func baseName(_ name: String) -> String { parse(name)?.base ?? name }

    /// 重名时软件自动加的序号（`ImageCardNaming.unique`：「周承山」→「周承山 2」）：末尾一个空格 + 一位数字 2~9。
    /// 只认一位数——「iPhone 15」「3号 12」这类真名字不能被当成序号。
    static func duplicateNumber(_ name: String) -> Int? {
        let chars = Array(name)
        guard chars.count >= 3, let last = chars.last, last.isASCII, let value = last.wholeNumberValue, (2...9).contains(value),
              chars[chars.count - 2] == " " else { return nil }
        return value
    }

    /// 另一个名字（卡片名 / 素材库关键词）和 `name` 是什么关系：
    /// 2 = 名字一模一样（去掉「第N集的」前缀之后）；1 = 同一个名字，只差在重名时软件自动加的序号上（「周承山 2」是「周承山」又提取一次的卡）；0 = 不相干。
    static func match(_ other: String, to name: String) -> Int {
        let base = baseName(other)
        if base == name { return 2 }
        return withoutDuplicateNumber(base) == withoutDuplicateNumber(name) ? 1 : 0
    }

    /// 去掉重名序号：「周承山 2」→「周承山」；没有序号就原样
    static func withoutDuplicateNumber(_ name: String) -> String {
        guard duplicateNumber(name) != nil else { return name }
        return String(name.dropLast(2))
    }

    /// 同一个基础名的多个版本里选哪个：返回 `versions`（各版本的起效集号，没有前缀的记 0）里被选中的**下标**。
    /// - 给了集号：只在**起效集号不大于它**的版本里取最大的一版；**没有这样的版本就返回 nil（不匹配）**。
    ///   ⚠️ 不能退回去取「最早的一版」（2026-10-09 用户实测：第 2 集的分镜头行写「周承山」，素材库里基础名恰好叫「周承山」的只有
    ///   第24 / 30 / 45 集的变化版——第一次出现的卡叫「周承山四十岁时期」——兜底取最早，就把 22 集之后才出现的变化版挂到第 2 集上了）。
    ///   提取是按集走的，首次出现的卡一定不晚于用到它的分镜，所以「比所有版本都早」只会是名字对不上，该留给人手动换，不该猜。
    /// - 没给集号（手动建的分镜不知道是第几集）：取最早的一版，也就是基础形象。
    /// 集号相同的（比如同一张卡入库过好几次）取靠前的。
    static func pick(versions: [Int], episode: Int?) -> Int? {
        guard !versions.isEmpty else { return nil }
        if let episode {
            return versions.indices.filter { versions[$0] <= episode }
                .max(by: { versions[$0] < versions[$1] || (versions[$0] == versions[$1] && $0 > $1) })
        }
        return versions.indices.min(by: { versions[$0] < versions[$1] || (versions[$0] == versions[$1] && $0 < $1) })
    }

    /// 「8」「８」「八」「十二」「二十」「一百零五」→ 数字；认不出 → nil
    static func number(_ text: String) -> Int? {
        let ascii = String(text.unicodeScalars.map { s -> Character in
            (0xFF10...0xFF19).contains(s.value) ? Character(UnicodeScalar(s.value - 0xFF10 + 0x30)!) : Character(s)
        })
        if let value = Int(ascii) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                        "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0, current = 0
        for ch in text {
            if let d = digits[ch] { current = d }
            else if ch == "十" { total += (current == 0 ? 1 : current) * 10; current = 0 }
            else if ch == "百" { total += (current == 0 ? 1 : current) * 100; current = 0 }
            else { return nil }
        }
        total += current
        return total > 0 ? total : nil
    }
}
