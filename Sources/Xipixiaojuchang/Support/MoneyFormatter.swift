import Foundation

enum MoneyFormatter {
    /// 分 → 元字符串：18 → "0.18"、90 → "0.90"
    static func yuanString(fen: Int) -> String {
        String(format: "%d.%02d", Int32(fen / 100), Int32(abs(fen % 100)))
    }

    /// 费用文案：90 → "¥0.90"
    static func costText(fen: Int) -> String { "¥" + yuanString(fen: fen) }
}
