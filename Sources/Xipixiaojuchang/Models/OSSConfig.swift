import Foundation

/// 阿里云 OSS 上传配置
struct OSSConfig: Equatable, Sendable {
    var accessKeyId: String
    var accessKeySecret: String
    var bucket: String
    var endpoint: String   // 如 oss-cn-qingdao.aliyuncs.com

    var isValid: Bool {
        !accessKeyId.isEmpty && !accessKeySecret.isEmpty && !bucket.isEmpty && !endpoint.isEmpty
    }
}

enum OSSConfigStore {
    private static let kAK = "ossAccessKeyId"
    private static let kSK = "ossAccessKeySecret"
    private static let kBucket = "ossBucket"
    private static let kEndpoint = "ossEndpoint"

    static func load() -> OSSConfig? {
        let defaults = UserDefaults.standard
        guard let ak = defaults.string(forKey: kAK), !ak.isEmpty,
              let sk = defaults.string(forKey: kSK), !sk.isEmpty,
              let bucket = defaults.string(forKey: kBucket), !bucket.isEmpty,
              let endpoint = defaults.string(forKey: kEndpoint), !endpoint.isEmpty else {
            return nil
        }
        return OSSConfig(accessKeyId: ak, accessKeySecret: sk, bucket: bucket, endpoint: endpoint)
    }

    static func save(_ config: OSSConfig) {
        let defaults = UserDefaults.standard
        defaults.set(config.accessKeyId, forKey: kAK)
        defaults.set(config.accessKeySecret, forKey: kSK)
        defaults.set(config.bucket, forKey: kBucket)
        defaults.set(config.endpoint, forKey: kEndpoint)
    }

    /// 是否启用 OSS 作为**兜底**（2026-09-18 用户要求加开关；默认开，保持原行为）。
    /// 关掉后：catbox 失败也不回退到 OSS（避免产生费用）。
    static var isEnabled: Bool {
        get {
            // 没存过 → 默认 true（老用户行为不变）
            if UserDefaults.standard.object(forKey: kEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: kEnabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: kEnabled) }
    }

    private static let kEnabled = "ossEnabled"

    static func delete() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: kAK)
        defaults.removeObject(forKey: kSK)
        defaults.removeObject(forKey: kBucket)
        defaults.removeObject(forKey: kEndpoint)
    }
}


/// catbox 账号的 userhash（2026-09-18 用户注册账号后提供）。
/// 有它 → 走 catbox 主站**永久**上传；没有 → 退回 litterbox 临时上传（72h）。
/// **素材上传位置**（2026-09-19 用户要求）：设置页上传区二选一 ——
/// 「开哪个，素材就传到哪里」（包括提交前需要补传的素材、一键重传）。
/// · freeHost = catbox 主站 → litterbox（默认，免配置）
/// · oss      = 阿里云 OSS（public-read）——上游拉不到 catbox 时切它
enum MaterialUploadHost: String {
    case freeHost
    case oss
}

enum MaterialUploadHostStore {
    private static let kHost = "materialUploadHost"

    static func load() -> MaterialUploadHost {
        MaterialUploadHost(rawValue: UserDefaults.standard.string(forKey: kHost) ?? "") ?? .freeHost
    }

    static func save(_ host: MaterialUploadHost) {
        UserDefaults.standard.set(host.rawValue, forKey: kHost)
    }
}

enum CatboxConfigStore {
    private static let kHash = "catboxUserhash"

    static func load() -> String? {
        let v = UserDefaults.standard.string(forKey: kHash)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty == false) ? v : nil
    }

    static func save(_ hash: String) {
        let v = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(v, forKey: kHash)
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: kHash)
    }
}
