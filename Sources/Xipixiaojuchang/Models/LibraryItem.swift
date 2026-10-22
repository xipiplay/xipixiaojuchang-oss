import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// 素材拖拽的 payload（拖出的是**素材 id**）。
///
/// ## ⚠️ 为什么必须自定义类型，不能用 `String`
/// 提示词编辑器是 `NSTextView`（`PromptEditor`，可编辑），而 **NSTextView 默认就是纯文本的投放目标**。
/// 素材的 payload 原本是 `item.id.uuidString` —— 于是拖素材经过 / 落在提示词框上，
/// 会变成"**往提示词里插进一串 UUID**"，而不是被素材区接收。
///
/// 换成自定义 UTType 之后：**只有素材区认它**，文本视图不认，这个坑从类型上就堵死了。
/// 本项目的拖拽点很少（全项目只有素材库的行 `.draggable`，只有素材区收这个类型），所以换起来影响面很小。
///
/// 类型标识在 `Resources/Info.plist` 的 `UTExportedTypeDeclarations` 里声明（构建时会拷进 bundle）。
struct MaterialTransfer: Transferable, Codable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .xipixiMaterial)
    }
}

extension UTType {
    /// 素材拖拽专用类型。`exportedAs` = 本 App 自己定义、自己消费。
    /// 标识与 `Info.plist` 里的 `UTTypeIdentifier` 必须**逐字一致**，改一个就要改另一个。
    static let xipixiMaterial = UTType(exportedAs: "io.github.xipiplay.xipixiaojuchang.material")
}

/// 素材库条目（全局素材池，拖入即预上传为直链供分镜引用）
struct LibraryItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image, video, audio
    }

    enum UploadState: String, Codable, Sendable {
        case pending      // 待上传
        case uploading    // 上传中
        case uploaded     // 已上传（remoteURL 有效）
        case failed       // 上传失败
    }

    /// 素材来源（区分图片工作区生成的素材与用户导入的素材）
    enum Source: String, Codable, Sendable {
        case userImported    // 用户拖入/导入（视频项目素材）
        case imageGenerated  // 图片生成入库
    }

    let id: UUID
    var kind: Kind
    var localPath: String?       // 本地文件路径（未上传/失败时保留）
    var remoteURL: String?       // 上传后的公网直链
    var uploadState: UploadState
    var fileName: String?
    var name: String?            // 显示名/匹配名（nil = 用文件名去扩展名）
    var duration: Double?        // 音视频时长（秒）
    var projectKey: String?      // 所属项目（素材库按项目隔离）
    var source: Source? = nil    // 来源标记（旧数据为 nil，视为 userImported）
    var imageGenItemID: UUID? = nil    // 来源图片生成条目（追溯）
    var imageGenResultID: UUID? = nil  // 来源图片生成版本（追溯）

    /// 显示名：优先自定义名，否则文件名去扩展名
    var matchName: String {
        if let name, !name.isEmpty { return name }
        if let fileName {
            return (fileName as NSString).deletingPathExtension
        }
        return "未命名"
    }

    /// 素材的分类（角色 / 场景 / 道具）。**两级回退**，缺一不可：
    ///
    /// ① **来源生图条目还在** → 用它的 `type`（权威，`sourceType` 由调用方查表传进来）。
    /// ② **来源条目已被删除** → 退回**按名字前缀判断**。
    ///    ⚠️ 实测这**不是边缘情况**：某个项目 12 条素材里 **11 条的 `imageGenItemID` 是悬空引用**
    ///    （清过生图工作区、但素材库里的条目留着）—— 只认来源的话，三个分类会**全空**，
    ///    看着像功能坏了（用户实测反馈"角色、场景、道具都是空的，都在全部里"）。
    ///    好在入库时就是按「类型-名字」命名的（见 `ImageSubjectType.namePrefix`），
    ///    前缀是 App 自己的约定，可靠。
    /// ③ **都没有**（用户手动拖进来的文件）→ nil，只出现在「全部」里。
    func subjectType(sourceType: ImageSubjectType?) -> ImageSubjectType? {
        if let sourceType { return sourceType }
        for type in ImageSubjectType.allCases where matchName.hasPrefix(type.namePrefix) {
            return type
        }
        return nil
    }

    /// 搜索用文本：显示名 + 原始文件名 + 匹配关键词，三者拼一起。
    ///
    /// 三个都要，因为它们各有用处：`name` 是用户在库里改过的显示名（「丫鬟」）、
    /// `fileName` 是原始文件名（「下载 (1).png」）、`matchKeyword` 是剥掉类型前缀和序号的裸词
    ///（「角色-丫鬟-1」→「丫鬟」）。只匹配其中一个，用户换个记法就搜不到。
    var searchText: String {
        [name, fileName, matchKeyword].compactMap { $0 }.joined(separator: " ")
    }

    /// 本地缩略图 URL：**文件真的还在磁盘上**才返回，否则 nil。
    ///
    /// ⚠️ 不要只看 `localPath` 字段非空就去建 URL —— 那只是个字段，文件可能早被移走或删掉了。
    /// 2026-09-12 实测：素材库 131 张图里 **48 张**的 localPath 指向的文件已不存在
    ///（素材是从 `~/Downloads` 拖进来的，Downloads 被清理过）。
    /// 只看字段 → 拿到一个死 URL → 缩略图**空白**（而且不会自己回落到 `remoteURL`）。
    /// 返回 nil 则各处的「本地 → 远程」回落逻辑才会生效。**统一从这里取，别再各处自己拼 URL。**
    var existingLocalImageURL: URL? {
        guard let localPath, FileManager.default.fileExists(atPath: localPath) else { return nil }
        return URL(fileURLWithPath: localPath)
    }

    /// 匹配关键词：剥离类型前缀与序号（角色-丫鬟-1 → 丫鬟）、去掉残留引号，供提示词匹配用
    var matchKeyword: String {
        if let name, !name.isEmpty {
            for prefix in ["角色-", "场景-", "道具-"] where name.hasPrefix(prefix) {
                var stripped = String(name.dropFirst(prefix.count))
                // 去掉尾部序号（-1、-2…）
                if let dashIndex = stripped.lastIndex(of: "-"), dashIndex > stripped.startIndex,
                   stripped[dashIndex...].dropFirst().allSatisfy(\.isNumber) {
                    stripped = String(stripped[..<dashIndex])
                }
                // 去掉残留引号（旧数据名字可能带「角色-雪娘"」）
                stripped = stripped.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”「」"))
                return stripped
            }
        }
        return matchName
    }

    init(id: UUID = UUID(),
         kind: Kind,
         localPath: String?,
         fileName: String? = nil,
         name: String? = nil,
         duration: Double? = nil,
         projectKey: String? = nil) {
        self.id = id
        self.kind = kind
        self.localPath = localPath
        self.remoteURL = nil
        self.uploadState = .pending
        self.fileName = fileName
        self.name = name
        self.duration = duration
        self.projectKey = projectKey
    }
}
