import Foundation

/// 分辨率档位（视频参数区用）。
///
/// 旧数据里 `WanModel` 还带分辨率、能力、系列等矩阵，本批已全部退场；
/// 仅保留 `Resolution` 这个仍被 `ShotDraft` / `LocalTask` / 参数区使用的基础类型。
enum Resolution: String, CaseIterable, Codable, Sendable {
    case p480, p720, p768, p1080, p4k

    var displayName: String {
        switch self {
        case .p480: "480P"
        case .p720: "720P"
        case .p768: "768P"
        case .p1080: "1080P"
        case .p4k: "4K"
        }
    }

    /// OpenAI 规范 `/v1/videos` 的 `resolution_name` 值（如 "480p"）。
    var apiValue: String {
        switch self {
        case .p480: "480p"
        case .p720: "720p"
        case .p768: "768p"
        case .p1080: "1080p"
        case .p4k: "4k"
        }
    }
}
