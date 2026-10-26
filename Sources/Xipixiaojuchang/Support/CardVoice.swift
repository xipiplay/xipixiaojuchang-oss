import Foundation

/// 角色卡的音色（2026-10-26 用户：音色和参考图一样绑在这个形象上，给生视频「全能参考」用）。
///
/// 存在卡上：`voiceAudioID`（素材库里的一段音频）、`voiceText`（文字描述）、`voiceMode`（用哪一种）。
/// 每张卡只管自己的——「周承山（四十岁）」是另一个形象，没绑就是没有，**不沿用**别的卡。只给生视频用，不传给生图模型。
enum CardVoice {
    /// 生视频时用的音色：音频或文字，二选一
    enum Resolved: Equatable {
        case audio(LibraryItem)
        case text(String)
    }

    /// 文字描述的统一写法：去掉首尾空白；空的算没有
    static func normalizedText(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 绑着的音频（已从素材库删掉的、不是音频的不算）
    static func audio(of card: ImageGenItem, library: (UUID) -> LibraryItem?) -> LibraryItem? {
        card.voiceAudioID.flatMap(library).flatMap { $0.kind == .audio ? $0 : nil }
    }

    /// 现在选的是哪一种：选过就按选的；没选过 = 有音频用音频，否则用文字
    static func mode(of card: ImageGenItem) -> VoiceMode {
        card.voiceMode ?? (card.voiceAudioID != nil ? .audio : .text)
    }

    /// 这张卡生视频时用的音色：选的那一种有内容才算；只有角色卡有
    static func resolve(_ card: ImageGenItem, library: (UUID) -> LibraryItem?) -> Resolved? {
        guard card.type == .character else { return nil }
        switch mode(of: card) {
        case .audio: return audio(of: card, library: library).map(Resolved.audio)
        case .text: return normalizedText(card.voiceText).map(Resolved.text)
        }
    }
}
